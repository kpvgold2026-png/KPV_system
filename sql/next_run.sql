-- ============================================================
-- KPV — Round 11 + 11.1 (2026-07-06)  [เขียนทับ next_run.sql เดิม — รัน idempotent ได้]
-- Round 11.1 (เพิ่มจาก R11 — user ยังไม่ได้รัน R11 รันไฟล์นี้ครั้งเดียวได้ครบ):
--  L1) Lot tracking ทองเก่า (FIFO): ตาราง old_gold_lots + backfill เปิดยอดจาก WAC
--      + _consume_old_lots + transfer_old_to_new_tx / stock_out_old_tx ตัดต้นทุนตาม lot จริง
--      + approve_close_report สร้าง lot ตอนทองเก่าเข้าสต๊อก (cost = sell_1baht ของ tx ต้นทาง)
--  L2) transfer_user_cash_to_shop — เช็คเงินในกระเป๋าพอฝั่ง server ก่อนโอน
--  L3) get_close_cashbook — คืนยอดคงเหลือสะสมทั้งกระเป๋า (= ยอดที่ approve จะกวาดจริง)
--  L4) นับ PARTIAL ใน sales_breakdown + dashboard (ให้ตรงกับตารางฝั่ง JS)
--  L5) _diff_sell_price — สินค้านอก G01–G07 คิดจาก weight_baht × ราคาขาย 1 บาท (เดิมคืน 0 เงียบๆ)
-- แก้ตามผล audit ทั้งระบบ:
--   1) confirm_sell/tradein/exchange/withdraw_tx → multi-payment (p_payments JSONB)
--      + FOR UPDATE กันยืนยันซ้ำ + เช็คสต๊อกก่อนตัด + หักเงินทอนออกจาก ledger
--   2) confirm_buyback_tx → แปลงยอดเป็น LAK ด้วยเรทรับซื้อ + ตัด fee ทิ้ง + lock
--   3) stock_out_old_tx → ตัดมูลค่า (old_value) ด้วย WAC เดียวกับ transfer + lock
--   4) TZ Asia/Bangkok ครบทุกจุด (sales_breakdown, wealth, recompute_diffs)
--   5) เปิด/ปิดกะกันซ้ำฝั่ง server + approve กันซ้ำ + cancel_pending_close (RPC ใหม่)
--   6) Diff ไม่นับ BUYBACK (get_diff_summary.total, get_dashboard_data.pl_diff)
--   7) create_exchange_tx validate บิล Free-Ex ฝั่ง server
--   8) role check: add_cashbank_entry, get_close_cashbook, open_shift
--   9) stock_in_new_tx ตัด fee ทิ้ง + ธนาคารไม่พบชื่อ → สร้างให้อัตโนมัติ
--  10) delete_tx บล็อค COMPLETED และ PARTIAL
-- ============================================================


-- ============================================================
-- 0) enum ใหม่: cashbank_type 'CHANGE' (รายการหักเงินทอน)
--    (ใช้ตอน runtime เท่านั้น — ADD VALUE ใน transaction ได้)
-- ============================================================
ALTER TYPE cashbank_type ADD VALUE IF NOT EXISTS 'CHANGE';


-- ============================================================
-- L1.1) ตาราง lot ทองเก่า (FIFO ต้นทุนจริง)
--   1 lot = ทองเก่า 1 กลุ่ม (product × ราคารับซื้อ) ที่เข้าสต๊อกพร้อมกัน
--   เข้า: approve_close_report (materialize) / ออก: transfer, stock_out (FIFO เก่าสุดก่อน)
--   client อ่านได้อย่างเดียว — เขียนผ่าน RPC (SECURITY DEFINER) เท่านั้น
-- ============================================================
CREATE TABLE IF NOT EXISTS old_gold_lots (
  id BIGSERIAL PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  qty_in NUMERIC(18,4) NOT NULL,
  qty_left NUMERIC(18,4) NOT NULL,
  gold_g_per_unit NUMERIC(18,4) NOT NULL,
  cost_per_g NUMERIC(18,4) NOT NULL,
  source_ref TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_old_gold_lots_fifo
  ON old_gold_lots (product_id, date, id) WHERE qty_left > 0;

ALTER TABLE old_gold_lots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS old_gold_lots_read_all ON old_gold_lots;
CREATE POLICY old_gold_lots_read_all ON old_gold_lots
  FOR SELECT USING (current_user_id() IS NOT NULL);
GRANT SELECT ON old_gold_lots TO authenticated;

-- backfill เปิดยอด (ครั้งแรกเท่านั้น — ตารางว่าง): สต๊อก OLD ปัจจุบัน 1 lot/product
-- ที่ cost_per_g = WAC เฉลี่ยปัจจุบัน (lot เปิดยอดจะเก่าสุด → ถูกตัดก่อนโดยอัตโนมัติ)
INSERT INTO old_gold_lots (product_id, qty_in, qty_left, gold_g_per_unit, cost_per_g, source_ref, date)
SELECT sb.product_id, sb.qty, sb.qty, p.weight_baht * 15,
       CASE WHEN COALESCE(w.old_gold_g, 0) > 0 THEN w.old_value / w.old_gold_g ELSE 0 END,
       'OPENING', NOW()
FROM stock_balances sb
JOIN products p ON p.id = sb.product_id
CROSS JOIN wac_state w
WHERE sb.gold_type = 'OLD' AND sb.qty > 0 AND w.id = 1
  AND NOT EXISTS (SELECT 1 FROM old_gold_lots);


-- ============================================================
-- L1.2) helper: ตัด lot ทองเก่าแบบ FIFO (เก่าสุดก่อน) คืนต้นทุนรวมที่ตัด
--   ⚠️ caller ต้องถือ lock wac_state (id=1 FOR UPDATE) อยู่แล้ว เพื่อ serialize
--   lot ไม่พอ (ข้อมูล drift) → ตัดเท่าที่มี ส่วนเกินคิดที่ WAC เฉลี่ยปัจจุบัน
--   internal เท่านั้น (REVOKE จาก client)
-- ============================================================
CREATE OR REPLACE FUNCTION _consume_old_lots(p_product_id TEXT, p_qty NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
  v_remain NUMERIC := COALESCE(p_qty, 0);
  v_lot RECORD;
  v_take NUMERIC;
  v_cost NUMERIC := 0;
  v_g NUMERIC;
  v_wac NUMERIC;
BEGIN
  IF v_remain <= 0 THEN RETURN 0; END IF;

  FOR v_lot IN
    SELECT id, qty_left, gold_g_per_unit, cost_per_g
    FROM old_gold_lots
    WHERE product_id = p_product_id AND qty_left > 0
    ORDER BY date, id
    FOR UPDATE
  LOOP
    EXIT WHEN v_remain <= 0;
    v_take := LEAST(v_lot.qty_left, v_remain);
    UPDATE old_gold_lots SET qty_left = qty_left - v_take WHERE id = v_lot.id;
    v_cost := v_cost + (v_take * v_lot.gold_g_per_unit * v_lot.cost_per_g);
    v_remain := v_remain - v_take;
  END LOOP;

  IF v_remain > 0 THEN
    SELECT weight_baht * 15 INTO v_g FROM products WHERE id = p_product_id;
    SELECT CASE WHEN COALESCE(old_gold_g, 0) > 0 THEN old_value / old_gold_g ELSE 0 END
      INTO v_wac FROM wac_state WHERE id = 1;
    v_cost := v_cost + (v_remain * COALESCE(v_g, 0) * COALESCE(v_wac, 0));
  END IF;

  RETURN v_cost;
END;
$$;
REVOKE ALL ON FUNCTION _consume_old_lots(TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.1) helper: หา bank_id จากชื่อ — ไม่พบ → สร้างแถวใหม่ (กันเงินหายจาก breakdown)
--      internal เท่านั้น (REVOKE จาก client)
-- ============================================================
CREATE OR REPLACE FUNCTION _resolve_bank_id(p_name TEXT)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF p_name IS NULL OR TRIM(p_name) = '' THEN RETURN NULL; END IF;
  SELECT id INTO v_id FROM banks WHERE name = TRIM(p_name) LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO banks (name, is_active) VALUES (TRIM(p_name), TRUE) RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION _resolve_bank_id(TEXT) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.2) helper: ลงบัญชีรายการจ่ายทุก entry ของ confirm_*_tx
--   • transaction_payments ครบทุก entry (amount สกุลจริง)
--   • cashbank (เงินเข้าร้าน) — ยกเว้น Sales รับเงินสด (เข้ากระเป๋า Sales รอปิดกะ)
--   • user_cashbook (กระเป๋า Sales) — เมื่อผู้ทำรายการเป็น Sales
--   • คืน paid_lak = Σ(amount × rate) สำหรับบันทึกลง transactions.paid
--   internal เท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION _apply_confirm_payments(
  p_tx_id TEXT, p_payments JSONB, p_cb_type cashbank_type, p_note TEXT,
  p_user_id UUID, p_is_sales BOOLEAN
)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_e RECORD;
  v_method TEXT;
  v_bank_id UUID;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_paid_lak NUMERIC := 0;
  v_first_currency TEXT := NULL;
  v_n INT := 0;
BEGIN
  FOR v_e IN
    SELECT UPPER(COALESCE(elem->>'method', 'CASH')) AS m,
           UPPER(COALESCE(NULLIF(elem->>'currency', ''), 'LAK')) AS cur,
           (elem->>'amount')::numeric AS amount,
           COALESCE(NULLIF((elem->>'rate')::numeric, 0), 1) AS rate,
           elem->>'bank' AS bank_name
    FROM jsonb_array_elements(p_payments) elem
  LOOP
    CONTINUE WHEN v_e.amount IS NULL OR v_e.amount <= 0;

    v_method := CASE WHEN v_e.m = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END;
    v_bank_id := CASE WHEN v_method = 'TRANSFER' THEN _resolve_bank_id(v_e.bank_name) ELSE NULL END;
    IF v_first_currency IS NULL THEN v_first_currency := v_e.cur; END IF;
    v_paid_lak := v_paid_lak + (v_e.amount * v_e.rate);

    INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
    VALUES (p_tx_id, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id, p_user_id);

    IF NOT (p_is_sales AND v_method = 'CASH') THEN
      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                 || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, p_cb_type, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id,
              p_tx_id, p_note, NOW(), p_user_id);
    END IF;

    IF p_is_sales THEN
      v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                  || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
      INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
      VALUES (v_ucb_id, p_user_id, p_cb_type, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id,
              p_tx_id, p_note, NOW());
    END IF;

    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'ไม่มีรายการชำระเงินที่ยอดมากกว่า 0';
  END IF;

  RETURN jsonb_build_object('paid_lak', v_paid_lak,
                            'first_currency', COALESCE(v_first_currency, 'LAK'),
                            'entries', v_n);
