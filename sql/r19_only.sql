-- KPV R19 only — R19-1 Buyback ยอดค้าง ≤ 500 LAK ปิดบิลได้ทุกสกุล (รวม LAK) ; R19-2 การ์ด Sales หน้า Report: ปิดกะแล้วโชว์ยอดถึงเที่ยงคืน (รออนุมัติ = โชว์ต่อ) ; R19-3 แก้ไขการชำระเงินบิลที่จบแล้ว

-- [R19-1]
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);

CREATE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_fee NUMERIC DEFAULT 0, p_change NUMERIC DEFAULT 0,
  p_allow_short BOOLEAN DEFAULT FALSE
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
  ELSIF COALESCE(p_allow_short, FALSE) AND v_new_balance <= 500 THEN
    -- [R19-1] ยอดค้าง ≤ 500 LAK (ทุกสกุล รวม LAK) → ถือว่าจ่ายครบตาม Total
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
    v_total_paid := v_price;
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
         COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)), 0)
    INTO v_total_qty, v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD';

  -- [R15-8] PriceIn ต่อชิ้นของ Buyback = เงินที่จ่ายจริงของบิล "แบ่งตามน้ำหนัก" แต่ละชิ้น
  --   เดิม = price ÷ จำนวนชิ้น (บิลผสมหลายขนาด → 10 บาท กับ 1 กรัม ได้ราคาต่อชิ้นเท่ากัน = ผิด)
  --   ผลรวมทุกชิ้น = price ของบิลพอดี (ปัดทศนิยม 2 ตำแหน่ง)
  IF NOT EXISTS (SELECT 1 FROM user_gold_received WHERE ref_tx_id = p_tx_id) THEN
    FOR v_item IN SELECT ti.product_id, ti.qty, _gold_g(p.weight_baht) AS g
                  FROM transaction_items ti JOIN products p ON p.id = ti.product_id
                  WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD' LOOP
      v_price_per_unit := CASE WHEN v_old_gold_g > 0
                               THEN ROUND(v_price * v_item.g / v_old_gold_g, 2)
                               WHEN v_total_qty > 0 THEN ROUND(v_price / v_total_qty, 2)
                               ELSE 0 END;
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
GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN) TO authenticated;


-- [R19-2]
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
  -- [R18 → R19-2] สถานะกะ = เทียบ "เปิดกะล่าสุด" กับ "ปิดกะล่าสุด (PENDING/APPROVED)"
  --   ปิดกะแล้ว (APPROVED) → โชว์ยอด ณ ตอนกดปิดกะ "เฉพาะวันที่ปิด" ; เลย 00:00 → ยังไม่เปิดกะ + ยอดรีเซ็ต
  --   รอ Manager ยืนยัน (PENDING) → โชว์ยอดค้างไว้จนกว่าจะอนุมัติ (ข้ามเที่ยงคืนก็ตาม)
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
           (lc.ts IS NOT NULL AND (lo.ts IS NULL OR lc.ts > lo.ts)) AS closed_after_open,
           (lc.ts IS NOT NULL AND (lo.ts IS NULL OR lc.ts > lo.ts)
            AND (lc.status = 'PENDING'
                 OR (lc.ts AT TIME ZONE 'Asia/Bangkok')::date = (NOW() AT TIME ZONE 'Asia/Bangkok')::date)
           ) AS is_closed
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
           WHEN s.closed_after_open                     THEN 'NOT_OPEN'  -- [R19-2] ปิดกะของวันก่อน
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


