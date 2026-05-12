-- ============================================================
-- Next-edit fixes
-- ============================================================
-- 1. open_shift  → เช็คเงินสด LAK ในร้าน + หักเงินตอนเปิดกะ
-- 3. banks seed  → ใส่ row สำหรับ BCEL/LDB/OTHER ที่ dropdown ใช้
--    + get_cashbank_balances ทนต่อ bank ที่ยังไม่มี tx
-- 5. stock_in    → ลบ cashbank_ref_tx_id_fkey violation
--
-- วิธีใช้: รันทั้งไฟล์ใน Supabase SQL Editor
-- ============================================================


-- ============================================================
-- #1: open_shift — เช็ค + หักเงินสด LAK ในร้าน
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
  v_shop_cash NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_shop_cash
  FROM cashbank
  WHERE method = 'CASH' AND currency = 'LAK';

  IF v_shop_cash < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'เงินสดในร้านไม่พอ (มี ' || to_char(v_shop_cash, 'FM999,999,999') ||
                 ' LAK, ต้องการ ' || to_char(p_amount, 'FM999,999,999') || ' LAK)'
    );
  END IF;

  v_id := 'SHIFT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
          || '-' || substring(p_user_id::text, 1, 4);
  v_cb_id := 'CB-' || v_id;

  -- หักจากเงินสดร้าน (cashbank)
  INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
  VALUES (v_cb_id, 'OPEN_SHIFT', -p_amount, 'LAK', 'CASH',
          'Open shift: ' || v_id, NOW(), p_user_id);

  -- บวกเข้าลิ้นชักพนักงาน (user_cashbook)
  INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
  VALUES (v_id, p_user_id, 'OPEN_SHIFT', p_amount, 'LAK', 'CASH', 'Open shift', NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION open_shift(UUID, NUMERIC) TO authenticated;


-- ============================================================
-- #3a: seed banks ที่ dropdown ใช้
-- ============================================================
INSERT INTO banks (name, is_active, sort_order)
SELECT v.name, TRUE, v.ord
FROM (VALUES ('BCEL', 1), ('LDB', 2), ('OTHER', 3)) AS v(name, ord)
WHERE NOT EXISTS (SELECT 1 FROM banks b WHERE b.name = v.name);


-- ============================================================
-- #3b: add_cashbank_entry → auto-create bank ถ้ายังไม่มี
-- ============================================================
CREATE OR REPLACE FUNCTION add_cashbank_entry(
  p_type cashbank_type,
  p_amount NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_name TEXT,
  p_note TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bank_id UUID := NULL;
  v_cb_id TEXT;
  v_signed_amount NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  IF p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    SELECT id INTO v_bank_id FROM banks WHERE name = p_bank_name LIMIT 1;
    IF v_bank_id IS NULL THEN
      INSERT INTO banks (name, is_active) VALUES (p_bank_name, TRUE)
      RETURNING id INTO v_bank_id;
    END IF;
  END IF;

  v_signed_amount := CASE
    WHEN p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE') THEN -ABS(p_amount)
    WHEN p_type IN ('CASH_IN', 'BANK_IN', 'BANK_DEPOSIT', 'OTHER_INCOME') THEN ABS(p_amount)
    ELSE p_amount
  END;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(random()::text), 1, 6);

  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type, v_signed_amount, p_currency, p_method, v_bank_id, p_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION add_cashbank_entry(cashbank_type, NUMERIC, currency_code, TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- #3c: get_cashbank_balances ทนต่อ bank ที่ยังไม่มี tx
-- ============================================================
CREATE OR REPLACE FUNCTION get_cashbank_balances()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cash JSONB;
  v_banks JSONB;
BEGIN
  SELECT COALESCE(jsonb_object_agg(currency, total), '{}'::jsonb) INTO v_cash FROM (
    SELECT currency::text, COALESCE(SUM(amount), 0) AS total
    FROM cashbank
    WHERE method = 'CASH'
    GROUP BY currency
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

  RETURN jsonb_build_object('cash', v_cash, 'banks', v_banks);
END;
$$;

GRANT EXECUTE ON FUNCTION get_cashbank_balances() TO authenticated;


-- ============================================================
-- #5: stock_in_new_tx — ลบ ref_tx_id ที่ทำให้ FK พัง
-- ============================================================
-- ref_tx_id อ้าง transactions(id) แต่ STOCK_IN ไม่มี transactions row
-- → ส่ง NULL แทน v_ref_id
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
  v_pid TEXT;
  v_qty NUMERIC;
  v_weight NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_admin() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
              || '-' || substring(md5(random()::text), 1, 4);

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

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

  FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    DECLARE
      v_method TEXT := v_pay->>'method';
      v_bank_name TEXT := v_pay->>'bank';
      v_cur TEXT := COALESCE(v_pay->>'currency', 'LAK');
      v_amount NUMERIC := (v_pay->>'amount')::numeric;
      v_rate NUMERIC := COALESCE((v_pay->>'rate')::numeric, 1);
      v_fee NUMERIC := COALESCE((v_pay->>'fee')::numeric, 0);
      v_bank_id UUID := NULL;
    BEGIN
      IF v_method = 'Bank' AND v_bank_name IS NOT NULL AND v_bank_name <> '' THEN
        SELECT id INTO v_bank_id FROM banks WHERE name = v_bank_name LIMIT 1;
        IF v_bank_id IS NULL THEN
          INSERT INTO banks (name, is_active) VALUES (v_bank_name, TRUE)
          RETURNING id INTO v_bank_id;
        END IF;
      END IF;

      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                 || '-' || substring(md5(random()::text || v_method), 1, 6);
      -- ref_tx_id = NULL เพราะ STOCK_IN ไม่มี transactions row (จะติด FK)
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code,
              CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(p_note, 'Stock In NEW') || ' [' || v_ref_id || ']', NOW(), v_user_id);

      IF v_fee > 0 THEN
        v_cb_id := 'CB-FEE-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                   || '-' || substring(md5(random()::text), 1, 4);
        INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
        VALUES (v_cb_id, 'STOCK_IN_FEE', -v_fee, v_cur::currency_code, 'TRANSFER',
                v_bank_id, NULL,
                'Stock In Fee [' || v_ref_id || ']', NOW(), v_user_id);
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Stock In สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION stock_in_new_tx(JSONB, TEXT, NUMERIC, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- bonus: get_dashboard_data ก็มี bug เดียวกัน
-- ============================================================
-- Dashboard ของ admin โหลดไม่ขึ้นถ้ามี bank ที่ยังไม่มี tx
-- → patch inner jsonb_object_agg(cb.currency, ...) ด้วย FILTER

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

  SELECT COALESCE(SUM(diff), 0) INTO v_pl_diff
  FROM diffs WHERE date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ABS(amount)), 0) INTO v_other_expense
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
    AND status IN ('COMPLETED', 'PAID')
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_buybacks
  FROM transactions
  WHERE type = 'BUYBACK' AND status IN ('COMPLETED', 'PAID')
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_withdraws
  FROM transactions
  WHERE type = 'WITHDRAW' AND status IN ('COMPLETED', 'PAID')
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
-- ทดสอบหลังรัน
-- ============================================================
--   SELECT name, is_active FROM banks ORDER BY sort_order;          -- ต้องมี BCEL, LDB, OTHER
--   SELECT * FROM get_cashbank_balances();                          -- ต้องไม่ error
--   SELECT * FROM get_dashboard_data(CURRENT_DATE, CURRENT_DATE);   -- ต้องไม่ error