END;
$$;
REVOKE ALL ON FUNCTION _apply_confirm_payments(TEXT, JSONB, cashbank_type, TEXT, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.3) helper: หักเงินทอน (เงินสด LAK เสมอ) ออกจาก ledger เดียวกับที่เงินเข้า
--   Sales → user_cashbook ตัวเอง / Manager,Admin → cashbank ร้าน
--   คืน NULL = สำเร็จ, คืนข้อความ = เงินไม่พอทอน (caller ต้อง RAISE เพื่อ rollback)
--   internal เท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION _apply_change_deduction(
  p_tx_id TEXT, p_change NUMERIC, p_user_id UUID, p_is_sales BOOLEAN
)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v_id TEXT;
BEGIN
  IF p_change IS NULL OR p_change <= 0 THEN RETURN NULL; END IF;

  IF p_is_sales THEN
    IF NOT check_user_cash_balance(p_user_id, 'LAK', p_change) THEN
      RETURN '❌ เงินสด LAK ในกระเป๋าไม่พอทอน ' || to_char(p_change, 'FM999,999,999,990') || ' LAK';
    END IF;
    v_id := 'UCB-CHG-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
            || '-' || substring(md5(p_tx_id || random()::text), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, ref_tx_id, note, date)
    VALUES (v_id, p_user_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW());
  ELSE
    IF NOT check_shop_balance('CASH', 'LAK', NULL, p_change) THEN
      RETURN '❌ เงินสด LAK ในร้านไม่พอทอน ' || to_char(p_change, 'FM999,999,999,990') || ' LAK';
    END IF;
    v_id := 'CB-CHG-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
            || '-' || substring(md5(p_tx_id || random()::text), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, ref_tx_id, note, date, created_by_id)
    VALUES (v_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW(), p_user_id);
  END IF;

  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION _apply_change_deduction(TEXT, NUMERIC, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- ข้อ9) stock_in_new_tx — ตัด fee ทิ้ง (p_fee คงไว้ใน signature เพื่อ compat แต่ ignore)
--   + ธนาคารไม่พบชื่อ → สร้างอัตโนมัติ (_resolve_bank_id)
--   (คงพฤติกรรม R9: เช็คยอดร้านพอก่อนหัก ต่อ วิธีจ่าย×สกุล×ธนาคาร)
-- ============================================================
CREATE OR REPLACE FUNCTION stock_in_new_tx(
  p_items JSONB,
  p_note TEXT,
  p_cost NUMERIC,
  p_payments JSONB,
  p_fee NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_pay JSONB;
  v_ref_id TEXT;
  v_cb_id TEXT;
  v_chk RECORD;
  v_chk_bank_id UUID;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_admin() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- ตรวจสินค้า + รวมน้ำหนัก
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    DECLARE v_weight NUMERIC;
    BEGIN
      SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
      IF v_weight IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
      END IF;
      v_total_g := v_total_g + (v_weight * v_item.qty);
    END;
  END LOOP;

  -- ‼️ เช็คยอดเงินในร้านพอก่อนหัก (ไม่รวม fee — เลิกใช้ fee แล้ว)
  FOR v_chk IN
    SELECT
      CASE WHEN UPPER(pe.elem->>'method') = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END AS m,
      COALESCE(pe.elem->>'currency', 'LAK') AS cur,
      NULLIF(pe.elem->>'bank', '') AS bankname,
      SUM( (pe.elem->>'amount')::numeric ) AS need
    FROM jsonb_array_elements(p_payments) AS pe(elem)
    GROUP BY 1, 2, 3
  LOOP
    v_chk_bank_id := NULL;
    IF v_chk.m = 'TRANSFER' AND v_chk.bankname IS NOT NULL THEN
      v_chk_bank_id := _resolve_bank_id(v_chk.bankname);
    END IF;
    IF NOT check_shop_balance(v_chk.m, v_chk.cur::currency_code, v_chk_bank_id, v_chk.need) THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ เงินในร้านไม่พอ: ต้องจ่าย ' || to_char(v_chk.need, 'FM999,999,999,990') || ' ' || v_chk.cur ||
        CASE WHEN v_chk.m = 'CASH' THEN ' (เงินสด)' ELSE ' (' || COALESCE(v_chk.bankname, 'ธนาคาร') || ')' END);
    END IF;
  END LOOP;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'NEW', 'STOCK_IN', 'IN', v_total_g, p_cost,
          CASE WHEN v_total_g > 0 THEN p_cost / v_total_g ELSE 0 END,
          CASE WHEN v_total_g > 0 THEN (p_cost / v_total_g) * 15 ELSE 0 END,
          TRUE, v_user_id, p_note, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_item.pid, 'NEW', v_item.qty, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
  END LOOP;

  INSERT INTO wac_state (id, new_gold_g, new_value, updated_at)
  VALUES (1, v_total_g, p_cost, NOW())
  ON CONFLICT (id)
  DO UPDATE SET new_gold_g = wac_state.new_gold_g + v_total_g,
                new_value = wac_state.new_value + p_cost,
                updated_at = NOW();

  -- หักเงินออกจากร้าน (cashbank) ต่อรายการจ่าย — ไม่มีแถว fee อีกต่อไป
  FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    DECLARE
      v_method TEXT := v_pay->>'method';
      v_bank_name TEXT := v_pay->>'bank';
      v_cur TEXT := COALESCE(v_pay->>'currency', 'LAK');
      v_amount NUMERIC := (v_pay->>'amount')::numeric;
      v_rate NUMERIC := COALESCE((v_pay->>'rate')::numeric, 1);
      v_bank_id UUID := NULL;
    BEGIN
      IF UPPER(v_method) <> 'CASH' THEN
        v_bank_id := _resolve_bank_id(v_bank_name);
      END IF;

      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_method), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code, v_rate,
              CASE WHEN UPPER(v_method) = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(NULLIF(p_note, ''), 'Stock In NEW') || ' [ref:' || v_ref_id || ']',
              NOW(), v_user_id);
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Stock In สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION stock_in_new_tx(JSONB, TEXT, NUMERIC, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ8) get_close_cashbook — เพิ่ม role check (ดูของตัวเอง หรือ Manager/Admin)
--   (คง Bangkok filter จาก R9)
-- ============================================================
CREATE OR REPLACE FUNCTION get_close_cashbook(p_user_id UUID, p_date DATE)
RETURNS TABLE (
  amount NUMERIC,
  currency TEXT,
  method TEXT,
  bank_id UUID,
  bank_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_user_id IS DISTINCT FROM current_user_id() AND NOT is_manager_or_admin() THEN
    RETURN;  -- ไม่ใช่เจ้าของข้อมูลและไม่ใช่ Manager/Admin → ไม่คืนอะไร
  END IF;

  -- [R11.1] คืน "ทั้งกระเป๋าสะสม" ไม่ filter วัน (p_date รับไว้เพื่อ signature compat)
  -- เหตุผล: approve_close_report กวาดยอดสะสมทั้งกระเป๋า → เลขที่ Sales เห็น/Manager
  -- อนุมัติ ต้องเท่ากับเงินที่ย้ายจริง (หลังปิดกะทุกครั้งกระเป๋าเป็น 0 อยู่แล้ว
  -- ดังนั้นยอดสะสม = ยอดตั้งแต่ปิดกะครั้งก่อน)
  RETURN QUERY
  SELECT ucb.amount, ucb.currency::text, ucb.method, ucb.bank_id, b.name
  FROM user_cashbook ucb
  LEFT JOIN banks b ON b.id = ucb.bank_id
  WHERE ucb.user_id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION get_close_cashbook(UUID, DATE) TO authenticated;


-- ============================================================
-- get_live_report (Box Wealth) — คงเดิมจาก R9 (diff = ปัจจุบัน − เมื่อวาน)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB AS $$
DECLARE
  v_today DATE;
  v_today_start TIMESTAMPTZ;
  v_current NUMERIC := 0;
  v_yest NUMERIC := 0;
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_today_start := (v_today::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_current FROM stock_moves;

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_yest FROM stock_moves WHERE date < v_today_start;

  RETURN jsonb_build_object(
    'netTotal', v_current,
    'carryForward', v_yest,
    'diff', v_current - v_yest
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;


-- ============================================================
-- ข้อ4) get_live_report_sales_breakdown — TZ Bangkok ครบทุก CTE
--   เดิม open_shift_today เป็น Bangkok แล้ว แต่ tx/gold/cash/close ยังใช้ ::date (UTC)
--   → ธุรกรรม/ปิดกะช่วง 00:00–06:59 น. ไทย ตกไปอยู่เมื่อวาน (สถานะกะ/ยอดเงินผิด)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report_sales_breakdown(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  WITH active_sales AS (
    SELECT u.id AS user_id,
           COALESCE(NULLIF(TRIM(u.nickname), ''), u.username) AS nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
      AND COALESCE(u.is_active, TRUE) = TRUE
  ),
  open_shift_today AS (
    SELECT DISTINCT user_id
    FROM user_cashbook
    WHERE type = 'OPEN_SHIFT' AND (date AT TIME ZONE 'Asia/Bangkok')::date = v_today
  ),
  tx_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(t.total) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')), 0) AS sell_money,
      COUNT(*) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')) AS sell_count,
      COALESCE(SUM(CASE WHEN t.type='BUYBACK' THEN COALESCE(t.price, t.total) ELSE 0 END), 0) AS buyback_money,
      COUNT(*) FILTER (WHERE t.type='BUYBACK') AS buyback_count,
      COALESCE(SUM(t.total) FILTER (WHERE t.type='WITHDRAW'), 0) AS withdraw_money,
      COUNT(*) FILTER (WHERE t.type='WITHDRAW') AS withdraw_count
    FROM transactions t
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    GROUP BY t.sale_user_id
  ),
  gold_g_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW') AND ti.item_role='NEW'), 0) AS sell_gold_g,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type='BUYBACK' AND ti.item_role='OLD'), 0) AS bb_gold_g,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type='WITHDRAW' AND ti.item_role='NEW'), 0) AS wd_gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    GROUP BY t.sale_user_id
  ),
  old_gold_per_sale AS (
    SELECT
      ug.user_id AS sale_user_id,
      jsonb_object_agg(ug.product_id, ug.qty_sum) AS gold_qty
    FROM (
      SELECT user_id, product_id, SUM(qty) AS qty_sum
      FROM user_gold_received
      WHERE settled = FALSE
      GROUP BY user_id, product_id
    ) ug
    GROUP BY ug.user_id
  ),
  cash_per_sale AS (
    SELECT
      ucb.user_id,
      jsonb_build_object(
        'Cash', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='USD'), 0)
        ),
        'BCEL', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='USD'), 0)
        ),
        'LDB', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        ),
        'Other', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        )
      ) AS cash_breakdown
    FROM user_cashbook ucb
    LEFT JOIN banks b ON b.id = ucb.bank_id
    -- [R12] "เงินที่ถือ" = ยอดสะสมทั้งกระเป๋า (ไม่ filter วัน) ให้เป็นสถานะปัจจุบัน
    --       เหมือน old_gold (settled=false) — หลังปิดกะ+approve กระเป๋าถูกกวาดเป็น 0
    --       ดังนั้นยอดสะสม = เงินที่ Sales ถืออยู่จริงตอนนี้ (p_date_* ยังใช้กับยอด tx/ทอง)
    GROUP BY ucb.user_id
  ),
  close_status AS (
    SELECT
      c.user_id,
      MAX(CASE WHEN c.status='PENDING' THEN 'PENDING'
               WHEN c.status='APPROVED' THEN 'CLOSED'
               ELSE NULL END) AS s
    FROM closes c
    WHERE (c.date AT TIME ZONE 'Asia/Bangkok')::date = v_today
    GROUP BY c.user_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'user_id',         a.user_id,
      'nickname',        a.nickname,
      'shift_status',    COALESCE(cs.s, CASE WHEN ost.user_id IS NOT NULL THEN 'OPEN' ELSE 'NOT_OPEN' END),
      'sell_money',      COALESCE(tps.sell_money, 0),
      'sell_count',      COALESCE(tps.sell_count, 0),
      'sell_gold_g',     COALESCE(ggs.sell_gold_g, 0),
      'buyback_money',   COALESCE(tps.buyback_money, 0),
      'buyback_count',   COALESCE(tps.buyback_count, 0),
      'buyback_gold_g',  COALESCE(ggs.bb_gold_g, 0),
      'withdraw_money',  COALESCE(tps.withdraw_money, 0),
      'withdraw_count',  COALESCE(tps.withdraw_count, 0),
      'withdraw_gold_g', COALESCE(ggs.wd_gold_g, 0),
      'old_gold',        COALESCE(ogs.gold_qty, '{}'::jsonb),
      'cash_breakdown',  COALESCE(cps.cash_breakdown, '{}'::jsonb)
    )
  )
  INTO v_result
  FROM active_sales a
  LEFT JOIN open_shift_today ost ON ost.user_id = a.user_id
  LEFT JOIN tx_per_sale tps ON tps.sale_user_id = a.user_id
  LEFT JOIN gold_g_per_sale ggs ON ggs.sale_user_id = a.user_id
  LEFT JOIN old_gold_per_sale ogs ON ogs.sale_user_id = a.user_id
  LEFT JOIN cash_per_sale cps ON cps.user_id = a.user_id
  LEFT JOIN close_status cs ON cs.user_id = a.user_id;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION get_live_report_sales_breakdown(DATE, DATE) TO authenticated;


