-- ============================================================
-- KPV — Round 9 (2026-06-04)  [เขียนทับ next_run.sql เดิม]
-- รัน idempotent ได้ มีแค่ฟังก์ชันที่แก้รอบนี้
--   ข้อ2: stock_in_new_tx          — เช็คยอดร้านพอก่อน + หักเงินจาก cashbank
--   ข้อ6: get_close_cashbook        — filter วันที่แบบ Bangkok (OPEN_SHIFT float ไม่หลุด)
--   ข้อ4: get_live_report           — diff = ปัจจุบัน − เมื่อวาน
--   ข้อ3: get_live_report_sales_breakdown — แสดงชื่อ (nickname→username) + ไม่ตัด is_active NULL
--   DIFF: confirm_sell/tradein/exchange/withdraw — แก้สูตร Diff ให้ตรงชีทเก่า
--         (recompute newSellTotal/oldSellTotal จาก items×sell_1baht ตามสูตรราคาขาย)
-- ============================================================


-- ============================================================
-- ข้อ2) stock_in_new_tx — เช็คยอดร้าน (cashbank) พอก่อนหัก แล้วค่อยบันทึก
--   • เช็ค balance ต่อ (วิธีจ่าย × สกุล × ธนาคาร) ก่อน INSERT ใดๆ (กันหักจนติดลบ)
--   • cashbank row = -amount (เงินออกจากร้าน) ผูก ref ผ่าน [ref:SIN-..] ใน note
--   • ดูรายละเอียดการจ่ายผ่านปุ่ม View (get_stock_move_detail) ในแท็บ Cash/Bank
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

  -- ‼️ เช็คยอดเงินในร้านพอก่อนหัก (รวมยอดต่อ วิธีจ่าย×สกุล×ธนาคาร รวมค่าธรรมเนียมด้วย)
  FOR v_chk IN
    SELECT
      CASE WHEN (pe.elem->>'method') = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END AS m,
      COALESCE(pe.elem->>'currency', 'LAK') AS cur,
      NULLIF(pe.elem->>'bank', '') AS bankname,
      SUM( (pe.elem->>'amount')::numeric + COALESCE((pe.elem->>'fee')::numeric, 0) ) AS need
    FROM jsonb_array_elements(p_payments) AS pe(elem)
    GROUP BY 1, 2, 3
  LOOP
    v_chk_bank_id := NULL;
    IF v_chk.m = 'TRANSFER' AND v_chk.bankname IS NOT NULL THEN
      SELECT id INTO v_chk_bank_id FROM banks WHERE name = v_chk.bankname LIMIT 1;
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

  -- หักเงินออกจากร้าน (cashbank) ต่อรายการจ่าย
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
      END IF;

      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_method), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code, v_rate,
              CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(NULLIF(p_note, ''), 'Stock In NEW') || ' [ref:' || v_ref_id || ']',
              NOW(), v_user_id);

      IF v_fee > 0 THEN
        v_cb_id := 'CB-FEE-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text), 1, 4);
        INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
        VALUES (v_cb_id, 'STOCK_IN_FEE', -v_fee, v_cur::currency_code, v_rate, 'TRANSFER', v_bank_id, NULL,
                'Stock In Fee [ref:' || v_ref_id || ']', NOW(), v_user_id);
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
-- ข้อ6) get_close_cashbook — filter วันที่แบบ Bangkok
--   เดิม ucb.date::date (UTC) ≠ p_date (Bangkok) → OPEN_SHIFT float ของกะหลุด
--   → ยอดเงินสดตอนปิดกะขึ้น 0 ทั้งที่เปิดกะมาด้วยเงินสด
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
  RETURN QUERY
  SELECT ucb.amount, ucb.currency::text, ucb.method, ucb.bank_id, b.name
  FROM user_cashbook ucb
  LEFT JOIN banks b ON b.id = ucb.bank_id
  WHERE ucb.user_id = p_user_id
    AND (ucb.date AT TIME ZONE 'Asia/Bangkok')::date = p_date;
END;
$$;
GRANT EXECUTE ON FUNCTION get_close_cashbook(UUID, DATE) TO authenticated;


