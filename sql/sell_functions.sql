CREATE OR REPLACE FUNCTION generate_tx_id(p_type tx_type)
RETURNS TEXT AS $$
DECLARE
  v_prefix TEXT;
  v_date TEXT;
  v_seq INT;
  v_id TEXT;
BEGIN
  v_prefix := CASE p_type
    WHEN 'SELL' THEN 'S'
    WHEN 'TRADEIN' THEN 'T'
    WHEN 'EXCHANGE' THEN 'E'
    WHEN 'SWITCH' THEN 'SW'
    WHEN 'FREE_EXCHANGE' THEN 'FE'
    WHEN 'BUYBACK' THEN 'B'
    WHEN 'WITHDRAW' THEN 'W'
  END;
  v_date := to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDD');

  SELECT COUNT(*) + 1 INTO v_seq
  FROM transactions
  WHERE type = p_type
    AND id LIKE v_prefix || '-' || v_date || '-%';

  v_id := v_prefix || '-' || v_date || '-' || lpad(v_seq::text, 4, '0');
  RETURN v_id;
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION calc_items_gold_g(p_items JSONB)
RETURNS NUMERIC AS $$
DECLARE
  v_total NUMERIC := 0;
  v_item JSONB;
  v_weight NUMERIC;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products
    WHERE id = (v_item->>'productId');
    v_total := v_total + (v_weight * (v_item->>'qty')::numeric);
  END LOOP;
  RETURN v_total;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_wac_per_g()
RETURNS NUMERIC AS $$
DECLARE
  v_total_g NUMERIC;
  v_total_value NUMERIC;
BEGIN
  SELECT (new_gold_g + old_gold_g), (new_value + old_value)
  INTO v_total_g, v_total_value
  FROM wac_state WHERE id = 1;

  IF v_total_g IS NULL OR v_total_g = 0 THEN RETURN 0; END IF;
  RETURN v_total_value / v_total_g;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION create_sell_tx(
  p_phone TEXT,
  p_bill_id TEXT,
  p_items JSONB,
  p_total NUMERIC,
  p_premium NUMERIC,
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
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;

    SELECT qty INTO v_stock FROM stock_balances
    WHERE product_id = v_pid AND gold_type = 'NEW';

    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'สต็อกไม่พอสำหรับ ' || v_pid || ' (มี ' || COALESCE(v_stock, 0) || ' ต้องการ ' || v_qty || ')'
      );
    END IF;
  END LOOP;

  v_tx_id := generate_tx_id('SELL');

  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, premium, currency, date)
  VALUES (v_tx_id, 'SELL', 'PENDING', p_bill_id, p_phone, v_user_id, p_total, p_premium, 'LAK', NOW());

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (
      v_tx_id, 'NEW',
      v_item->>'productId',
      (v_item->>'qty')::numeric
    );
  END LOOP;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New SELL waiting for review: ' || v_tx_id, 'Manager', 'sell', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION create_sell_tx(TEXT, TEXT, JSONB, NUMERIC, NUMERIC, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION review_sell_tx(
  p_tx_id TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  SELECT status INTO v_status FROM transactions
  WHERE id = p_tx_id AND type = 'SELL';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Already reviewed');
  END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'SELL', 'APPROVED', v_user_id);

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION review_sell_tx(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION confirm_sell_tx(
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
  v_phone TEXT;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_premium NUMERIC;
  v_diff NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.total, t.phone, t.premium INTO v_status, v_total, v_phone, v_premium
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'SELL';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
  INTO v_items
  FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  UPDATE transactions
  SET status = 'COMPLETED',
      paid = p_paid,
      change_amount = p_change,
      currency = p_currency,
      updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'SELL', 'OUT', v_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN
    SELECT product_id, qty FROM transaction_items
    WHERE tx_id = p_tx_id AND item_role = 'NEW'
  LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
    VALUES (v_move_id, v_item.product_id, v_item.qty);

    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
  SET new_gold_g = new_gold_g - v_gold_g,
      new_value = new_value - v_cost,
      updated_at = NOW()
  WHERE id = 1;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(p_tx_id), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW(), v_user_id);

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(p_tx_id), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_cost;
  INSERT INTO diffs (tx_id, type, sell_value, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'SELL', v_total, COALESCE(v_premium, 0), v_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value,
        premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff,
        diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'cost', v_cost, 'diff', v_diff);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_sell_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION delete_sell_tx(p_tx_id TEXT)
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
  IF v_payload IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found');
  END IF;

  SELECT status INTO v_status FROM transactions WHERE id = p_tx_id;
  IF v_status = 'COMPLETED' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot delete completed tx — use reverse instead');
  END IF;

  INSERT INTO audit_logs (table_name, ref_id, action, payload, user_id)
  VALUES ('transactions', p_tx_id, 'DELETE', v_payload, v_user_id);

  DELETE FROM transactions WHERE id = p_tx_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION delete_sell_tx(TEXT) TO authenticated;