-- ============================================================
-- DIFF helpers — คงเดิมจาก R9 (สูตรชีทเก่า)
-- ============================================================
-- [R11.1] สินค้านอก G01–G07 → คิด pro-rata จาก weight_baht × ราคาขาย 1 บาท (เดิมคืน 0 เงียบๆ)
--   (เปลี่ยน IMMUTABLE → STABLE เพราะ lookup ตาราง products)
CREATE OR REPLACE FUNCTION _diff_sell_price(p_pid TEXT, p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT CASE p_pid
    WHEN 'G01' THEN ROUND(p_s1b * 10 / 1000.0) * 1000
    WHEN 'G02' THEN ROUND(p_s1b * 5  / 1000.0) * 1000
    WHEN 'G03' THEN ROUND(p_s1b * 2  / 1000.0) * 1000
    WHEN 'G04' THEN ROUND(p_s1b       / 1000.0) * 1000
    WHEN 'G05' THEN ROUND((p_s1b / 2) / 1000.0) * 1000
    WHEN 'G06' THEN ROUND((p_s1b / 4) / 1000.0) * 1000
    WHEN 'G07' THEN CEIL((p_s1b / 15.0 + 120000) / 1000.0) * 1000
    ELSE COALESCE(
      (SELECT ROUND((p_s1b * p.weight_baht) / 1000.0) * 1000
       FROM products p WHERE p.id = p_pid),
      0)
    END;
$$;

CREATE OR REPLACE FUNCTION _diff_items_sell_total(p_tx_id TEXT, p_roles TEXT[], p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(ti.qty * _diff_sell_price(ti.product_id, p_s1b)), 0)
  FROM transaction_items ti
  WHERE ti.tx_id = p_tx_id AND ti.item_role::text = ANY(p_roles);
$$;

CREATE OR REPLACE FUNCTION _diff_sell_1baht(p_tx_sell_1baht NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(p_tx_sell_1baht, 0),
                  (SELECT sell_1baht FROM pricing ORDER BY date DESC LIMIT 1),
                  0);
$$;


-- ============================================================
-- ข้อ1) confirm_sell_tx — multi-payment
--   signature ใหม่: (p_tx_id, p_payments JSONB, p_change) — DROP ตัวเก่า
--   + FOR UPDATE แถว tx (กันยืนยันซ้ำ 2 เครื่อง)
--   + เช็คสต๊อกพอก่อนตัด (FOR UPDATE)
--   + หักเงินทอนออกจาก ledger (helper 0.3)
--   Diff: คงสูตร R9 — diff = ขายใหม่ + premium − (น้ำหนักใหม่ × WAC)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_sell_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_sell_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_sell_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_phone TEXT;
  v_premium NUMERIC;
  v_sell_1baht NUMERIC := 0;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  SELECT t.status, t.total, t.phone, t.premium, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_phone, v_premium, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'SELL'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Transaction not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  -- ‼️ เช็คสต๊อกพอก่อนตัด (ไม่พอ = ไม่แตะอะไรเลย tx คง APPROVED)
  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);

  -- ลงบัญชีทุกรายการจ่าย (transaction_payments + cashbank/user_cashbook)
  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'SELL', 'Sell ' || p_tx_id, v_user_id, v_is_sales);

  -- เงินทอน — หักออกจากกระเป๋าเดียวกับที่เงินสดเข้า (ไม่พอ = rollback ทั้งบิล)
  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'SELL', 'OUT', v_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_gold_g, new_value = new_value - v_cost, updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): sell_value = ขายใหม่ ; diff = ขายใหม่ + premium − ต้นทุน WAC
  v_diff := v_new_sell_total + COALESCE(v_premium, 0) - v_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'SELL', v_new_sell_total, 0, 0, COALESCE(v_premium, 0), v_cost, 0, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = 0, switch_fee = 0, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = 0, diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'cost', v_cost, 'diff', v_diff);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_sell_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_tradein_tx — multi-payment (เหมือน sell + ทองเก่าเข้า user_gold_received)
--   Diff: diff = ขายใหม่ + premium − ((ใหม่−เก่า)×WAC) − ขายเก่า
-- ============================================================
DROP FUNCTION IF EXISTS confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_tradein_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_tradein_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_cost_diff NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_old_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  SELECT t.status, t.total, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'TRADEIN'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_new_gold_g := calc_items_gold_g(v_new_items);

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0) INTO v_old_gold_g
  FROM transaction_items ti JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'FOC');

  v_wac_per_g := get_wac_per_g();
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);
  v_old_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['OLD','FOC'], v_s1b);
  v_cost_diff := (v_new_gold_g - v_old_gold_g) * v_wac_per_g;

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'TRADEIN', 'Tradein ' || p_tx_id, v_user_id, v_is_sales);

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'TRADEIN', 'OUT', v_new_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'FOC') LOOP
    INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id, price_per_unit, settled)
    VALUES (COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty, 'TRADEIN', p_tx_id, NOW(), v_user_id, 0, FALSE);
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - (v_new_gold_g * v_wac_per_g),
        updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): cost_diff = (ใหม่−เก่า)×WAC ; cost_old_gold = ขายเก่า
  v_diff := v_new_sell_total + COALESCE(v_premium, 0) - v_cost_diff - v_old_sell_total;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'TRADEIN', v_new_sell_total, 0, 0, COALESCE(v_premium, 0), v_cost_diff, v_old_sell_total, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = 0, switch_fee = 0, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณเรียบร้อย: ' || p_tx_id, v_sale_user, 'tradein', p_tx_id);
  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_exchange_tx — multi-payment
--   Diff: diff = ขายใหม่ + exFee + swFee + premium − ขายเก่า (ไม่คิด WAC)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_exchange_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_exchange_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_ex_fee NUMERIC;
  v_switch_fee NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_old_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_new_gold_g := calc_items_gold_g(v_new_items);

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);
  v_old_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'EXCHANGE', 'Exchange ' || p_tx_id, v_user_id, v_is_sales);

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'EXCHANGE', 'OUT', v_new_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'SWITCH', 'FREE_EX') LOOP
    INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id, price_per_unit, settled)
    VALUES (COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty, 'EXCHANGE', p_tx_id, NOW(), v_user_id, 0, FALSE);
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): ไม่คิด WAC (cost_diff=0)
  v_diff := v_new_sell_total + COALESCE(v_ex_fee, 0) + COALESCE(v_switch_fee, 0) + COALESCE(v_premium, 0) - v_old_sell_total;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_new_sell_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0),
          0, v_old_sell_total, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = 0, cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณเรียบร้อย: ' || p_tx_id, v_sale_user, 'exchange', p_tx_id);
  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_withdraw_tx — multi-payment (Diff = 0 ทุกค่า ตาม R9)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_withdraw_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_withdraw_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_withdraw_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  SELECT t.status, t.total INTO v_status, v_total
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'WITHDRAW'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED'); END IF;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'WITHDRAW', 'Withdraw ' || p_tx_id, v_user_id, v_is_sales);

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'WITHDRAW', 'OUT', v_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_gold_g, new_value = new_value - v_cost, updated_at = NOW()
    WHERE id = 1;

  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'WITHDRAW', 0, 0, 0, 0, 0, 0, 0, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = 0, ex_fee = 0, switch_fee = 0, premium = 0,
        cost_diff = 0, cost_old_gold = 0, diff = 0;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_withdraw_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ2) confirm_buyback_tx — แก้ 3 บัค (คง signature เดิม + DEFAULT)
