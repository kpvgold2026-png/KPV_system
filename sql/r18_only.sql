-- KPV R18 only — การ์ด Sales ในหน้า Report: ปิดกะแล้วยังโชว์ยอด (ข้ามเที่ยงคืนด้วย) จนกว่าจะเปิดกะใหม่

CREATE OR REPLACE FUNCTION get_live_report_sales_breakdown(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
BEGIN
  WITH active_sales AS (
    SELECT u.id AS user_id,
           COALESCE(NULLIF(TRIM(u.nickname), ''), u.username) AS nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
      AND COALESCE(u.is_active, TRUE) = TRUE
  ),
  -- [R18] สถานะกะ = เทียบ "เปิดกะล่าสุด" กับ "ปิดกะล่าสุด (PENDING/APPROVED)" ไม่ผูกกับวันนี้
  --   ปิดกะแล้วยังไม่เปิดกะใหม่ (ข้ามเที่ยงคืนก็ตาม) → is_closed = TRUE → โชว์ยอด ณ ตอนกดปิดกะ
  --   ยอดจะหายไปก็ต่อเมื่อเปิดกะใหม่ (open_ts > close_ts)
  last_open AS (
    SELECT user_id, MAX(date) AS ts
    FROM user_cashbook
    WHERE type = 'OPEN_SHIFT'
    GROUP BY user_id
  ),
  last_close AS (
    SELECT DISTINCT ON (user_id) user_id, id, date AS ts, status
    FROM closes
    WHERE status IN ('PENDING', 'APPROVED')
    ORDER BY user_id, date DESC
  ),
  shift AS (
    SELECT a.user_id,
           lc.id AS close_id,
           lc.ts AS close_ts,
           lc.status AS close_st,
           lo.ts AS open_ts,
           (lc.ts IS NOT NULL AND (lo.ts IS NULL OR lc.ts > lo.ts)) AS is_closed
    FROM active_sales a
    LEFT JOIN last_open lo ON lo.user_id = a.user_id
    LEFT JOIN last_close lc ON lc.user_id = a.user_id
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
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW') AND ti.item_role='NEW'), 0) AS sell_gold_g,
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type='BUYBACK' AND ti.item_role='OLD'), 0) AS bb_gold_g,
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type='WITHDRAW' AND ti.item_role='NEW'), 0) AS wd_gold_g
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
      SELECT g.user_id, g.product_id, SUM(g.qty) AS qty_sum
      FROM user_gold_received g
      JOIN shift s ON s.user_id = g.user_id
      -- [R18] กะเปิดอยู่ → ทองที่ยังไม่ settle ; ปิดกะแล้ว → ทองของกะนั้น
      --   (PENDING: ยังไม่ settle และรับก่อนกดปิด ; APPROVED: settle ด้วย close นี้)
      WHERE (NOT s.is_closed AND g.settled = FALSE)
         OR (s.is_closed AND ((g.settled = FALSE AND g.date <= s.close_ts)
                              OR g.settled_close_id = s.close_id))
      GROUP BY g.user_id, g.product_id
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
    JOIN shift s ON s.user_id = ucb.user_id
    -- [R18] ปิดกะแล้ว → ตัดที่เวลากดปิดกะ: รายการกวาดเงินตอน approve ลงวันที่ทีหลัง
    --       จึงไม่ถูกนับ → ยอดค้างเท่าตอนปิดกะ จนกว่าจะเปิดกะใหม่
    WHERE NOT s.is_closed OR ucb.date <= s.close_ts
    -- [R12] "เงินที่ถือ" = ยอดสะสมทั้งกระเป๋า (ไม่ filter วัน) ให้เป็นสถานะปัจจุบัน
    --       เหมือน old_gold (settled=false) — หลังปิดกะ+approve กระเป๋าถูกกวาดเป็น 0
    --       ดังนั้นยอดสะสม = เงินที่ Sales ถืออยู่จริงตอนนี้ (p_date_* ยังใช้กับยอด tx/ทอง)
    GROUP BY ucb.user_id
  ),
  close_status AS (
    SELECT
      s.user_id,
      CASE WHEN s.is_closed AND s.close_st = 'PENDING'  THEN 'PENDING'
           WHEN s.is_closed AND s.close_st = 'APPROVED' THEN 'CLOSED'
           WHEN s.open_ts IS NOT NULL                   THEN 'OPEN'
           ELSE 'NOT_OPEN' END AS s,
      CASE WHEN s.is_closed THEN (s.close_ts AT TIME ZONE 'Asia/Bangkok')::date END AS close_date
    FROM shift s
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'user_id',         a.user_id,
      'nickname',        a.nickname,
      'shift_status',    COALESCE(cs.s, 'NOT_OPEN'),
      'close_date',      cs.close_date,
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
  LEFT JOIN close_status cs ON cs.user_id = a.user_id;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION get_live_report_sales_breakdown(DATE, DATE) TO authenticated;
