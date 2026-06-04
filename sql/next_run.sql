-- ============================================================
-- KPV — Round 9 (2026-06-04)  [เขียนทับ next_run.sql เดิม]
-- รัน idempotent ได้ มีแค่ฟังก์ชันที่แก้รอบนี้
--   ข้อ2: stock_in_new_tx          — เช็คยอดร้านพอก่อน + หักเงินจาก cashbank
--   ข้อ6: get_close_cashbook        — filter วันที่แบบ Bangkok (OPEN_SHIFT float ไม่หลุด)
--   ข้อ4: get_live_report           — diff = ปัจจุบัน − เมื่อวาน
--   ข้อ3: get_live_report_sales_breakdown — แสดงชื่อ (nickname→username) + ไม่ตัด is_active NULL
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
