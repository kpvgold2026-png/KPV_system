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
  v_pid TEXT;
  v_qty NUMERIC;
  v_weight NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_admin() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

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
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code,
              CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, v_ref_id, COALESCE(p_note, 'Stock In NEW'), NOW(), v_user_id);

      IF v_fee > 0 THEN
        v_cb_id := 'CB-FEE-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text), 1, 4);
        INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
        VALUES (v_cb_id, 'STOCK_IN_FEE', -v_fee, v_cur::currency_code, 'TRANSFER', v_bank_id, v_ref_id, 'Stock In Fee', NOW(), v_user_id);
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Stock In สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION stock_in_new_tx(JSONB, TEXT, NUMERIC, JSONB, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION transfer_old_to_new_tx(p_items JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  v_ref_id := 'TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_item.pid AND gold_type = 'OLD';
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'OLD', 'TRANSFER', 'OUT', v_total_g, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'NEW', 'TRANSFER', 'IN', v_total_g, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_item.pid, 'NEW', v_item.qty, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
  END LOOP;

  UPDATE wac_state
  SET old_gold_g = GREATEST(0, old_gold_g - v_total_g),
      new_gold_g = new_gold_g + v_total_g,
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object('success', true, 'message', 'Transfer สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION transfer_old_to_new_tx(JSONB) TO authenticated;

CREATE OR REPLACE FUNCTION stock_out_old_tx(p_items JSONB, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  v_ref_id := 'SOUT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_item.pid AND gold_type = 'OLD';
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'OLD', 'STOCK_OUT', 'OUT', v_total_g, TRUE, v_user_id, p_note, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  UPDATE wac_state
  SET old_gold_g = GREATEST(0, old_gold_g - v_total_g),
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object('success', true, 'message', 'Stock Out สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION stock_out_old_tx(JSONB, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_stock_summary(p_gold_type gold_type)
RETURNS JSONB AS $$
DECLARE
  v_carry JSONB;
  v_in JSONB;
  v_out JSONB;
  v_today_local DATE;
BEGIN
  v_today_local := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;

  SELECT jsonb_object_agg(product_id, qty)
  INTO v_carry
  FROM stock_balances WHERE gold_type = p_gold_type;

  SELECT COALESCE(jsonb_object_agg(product_id, total_qty), '{}'::jsonb)
  INTO v_in
  FROM (
    SELECT smi.product_id, SUM(smi.qty) AS total_qty
    FROM stock_move_items smi
    JOIN stock_moves sm ON sm.id = smi.move_id
    WHERE sm.gold_type = p_gold_type
      AND sm.direction = 'IN'
      AND (sm.date AT TIME ZONE 'Asia/Bangkok')::date = v_today_local
    GROUP BY smi.product_id
  ) t;

  SELECT COALESCE(jsonb_object_agg(product_id, total_qty), '{}'::jsonb)
  INTO v_out
  FROM (
    SELECT smi.product_id, SUM(smi.qty) AS total_qty
    FROM stock_move_items smi
    JOIN stock_moves sm ON sm.id = smi.move_id
    WHERE sm.gold_type = p_gold_type
      AND sm.direction = 'OUT'
      AND (sm.date AT TIME ZONE 'Asia/Bangkok')::date = v_today_local
    GROUP BY smi.product_id
  ) t;

  RETURN jsonb_build_object('carry', COALESCE(v_carry, '{}'::jsonb), 'in', v_in, 'out', v_out);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_stock_summary(gold_type) TO authenticated;

CREATE OR REPLACE FUNCTION get_stock_moves(p_gold_type gold_type, p_date_from DATE DEFAULT NULL, p_date_to DATE DEFAULT NULL)
RETURNS JSONB AS $$
DECLARE
  v_today_local DATE;
  v_from DATE;
  v_to DATE;
  v_prev_w NUMERIC := 0;
  v_prev_c NUMERIC := 0;
  v_moves JSONB;
BEGIN
  v_today_local := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_from := COALESCE(p_date_from, v_today_local);
  v_to := COALESCE(p_date_to, v_today_local);

  SELECT
    COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0),
    COALESCE(SUM(CASE WHEN direction = 'IN' THEN COALESCE(price, 0) ELSE -COALESCE(price, 0) END), 0)
  INTO v_prev_w, v_prev_c
  FROM stock_moves
  WHERE gold_type = p_gold_type
    AND (date AT TIME ZONE 'Asia/Bangkok')::date < v_from;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ref_id,
    'type', type,
    'dir', direction,
    'goldG', gold_g,
    'price', COALESCE(price, 0),
    'date', date,
    'note', note
  ) ORDER BY date), '[]'::jsonb)
  INTO v_moves
  FROM stock_moves
  WHERE gold_type = p_gold_type
    AND (date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object('prevW', v_prev_w, 'prevC', v_prev_c, 'moves', v_moves);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_stock_moves(gold_type, DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_stock_move_detail(p_ref_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'ref_id', sm.ref_id,
    'type', sm.type,
    'direction', sm.direction,
    'gold_type', sm.gold_type,
    'gold_g', sm.gold_g,
    'price', sm.price,
    'note', sm.note,
    'date', sm.date,
    'items', (
      SELECT jsonb_agg(jsonb_build_object('productId', smi.product_id, 'qty', smi.qty))
      FROM stock_move_items smi WHERE smi.move_id = sm.id
    )
  )
  INTO v_result
  FROM stock_moves sm
  WHERE sm.ref_id = p_ref_id
  LIMIT 1;

  RETURN COALESCE(v_result, jsonb_build_object('success', false, 'message', 'Not found'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_stock_move_detail(TEXT) TO authenticated;