-- ============================================================
-- ข้อ4) get_live_report (Box Wealth) — diff = ปัจจุบัน − เมื่อวาน
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB AS $$
DECLARE
  v_today DATE;
  v_today_start TIMESTAMPTZ;   -- = สิ้นสุดเมื่อวาน
  v_current NUMERIC := 0;      -- ทองคงเหลือปัจจุบัน (g)
  v_yest NUMERIC := 0;         -- ทองคงเหลือสิ้นวันเมื่อวาน (g)
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_today_start := (v_today::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_current FROM stock_moves;

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_yest FROM stock_moves WHERE date < v_today_start;

  RETURN jsonb_build_object(
    'netTotal', v_current,           -- ทองปัจจุบัน
    'carryForward', v_yest,          -- ทองเมื่อวาน (ยอดยกมา)
    'diff', v_current - v_yest       -- ปัจจุบัน − เมื่อวาน (บวก = ทองเพิ่มขึ้นวันนี้)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;


-- ============================================================
-- ข้อ3) get_live_report_sales_breakdown — แสดงชื่อคนให้ถูก
--   • nickname ว่าง/NULL → ใช้ username (รหัส) แทน (ไม่โผล่เป็น role)
--   • COALESCE(is_active, TRUE) → user ที่ is_active = NULL ไม่ถูกตัดทิ้ง (ไม่ fallback ไป view เก่า)
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
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID')
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
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID')
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
    WHERE ucb.date::date BETWEEN p_date_from AND p_date_to
    GROUP BY ucb.user_id
  ),
  close_status AS (
    SELECT
      c.user_id,
      MAX(CASE WHEN c.status='PENDING' THEN 'PENDING'
               WHEN c.status='APPROVED' THEN 'CLOSED'
               ELSE NULL END) AS s
    FROM closes c
    WHERE c.date::date = v_today
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
-- DIFF FIX — สูตรตาราง Diff ให้ตรงกับชีทเก่า (ที่ใช้งานได้)
--   คอลัมน์: sell_value=ราคาขายใหม่ | ex_fee | switch_fee | premium
--           cost_diff=ต้นทุน WAC | cost_old_gold=ราคาขายเก่า | diff=กำไร
--   SELL      : diff = ขายใหม่ + premium − (น้ำหนักใหม่ × WAC)
--   TRADEIN   : diff = ขายใหม่ + premium − ((น้ำหนักใหม่ − น้ำหนักเก่า) × WAC) − ขายเก่า
--   EXCHANGE  : diff = ขายใหม่ + exFee + swFee + premium − ขายเก่า   (ไม่คิด WAC)
--   WITHDRAW  : diff = 0  (ทุกค่า = 0 ; กำไรถูกบันทึกตอนฝากแล้ว)
-- ============================================================

-- helper: ราคาขายต่อชิ้น (ตรงกับ calculateSellPrice ใน utils.js — ปัดพัน, G07 พิเศษ)
CREATE OR REPLACE FUNCTION _diff_sell_price(p_pid TEXT, p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_pid
    WHEN 'G01' THEN ROUND(p_s1b * 10 / 1000.0) * 1000
    WHEN 'G02' THEN ROUND(p_s1b * 5  / 1000.0) * 1000
    WHEN 'G03' THEN ROUND(p_s1b * 2  / 1000.0) * 1000
    WHEN 'G04' THEN ROUND(p_s1b       / 1000.0) * 1000
    WHEN 'G05' THEN ROUND((p_s1b / 2) / 1000.0) * 1000
    WHEN 'G06' THEN ROUND((p_s1b / 4) / 1000.0) * 1000
    WHEN 'G07' THEN CEIL((p_s1b / 15.0 + 120000) / 1000.0) * 1000
    ELSE 0 END;
$$;

-- helper: รวมราคาขายของ items ใน tx ตาม role (newSellTotal / oldSellTotal)
CREATE OR REPLACE FUNCTION _diff_items_sell_total(p_tx_id TEXT, p_roles TEXT[], p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(ti.qty * _diff_sell_price(ti.product_id, p_s1b)), 0)
  FROM transaction_items ti
  WHERE ti.tx_id = p_tx_id AND ti.item_role::text = ANY(p_roles);
$$;

-- helper: sell_1baht ที่ใช้ = ของ tx (ถ้ามี) → ไม่งั้น pricing แถวล่าสุด
CREATE OR REPLACE FUNCTION _diff_sell_1baht(p_tx_sell_1baht NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(p_tx_sell_1baht, 0),
                  (SELECT sell_1baht FROM pricing ORDER BY date DESC LIMIT 1),
                  0);
$$;


-- ============================================================
-- DIFF) confirm_sell_tx — diff = ขายใหม่ + premium − (น้ำหนักใหม่ × WAC)
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_sell_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
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
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.phone, t.premium, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_phone, v_premium, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'SELL';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Transaction not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
        currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

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

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW());
  END IF;

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
GRANT EXECUTE ON FUNCTION confirm_sell_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- DIFF) confirm_tradein_tx — diff = ขายใหม่ + premium − ((ใหม่−เก่า)×WAC) − ขายเก่า
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_tradein_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
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
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'TRADEIN';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

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
  v_cost_diff := (v_new_gold_g - v_old_gold_g) * v_wac_per_g;   -- ‼️ ต้นทุน "ส่วนต่าง" (ชีท)

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
        currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

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

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW());
  END IF;

  -- DIFF (ชีท): sell_value = ขายใหม่ ; cost_diff = (ใหม่−เก่า)×WAC ; cost_old_gold = ขายเก่า
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
GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- DIFF) confirm_exchange_tx — diff = ขายใหม่ + exFee + swFee + premium − ขายเก่า (ไม่คิด WAC)
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_exchange_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
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
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_new_gold_g := calc_items_gold_g(v_new_items);

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);
  v_old_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
        currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

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

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW());
  END IF;

  -- DIFF (ชีท): ไม่คิด WAC (cost_diff=0) ; diff = ขายใหม่ + exFee + swFee + premium − ขายเก่า
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
GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- DIFF) confirm_withdraw_tx — diff = 0 (กำไรบันทึกตอนฝากแล้ว ; ทุกค่า Diff = 0)
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_withdraw_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total INTO v_status, v_total
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'WITHDRAW';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change, currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

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

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'WITHDRAW', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Withdraw ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'WITHDRAW', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Withdraw ' || p_tx_id, NOW());
  END IF;

  -- DIFF (ชีท): WITHDRAW ทุกค่า = 0 (กำไรถูกบันทึกตอนรับฝากทองแล้ว)
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
GRANT EXECUTE ON FUNCTION confirm_withdraw_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- (ทางเลือก) recompute_diffs — แก้ตาราง Diff ย้อนหลังด้วยสูตรใหม่
--   ⚠️ ใช้ WAC + ราคาขายปัจจุบัน (เหมือนชีท) → แถวเก่าจะสะท้อนเรตปัจจุบัน
--   เรียกเอง: SELECT recompute_diffs('2026-01-01','2026-12-31');
--   ไม่ถูกรันอัตโนมัติตอนรันไฟล์นี้ (นิยามไว้เฉยๆ)
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
  v_old_cost NUMERIC;
  v_diff NUMERIC;
  v_n INT := 0;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager/Admin only');
  END IF;

  FOR v_t IN
    SELECT id, type, COALESCE(premium,0) AS premium, COALESCE(ex_fee,0) AS ex_fee,
           COALESCE(switch_fee,0) AS switch_fee, COALESCE(sell_1baht,0) AS sell_1baht
    FROM transactions
    WHERE type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW')
      AND status IN ('COMPLETED','PAID')
      AND date::date BETWEEN p_from AND p_to
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
      VALUES (v_t.id, 'SELL', v_new_sell, 0, 0, v_t.premium, v_cost_diff, 0, v_diff, NOW())
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
      VALUES (v_t.id, 'TRADEIN', v_new_sell, 0, 0, v_t.premium, v_cost_diff, v_old_sell, v_diff, NOW())
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=0, switch_fee=0,
        premium=EXCLUDED.premium, cost_diff=EXCLUDED.cost_diff, cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSIF v_t.type = 'EXCHANGE' THEN
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_old_sell := _diff_items_sell_total(v_t.id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);
      v_diff := v_new_sell + v_t.ex_fee + v_t.switch_fee + v_t.premium - v_old_sell;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'EXCHANGE', v_new_sell, v_t.ex_fee, v_t.switch_fee, v_t.premium, 0, v_old_sell, v_diff, NOW())
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=EXCLUDED.ex_fee,
        switch_fee=EXCLUDED.switch_fee, premium=EXCLUDED.premium, cost_diff=0,
        cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSE  -- WITHDRAW
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'WITHDRAW', 0, 0, 0, 0, 0, 0, 0, NOW())
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=0, ex_fee=0, switch_fee=0, premium=0,
        cost_diff=0, cost_old_gold=0, diff=0;
    END IF;

    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'recomputed', v_n);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION recompute_diffs(DATE, DATE) TO authenticated;
