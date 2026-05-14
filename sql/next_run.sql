-- ============================================================
-- next_run.sql (Round 7)
-- ============================================================
-- แก้ตามที่ user ระบุ:
--   - cost_old_gold ใน Diff ต้องคำนวณจาก "ราคาขายปัจจุบัน" ของ tx นั้น
--     ไม่ใช่ WAC: cost_old_gold = (sell_1baht / 15) × old_gold_g
--   - เก็บ sell_1baht ใน transactions เพื่อใช้ตอน confirm (กันราคาเปลี่ยน)
--
-- รวมทุกอย่างจาก Round 4-6 ที่ยังจำเป็น (idempotent — รันซ้ำได้)
-- ============================================================


-- ============================================================
-- 0) ALTER TABLE — เพิ่ม column ที่ต้องใช้
-- ============================================================
ALTER TABLE transactions
  ADD COLUMN IF NOT EXISTS sell_1baht NUMERIC DEFAULT 0;

ALTER TABLE diffs
  ADD COLUMN IF NOT EXISTS cost_old_gold NUMERIC DEFAULT 0;


-- ============================================================
-- 1) bill_sequence + generate_tx_id (Round 4)
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

DROP FUNCTION IF EXISTS generate_tx_id(text);
DROP FUNCTION IF EXISTS generate_tx_id(tx_type);
CREATE OR REPLACE FUNCTION generate_tx_id(p_type text)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_year_full INT;
  v_year_2 TEXT;
  v_prefix TEXT;
  v_next_seq INT;
  v_type tx_type;
