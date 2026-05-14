-- ============================================================
-- next_run.sql (Round 4.1 — fix: format ต้องไปอยู่ที่ transactions.id ไม่ใช่ bill_id)
-- ============================================================
-- ปัญหา round 4:
--   - ผม override `bill_id` ผ่าน trigger ผิด — bill_id คือเลขในเล่มบิลกระดาษ
--     ที่ Sales กรอกเอง ห้ามแตะ
--   - format SE26000001 ต้องไปอยู่ที่ `transactions.id` (PK ใช้แทน TRANSACTION_ID)
--
-- โครงสร้างที่พบหลังดู source ของ create_*_tx ทั้ง 5 ตัว:
--   ทุก function เรียก `generate_tx_id('<TYPE>')` แล้วเอาค่าไป INSERT
--   ดังนั้นแก้แค่ตัว generate_tx_id() ก็พอ — ไม่ต้องแตะ create_*_tx เลย
-- ============================================================


-- ============================================================
-- 1) revert ของรอบ 4: ลบ trigger ที่ override bill_id
-- ============================================================
DROP TRIGGER IF EXISTS trg_transactions_bill_id ON transactions;
DROP FUNCTION IF EXISTS trg_auto_bill_id();

-- bill_sequence table ใช้ต่อ (counter per-year per-type)
-- แต่ next_bill_id() ของรอบก่อน ลบทิ้ง — ใช้ generate_tx_id() เป็น single source
DROP FUNCTION IF EXISTS next_bill_id(tx_type);


-- ============================================================
-- 2) bill_sequence — counter ต่อปี/ประเภท (ไม่ reuse, ไม่เคย rollback)
-- ============================================================
CREATE TABLE IF NOT EXISTS bill_sequence (
  year INT NOT NULL,
  tx_type tx_type NOT NULL,
  last_seq INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (year, tx_type)
);

ALTER TABLE bill_sequence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bill_sequence FROM authenticated, anon;


-- ============================================================
-- 3) generate_tx_id(p_type) → 'SE26000001'
--    overwrite ของเดิม (เดิมเป็น TX-YYYYMMDDHHMMSS-...)
-- ============================================================
-- รองรับทั้ง signature เก่าที่อาจรับ text หรือ tx_type
DROP FUNCTION IF EXISTS generate_tx_id(text);
DROP FUNCTION IF EXISTS generate_tx_id(tx_type);

CREATE OR REPLACE FUNCTION generate_tx_id(p_type text)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_year_full INT;
  v_year_2 TEXT;
  v_prefix TEXT;
  v_next_seq INT;
  v_type tx_type;