--   • สะสมยอดจ่ายเป็น LAK: paid += p_paid × เรทรับซื้อ (เดิมบวกเลขดิบข้ามสกุล)
--   • fee เลิกใช้ — ignore p_fee (คง param ไว้เพื่อ compat, ไม่ insert แถว fee)
--   • FOR UPDATE แถว tx กันยืนยันพร้อมกัน
--   (การเทียบ method ใช้ UPPER อยู่แล้ว — JS ส่ง 'CASH'/'BANK')
-- ============================================================
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);

CREATE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_fee NUMERIC DEFAULT 0, p_change NUMERIC DEFAULT 0
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_price NUMERIC;
  v_total_paid NUMERIC;
  v_new_balance NUMERIC;
  v_new_status tx_status;
  v_total_qty NUMERIC := 0;
  v_price_per_unit NUMERIC := 0;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_sale_user UUID;
  v_old_gold_g NUMERIC := 0;
  v_sell_1baht NUMERIC := 0;
  v_old_cost NUMERIC := 0;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_pay_from_drawer BOOLEAN;
  v_cb_method TEXT;
  v_rate NUMERIC := 1;
  v_paid_lak NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_pay_from_drawer := (v_is_sales AND v_is_cash);
  v_cb_method := CASE WHEN v_is_cash THEN 'CASH' ELSE 'TRANSFER' END;

  IF p_paid IS NULL OR p_paid <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- ‼️ เรทรับซื้อ (ร้านจ่ายเงินออก): THB→thb_buy, USD→usd_buy — สะสม paid เป็น LAK
  IF p_currency <> 'LAK' THEN
    SELECT CASE WHEN p_currency = 'THB' THEN thb_buy
                WHEN p_currency = 'USD' THEN usd_buy END
      INTO v_rate
    FROM price_rates ORDER BY date DESC LIMIT 1;
    IF v_rate IS NULL OR v_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยังไม่ได้ตั้งเรทรับซื้อ ' || p_currency || '/LAK — โปรดตั้งเรทใน Price Rate ก่อน');
    END IF;
  END IF;
  v_paid_lak := p_paid * v_rate;

  -- [LOCK] กันจ่ายบิลเดียวกันพร้อมกัน 2 เครื่อง
  SELECT t.status, t.price, t.paid, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_price, v_total_paid, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK'
  FOR UPDATE;

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
  END IF;

  -- เช็คเงินพอจ่าย (สกุลจริงที่จ่าย): Sales+เงินสด → กระเป๋า Sales ; อื่นๆ → เงินร้าน
  IF v_pay_from_drawer THEN
    IF NOT check_user_cash_balance(v_user_id, p_currency, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในกระเป๋าของคุณไม่พอจ่าย Buyback');
    END IF;
  ELSE
    IF NOT check_shop_balance(v_cb_method, p_currency, p_bank_id, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินในร้านไม่พอ โปรดติดต่อ Admin');
    END IF;
  END IF;

  v_total_paid := COALESCE(v_total_paid, 0) + v_paid_lak;
  v_new_balance := v_price - v_total_paid;

  IF v_new_balance <= 0 THEN
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
  ELSE
    v_new_status := 'PARTIAL';
  END IF;

  UPDATE transactions
  SET status = v_new_status, paid = v_total_paid, balance = v_new_balance,
      fee = 0, change_amount = COALESCE(p_change, 0), updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, v_cb_method, p_bank_id, v_user_id);

  -- เงินออกจากร้าน (cashbank): เฉพาะกรณีไม่ใช่ "เงินสดจากกระเป๋า Sales" (amount = สกุลจริง)
  IF NOT v_pay_from_drawer THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): หักเงินที่จ่ายออก (สกุลจริง)
  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW());
  END IF;

  -- [R12.1] บันทึกทองเก่าที่รับ "ตั้งแต่จ่ายครั้งแรก" (เดิมบันทึกเฉพาะจ่ายครบ →
  --   บิลค้างยอด PARTIAL ไม่ถูกบันทึกเลย ทองไม่เข้า Stock Old ตอนอนุมัติปิดกะ)
  --   ลูกค้าส่งมอบทองตั้งแต่ตกลงขาย จึงบันทึกเต็มจำนวนตอนจ่ายงวดแรก
  --   เช็ค EXISTS กันบันทึกซ้ำงวดถัดไป + ครอบคลุมบิล PARTIAL เก่าที่ค้างอยู่
  SELECT COALESCE(SUM(ti.qty), 0),
         COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
    INTO v_total_qty, v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD';

  IF v_total_qty > 0 THEN
    v_price_per_unit := v_price / v_total_qty;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM user_gold_received WHERE ref_tx_id = p_tx_id) THEN
    FOR v_item IN SELECT product_id, qty FROM transaction_items
                  WHERE tx_id = p_tx_id AND item_role = 'OLD' LOOP
      INSERT INTO user_gold_received (
        user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
        price_per_unit, settled
      )
      VALUES (
        COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
        'BUYBACK', p_tx_id, NOW(), v_user_id,
        v_price_per_unit, FALSE
      );
    END LOOP;
  END IF;

  IF v_new_status = 'COMPLETED' THEN
    v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

    INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, 0, 0, 0,
            0, v_old_cost,
            ((-v_price) - v_old_cost), NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
          switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
          cost_diff = EXCLUDED.cost_diff,
          cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

    PERFORM _notify_user('PAYMENT', '💰 BUYBACK ของคุณจ่ายเงินเรียบร้อย: ' || p_tx_id,
                         v_sale_user, 'buyback', p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'status', v_new_status, 'balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC) TO authenticated;


-- ============================================================
-- L1.3) transfer_old_to_new_tx — เปลี่ยนต้นทุนจาก WAC เฉลี่ย → FIFO ราย lot
--   (base: เวอร์ชันล่าสุดจาก git cf4fbbd — คง lock/ref/โครงเดิมทั้งหมด)
--   consumed_cost = Σ ต้นทุนจริงของ lot ที่ถูกตัด (เก่าสุดก่อน ต่อ product)
-- ============================================================
CREATE OR REPLACE FUNCTION transfer_old_to_new_tx(p_items JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
  v_old_wac NUMERIC;
  v_consumed_cost NUMERIC := 0;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- [LOCK] serialize ทุก tx ที่แตะ wac/stock ผ่าน row นี้
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('TF', 'TRANSFER');

  -- 1) total weight + ตรวจสต็อก OLD พอ (FOR UPDATE) — ห้าม mutate ก่อน validate ครบ
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances
      WHERE product_id = v_item.pid AND gold_type = 'OLD'
      FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  -- 2) ตัด lot FIFO ต่อ product → ต้นทุนจริงรวม (หลัง validate ผ่านครบแล้วเท่านั้น)
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    v_consumed_cost := v_consumed_cost + _consume_old_lots(v_item.pid, v_item.qty);
  END LOOP;
  v_old_wac := CASE WHEN v_total_g > 0 THEN v_consumed_cost / v_total_g ELSE 0 END;

  -- 3) INSERT OLD/OUT
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price,
                           wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'OLD', 'TRANSFER', 'OUT', v_total_g, v_consumed_cost,
          v_old_wac, v_old_wac * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
      WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  -- 4) INSERT NEW/IN
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price,
                           wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'NEW', 'TRANSFER', 'IN', v_total_g, v_consumed_cost,
          v_old_wac, v_old_wac * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.pid, v_item.qty);
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_item.pid, 'NEW', v_item.qty, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
  END LOOP;

  -- 5) UPDATE wac_state — sync ทั้ง qty และ value (value ตามต้นทุน lot จริง)
  UPDATE wac_state
  SET old_gold_g = GREATEST(0, COALESCE(old_gold_g, 0) - v_total_g),
      old_value  = GREATEST(0, COALESCE(old_value, 0)  - v_consumed_cost),
      new_gold_g = COALESCE(new_gold_g, 0) + v_total_g,
      new_value  = COALESCE(new_value, 0)  + v_consumed_cost,
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Transfer สำเร็จ',
    'ref_id', v_ref_id,
    'consumed_cost', v_consumed_cost,
    'old_wac_per_g', v_old_wac
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION transfer_old_to_new_tx(JSONB) TO authenticated;