-- ============================================================
-- [R19-3] แก้ไขการชำระเงินของบิลที่จบแล้ว (Manager/Admin เท่านั้น)
--   แก้ได้: วิธีจ่าย (เงินสด/โอน), สกุลเงิน, ธนาคาร, แบ่งยอด, เงินทอน — ยอดบิล (total/price) เท่าเดิม
--   ลงบัญชีเป็น "ส่วนต่าง" ต่อ (วิธีจ่าย × สกุล × ธนาคาร) = ใหม่ − เดิม (ลงวันที่ตอนแก้)
--   ใครถือเงินของบิลนี้อยู่ (ledger):
--     SHIFT = Sales เป็นคนรับ/จ่าย และกะนั้นยังไม่ปิด → กระเป๋า Sales (user_cashbook)
--             (เงินโอนลง cashbank ร้านด้วยเหมือนตอนยืนยันบิล)
--     SHOP  = Manager/Admin เป็นคนรับ/จ่าย หรือกะของ Sales อนุมัติปิดแล้ว → เงินร้าน (cashbank)
--     ห้ามแก้ = กะส่งปิดแล้วแต่ยังรอ Manager อนุมัติ (PENDING) / บิลจ่ายข้ามกะ / มีผู้รับเงินหลายคน
--   ช่องที่ยอดลดลง ต้องมีเงินพอ ไม่พอ = ไม่แก้อะไรเลย
--   เก็บประวัติทุกครั้งใน tx_payment_edits
-- ============================================================
CREATE TABLE IF NOT EXISTS tx_payment_edits (
  id BIGSERIAL PRIMARY KEY,
  tx_id TEXT NOT NULL,
  mode TEXT NOT NULL,
  ledger_user_id UUID,
  old_payments JSONB,
  new_payments JSONB,
  old_change NUMERIC,
  new_change NUMERIC,
  deltas JSONB,
  reason TEXT,
  edited_by_id UUID,
  edited_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tx_payment_edits_tx ON tx_payment_edits (tx_id, edited_at);

ALTER TABLE tx_payment_edits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tx_payment_edits FROM anon, authenticated;
REVOKE ALL ON SEQUENCE tx_payment_edits_id_seq FROM anon, authenticated;


-- helper: บิลนี้ลงบัญชีที่ไหน (SHIFT/SHOP) หรือห้ามแก้ — internal เท่านั้น
CREATE OR REPLACE FUNCTION _tx_edit_ledger(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_n_users INT;
  v_user UUID;
  v_min TIMESTAMPTZ;
  v_max TIMESTAMPTZ;
  v_c1_id TEXT; v_c1_st close_status;
  v_c2_id TEXT;
  v_nick TEXT;
BEGIN
  -- แถวของบิลในกระเป๋า Sales (ไม่นับแถวที่เกิดจากการแก้บิลเอง)
  SELECT COUNT(DISTINCT user_id), (MIN(user_id::text))::uuid, MIN(date), MAX(date)
    INTO v_n_users, v_user, v_min, v_max
  FROM user_cashbook
  WHERE ref_tx_id = p_tx_id AND id NOT LIKE 'UCB-EDIT-%';

  IF COALESCE(v_n_users, 0) = 0 THEN
    RETURN jsonb_build_object('mode', 'SHOP');
  END IF;
  IF v_n_users > 1 THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้มี Sales รับเงินหลายคน แก้ไขไม่ได้');
  END IF;
  IF EXISTS (SELECT 1 FROM transaction_payments
             WHERE tx_id = p_tx_id AND paid_by_id IS DISTINCT FROM v_user) THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้มีทั้ง Sales และ Manager รับ/จ่ายเงิน แก้ไขไม่ได้');
  END IF;

  SELECT COALESCE(NULLIF(TRIM(nickname), ''), username) INTO v_nick FROM users WHERE id = v_user;

  -- กะแรกที่ปิดหลังจ่ายเงินของบิลนี้ (เงินก่อนเวลากดปิดกะถูกกวาดเข้าร้านตอนอนุมัติ)
  SELECT id, status INTO v_c1_id, v_c1_st FROM closes
  WHERE user_id = v_user AND status IN ('PENDING', 'APPROVED') AND date >= v_min
  ORDER BY date LIMIT 1;
  SELECT id INTO v_c2_id FROM closes
  WHERE user_id = v_user AND status IN ('PENDING', 'APPROVED') AND date >= v_max
  ORDER BY date LIMIT 1;

  IF v_c1_id IS DISTINCT FROM v_c2_id THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้จ่ายเงินข้ามกะ แก้ไขไม่ได้');
  END IF;
  IF v_c1_id IS NULL THEN
    RETURN jsonb_build_object('mode', 'SHIFT', 'user_id', v_user, 'nickname', v_nick);
  END IF;
  IF v_c1_st = 'PENDING' THEN
    RETURN jsonb_build_object('blocked',
      '❌ ' || COALESCE(v_nick, 'Sales') || ' ส่งปิดกะแล้ว (' || v_c1_id || ') รอ Manager อนุมัติ — อนุมัติหรือปฏิเสธการปิดกะก่อนจึงจะแก้บิลได้');
  END IF;
  RETURN jsonb_build_object('mode', 'SHOP', 'user_id', v_user, 'nickname', v_nick, 'close_id', v_c1_id);
END;
$$;
REVOKE ALL ON FUNCTION _tx_edit_ledger(TEXT) FROM PUBLIC, anon, authenticated;


-- ข้อมูลสำหรับเปิดหน้าแก้ไข: รายการจ่ายเดิม + บัญชีที่จะลง + ประวัติการแก้
CREATE OR REPLACE FUNCTION get_tx_payment_edit_info(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tx RECORD;
  v_led JSONB;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  SELECT t.id, t.type::text AS type, t.status::text AS status, t.total, t.price,
         t.change_amount, t.phone
    INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้การชำระไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;

  v_led := _tx_edit_ledger(p_tx_id);
  IF v_led ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_led->>'blocked');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'type', v_tx.type,
    'phone', v_tx.phone,
    'total', CASE WHEN v_tx.type = 'BUYBACK' THEN COALESCE(v_tx.price, v_tx.total) ELSE v_tx.total END,
    'change', COALESCE(v_tx.change_amount, 0),
    'ledger', v_led,
    'payments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('method', tp.method, 'currency', tp.currency,
                                          'amount', tp.amount, 'bank', b.name))
      FROM transaction_payments tp LEFT JOIN banks b ON b.id = tp.bank_id
      WHERE tp.tx_id = p_tx_id), '[]'::jsonb),
    'edits', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('edited_at', e.edited_at, 'mode', e.mode, 'reason', e.reason,
                                          'by', COALESCE(NULLIF(TRIM(u.nickname), ''), u.username))
                       ORDER BY e.edited_at)
      FROM tx_payment_edits e LEFT JOIN users u ON u.id = e.edited_by_id
      WHERE e.tx_id = p_tx_id), '[]'::jsonb)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_tx_payment_edit_info(TEXT) TO authenticated;