BEGIN
  -- cast text → tx_type (รองรับ caller ส่ง 'SELL', 'BUYBACK', ...)
  v_type := p_type::tx_type;

  v_year_full := EXTRACT(YEAR FROM (NOW() AT TIME ZONE 'Asia/Bangkok'))::int;
  v_year_2 := lpad((v_year_full % 100)::text, 2, '0');

  v_prefix := CASE v_type
    WHEN 'SELL'     THEN 'SE'
    WHEN 'TRADEIN'  THEN 'TI'
    WHEN 'EXCHANGE' THEN 'EX'
    WHEN 'BUYBACK'  THEN 'BB'
    WHEN 'WITHDRAW' THEN 'WD'
    ELSE 'XX'
  END;

  -- atomic upsert + increment (gap-less per year+type)
  INSERT INTO bill_sequence (year, tx_type, last_seq, updated_at)
  VALUES (v_year_full, v_type, 1, NOW())
  ON CONFLICT (year, tx_type)
  DO UPDATE SET last_seq = bill_sequence.last_seq + 1, updated_at = NOW()
  RETURNING last_seq INTO v_next_seq;

  RETURN v_prefix || v_year_2 || lpad(v_next_seq::text, 6, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION generate_tx_id(text) TO authenticated;


-- ============================================================
-- 4) Old gold delay flow — ทำเหมือนเดิม (รอบ 4 ใช้ได้แล้ว ไม่แตะ)
-- ============================================================
ALTER TABLE user_gold_received
  ADD COLUMN IF NOT EXISTS price_per_unit NUMERIC(18,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS settled BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS settled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS settled_close_id TEXT;

CREATE INDEX IF NOT EXISTS idx_user_gold_unsettled
  ON user_gold_received(user_id) WHERE settled = FALSE;


-- ============================================================
-- 5) confirm_buyback_tx — เหมือนรอบ 4 (ไม่เปลี่ยน)
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT,
  p_paid NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_id UUID,
  p_fee NUMERIC,
  p_change NUMERIC
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
  v_first_payment BOOLEAN;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.price, t.paid, t.sale_user_id
    INTO v_status, v_price, v_total_paid, v_sale_user
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
  END IF;

  IF NOT check_shop_balance(
    CASE WHEN p_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
    p_currency, p_bank_id, p_paid
  ) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
  END IF;

  v_first_payment := (v_total_paid IS NULL OR v_total_paid = 0);
  v_total_paid := COALESCE(v_total_paid, 0) + p_paid;
  v_new_balance := v_price - v_total_paid;

  IF v_new_balance <= 0 THEN
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
  ELSE
    v_new_status := 'PARTIAL';
  END IF;

  UPDATE transactions
  SET status = v_new_status, paid = v_total_paid, balance = v_new_balance,
      fee = COALESCE(p_fee, 0), change_amount = COALESCE(p_change, 0), updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency,
          CASE WHEN p_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
          p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);

  IF COALESCE(p_fee, 0) > 0 AND v_first_payment THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-FEE-' || substring(md5(p_tx_id), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK_FEE', p_fee, p_currency,
            CASE WHEN p_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
            p_bank_id, p_tx_id, 'Buyback fee ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'BUYBACK', -p_paid, p_currency,
            CASE WHEN p_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW());
  END IF;

  IF v_new_status = 'COMPLETED' THEN
    SELECT COALESCE(SUM(qty), 0) INTO v_total_qty
    FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'OLD';

    IF v_total_qty > 0 THEN
      v_price_per_unit := v_price / v_total_qty;
    END IF;

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

    INSERT INTO diffs (tx_id, type, sell_value, fee, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, COALESCE(p_fee, 0), COALESCE(p_fee, 0), NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value, fee = EXCLUDED.fee, diff = EXCLUDED.diff;

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
-- 6) confirm_tradein_tx — เหมือนรอบ 4
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_tradein_tx(
  p_tx_id TEXT,
  p_paid NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_id UUID,
  p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_diff_amount NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.total, t.diff_amount, t.premium, t.sale_user_id
    INTO v_status, v_total, v_diff_amount, v_premium, v_sale_user
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'TRADEIN';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found');
  END IF;
  IF v_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_new_gold_g := calc_items_gold_g(v_new_items);
  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;

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
    INSERT INTO user_gold_received (
      user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
      price_per_unit, settled
    )
    VALUES (
      COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
      'TRADEIN', p_tx_id, NOW(), v_user_id,
      0, FALSE
    );
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW(), v_user_id);

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_new_cost;
  INSERT INTO diffs (tx_id, type, sell_value, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'TRADEIN', COALESCE(v_diff_amount, 0), COALESCE(v_premium, 0), v_new_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 7) confirm_exchange_tx — เหมือนรอบ 4
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_exchange_tx(
  p_tx_id TEXT,
  p_paid NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_id UUID,
  p_change NUMERIC
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
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_new_gold_g := calc_items_gold_g(v_new_items);
  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;

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
    INSERT INTO user_gold_received (
      user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
      price_per_unit, settled
    )
    VALUES (
      COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
      'EXCHANGE', p_tx_id, NOW(), v_user_id,
      0, FALSE
    );
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW(), v_user_id);

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_new_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0), v_new_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 8) approve_close_report — เหมือนรอบ 4 (materialize old gold)
-- ============================================================
CREATE OR REPLACE FUNCTION approve_close_report(p_close_id TEXT, p_decision TEXT, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_new_status close_status;
  v_close_user UUID;
  v_nickname TEXT;
  v_close_date DATE;
  v_ref_id TEXT;
  v_total_qty NUMERIC := 0;
  v_total_gold_g NUMERIC := 0;
  v_total_value NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  v_new_status := CASE WHEN p_decision = 'APPROVE'
                       THEN 'APPROVED'::close_status
                       ELSE 'REJECTED'::close_status END;

  SELECT c.user_id, c.date::date, u.nickname
    INTO v_close_user, v_close_date, v_nickname
    FROM closes c JOIN users u ON u.id = c.user_id
    WHERE c.id = p_close_id;

  IF v_close_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Close not found');
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

  v_ref_id := 'CLOSE-' || COALESCE(v_nickname, 'unknown') || '-'
              || to_char(v_close_date, 'YYYYMMDD');

  SELECT
    COALESCE(SUM(ug.qty), 0),
    COALESCE(SUM(ug.qty * p.weight_baht * 15), 0),
    COALESCE(SUM(ug.qty * ug.price_per_unit), 0)
    INTO v_total_qty, v_total_gold_g, v_total_value
  FROM user_gold_received ug
  JOIN products p ON p.id = ug.product_id
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

    UPDATE wac_state
      SET old_gold_g = COALESCE(old_gold_g, 0) + v_total_gold_g,
          old_value  = COALESCE(old_value, 0) + v_total_value,
          updated_at = NOW()
      WHERE id = 1;

    UPDATE user_gold_received
      SET settled = TRUE, settled_at = NOW(), settled_close_id = p_close_id
      WHERE user_id = v_close_user AND settled = FALSE;
  END IF;

  PERFORM _notify_user('INFO', '✅ ปิดกะของคุณได้รับการอนุมัติ: ' || p_close_id,
                       v_close_user, 'close', NULL);

  RETURN jsonb_build_object(
    'success', true,
    'materialized_ref', CASE WHEN v_total_qty > 0 THEN v_ref_id ELSE NULL END,
    'materialized_qty', v_total_qty,
    'materialized_value', v_total_value
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION approve_close_report(TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- ทดสอบหลังรัน
-- ============================================================
--   -- สร้าง tx ใหม่ → id ควรเป็น SE26000001 / BB26000001 / etc.
--   SELECT id, bill_id, type, date FROM transactions ORDER BY date DESC LIMIT 10;
--
--   -- counter table ดูความเดิน
--   SELECT * FROM bill_sequence ORDER BY year DESC, tx_type;
--
--   -- ลบบิลแล้วสร้างใหม่ → id ไม่ reuse
--   --   DELETE FROM transactions WHERE id = 'SE26000005';
--   --   (สร้าง SELL ใหม่) → ได้ id = SE26000006 ไม่ใช่ 000005
