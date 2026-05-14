-- ============================================================
-- next_run.sql (Round 5 — add RPCs for old-feature parity)
-- ============================================================
-- รอบนี้เพิ่ม RPCs ใหม่เพื่อเอา feature เก่า (Google Sheets) กลับมา:
--   1. get_sales_gold_grams_v2 — breakdown per-type (sell/tradein/exchange/buyback/withdraw)
--   2. get_incomplete_summary — รายการ tx ที่ยังไม่ COMPLETED/REJECTED (สำหรับ accounting INCOMPLETE card)
--   3. get_live_report_sales_breakdown — per-sales breakdown (shift status + per-method×currency cash + per-product old gold)
--   4. get_close_report_v2 — เพิ่ม bank_name ใน cashbook (สำหรับ BCEL/LDB row)
--   5. get_history_txs_v2 — เพิ่ม field foc_bill_ref/free_ex_bill_ref/withdraw_code/note/foc_premium_deduct
--
-- ทั้งหมดเป็น **additive** (สร้าง function ใหม่ ไม่แตะของเดิม) เพื่อกัน regression
-- ============================================================


-- ============================================================
-- 1) get_sales_gold_grams_v2(p_date_from, p_date_to)
--    คืน gram per-type เพื่อให้ accounting คำนวณ cost แยก type ถูกต้อง
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_gold_grams_v2(
  p_date_from DATE,
  p_date_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH item_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, ti.item_role,
           SUM(ti.qty * p.weight_baht * 15) AS gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID')
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
  )
  INTO v_result
  FROM item_g;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_gold_grams_v2(DATE, DATE) TO authenticated;


-- ============================================================
-- 2) get_incomplete_summary(p_date_from, p_date_to)
--    คืน รายการ tx ที่ status NOT IN COMPLETED/PAID/REJECTED แยก type
-- ============================================================
CREATE OR REPLACE FUNCTION get_incomplete_summary(
  p_date_from DATE,
  p_date_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH tx_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, t.total,
           COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE ti.item_role='NEW'), 0) AS gold_g
    FROM transactions t
    LEFT JOIN transaction_items ti ON ti.tx_id = t.id
    LEFT JOIN products p ON p.id = ti.product_id
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
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
  )
  INTO v_result
  FROM tx_g;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_incomplete_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- 3) get_live_report_sales_breakdown(p_date_from, p_date_to)
--    per-sales: shift status + sell/buyback/withdraw amount + per-product old gold
--    + cash_breakdown (Cash/BCEL/LDB/Other × LAK/THB/USD)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report_sales_breakdown(
  p_date_from DATE,
  p_date_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  WITH active_sales AS (
    -- รับทั้ง 'Sales' และ 'User' (case-insensitive — กัน enum/casing แตกต่าง)
    SELECT u.id AS user_id, u.nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
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
    -- ทองเก่าที่ Sales ได้รับ (ยังไม่ settled = อยู่กับ Sales)
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
    -- breakdown: Cash/BCEL/LDB/Other × LAK/THB/USD
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
  shift_status AS (
    SELECT
      c.user_id,
      MAX(CASE WHEN c.status='PENDING' THEN 'PENDING'
               WHEN c.status='APPROVED' THEN 'CLOSED'
               ELSE NULL END) AS shift_status
    FROM closes c
    WHERE c.date::date = v_today
    GROUP BY c.user_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'user_id',         a.user_id,
      'nickname',        a.nickname,
      'shift_status',    COALESCE(ss.shift_status, 'OPEN'),
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
  LEFT JOIN tx_per_sale tps ON tps.sale_user_id = a.user_id
  LEFT JOIN gold_g_per_sale ggs ON ggs.sale_user_id = a.user_id
  LEFT JOIN old_gold_per_sale ogs ON ogs.sale_user_id = a.user_id
  LEFT JOIN cash_per_sale cps ON cps.user_id = a.user_id
  LEFT JOIN shift_status ss ON ss.user_id = a.user_id;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION get_live_report_sales_breakdown(DATE, DATE) TO authenticated;


-- ============================================================
-- 4) เพิ่ม view เพื่อ join cashbook ↔ bank name (ใช้ใน close summary modal)
--    คืน rows ของ user_cashbook + bank_name field
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
    AND ucb.date::date = p_date;
END;
$$;

GRANT EXECUTE ON FUNCTION get_close_cashbook(UUID, DATE) TO authenticated;


-- ============================================================
-- หมายเหตุสำคัญ — RPC เดิมที่ผมไม่ได้แตะ (เพื่อกัน regression):
-- ============================================================
--   - get_dashboard_data          → ยังใช้ของเดิม
--   - get_sales_gold_grams         → ยังใช้ของเดิม (frontend เรียก v2 แทนที่ตรงที่ต้องการ per-type)
--   - get_close_report             → ยังใช้ของเดิม + frontend เรียก get_close_cashbook เพิ่มเอา bank breakdown
--   - get_history_txs              → ยังใช้ของเดิม
--                                   ⚠️ ถ้า frontend ต้องการ field foc_bill_ref/free_ex_bill_ref/
--                                       withdraw_code/foc_premium_deduct/note เพิ่ม → ต้อง dump
--                                       source ของ get_history_txs มาให้ก่อน (รัน query นี้
--                                       แล้วส่งกลับ): SELECT pg_get_functiondef(oid)
--                                       FROM pg_proc WHERE proname='get_history_txs';
--
-- ⚠️ Reports auto back-fill (#11): ต้องตั้ง pg_cron job (Supabase Dashboard) call
--    procedure ที่คำนวณ daily_report ของวันก่อน — ผมยังไม่ทำใน round นี้
--    เพราะต้องดู logic เดิมของ AUTO_CALCULATE_REPORTS ใน Google Apps Script
--
-- ============================================================
-- ทดสอบหลังรัน:
-- ============================================================
--   -- per-type gram breakdown
--   SELECT get_sales_gold_grams_v2(CURRENT_DATE, CURRENT_DATE);
--
--   -- incomplete summary
--   SELECT get_incomplete_summary(CURRENT_DATE, CURRENT_DATE);
--
--   -- live report sales breakdown
--   SELECT get_live_report_sales_breakdown(CURRENT_DATE, CURRENT_DATE);
--
--   -- close cashbook (replace user_id + date)
--   SELECT * FROM get_close_cashbook('USER_UUID_HERE'::uuid, CURRENT_DATE);
