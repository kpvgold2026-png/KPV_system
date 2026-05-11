CREATE OR REPLACE FUNCTION create_buyback_tx(
  p_phone TEXT,
  p_bill_id TEXT,
  p_items JSONB,
  p_price NUMERIC,
  p_fee NUMERIC,
  p_sell_1baht NUMERIC
)
RETURNS JSONB AS $$
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

  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, price, fee, balance, currency, date)
  VALUES (v_tx_id, 'BUYBACK', 'PENDING', p_bill_id, p_phone, v_user_id, p_price, p_price, COALESCE(p_fee, 0), p_price, 'LAK', NOW());

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION create_buyback_tx(TEXT, TEXT, JSONB, NUMERIC, NUMERIC, NUMERIC) TO authenticated;

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
  v_items JSONB;
  v_gold_g NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_ug_id BIGINT;
  v_first_payment BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();

  SELECT t.status, t.price, t.paid INTO v_status, v_price, v_total_paid
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
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
  SET status = v_new_status,
      paid = v_total_paid,
      balance = v_new_balance,
      fee = COALESCE(p_fee, 0),
      change_amount = COALESCE(p_change, 0),
      updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);

  IF COALESCE(p_fee, 0) > 0 AND v_first_payment THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-FEE-' || substring(md5(p_tx_id), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK_FEE', p_fee, p_currency, p_method, p_bank_id, p_tx_id, 'Buyback fee ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'BUYBACK', -p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW());
  END IF;

  IF v_new_status = 'COMPLETED' THEN
    SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items
    FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'OLD';

    v_gold_g := calc_items_gold_g(v_items);

    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, fulfilled, user_id, date)
    VALUES (p_tx_id, 'OLD', 'BUYBACK', 'IN', v_gold_g, v_price, FALSE, v_user_id, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN
      SELECT product_id, qty FROM transaction_items
      WHERE tx_id = p_tx_id AND item_role = 'OLD'
    LOOP
      INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.product_id, v_item.qty);

      INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
      VALUES (v_item.product_id, 'OLD', v_item.qty, NOW())
      ON CONFLICT (product_id, gold_type)
      DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();

      IF v_role = 'Sales' OR v_role IS NULL THEN
        INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id)
        VALUES (v_user_id, v_item.product_id, v_item.qty, 'BUYBACK', p_tx_id, NOW(), v_user_id);
      END IF;
    END LOOP;

    INSERT INTO diffs (tx_id, type, sell_value, fee, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, COALESCE(p_fee, 0), COALESCE(p_fee, 0) - 0, NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value,
          fee = EXCLUDED.fee,
          diff = EXCLUDED.diff;
  END IF;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'status', v_new_status, 'balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION delete_buyback_tx(p_tx_id TEXT)
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
    RETURN jsonb_build_object('success', false, 'message', 'Cannot delete completed tx');
  END IF;

  INSERT INTO audit_logs (table_name, ref_id, action, payload, user_id)
  VALUES ('transactions', p_tx_id, 'DELETE', v_payload, v_user_id);

  DELETE FROM transactions WHERE id = p_tx_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION delete_buyback_tx(TEXT) TO authenticated;