-- ============================================================
-- ข้อ3) stock_out_old_tx — ตัดมูลค่า (old_value) + lock
--   R11.1: ต้นทุนที่ตัดเปลี่ยนจาก WAC เฉลี่ย → FIFO ราย lot (เหมือน transfer)
-- ============================================================
CREATE OR REPLACE FUNCTION stock_out_old_tx(p_items JSONB, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
  v_old_wac NUMERIC;
  v_consumed_cost NUMERIC := 0;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- [LOCK] serialize ทุก tx ที่แตะ wac/stock ผ่าน row นี้
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('SO', 'STOCK_OUT');

  -- ตรวจสินค้า + เช็คสต๊อกพอ (FOR UPDATE) — ห้าม mutate ก่อน validate ครบ
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances
      WHERE product_id = v_item.pid AND gold_type = 'OLD'
      FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  -- ตัด lot FIFO ต่อ product → ต้นทุนจริงรวม (หลัง validate ผ่านครบแล้วเท่านั้น)
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    v_consumed_cost := v_consumed_cost + _consume_old_lots(v_item.pid, v_item.qty);
  END LOOP;
  v_old_wac := CASE WHEN v_total_g > 0 THEN v_consumed_cost / v_total_g ELSE 0 END;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'OLD', 'STOCK_OUT', 'OUT', v_total_g, v_consumed_cost,
          v_old_wac, v_old_wac * 15, TRUE, v_user_id, p_note, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  -- ตัดทั้งน้ำหนักและมูลค่า (เดิมตัดแค่น้ำหนัก)
  UPDATE wac_state
  SET old_gold_g = GREATEST(0, COALESCE(old_gold_g, 0) - v_total_g),
      old_value  = GREATEST(0, COALESCE(old_value, 0)  - v_consumed_cost),
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object('success', true, 'message', 'Stock Out สำเร็จ', 'ref_id', v_ref_id,
                            'consumed_cost', v_consumed_cost, 'old_wac_per_g', v_old_wac);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION stock_out_old_tx(JSONB, TEXT) TO authenticated;


-- ============================================================
-- ข้อ4) recompute_diffs — Bangkok + ใช้วันที่ของ tx จริง (เดิมใส่ NOW() ทำแถวเก่าย้ายมาวันนี้)
--   ⚠️ ใช้ WAC + ราคาขายปัจจุบัน (เหมือนชีท) → แถวเก่าสะท้อนเรตปัจจุบัน
--   เรียกเอง: SELECT recompute_diffs('2026-01-01','2026-12-31');
-- ============================================================
CREATE OR REPLACE FUNCTION recompute_diffs(p_from DATE, p_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_t RECORD;
  v_wac NUMERIC := get_wac_per_g();
  v_s1b NUMERIC;
  v_new_g NUMERIC;
  v_old_g NUMERIC;
  v_new_sell NUMERIC;
  v_old_sell NUMERIC;
  v_cost_diff NUMERIC;
  v_diff NUMERIC;
  v_n INT := 0;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager/Admin only');
  END IF;

  FOR v_t IN
    SELECT id, type, date, COALESCE(premium,0) AS premium, COALESCE(ex_fee,0) AS ex_fee,
           COALESCE(switch_fee,0) AS switch_fee, COALESCE(sell_1baht,0) AS sell_1baht
    FROM transactions
    WHERE type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW')
      AND status IN ('COMPLETED','PAID')
      AND (date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_from AND p_to
  LOOP
    v_s1b := _diff_sell_1baht(v_t.sell_1baht);

    SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15),0) INTO v_new_g
    FROM transaction_items ti JOIN products p ON p.id = ti.product_id
    WHERE ti.tx_id = v_t.id AND ti.item_role = 'NEW';

    IF v_t.type = 'SELL' THEN
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_cost_diff := v_new_g * v_wac;
      v_diff := v_new_sell + v_t.premium - v_cost_diff;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'SELL', v_new_sell, 0, 0, v_t.premium, v_cost_diff, 0, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=0, switch_fee=0,
        premium=EXCLUDED.premium, cost_diff=EXCLUDED.cost_diff, cost_old_gold=0, diff=EXCLUDED.diff;

    ELSIF v_t.type = 'TRADEIN' THEN
      SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15),0) INTO v_old_g
      FROM transaction_items ti JOIN products p ON p.id = ti.product_id
      WHERE ti.tx_id = v_t.id AND ti.item_role IN ('OLD','FOC');
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_old_sell := _diff_items_sell_total(v_t.id, ARRAY['OLD','FOC'], v_s1b);
      v_cost_diff := (v_new_g - v_old_g) * v_wac;
      v_diff := v_new_sell + v_t.premium - v_cost_diff - v_old_sell;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'TRADEIN', v_new_sell, 0, 0, v_t.premium, v_cost_diff, v_old_sell, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=0, switch_fee=0,
        premium=EXCLUDED.premium, cost_diff=EXCLUDED.cost_diff, cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSIF v_t.type = 'EXCHANGE' THEN
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_old_sell := _diff_items_sell_total(v_t.id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);
      v_diff := v_new_sell + v_t.ex_fee + v_t.switch_fee + v_t.premium - v_old_sell;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'EXCHANGE', v_new_sell, v_t.ex_fee, v_t.switch_fee, v_t.premium, 0, v_old_sell, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=EXCLUDED.ex_fee,
        switch_fee=EXCLUDED.switch_fee, premium=EXCLUDED.premium, cost_diff=0,
        cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSE  -- WITHDRAW
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'WITHDRAW', 0, 0, 0, 0, 0, 0, 0, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=0, ex_fee=0, switch_fee=0, premium=0,
        cost_diff=0, cost_old_gold=0, diff=0;
    END IF;

    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'recomputed', v_n);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION recompute_diffs(DATE, DATE) TO authenticated;


