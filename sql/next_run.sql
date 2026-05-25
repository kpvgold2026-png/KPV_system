-- ============================================================
-- next_run.sql — Round 7.4 (2026-05-25)
-- ============================================================
-- 1) ALTER cashbank ADD COLUMN rate (idempotent)
-- 2) get_stock_move_detail — รวม items + value/g + value/baht
--                            + WAC/g + WAC/baht + payments (FX rate)
-- 3) add_cashbank_entry — เพิ่ม p_rate (FX rate, default 1)
-- ============================================================


-- ============================================================
-- 1) cashbank.rate — เก็บ FX rate ต่อแถว
-- ============================================================
ALTER TABLE cashbank ADD COLUMN IF NOT EXISTS rate NUMERIC NOT NULL DEFAULT 1;

COMMENT ON COLUMN cashbank.rate IS
  'FX rate at entry time. amount×rate = LAK equivalent. LAK rows = 1.';


-- ============================================================
-- 2) get_stock_move_detail — รายละเอียดเต็มสำหรับ View Detail
--    คืน: ref_id, gold_type, type, direction, gold_g, price,
--          wac_per_g, wac_per_baht, price_per_g, price_per_baht,
--          items[], payments[], note
--    หมาย: TRANSFER ref_id มี 2 rows (OLD/OUT + NEW/IN) → ใช้ p_gold_type
--          กรอง; default = พิจารณา NEW/IN ก่อน OUT
-- ============================================================
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text);
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text, text);

CREATE OR REPLACE FUNCTION public.get_stock_move_detail(
  p_ref_id TEXT,
  p_gold_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_move RECORD;
  v_items JSONB;
  v_payments JSONB;
  v_price_per_g NUMERIC := 0;
  v_price_per_baht NUMERIC := 0;
  v_wac_per_g NUMERIC := 0;
  v_wac_per_baht NUMERIC := 0;
BEGIN
  -- เลือก row หลัก: ถ้ามี p_gold_type → ใช้ตรง ๆ; ไม่มี → priority IN > OUT
  SELECT sm.id, sm.ref_id, sm.gold_type, sm.type, sm.direction,
         sm.gold_g, sm.price, sm.wac_per_g, sm.wac_per_baht,
         sm.date, sm.note
    INTO v_move
    FROM stock_moves sm
    WHERE sm.ref_id = p_ref_id
      AND (p_gold_type IS NULL OR sm.gold_type::text = p_gold_type)
    ORDER BY CASE WHEN sm.direction = 'IN' THEN 0 ELSE 1 END,
             sm.date ASC
    LIMIT 1;

  IF v_move.id IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  -- items (กับชื่อสินค้า)
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object('productId', smi.product_id, 'qty', smi.qty)
           ORDER BY smi.product_id
         ), '[]'::jsonb)
    INTO v_items
    FROM stock_move_items smi
    WHERE smi.move_id = v_move.id;

  -- per-unit derived
  IF v_move.gold_g > 0 THEN
    v_price_per_g := COALESCE(v_move.price, 0) / v_move.gold_g;
    v_price_per_baht := v_price_per_g * 15;
  END IF;
  v_wac_per_g := COALESCE(v_move.wac_per_g, 0);
  v_wac_per_baht := COALESCE(v_move.wac_per_baht, v_wac_per_g * 15);

  -- payments (cashbank row ที่ผูกกับ ref_id นี้)
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'type', cb.type,
             'method', cb.method,
             'bank', COALESCE(b.name, ''),
             'currency', cb.currency,
             'amount', cb.amount,
             'rate', COALESCE(cb.rate, 1),
             'lak', cb.amount * COALESCE(cb.rate, 1)
           )
           ORDER BY cb.date ASC, cb.id ASC
         ), '[]'::jsonb)
    INTO v_payments
    FROM cashbank cb
    LEFT JOIN banks b ON b.id = cb.bank_id
    WHERE cb.ref_tx_id = p_ref_id;

  RETURN jsonb_build_object(
    'found', true,
    'ref_id', v_move.ref_id,
    'gold_type', v_move.gold_type,
    'type', v_move.type,
    'direction', v_move.direction,
    'gold_g', v_move.gold_g,
    'price', v_move.price,
    'price_per_g', v_price_per_g,
    'price_per_baht', v_price_per_baht,
    'wac_per_g', v_wac_per_g,
    'wac_per_baht', v_wac_per_baht,
    'date', v_move.date,
    'note', v_move.note,
    'items', v_items,
    'payments', v_payments
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_move_detail(text, text) TO authenticated;


-- ============================================================
-- 3) add_cashbank_entry — เพิ่ม p_rate (FX rate)
--    ถ้า p_currency = 'LAK' บังคับ rate = 1
-- ============================================================
DROP FUNCTION IF EXISTS public.add_cashbank_entry(text, numeric, text, text, text, text);
DROP FUNCTION IF EXISTS public.add_cashbank_entry(text, numeric, text, text, text, text, numeric);

CREATE OR REPLACE FUNCTION public.add_cashbank_entry(
  p_type TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_method TEXT,
  p_bank_name TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL,
  p_rate NUMERIC DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_user_id UUID;
  v_id TEXT;
  v_bank_id UUID;
  v_rate NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Auth required');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Amount must be > 0');
  END IF;

  -- LAK บังคับ rate = 1; foreign currency ต้อง rate > 0
  IF UPPER(p_currency) = 'LAK' THEN
    v_rate := 1;
  ELSE
    v_rate := COALESCE(p_rate, 0);
    IF v_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
              'Rate ต้อง > 0 สำหรับสกุล ' || p_currency);
    END IF;
  END IF;

  IF p_method = 'BANK' AND p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    SELECT id INTO v_bank_id FROM banks WHERE name = p_bank_name LIMIT 1;
  END IF;

  v_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(random()::text), 1, 4);

  INSERT INTO cashbank (id, type, amount, currency, rate, method,
                        bank_id, ref_tx_id, note, date)
  VALUES (v_id, p_type, p_amount, p_currency, v_rate, p_method,
          v_bank_id, NULL, p_note, NOW());

  RETURN jsonb_build_object(
    'success', true,
    'id', v_id,
    'lak', p_amount * v_rate
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.add_cashbank_entry(text, numeric, text, text, text, text, numeric) TO authenticated;


-- ============================================================
-- ทดสอบหลังรัน
-- ============================================================
--   -- ตรวจ column ใหม่
--   SELECT column_name, data_type, column_default
--   FROM information_schema.columns
--   WHERE table_name = 'cashbank' AND column_name = 'rate';
--
--   -- get_stock_move_detail
--   SELECT get_stock_move_detail('CLOSE-Close_Na-20260524');
--   SELECT get_stock_move_detail('TRF-...', 'NEW');
--   SELECT get_stock_move_detail('TRF-...', 'OLD');
--
--   -- add_cashbank_entry กับ rate
--   SELECT add_cashbank_entry('OTHER_INCOME', 1000, 'THB', 'CASH',
--                              NULL, 'test', 685);
--   -- ควรเห็น lak = 685,000 ใน response