-- แก้ไขการชำระเงิน — p_payments รูปแบบเดียวกับ confirm_*_tx: [{method, currency, amount, rate, bank}]
--   p_change = เงินทอนใหม่ (LAK เงินสด, Buyback ไม่มีเงินทอน)
CREATE OR REPLACE FUNCTION edit_tx_payments(
  p_tx_id TEXT, p_payments JSONB, p_change NUMERIC, p_reason TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_editor UUID;
  v_tx RECORD;
  v_led JSONB;
  v_mode TEXT;
  v_user UUID;
  v_is_shift BOOLEAN;
  v_payer UUID;
  v_sign NUMERIC;
  v_cb_type cashbank_type;
  v_total NUMERIC;
  v_change NUMERIC := ROUND(COALESCE(p_change, 0));
  v_old_change NUMERIC;
  v_new_paid NUMERIC := 0;
  v_over NUMERIC;
  v_first_cur TEXT := NULL;
  v_old_payments JSONB;
  v_new_payments JSONB := '[]'::jsonb;
  v_new JSONB := '[]'::jsonb;
  v_deltas JSONB := '[]'::jsonb;
  v_e RECORD;
  v_d RECORD;
  v_method TEXT;
  v_bank_id UUID;
  v_note TEXT;
  v_n INT := 0;
  v_ok BOOLEAN;
BEGIN
  v_editor := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;
  IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'message', 'กรุณาระบุเหตุผลที่แก้ไข');
  END IF;
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  -- [LOCK] กันแก้บิลเดียวกันพร้อมกัน
  SELECT t.id, t.type::text AS type, t.status::text AS status, t.total, t.price,
         COALESCE(t.change_amount, 0) AS change_amount, t.sale_user_id
    INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id
  FOR UPDATE;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้การชำระไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;

  -- [LOCK] กันอนุมัติปิดกะแทรกระหว่างแก้ (approve_close_report lock row นี้เหมือนกัน)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_led := _tx_edit_ledger(p_tx_id);
  IF v_led ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_led->>'blocked');
  END IF;
  v_mode := v_led->>'mode';
  v_user := (v_led->>'user_id')::uuid;
  v_is_shift := (v_mode = 'SHIFT');

  SELECT tp.paid_by_id INTO v_payer FROM transaction_payments tp WHERE tp.tx_id = p_tx_id LIMIT 1;
  v_payer := COALESCE(v_user, v_payer, v_editor);

  -- เงินเข้า (+1) : SELL/TRADEIN/EXCHANGE/WITHDRAW ; เงินออก (−1) : BUYBACK
  v_sign := CASE WHEN v_tx.type = 'BUYBACK' THEN -1 ELSE 1 END;
  v_cb_type := v_tx.type::cashbank_type;
  v_total := CASE WHEN v_tx.type = 'BUYBACK' THEN COALESCE(v_tx.price, v_tx.total) ELSE v_tx.total END;
  v_old_change := v_tx.change_amount;
  IF v_tx.type = 'BUYBACK' THEN v_change := 0; END IF;
  IF v_change < 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'เงินทอนต้องไม่ติดลบ');
  END IF;

  -- รายการใหม่
  FOR v_e IN
    SELECT UPPER(COALESCE(elem->>'method', 'CASH')) AS m,
           UPPER(COALESCE(NULLIF(elem->>'currency', ''), 'LAK')) AS cur,
           (elem->>'amount')::numeric AS amount,
           COALESCE(NULLIF((elem->>'rate')::numeric, 0), 1) AS rate,
           elem->>'bank' AS bank_name
    FROM jsonb_array_elements(p_payments) elem
  LOOP
    CONTINUE WHEN v_e.amount IS NULL OR v_e.amount <= 0;
    IF v_e.cur NOT IN ('LAK', 'THB', 'USD') THEN
      RETURN jsonb_build_object('success', false, 'message', 'สกุลเงินไม่ถูกต้อง: ' || v_e.cur);
    END IF;
    v_method := CASE WHEN v_e.m = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END;
    IF v_method = 'TRANSFER' AND COALESCE(TRIM(v_e.bank_name), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'message', 'รายการโอนต้องระบุธนาคาร');
    END IF;
    v_bank_id := CASE WHEN v_method = 'TRANSFER' THEN _resolve_bank_id(v_e.bank_name) ELSE NULL END;
    IF v_first_cur IS NULL THEN v_first_cur := v_e.cur; END IF;
    v_new_paid := v_new_paid + v_e.amount * CASE WHEN v_e.cur = 'LAK' THEN 1 ELSE v_e.rate END;
    v_new := v_new || jsonb_build_object('method', v_method, 'currency', v_e.cur,
                                         'bank_id', v_bank_id, 'amount', v_e.amount);
    v_new_payments := v_new_payments || jsonb_build_object('method', v_method, 'currency', v_e.cur,
                                         'amount', v_e.amount, 'rate', v_e.rate, 'bank', v_e.bank_name);
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- ยอดต้องครบเหมือนตอนยืนยันบิล
  IF v_tx.type = 'BUYBACK' THEN
    IF v_new_paid > v_total + 1 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดจ่ายเกิน Total (' || to_char(v_new_paid, 'FM999,999,999,990') || ' > ' || to_char(v_total, 'FM999,999,999,990') || ' LAK)');
    END IF;
    IF v_total - v_new_paid > 500 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดจ่ายยังไม่ครบ ขาดอีก ' || to_char(v_total - v_new_paid, 'FM999,999,999,990') || ' LAK');
    END IF;
  ELSE
    IF v_new_paid < v_total - 1 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดชำระยังไม่ครบ ขาดอีก ' || to_char(v_total - v_new_paid, 'FM999,999,999,990') || ' LAK');
    END IF;
    -- เงินทอนปัด 1,000 (roundChangeLak) → ต่างจากยอดเกินได้ไม่เกิน 1,000
    v_over := GREATEST(v_new_paid - v_total, 0);
    IF v_change > v_over + 500 OR v_change < v_over - 1000 THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินทอนไม่ตรงกับยอดที่ชำระเกิน');
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', tp.method, 'currency', tp.currency,
                                               'amount', tp.amount, 'bank', b.name, 'paid_by_id', tp.paid_by_id)), '[]'::jsonb)
    INTO v_old_payments
  FROM transaction_payments tp LEFT JOIN banks b ON b.id = tp.bank_id
  WHERE tp.tx_id = p_tx_id;

  -- ส่วนต่างต่อ (วิธีจ่าย × สกุล × ธนาคาร) = ใหม่ − เดิม (เงินทอน = เงินสด LAK ทิศตรงข้าม)
  FOR v_d IN
    WITH eff AS (
      SELECT CASE WHEN UPPER(tp.method::text) = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END AS method,
             tp.currency::text AS currency, tp.bank_id, -v_sign * tp.amount AS amt
      FROM transaction_payments tp WHERE tp.tx_id = p_tx_id
      UNION ALL
      SELECT 'CASH', 'LAK', NULL::uuid, v_old_change WHERE v_old_change > 0
      UNION ALL
      SELECT x->>'method', x->>'currency', NULLIF(x->>'bank_id', '')::uuid, v_sign * (x->>'amount')::numeric
      FROM jsonb_array_elements(v_new) x
      UNION ALL
      SELECT 'CASH', 'LAK', NULL::uuid, -v_change WHERE v_change > 0
    )
    SELECT eff.method, eff.currency, eff.bank_id, b.name AS bank_name, SUM(eff.amt) AS delta
    FROM eff LEFT JOIN banks b ON b.id = eff.bank_id
    GROUP BY eff.method, eff.currency, eff.bank_id, b.name
    HAVING ABS(SUM(eff.amt)) > 0.000001
    ORDER BY SUM(eff.amt)
  LOOP
    -- ช่องที่ยอดลดลง → ต้องมีเงินพอ
    IF v_d.delta < 0 THEN
      IF v_is_shift AND v_d.method = 'CASH' THEN
        v_ok := check_user_cash_balance(v_user, v_d.currency::currency_code, -v_d.delta);
      ELSE
        v_ok := check_shop_balance(v_d.method, v_d.currency::currency_code, v_d.bank_id, -v_d.delta);
      END IF;
      IF NOT v_ok THEN
        RAISE EXCEPTION '❌ % % % ไม่พอหัก % % — แก้ไขไม่ได้',
          CASE WHEN v_is_shift AND v_d.method = 'CASH'
               THEN 'เงินสดในกระเป๋า ' || COALESCE(v_led->>'nickname', 'Sales')
               WHEN v_d.method = 'CASH' THEN 'เงินสดในร้าน'
               ELSE 'เงินในบัญชีร้าน' END,
          CASE WHEN v_d.method = 'CASH' THEN '' ELSE COALESCE(v_d.bank_name, '') END,
          v_d.currency, to_char(-v_d.delta, 'FM999,999,999,990.99'), v_d.currency;
      END IF;
    END IF;

    v_note := 'แก้ไขการชำระ ' || p_tx_id;

    -- เงินร้าน: ทุกช่อง ยกเว้นเงินสดที่อยู่ในกระเป๋า Sales (SHIFT)
    IF NOT (v_is_shift AND v_d.method = 'CASH') THEN
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES ('CB-EDIT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6),
              v_cb_type, v_d.delta, v_d.currency::currency_code, v_d.method, v_d.bank_id,
              p_tx_id, v_note, NOW(), v_editor);
    END IF;

    -- กระเป๋า Sales (SHIFT): ลงทุกช่องเหมือนตอนยืนยันบิล (โอน = แถวติดตาม เคลียร์ตอนปิดกะ)
    IF v_is_shift THEN
      INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
      VALUES ('UCB-EDIT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6),
              v_user, v_cb_type, v_d.delta, v_d.currency::currency_code, v_d.method, v_d.bank_id,
              p_tx_id, v_note, NOW());
    END IF;

    v_deltas := v_deltas || jsonb_build_object('method', v_d.method, 'currency', v_d.currency,
                                               'bank', v_d.bank_name, 'delta', v_d.delta);
  END LOOP;

  -- แทนรายการจ่ายของบิล (Report/ตารางช่องทางรับเงินอ่านจากตารางนี้)
  DELETE FROM transaction_payments WHERE tx_id = p_tx_id;
  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  SELECT p_tx_id, (x->>'amount')::numeric, (x->>'currency')::currency_code, x->>'method',
         NULLIF(x->>'bank_id', '')::uuid, v_payer
  FROM jsonb_array_elements(v_new) x;

  IF v_tx.type = 'BUYBACK' THEN
    -- ยอดค้าง ≤ 500 LAK ถือว่าจ่ายครบ (R19-1) → paid = price คงเดิม (ต้นทุนทองเก่าไม่เปลี่ยน)
    UPDATE transactions SET paid = v_total, balance = 0, updated_at = NOW() WHERE id = p_tx_id;
  ELSE
    UPDATE transactions
      SET paid = v_new_paid, change_amount = v_change,
          currency = COALESCE(v_first_cur, 'LAK')::currency_code, updated_at = NOW()
      WHERE id = p_tx_id;
  END IF;

  INSERT INTO tx_payment_edits (tx_id, mode, ledger_user_id, old_payments, new_payments,
                                old_change, new_change, deltas, reason, edited_by_id)
  VALUES (p_tx_id, v_mode, v_user, v_old_payments, v_new_payments,
          v_old_change, v_change, v_deltas, TRIM(p_reason), v_editor);

  IF v_is_shift AND jsonb_array_length(v_deltas) > 0 THEN
    PERFORM _notify_user('INFO', '✏️ Manager แก้ไขการชำระเงินบิล ' || p_tx_id || ' — ยอดในกระเป๋าของคุณถูกปรับ',
                         v_user, LOWER(v_tx.type), p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'mode', v_mode, 'deltas', v_deltas);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION edit_tx_payments(TEXT, JSONB, NUMERIC, TEXT) TO authenticated;