-- ============================================================
-- ข้อ5) open_shift — กันเปิดกะซ้ำวันเดียวกัน (Bangkok) + role check
--   คืน already_open:true ให้ frontend ปิด modal เงียบๆ (auth.js รองรับแล้ว)
-- ============================================================
CREATE OR REPLACE FUNCTION open_shift(
  p_user_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id TEXT;
  v_cb_id TEXT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- เปิดกะแทนคนอื่นได้เฉพาะ Manager/Admin
  IF p_user_id IS DISTINCT FROM current_user_id() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'เปิดกะได้เฉพาะของตัวเอง');
  END IF;

  -- ‼️ กันเปิดกะซ้ำ (วันนี้ตามเวลาไทย) — กัน float โดนหัก 2 รอบ
  IF EXISTS (
    SELECT 1 FROM user_cashbook
    WHERE user_id = p_user_id AND type = 'OPEN_SHIFT'
      AND (date AT TIME ZONE 'Asia/Bangkok')::date = (NOW() AT TIME ZONE 'Asia/Bangkok')::date
  ) THEN
    RETURN jsonb_build_object('success', false, 'already_open', true, 'message', 'เปิดกะวันนี้ไปแล้ว');
  END IF;

  IF NOT check_shop_balance('CASH', 'LAK', NULL, p_amount) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
  END IF;

  v_id := 'SHIFT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
          || '-' || substring(p_user_id::text, 1, 4);
  v_cb_id := 'CB-' || v_id;

  INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
  VALUES (v_cb_id, 'OPEN_SHIFT', -p_amount, 'LAK', 'CASH',
          'Open shift: ' || v_id, NOW(), p_user_id);

  INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
  VALUES (v_id, p_user_id, 'OPEN_SHIFT', p_amount, 'LAK', 'CASH', 'Open shift', NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION open_shift(UUID, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ5) submit_close_report — กันส่งปิดกะซ้ำวันเดียวกัน (Bangkok)
-- ============================================================
CREATE OR REPLACE FUNCTION submit_close_report(
  p_date DATE,
  p_cash_summary JSONB,
  p_bank_summary JSONB,
  p_gold_summary JSONB,
  p_total_tx INT,
  p_total_amount NUMERIC,
  p_note TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_close_id TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  -- ‼️ กันปิดกะซ้ำ: มี PENDING/APPROVED ของวันนี้ (เวลาไทย) อยู่แล้ว → ไม่รับซ้ำ
  IF EXISTS (
    SELECT 1 FROM closes
    WHERE user_id = v_user_id
      AND status IN ('PENDING', 'APPROVED')
      AND (date AT TIME ZONE 'Asia/Bangkok')::date = (NOW() AT TIME ZONE 'Asia/Bangkok')::date
  ) THEN
    RETURN jsonb_build_object('success', false, 'message',
      '❌ ส่งปิดกะของวันนี้ไปแล้ว (รออนุมัติหรืออนุมัติแล้ว)');
  END IF;

  v_close_id := 'CL-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  INSERT INTO closes (id, user_id, date, status, total_tx, total_amount,
                      cash_summary, bank_summary, gold_summary, note)
  VALUES (v_close_id, v_user_id, NOW(), 'PENDING', p_total_tx, p_total_amount,
          p_cash_summary, p_bank_summary, p_gold_summary, p_note);

  INSERT INTO notifications (type, message, target_role, tab, created_by_id)
  VALUES ('CLOSE', 'New CLOSE shift waiting for approval: ' || v_close_id, 'Manager', 'close', v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_close_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION submit_close_report(DATE, JSONB, JSONB, JSONB, INT, NUMERIC, TEXT) TO authenticated;


-- ============================================================
-- ข้อ5) approve_close_report — FOR UPDATE + guard เฉพาะ PENDING
--   (กัน approve ซ้ำ / approve แถวที่ Sales ยกเลิกไปแล้ว / 2 Manager กดพร้อมกัน)
-- ============================================================
CREATE OR REPLACE FUNCTION approve_close_report(
  p_close_id TEXT,
  p_decision TEXT,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_close_user UUID;
  v_close_date DATE;
  v_cur_status close_status;
  v_nickname TEXT;
  v_new_status close_status;
  v_total_qty NUMERIC;
  v_total_gold_g NUMERIC;
  v_total_value NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_cash RECORD;
  v_uc_id TEXT;
  v_cb_id TEXT;
  v_cash_moved JSONB := '{}'::jsonb;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  v_new_status := CASE WHEN p_decision = 'APPROVE'
                       THEN 'APPROVED'::close_status
                       ELSE 'REJECTED'::close_status END;

  -- [LOCK] + อ่านสถานะปัจจุบัน
  SELECT c.user_id, c.date::date, c.status, u.nickname
    INTO v_close_user, v_close_date, v_cur_status, v_nickname
    FROM closes c JOIN users u ON u.id = c.user_id
    WHERE c.id = p_close_id
    FOR UPDATE OF c;

  IF v_close_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Close not found');
  END IF;

  -- ‼️ ดำเนินการได้เฉพาะ PENDING เท่านั้น
  IF v_cur_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message',
      'รายการปิดกะนี้ถูกดำเนินการไปแล้ว (สถานะ ' || v_cur_status || ')');
  END IF;

  UPDATE closes SET status = v_new_status, approved_by_id = v_user_id,
                    approved_at = NOW(), approval_note = p_note
    WHERE id = p_close_id;

  IF v_new_status = 'REJECTED' THEN
    PERFORM _notify_user('WARNING', '❌ ปิดกะถูกปฏิเสธ: ' || p_close_id ||
                         CASE WHEN p_note IS NOT NULL THEN ' (' || p_note || ')' ELSE '' END,
                         v_close_user, 'close', NULL);
    RETURN jsonb_build_object('success', true);
  END IF;

  -- [LOCK] เฉพาะตอน APPROVE (materialize stock)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('CL', 'CLOSE');

  SELECT
    COALESCE(SUM(ug.qty), 0),
    COALESCE(SUM(ug.qty * p.weight_baht * 15), 0),
    COALESCE(SUM(ug.qty * p.weight_baht * COALESCE(tx.sell_1baht, 0)), 0)
    INTO v_total_qty, v_total_gold_g, v_total_value
  FROM user_gold_received ug
  JOIN products p ON p.id = ug.product_id
  LEFT JOIN transactions tx ON tx.id = ug.ref_tx_id
  WHERE ug.user_id = v_close_user
    AND ug.settled = FALSE;

  IF v_total_qty > 0 THEN
    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, fulfilled, user_id, date)
    VALUES (v_ref_id, 'OLD', 'STOCK_IN', 'IN', v_total_gold_g, v_total_value, TRUE, v_close_user, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN
      SELECT product_id, SUM(qty) AS qty
      FROM user_gold_received
      WHERE user_id = v_close_user AND settled = FALSE
      GROUP BY product_id
    LOOP
      INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.product_id, v_item.qty);

      INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
      VALUES (v_item.product_id, 'OLD', v_item.qty, NOW())
      ON CONFLICT (product_id, gold_type)
      DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
    END LOOP;

    -- [R11.1] สร้าง lot ทองเก่า (FIFO): 1 lot ต่อ product × ราคารับซื้อ (sell_1baht ของ tx ต้นทาง)
    -- Σ(qty × g/unit × cost_per_g) = v_total_value เป๊ะ (สูตรเดียวกับ SELECT ด้านบน)
    INSERT INTO old_gold_lots (product_id, qty_in, qty_left, gold_g_per_unit, cost_per_g, source_ref, date)
    SELECT ug.product_id, SUM(ug.qty), SUM(ug.qty), p.weight_baht * 15,
           COALESCE(tx.sell_1baht, 0) / 15.0, p_close_id, NOW()
    FROM user_gold_received ug
    JOIN products p ON p.id = ug.product_id
    LEFT JOIN transactions tx ON tx.id = ug.ref_tx_id
    WHERE ug.user_id = v_close_user AND ug.settled = FALSE
    GROUP BY ug.product_id, p.weight_baht, COALESCE(tx.sell_1baht, 0);

    UPDATE wac_state
      SET old_gold_g = COALESCE(old_gold_g, 0) + v_total_gold_g,
          old_value  = COALESCE(old_value, 0) + v_total_value,
          updated_at = NOW()
      WHERE id = 1;

    UPDATE user_gold_received
      SET settled = TRUE, settled_at = NOW(), settled_close_id = p_close_id
      WHERE user_id = v_close_user AND settled = FALSE;
  END IF;

  -- โอนเงินสดที่ Sales ถืออยู่ (user_cashbook method=CASH) เข้าร้านอัตโนมัติ
  FOR v_cash IN
    SELECT currency, SUM(amount) AS bal
    FROM user_cashbook
    WHERE user_id = v_close_user AND method = 'CASH'
    GROUP BY currency
    HAVING SUM(amount) > 0
  LOOP
    v_uc_id := 'UC-CLS-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_cash.currency::text), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_close_user, 'CASH_OUT', -v_cash.bal, v_cash.currency, 'CASH', 'ปิดกะ โอนเข้าร้าน ' || p_close_id, NOW());

    v_cb_id := 'CB-CLS-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_cash.currency::text), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_cash.bal, v_cash.currency, 'CASH', 'ปิดกะ ' || p_close_id || ' โอนเงินสดจาก ' || v_nickname, NOW(), v_user_id);

    v_cash_moved := v_cash_moved || jsonb_build_object(v_cash.currency::text, v_cash.bal);
  END LOOP;

  PERFORM _notify_user('INFO', '✅ ปิดกะของคุณได้รับการอนุมัติ: ' || p_close_id,
                       v_close_user, 'close', NULL);

  RETURN jsonb_build_object(
    'success', true,
    'materialized_ref', CASE WHEN v_total_qty > 0 THEN v_ref_id ELSE NULL END,
    'materialized_qty', v_total_qty,
    'materialized_value', v_total_value,
    'cash_moved', v_cash_moved
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION approve_close_report(TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- ข้อ5) cancel_pending_close — RPC ใหม่ (แทนการ dbDelete จาก client)
--   ลบได้เฉพาะของตัวเอง + สถานะ PENDING เท่านั้น (กัน race กับ Manager approve)
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_pending_close(p_close_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id TEXT;
BEGIN
  DELETE FROM closes
  WHERE id = p_close_id
    AND user_id = current_user_id()
    AND status = 'PENDING'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message',
      'ไม่พบรายการปิดกะที่รออนุมัติ (อาจถูกอนุมัติ/ปฏิเสธไปแล้ว)');
  END IF;

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION cancel_pending_close(TEXT) TO authenticated;


-- ============================================================
-- L2) transfer_user_cash_to_shop — เช็คเงินสดในกระเป๋าพอฝั่ง server ก่อนโอน
--   (base: เวอร์ชันล่าสุดจาก git a12fb4f — เช็คครบทุกสกุลก่อน ไม่พอ = ไม่ทำอะไรเลย)
--   ตัวที่ deploy อยู่อาจเป็นเวอร์ชันเก่าที่ไม่เช็ค → รันทับให้ชัวร์
-- ============================================================
CREATE OR REPLACE FUNCTION transfer_user_cash_to_shop(p_transfers JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_t RECORD;
  v_uc_id TEXT;
  v_cb_id TEXT;
  v_bal NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  -- รอบที่ 1: เช็คว่าเงินสดในกระเป๋าพอทุกสกุลก่อน (ถ้าไม่พอ → ไม่ทำอะไรเลย)
  FOR v_t IN SELECT (value->>'currency') AS currency, (value->>'amount')::numeric AS amount
             FROM jsonb_array_elements(p_transfers) LOOP
    IF v_t.amount <= 0 THEN CONTINUE; END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_bal
    FROM user_cashbook
    WHERE user_id = v_user_id AND method = 'CASH' AND currency = v_t.currency::currency_code;
    IF v_bal < v_t.amount THEN
      RETURN jsonb_build_object('success', false,
        'message', '❌ เงินสด ' || v_t.currency || ' ในกระเป๋าไม่พอ (มี ' || v_bal || ' ต้องการ ' || v_t.amount || ')');
    END IF;
  END LOOP;

  -- รอบที่ 2: หักจากกระเป๋า Sales แล้วเพิ่มเข้าร้าน
  FOR v_t IN SELECT (value->>'currency') AS currency, (value->>'amount')::numeric AS amount
             FROM jsonb_array_elements(p_transfers) LOOP
    IF v_t.amount <= 0 THEN CONTINUE; END IF;

    v_uc_id := 'UC-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_user_id, 'CASH_OUT', -v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer to shop', NOW());

    v_cb_id := 'CB-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer from user cash', NOW(), v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION transfer_user_cash_to_shop(JSONB) TO authenticated;


-- ============================================================
-- ข้อ6) get_diff_summary — total ไม่รวม BUYBACK (ตาม tab Diff ที่ตัด BUYBACK แล้ว)
--   rows ยังคืนครบทุก type (frontend กรองเอง)
-- ============================================================
CREATE OR REPLACE FUNCTION get_diff_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_rows JSONB;
  v_total NUMERIC := 0;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(diff), 0) INTO v_total
  FROM diffs WHERE date BETWEEN v_from AND v_to AND type <> 'BUYBACK';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tx_id', d.tx_id,
    'type', d.type,
    'sell_value', d.sell_value,
    'ex_fee', d.ex_fee,
    'switch_fee', d.switch_fee,
    'premium', d.premium,
    'cost_diff', d.cost_diff,
    'cost_old_gold', d.cost_old_gold,
    'diff', d.diff,
    'date', d.date
  ) ORDER BY d.date DESC), '[]'::jsonb)
  INTO v_rows
  FROM diffs d
  WHERE d.date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_diff_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- ข้อ7) create_exchange_tx — validate บิล Free-Ex ฝั่ง server