BEGIN
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
-- 2) user_gold_received columns (Round 4)
-- ============================================================
ALTER TABLE user_gold_received
  ADD COLUMN IF NOT EXISTS price_per_unit NUMERIC(18,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS settled BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS settled_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS settled_close_id TEXT;

CREATE INDEX IF NOT EXISTS idx_user_gold_unsettled
  ON user_gold_received(user_id) WHERE settled = FALSE;


-- ============================================================
-- 3) create_*_tx — เก็บ p_sell_1baht ใน transactions (Round 7)
--    (signature เดิม — เพิ่มแค่ column ใน INSERT)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_sell_tx(
  p_phone text, p_bill_id text, p_items jsonb,
  p_total numeric, p_premium numeric, p_sell_1baht numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false,
        'message', 'สต็อกไม่พอสำหรับ ' || v_pid || ' (มี ' || COALESCE(v_stock, 0) || ' ต้องการ ' || v_qty || ')');
    END IF;
  END LOOP;
  v_tx_id := generate_tx_id('SELL');
  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, premium, sell_1baht, currency, date)
  VALUES (v_tx_id, 'SELL', 'PENDING', p_bill_id, p_phone, v_user_id, p_total, p_premium, COALESCE(p_sell_1baht, 0), 'LAK', NOW());
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;
  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New SELL waiting for review: ' || v_tx_id, 'Manager', 'sell', v_tx_id, v_user_id);
  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_buyback_tx(
  p_phone text, p_bill_id text, p_items jsonb,
  p_price numeric, p_fee numeric, p_sell_1baht numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  v_tx_id := generate_tx_id('BUYBACK');
  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, price, fee, balance, sell_1baht, currency, date)
  VALUES (v_tx_id, 'BUYBACK', 'PENDING', p_bill_id, p_phone, v_user_id, p_price, p_price, COALESCE(p_fee, 0), p_price, COALESCE(p_sell_1baht, 0), 'LAK', NOW());
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;
  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('PAYMENT', 'New BUYBACK waiting for payment: ' || v_tx_id, 'Manager', 'buyback', v_tx_id, v_user_id);
  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_tradein_tx(
  p_phone text, p_bill_id text, p_old_items jsonb, p_new_items jsonb,
  p_foc_items jsonb, p_foc_bill_ref text, p_difference numeric,
  p_premium numeric, p_foc_premium_deduct numeric, p_total numeric, p_sell_1baht numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
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
  v_tx_id := generate_tx_id('TRADEIN');
  INSERT INTO transactions (
    id, type, status, bill_id, phone, sale_user_id,
    diff_amount, premium, foc_premium_deduct, foc_bill_ref,
    total, sell_1baht, currency, date
  )
  VALUES (
    v_tx_id, 'TRADEIN', 'PENDING', p_bill_id, p_phone, v_user_id,
    p_difference, p_premium, COALESCE(p_foc_premium_deduct, 0), NULLIF(p_foc_bill_ref, ''),
    p_total, COALESCE(p_sell_1baht, 0), 'LAK', NOW()
  );
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_old_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;
  IF p_foc_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_foc_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'FOC', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;
  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New TRADEIN waiting for review: ' || v_tx_id, 'Manager', 'tradein', v_tx_id, v_user_id);
  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_exchange_tx(
  p_phone text, p_bill_id text, p_new_items jsonb, p_old_exchange_items jsonb,
  p_switch_items jsonb, p_free_ex_items jsonb, p_exchange_fee numeric,
  p_switch_fee numeric, p_premium numeric, p_total numeric,
  p_free_ex_bill_ref text, p_sell_1baht numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
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
  v_tx_id := generate_tx_id('EXCHANGE');
  INSERT INTO transactions (
    id, type, status, bill_id, phone, sale_user_id,
    ex_fee, switch_fee, premium, free_ex_bill_ref,
    total, sell_1baht, currency, date
  )
  VALUES (
    v_tx_id, 'EXCHANGE', 'PENDING', p_bill_id, p_phone, v_user_id,
    COALESCE(p_exchange_fee, 0), COALESCE(p_switch_fee, 0), COALESCE(p_premium, 0), NULLIF(p_free_ex_bill_ref, ''),
    p_total, COALESCE(p_sell_1baht, 0), 'LAK', NOW()
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
$function$;

CREATE OR REPLACE FUNCTION public.create_withdraw_tx(
  p_phone text, p_bill_id text, p_items jsonb,
  p_premium numeric, p_total numeric, p_withdraw_code text, p_sell_1baht numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อกไม่พอ ' || v_pid);
    END IF;
  END LOOP;
  v_tx_id := generate_tx_id('WITHDRAW');
  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, premium, withdraw_code, sell_1baht, currency, date)
  VALUES (v_tx_id, 'WITHDRAW', 'PENDING', p_bill_id, p_phone, v_user_id, p_total, COALESCE(p_premium, 0), p_withdraw_code, COALESCE(p_sell_1baht, 0), 'LAK', NOW());
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;
  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New WITHDRAW waiting for review: ' || v_tx_id, 'Manager', 'withdraw', v_tx_id, v_user_id);
  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;


-- ============================================================
-- 4) confirm_buyback_tx — cost_old_gold = (sell_1baht/15) × old_gold_g
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_fee NUMERIC, p_change NUMERIC
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
  v_old_gold_g NUMERIC := 0;
  v_sell_1baht NUMERIC := 0;
  v_old_cost NUMERIC := 0;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.price, t.paid, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_price, v_total_paid, v_sale_user, v_sell_1baht
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
    SELECT COALESCE(SUM(ti.qty), 0),
           COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
      INTO v_total_qty, v_old_gold_g
    FROM transaction_items ti
    JOIN products p ON p.id = ti.product_id
    WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD';

    IF v_total_qty > 0 THEN
      v_price_per_unit := v_price / v_total_qty;
    END IF;

    -- ‼️ Round 7: cost_old_gold = (sell_1baht/15) × old_gold_g (ราคาขายปัจจุบัน ไม่ใช่ WAC)
    v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

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

    -- BUYBACK: ร้านจ่ายเงิน v_price ให้ลูกค้า + รับทองเก่ามูลค่า v_old_cost
    -- diff = old_cost - price + fee (กำไรของร้าน หลังบวกค่าธรรมเนียมที่ลูกค้าจ่าย)
    INSERT INTO diffs (tx_id, type, sell_value, fee, cost_old_gold, cost_diff, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, COALESCE(p_fee, 0),
            v_old_cost, 0,
            (v_old_cost - v_price + COALESCE(p_fee, 0)), NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value, fee = EXCLUDED.fee,
          cost_old_gold = EXCLUDED.cost_old_gold,
          cost_diff = EXCLUDED.cost_diff, diff = EXCLUDED.diff;

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
-- 5) confirm_tradein_tx — cost_old_gold = (sell_1baht/15) × old_gold_g
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
  v_diff_amount NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_old_cost NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.total, t.diff_amount, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_diff_amount, v_premium, v_sale_user, v_sell_1baht
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

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
    INTO v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'FOC');

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  -- ‼️ Round 7: cost_old_gold ใช้ราคาขายปัจจุบัน (sell_1baht/15) ไม่ใช่ WAC
  v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

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

  -- TRADEIN: diff = diff_amount + premium + cost_old_gold - new_cost
  v_diff := COALESCE(v_diff_amount, 0) + COALESCE(v_premium, 0) + v_old_cost - v_new_cost;
  INSERT INTO diffs (tx_id, type, sell_value, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'TRADEIN', COALESCE(v_diff_amount, 0), COALESCE(v_premium, 0),
          v_new_cost, v_old_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold,
        diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'tradein', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 6) confirm_exchange_tx — cost_old_gold = (sell_1baht/15) × old_gold_g
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
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_old_cost NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_new_gold_g := calc_items_gold_g(v_new_items);

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
    INTO v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'SWITCH', 'FREE_EX');

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  -- ‼️ Round 7: cost_old_gold ใช้ราคาขายปัจจุบัน
  v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

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

  -- EXCHANGE: diff = total + fees + premium + cost_old_gold - new_cost
  v_diff := v_total + COALESCE(v_ex_fee, 0) + COALESCE(v_switch_fee, 0) + COALESCE(v_premium, 0) + v_old_cost - v_new_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0),
          v_new_cost, v_old_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold,
        diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'exchange', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 7) approve_close_report (Round 4 — เก็บไว้)
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
-- 8) get_sales_gold_grams_v2 (Round 5)
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_gold_grams_v2(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
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
  INTO v_result FROM item_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_sales_gold_grams_v2(DATE, DATE) TO authenticated;


-- ============================================================
-- 9) get_incomplete_summary (Round 5)
-- ============================================================
CREATE OR REPLACE FUNCTION get_incomplete_summary(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
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
  INTO v_result FROM tx_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_incomplete_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- 10) get_live_report_sales_breakdown (Round 6)
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
    SELECT u.id AS user_id, u.nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
  ),
  user_activity AS (
    SELECT DISTINCT user_id FROM user_cashbook WHERE date::date = v_today
    UNION
    SELECT DISTINCT created_by_id AS user_id FROM cashbank WHERE date::date = v_today
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
      'shift_status',    COALESCE(cs.s, CASE WHEN ua.user_id IS NOT NULL THEN 'OPEN' ELSE 'NOT_OPEN' END),
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
  LEFT JOIN user_activity ua ON ua.user_id = a.user_id
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
-- 11) get_close_cashbook (Round 5)
-- ============================================================
CREATE OR REPLACE FUNCTION get_close_cashbook(p_user_id UUID, p_date DATE)
RETURNS TABLE (
  amount NUMERIC,
  currency TEXT,
  method TEXT,
  bank_id UUID,
  bank_name TEXT
) LANGUAGE plpgsql SECURITY DEFINER AS $$
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
-- 12) get_wealth_summary (Round 6)
-- ============================================================
CREATE OR REPLACE FUNCTION get_wealth_summary(p_days INT DEFAULT 30)
RETURNS TABLE (date DATE, carry NUMERIC, net NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  WITH dates AS (
    SELECT generate_series(
      (CURRENT_DATE - (p_days - 1))::date,
      CURRENT_DATE,
      '1 day'::interval
    )::date AS d
  ),
  daily_net AS (
    SELECT d.d AS dd,
      COALESCE((
        SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
        FROM stock_moves sm
        WHERE sm.date::date <= d.d
      ), 0) AS net_val
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
-- ทดสอบ:
-- ============================================================
--   -- ดู transactions.sell_1baht ของบิลที่ใหม่
--   SELECT id, type, sell_1baht, total FROM transactions ORDER BY date DESC LIMIT 10;
--
--   -- ดู cost_old_gold ใน diffs ที่ใหม่
--   SELECT tx_id, type, sell_value, cost_diff, cost_old_gold, diff FROM diffs ORDER BY date DESC LIMIT 10;
--
--   -- (ทางเลือก) back-fill sell_1baht ของ tx เก่าจาก current pricing
--   --   ผมไม่รู้ schema ของ pricing table → ถ้าต้องการ back-fill แจ้งมา
