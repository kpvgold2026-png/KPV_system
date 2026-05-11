CREATE OR REPLACE FUNCTION create_exchange_tx(
  p_phone TEXT,
  p_bill_id TEXT,
  p_new_items JSONB,
  p_old_exchange_items JSONB,
  p_switch_items JSONB,
  p_free_ex_items JSONB,
  p_exchange_fee NUMERIC,
  p_switch_fee NUMERIC,
  p_premium NUMERIC,
  p_total NUMERIC,
  p_free_ex_bill_ref TEXT,
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
    total, currency, date
  )
  VALUES (
    v_tx_id, 'EXCHANGE', 'PENDING', p_bill_id, p_phone, v_user_id,
    COALESCE(p_exchange_fee, 0), COALESCE(p_switch_fee, 0), COALESCE(p_premium, 0), NULLIF(p_free_ex_bill_ref, ''),
    p_total, 'LAK', NOW()
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION create_exchange_tx(TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION review_exchange_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  SELECT status INTO v_status FROM transactions WHERE id = p_tx_id AND type = 'EXCHANGE';
  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'PENDING' THEN RETURN jsonb_build_object('success', false, 'message', 'Already reviewed'); END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'EXCHANGE', 'APPROVED', v_user_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION review_exchange_tx(TEXT) TO authenticated;

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
  v_new_items JSONB;
  v_old_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC;
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

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium
  INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
  INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
  INTO v_old_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'SWITCH', 'FREE_EX');

  v_new_gold_g := calc_items_gold_g(v_new_items);
  v_old_gold_g := calc_items_gold_g(v_old_items);
  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;

  UPDATE transactions
  SET status = 'COMPLETED', paid = p_paid, change_amount = p_change, currency = p_currency, updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'EXCHANGE', 'OUT', v_new_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN
    SELECT product_id, qty FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW'
  LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  IF v_old_gold_g > 0 THEN
    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, fulfilled, user_id, date)
    VALUES (p_tx_id, 'OLD', 'EXCHANGE', 'IN', v_old_gold_g, FALSE, v_user_id, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN
      SELECT product_id, qty FROM transaction_items
      WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'SWITCH', 'FREE_EX')
    LOOP
      INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
      INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
      VALUES (v_item.product_id, 'OLD', v_item.qty, NOW())
      ON CONFLICT (product_id, gold_type)
      DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();

      IF v_role = 'Sales' OR v_role IS NULL THEN
        INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id)
        VALUES (v_user_id, v_item.product_id, v_item.qty, 'EXCHANGE', p_tx_id, NOW(), v_user_id);
      END IF;
    END LOOP;
  END IF;

  UPDATE wac_state
  SET new_gold_g = new_gold_g - v_new_gold_g,
      new_value = new_value - v_new_cost,
      updated_at = NOW()
  WHERE id = 1;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
  VALUES (v_cb_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW(), v_user_id);

  IF v_role = 'Sales' OR v_role IS NULL THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_new_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0), v_new_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value,
        ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee,
        premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff,
        diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;