--   (เดิมเช็คแค่ฝั่ง JS ซึ่งข้ามได้) กติกาเดียวกับปุ่มตรวจสอบ:
--   บิลมีจริง+ชำระแล้ว / ไม่เกิน 30 วัน / ยังไม่เคยถูกใช้ / จำนวนชิ้นไม่เกินในบิล
-- ============================================================
CREATE OR REPLACE FUNCTION create_exchange_tx(
  p_phone TEXT,
  p_bill_id TEXT,
  p_new_items JSONB,
  p_old_exchange_items JSONB,
  p_switch_items JSONB,
  p_free_ex_items JSONB,
  p_exchange_fee NUMERIC,
  p_switch_fee NUMERIC,
  p_premium NUMERIC,
  p_total NUMERIC,
  p_free_ex_bill_ref TEXT,
  p_sell_1baht NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_ref_id TEXT;
  v_ref_date TIMESTAMPTZ;
  v_avail NUMERIC;
  v_fi RECORD;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อกไม่พอ ' || v_pid);
    END IF;
  END LOOP;

  -- ‼️ validate Free-Ex ฝั่ง server (กติกาเดียวกับปุ่มตรวจสอบใน UI)
  IF p_free_ex_items IS NOT NULL AND jsonb_array_length(COALESCE(p_free_ex_items, '[]'::jsonb)) > 0 THEN
    IF NULLIF(TRIM(COALESCE(p_free_ex_bill_ref, '')), '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ กรุณาระบุบิลอ้างอิงสำหรับ Free Ex');
    END IF;

    SELECT t.id, t.date INTO v_ref_id, v_ref_date
    FROM transactions t
    WHERE t.bill_id = TRIM(p_free_ex_bill_ref)
      AND t.status IN ('COMPLETED', 'PAID')
    ORDER BY t.date DESC LIMIT 1;

    IF v_ref_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ไม่พบบิล ' || TRIM(p_free_ex_bill_ref) || ' ที่ชำระเงินแล้ว');
    END IF;

    IF v_ref_date < NOW() - INTERVAL '30 days' THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ บิลอ้างอิงเกิน 1 เดือนแล้ว ใช้แลก Free Ex ไม่ได้');
    END IF;

    IF EXISTS (SELECT 1 FROM transactions x WHERE x.free_ex_bill_ref = TRIM(p_free_ex_bill_ref)) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ บิลนี้ถูกนำไปแลก Free Ex แล้ว');
    END IF;

    FOR v_fi IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_free_ex_items) LOOP
      SELECT COALESCE(SUM(ti.qty), 0) INTO v_avail
      FROM transaction_items ti
      WHERE ti.tx_id = v_ref_id AND ti.item_role = 'NEW' AND ti.product_id = v_fi.pid;
      IF v_fi.qty > v_avail THEN
        RETURN jsonb_build_object('success', false, 'message',
          '❌ ' || v_fi.pid || ' ในบิลอ้างอิงมี ' || v_avail || ' ชิ้น แต่ขอแลก ' || v_fi.qty || ' ชิ้น');
      END IF;
    END LOOP;
  END IF;

  v_tx_id := generate_tx_id('EXCHANGE');

  INSERT INTO transactions (
    id, type, status, bill_id, phone, sale_user_id,
    ex_fee, switch_fee, premium, free_ex_bill_ref,
    total, currency, date
  )
  VALUES (
    v_tx_id, 'EXCHANGE', 'PENDING', p_bill_id, p_phone, v_user_id,
    COALESCE(p_exchange_fee, 0), COALESCE(p_switch_fee, 0), COALESCE(p_premium, 0), NULLIF(TRIM(COALESCE(p_free_ex_bill_ref, '')), ''),
    p_total, 'LAK', NOW()
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  IF p_old_exchange_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_old_exchange_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  IF p_switch_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_switch_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'SWITCH', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  IF p_free_ex_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_free_ex_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'FREE_EX', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New EXCHANGE waiting for review: ' || v_tx_id, 'Manager', 'exchange', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION create_exchange_tx(TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ8) add_cashbank_entry — เพิ่ม role check (Manager/Admin เท่านั้น)
--   (คงพฤติกรรม R10: balance check ก่อนหัก + Other Expense THB/USD เก็บเรท)
-- ============================================================
DROP FUNCTION IF EXISTS add_cashbank_entry(cashbank_type, NUMERIC, currency_code, TEXT, TEXT, TEXT, NUMERIC);
DROP FUNCTION IF EXISTS add_cashbank_entry(TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION add_cashbank_entry(
  p_type TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_method TEXT,
  p_bank_name TEXT,
  p_note TEXT,
  p_rate NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bank_id UUID := NULL;
  v_cb_id TEXT;
  v_is_deduct BOOLEAN;
  v_eff_currency TEXT := UPPER(p_currency);
  v_eff_amount NUMERIC := ABS(COALESCE(p_amount, 0));
  v_rate NUMERIC := COALESCE(NULLIF(p_rate, 0), 1);
  v_note TEXT := COALESCE(p_note, '');
  v_sell_rate NUMERIC;
  v_orig_amount NUMERIC := ABS(COALESCE(p_amount, 0));
  v_signed_amount NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  -- ‼️ เงินร้านแตะได้เฉพาะ Manager/Admin (เดิมทุก authenticated เรียกตรงได้)
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;
  IF v_eff_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- หา bank_id (สร้างใหม่ถ้ายังไม่มี)
  IF p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    v_bank_id := _resolve_bank_id(p_bank_name);
  END IF;

  -- Other Expense กรอก THB/USD → เก็บสกุลตามจริง + เรทขายล่าสุดในคอลัมน์ rate
  IF p_type = 'OTHER_EXPENSE' AND v_eff_currency <> 'LAK' THEN
    SELECT CASE WHEN v_eff_currency = 'THB' THEN thb_sell
                WHEN v_eff_currency = 'USD' THEN usd_sell
                ELSE NULL END
      INTO v_sell_rate
    FROM price_rates
    ORDER BY date DESC
    LIMIT 1;

    IF v_sell_rate IS NULL OR v_sell_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยังไม่ได้ตั้งเรทขาย ' || v_eff_currency || '/LAK — โปรดตั้งเรทใน Price Rate ก่อนบันทึก Other Expense');
    END IF;

    v_rate := v_sell_rate;
    v_note := TRIM(BOTH ' ' FROM
              COALESCE(NULLIF(v_note, '') || ' ', '')
              || '[= ' || to_char(ROUND(v_orig_amount * v_sell_rate), 'FM999,999,999,990') || ' LAK @ '
              || to_char(v_sell_rate, 'FM999,999,990.######') || ' (Sell)]');
  END IF;

  v_is_deduct := p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE');

  -- เช็คยอดเงินในร้านพอก่อนหัก — ห้ามติดลบ
  IF v_is_deduct THEN
    IF NOT check_shop_balance(p_method, v_eff_currency::currency_code, v_bank_id, v_eff_amount) THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ เงินในร้านไม่พอ: ต้องจ่าย ' || to_char(v_eff_amount, 'FM999,999,999,990') || ' ' || v_eff_currency ||
        CASE WHEN UPPER(COALESCE(p_method, '')) = 'CASH' THEN ' (เงินสด)'
             ELSE ' (' || COALESCE(NULLIF(p_bank_name, ''), 'ธนาคาร') || ')' END);
    END IF;
  END IF;

  v_signed_amount := CASE WHEN v_is_deduct THEN -v_eff_amount ELSE v_eff_amount END;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(random()::text), 1, 6);

  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type::cashbank_type, v_signed_amount, v_eff_currency::currency_code, v_rate,
          p_method, v_bank_id, v_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION add_cashbank_entry(TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ10) delete_tx — บล็อคทั้ง COMPLETED และ PARTIAL
--   (BUYBACK PARTIAL จ่ายเงินออกไปแล้วบางส่วน — ลบแล้วเงินค้างแบบไร้ที่มา)
-- ============================================================
CREATE OR REPLACE FUNCTION delete_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_payload JSONB;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;
  SELECT row_to_json(t)::jsonb INTO v_payload FROM transactions t WHERE id = p_tx_id;
  IF v_payload IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  -- [R12] แนบรายการทอง (เก่า/ใหม่) ลง payload เพื่อให้ Deleted List แสดงได้
  v_payload := v_payload || jsonb_build_object('items', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id', ti.product_id, 'qty', ti.qty, 'item_role', ti.item_role)), '[]'::jsonb)
    FROM transaction_items ti WHERE ti.tx_id = p_tx_id
  ));
  SELECT status INTO v_status FROM transactions WHERE id = p_tx_id;
  IF v_status IN ('COMPLETED', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot delete: transaction has payments (' || v_status || ')');
  END IF;
  INSERT INTO audit_logs (table_name, ref_id, action, payload, user_id)
  VALUES ('transactions', p_tx_id, 'DELETE', v_payload, v_user_id);
  DELETE FROM transactions WHERE id = p_tx_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION delete_tx(TEXT) TO authenticated;


-- ============================================================
-- ข้อ4) get_wealth_summary — ขอบวันแบบ Bangkok (เดิม CURRENT_DATE/::date = UTC
--   → วันตัดที่ 07:00 เช้าไทย, แถววันนี้โผล่ช้า และไม่ตรงกับ Box Wealth)
-- ============================================================
CREATE OR REPLACE FUNCTION get_wealth_summary(p_days INT DEFAULT 30)
RETURNS TABLE (date DATE, carry NUMERIC, net NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  RETURN QUERY
  WITH dates AS (
    SELECT generate_series(
      (v_today - (p_days - 1))::date,
      v_today,
      '1 day'::interval
    )::date AS d
  ),
  daily_net AS (
    SELECT d.d AS dd,
      COALESCE(
        -- [R12] ใช้ snapshot ที่ล็อกไว้ตอนเที่ยงคืน (cron) ก่อน — วันไหนไม่มีค่อยคำนวณสด
        (SELECT dr.net FROM daily_reports dr WHERE dr.date::date = d.d),
        (SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
         FROM stock_moves sm
         WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= d.d),
        0
      ) AS net_val
    FROM dates d
  )
  SELECT dn.dd AS date,
         COALESCE(LAG(dn.net_val) OVER (ORDER BY dn.dd), 0)::NUMERIC AS carry,
         dn.net_val AS net
  FROM daily_net dn
  ORDER BY dn.dd DESC;
END;
$$;
GRANT EXECUTE ON FUNCTION get_wealth_summary(INT) TO authenticated;


-- ============================================================
-- ข้อ6) get_dashboard_data — pl_diff ไม่รวม BUYBACK
--   (คงส่วนอื่นตาม R10: Other Expense รวมเป็น LAK ด้วย rate)
-- ============================================================
CREATE OR REPLACE FUNCTION get_dashboard_data(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_wac JSONB;
  v_pl_diff NUMERIC := 0;
  v_other_expense NUMERIC := 0;
  v_new_pieces NUMERIC := 0;
  v_new_g NUMERIC := 0;
  v_old_pieces NUMERIC := 0;
  v_old_g NUMERIC := 0;
  v_cash JSONB;
  v_banks JSONB;
  v_sales JSONB;
  v_buybacks JSONB;
  v_withdraws JSONB;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT row_to_json(w)::jsonb INTO v_wac FROM wac_state w WHERE id = 1;

  -- ‼️ P/L Diff ไม่รวม BUYBACK (ตามนโยบาย tab Diff)
  SELECT COALESCE(SUM(diff), 0) INTO v_pl_diff
  FROM diffs WHERE date BETWEEN v_from AND v_to AND type <> 'BUYBACK';

  SELECT COALESCE(SUM(ABS(amount) * COALESCE(rate, 1)), 0) INTO v_other_expense
  FROM cashbank WHERE type = 'OTHER_EXPENSE' AND date BETWEEN v_from AND v_to;

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * p.weight_baht * 15), 0)
  INTO v_new_pieces, v_new_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'NEW';

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * p.weight_baht * 15), 0)
  INTO v_old_pieces, v_old_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'OLD';

  SELECT COALESCE(jsonb_object_agg(currency, total), '{}'::jsonb) INTO v_cash FROM (
    SELECT currency::text, COALESCE(SUM(amount), 0) AS total
    FROM cashbank WHERE method = 'CASH' GROUP BY currency
  ) t;

  SELECT COALESCE(jsonb_object_agg(bank_name, balances), '{}'::jsonb) INTO v_banks FROM (
    SELECT b.name AS bank_name,
           COALESCE(
             jsonb_object_agg(cb.currency, COALESCE(cb.total, 0))
               FILTER (WHERE cb.currency IS NOT NULL),
             '{}'::jsonb
           ) AS balances
    FROM banks b
    LEFT JOIN (
      SELECT bank_id, currency::text AS currency, SUM(amount) AS total
      FROM cashbank
      WHERE method <> 'CASH' AND bank_id IS NOT NULL
      GROUP BY bank_id, currency
    ) cb ON cb.bank_id = b.id
    WHERE b.is_active = TRUE
    GROUP BY b.name
  ) t;

  SELECT jsonb_build_object(
    'sell', COALESCE(SUM(CASE WHEN type = 'SELL' THEN total ELSE 0 END), 0),
    'sell_count', COALESCE(SUM(CASE WHEN type = 'SELL' THEN 1 ELSE 0 END), 0),
    'tradein', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN total ELSE 0 END), 0),
    'tradein_count', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN 1 ELSE 0 END), 0),
    'exchange', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN total ELSE 0 END), 0),
    'exchange_count', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN 1 ELSE 0 END), 0)
  ) INTO v_sales
  FROM transactions
  WHERE type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_buybacks
  FROM transactions
  WHERE type = 'BUYBACK' AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1]
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_withdraws
  FROM transactions
  WHERE type = 'WITHDRAW' AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1]
    AND date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'wac', COALESCE(v_wac, '{}'::jsonb),
    'pl_diff', v_pl_diff,
    'other_expense', v_other_expense,
    'new_pieces', v_new_pieces,
    'new_g', v_new_g,
    'old_pieces', v_old_pieces,
    'old_g', v_old_g,
    'cash', v_cash,
    'banks', v_banks,
    'sales', v_sales,
    'buybacks', v_buybacks,
    'withdraws', v_withdraws
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_dashboard_data(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Accounting — get_incomplete_summary (แก้ buyback ไม่มีน้ำหนัก g)
--   เดิม gold_g = SUM(... ) FILTER (item_role='NEW') → buyback ที่มีแต่ item OLD
--   ได้ 0 g เสมอ. แก้: buyback ใช้ OLD, type อื่นใช้ NEW (ทองที่ออกจากสต๊อก)
--   + ตัดวันแบบ Asia/Bangkok ให้ตรงกับ get_dashboard_data
-- ============================================================
CREATE OR REPLACE FUNCTION get_incomplete_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  WITH tx_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, t.total,
           COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (
             WHERE (t.type = 'BUYBACK' AND ti.item_role = 'OLD')
                OR (t.type <> 'BUYBACK' AND ti.item_role = 'NEW')
           ), 0) AS gold_g
    FROM transactions t
    LEFT JOIN transaction_items ti ON ti.tx_id = t.id
    LEFT JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status NOT IN ('COMPLETED', 'PAID', 'REJECTED')
    GROUP BY t.id, t.type, t.total
  )
  SELECT jsonb_build_object(
    'total_money', COALESCE(SUM(total), 0),
    'total_gold_g', COALESCE(SUM(gold_g), 0),
    'sell',     jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='SELL'),0),     'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='SELL'),0),     'count', COUNT(*) FILTER (WHERE tx_type='SELL')),
    'tradein',  jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='TRADEIN'),0),  'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'),0),  'count', COUNT(*) FILTER (WHERE tx_type='TRADEIN')),
    'exchange', jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='EXCHANGE'),0), 'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE'),0), 'count', COUNT(*) FILTER (WHERE tx_type='EXCHANGE')),
    'withdraw', jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='WITHDRAW'),0), 'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='WITHDRAW'),0), 'count', COUNT(*) FILTER (WHERE tx_type='WITHDRAW')),
    'buyback',  jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='BUYBACK'),0),  'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='BUYBACK'),0),  'count', COUNT(*) FILTER (WHERE tx_type='BUYBACK'))
  ) INTO v_result FROM tx_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_incomplete_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Accounting — get_sales_gold_grams_v2 (ให้ตรง money ใน Box Sell)
--   เดิม status IN ('COMPLETED','PAID') + t.date::date (UTC)
--   → ไม่ sync กับ get_dashboard_data.sales (นับ PARTIAL + TZ ไทย)
--   → ต้นทุน/Diff ของ SELL เพี้ยนช่วงคาบเกี่ยววัน. แก้ให้เงื่อนไขตรงกัน
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_gold_grams_v2(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  WITH item_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, ti.item_role,
           SUM(ti.qty * p.weight_baht * 15) AS gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    GROUP BY t.id, t.type, ti.item_role
  )
  SELECT jsonb_build_object(
    'sell_new_g',     COALESCE(SUM(gold_g) FILTER (WHERE tx_type='SELL'     AND item_role='NEW'), 0),
    'tradein_new_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'  AND item_role='NEW'), 0),
    'tradein_old_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'  AND item_role IN ('OLD','FOC')), 0),
    'exchange_new_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE' AND item_role='NEW'), 0),
    'exchange_old_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE' AND item_role IN ('OLD','SWITCH','FREE_EX')), 0),
    'buyback_old_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='BUYBACK'  AND item_role='OLD'), 0),
    'withdraw_new_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='WITHDRAW' AND item_role='NEW'), 0)
  ) INTO v_result FROM item_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_sales_gold_grams_v2(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Wealth snapshot รายวัน (บันทึกยอดทองล็อกไว้ทุกเที่ยงคืนเวลาไทย)
--   daily_reports เก็บ net = ทองคงเหลือสะสม (g) สิ้นวันนั้น, carry = สิ้นวันก่อน
--   get_wealth_summary จะอ่าน snapshot ก่อน (วันไหนไม่มีค่อยคำนวณสด)
-- ============================================================
-- ให้แน่ใจว่าตารางมีคอลัมน์ + unique(date) สำหรับ upsert
ALTER TABLE daily_reports ADD COLUMN IF NOT EXISTS carry NUMERIC DEFAULT 0;
ALTER TABLE daily_reports ADD COLUMN IF NOT EXISTS net   NUMERIC DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS uq_daily_reports_date ON daily_reports(date);

-- ฟังก์ชันบันทึก snapshot ของ "วันที่ระบุ" (default = เมื่อวาน เวลาไทย
-- เพราะ cron รัน 00:05 เวลาไทย → บันทึกยอดสิ้นวันที่เพิ่งจบ)
CREATE OR REPLACE FUNCTION snapshot_daily_wealth(p_date DATE DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_date  DATE := COALESCE(p_date, ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 1));
  v_net   NUMERIC;
  v_carry NUMERIC;
BEGIN
  SELECT COALESCE(SUM(CASE WHEN direction='IN' THEN gold_g ELSE -gold_g END), 0) INTO v_net
    FROM stock_moves WHERE (date AT TIME ZONE 'Asia/Bangkok')::date <= v_date;
  SELECT COALESCE(SUM(CASE WHEN direction='IN' THEN gold_g ELSE -gold_g END), 0) INTO v_carry
    FROM stock_moves WHERE (date AT TIME ZONE 'Asia/Bangkok')::date <= v_date - 1;
  INSERT INTO daily_reports (date, carry, net) VALUES (v_date, v_carry, v_net)
  ON CONFLICT (date) DO UPDATE SET carry = EXCLUDED.carry, net = EXCLUDED.net;
END;
$$;
GRANT EXECUTE ON FUNCTION snapshot_daily_wealth(DATE) TO authenticated;

-- Backfill ครั้งเดียวตอน deploy: ล็อกยอด 60 วันย้อนหลัง (ไม่ทับของเดิมที่มีแล้ว)
INSERT INTO daily_reports (date, carry, net)
SELECT g::date AS d,
       COALESCE((SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
                 FROM stock_moves sm WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= g::date - 1), 0),
       COALESCE((SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
                 FROM stock_moves sm WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= g::date), 0)
FROM generate_series(
       ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 60),
       ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 1),
       '1 day'::interval) g
ON CONFLICT (date) DO NOTHING;

-- ตั้ง pg_cron: รันทุกวัน 17:05 UTC = 00:05 เวลาไทย (บันทึกยอดของวันที่เพิ่งจบ)
-- ห่อด้วย exception handling: ถ้า pg_cron ไม่พร้อม (สิทธิ์/ยังไม่เปิด) จะแค่ SKIP
-- ไม่ทำให้ทั้งสคริปต์ rollback → ค่อยเปิด pg_cron ที่ Dashboard แล้วรันบล็อกนี้ซ้ำ
DO $cronsetup$
BEGIN
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
  BEGIN
    PERFORM cron.unschedule('kpv-daily-wealth');   -- ถ้าเคยตั้งไว้ → ลบก่อน
  EXCEPTION WHEN OTHERS THEN NULL;                  -- ยังไม่เคยตั้ง → ข้าม
  END;
  PERFORM cron.schedule('kpv-daily-wealth', '5 17 * * *', 'SELECT snapshot_daily_wealth();');
  RAISE NOTICE '✅ ตั้ง pg_cron kpv-daily-wealth (00:05 เวลาไทย) สำเร็จ';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '⚠️ ข้ามการตั้ง pg_cron: %  → เปิด pg_cron ที่ Dashboard→Database→Extensions แล้วรันบล็อกนี้ใหม่', SQLERRM;
END
$cronsetup$;


-- ============================================================
-- [R12.1] Single-device session (1 user = 1 เครื่อง)
--   JS (auth.js) มีระบบ kick อยู่แล้ว: login เครื่องใหม่ → broadcast เตะเครื่องเก่า
--   + poll get_my_session ทุก 10 วิ — บล็อกนี้ ensure ฝั่ง DB ให้ครบ (idempotent)
-- ============================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS session_token TEXT;

CREATE OR REPLACE FUNCTION set_my_session(p_session TEXT)
RETURNS JSONB AS $$
DECLARE v_user_id UUID;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  UPDATE users SET session_token = p_session, updated_at = NOW() WHERE id = v_user_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION set_my_session(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_my_session()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_session TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('session_token', NULL);
  END IF;
  SELECT session_token INTO v_session FROM users WHERE id = v_user_id;
  RETURN jsonb_build_object('session_token', v_session);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('session_token', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_my_session() TO authenticated;
