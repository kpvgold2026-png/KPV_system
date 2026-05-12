-- ============================================================
-- Round 2 fixes
-- ============================================================
-- #6 open_shift simplified message
-- #7 balance checks (cash/bank ห้ามติดลบ)
-- #4 notification — Admin เห็น Manager + notify-back-to-Sales เมื่อ review
-- #3 get_sales_with_shift — RPC สำหรับลิสต์ Sales + สถานะกะ
-- #10 get_history_txs — เพิ่ม diff fields
-- ============================================================


-- ============================================================
-- helper: check_shop_balance
-- ============================================================
-- คืน TRUE ถ้าร้านมีเงินพอใน method/currency/bank นั้น
CREATE OR REPLACE FUNCTION check_shop_balance(
  p_method TEXT,
  p_currency currency_code,
  p_bank_id UUID,
  p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RETURN TRUE; END IF;
  IF p_method = 'CASH' THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_balance
    FROM cashbank WHERE method = 'CASH' AND currency = p_currency;
  ELSE
    SELECT COALESCE(SUM(amount), 0) INTO v_balance
    FROM cashbank
    WHERE method <> 'CASH'
      AND currency = p_currency
      AND (p_bank_id IS NULL OR bank_id = p_bank_id);
  END IF;
  RETURN v_balance >= p_amount;
END;
$$;

GRANT EXECUTE ON FUNCTION check_shop_balance(TEXT, currency_code, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- #6: open_shift — error message สั้นลง
-- ============================================================
CREATE OR REPLACE FUNCTION open_shift(
  p_user_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id TEXT;
  v_cb_id TEXT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  IF NOT check_shop_balance('CASH', 'LAK', NULL, p_amount) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
  END IF;

  v_id := 'SHIFT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
          || '-' || substring(p_user_id::text, 1, 4);
  v_cb_id := 'CB-' || v_id;

  INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
  VALUES (v_cb_id, 'OPEN_SHIFT', -p_amount, 'LAK', 'CASH',
          'Open shift: ' || v_id, NOW(), p_user_id);

  INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
  VALUES (v_id, p_user_id, 'OPEN_SHIFT', p_amount, 'LAK', 'CASH', 'Open shift', NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION open_shift(UUID, NUMERIC) TO authenticated;


-- ============================================================
-- #7a: add_cashbank_entry — เช็ค balance ก่อนหัก
-- ============================================================
CREATE OR REPLACE FUNCTION add_cashbank_entry(
  p_type cashbank_type,
  p_amount NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_name TEXT,
  p_note TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bank_id UUID := NULL;
  v_cb_id TEXT;
  v_signed_amount NUMERIC;
  v_is_deduct BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  IF p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    SELECT id INTO v_bank_id FROM banks WHERE name = p_bank_name LIMIT 1;
    IF v_bank_id IS NULL THEN
      INSERT INTO banks (name, is_active) VALUES (p_bank_name, TRUE)
      RETURNING id INTO v_bank_id;
    END IF;
  END IF;

  v_is_deduct := p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE');

  IF v_is_deduct THEN
    IF NOT check_shop_balance(p_method, p_currency, v_bank_id, ABS(p_amount)) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
    END IF;
  END IF;

  v_signed_amount := CASE
    WHEN v_is_deduct THEN -ABS(p_amount)
    WHEN p_type IN ('CASH_IN', 'BANK_IN', 'BANK_DEPOSIT', 'OTHER_INCOME') THEN ABS(p_amount)
    ELSE p_amount
  END;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(random()::text), 1, 6);

  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type, v_signed_amount, p_currency, p_method, v_bank_id, p_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION add_cashbank_entry(cashbank_type, NUMERIC, currency_code, TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- #4a: get_notifications — Admin เห็น Manager + Admin notifications
-- ============================================================
CREATE OR REPLACE FUNCTION get_notifications()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_result JSONB;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF v_user_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', n.id,
    'type', n.type,
    'message', n.message,
    'tab', n.tab,
    'ref_tx_id', n.ref_tx_id,
    'created_at', n.created_at,
    'read', (nr.user_id IS NOT NULL)
  ) ORDER BY n.created_at DESC), '[]'::jsonb)
  INTO v_result
  FROM notifications n
  LEFT JOIN notification_reads nr ON nr.notification_id = n.id AND nr.user_id = v_user_id
  WHERE n.created_by_id IS DISTINCT FROM v_user_id
    AND (
      n.target_user_id = v_user_id
      OR n.target_role::text = v_role::text
      OR (v_role = 'Admin' AND n.target_role IN ('Manager', 'Sales'))
    )
    AND n.created_at > NOW() - INTERVAL '7 days'
  LIMIT 50;

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_notifications() TO authenticated;


-- ============================================================
-- #4b: notify-back-to-Sales เมื่อ Manager review/approve/reject
-- ============================================================
-- helper: insert notification ไปหา user
CREATE OR REPLACE FUNCTION _notify_user(
  p_type notification_type,
  p_message TEXT,
  p_target_user UUID,
  p_tab TEXT,
  p_tx_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_target_user IS NULL THEN RETURN; END IF;
  INSERT INTO notifications (type, message, target_user_id, tab, ref_tx_id, created_by_id)
  VALUES (p_type, p_message, p_target_user, p_tab, p_tx_id, current_user_id());
END;
$$;


-- review_sell_tx (เก่า) → patch ให้ notify Sales เมื่อ approved/rejected
-- โดย wrap function จากเดิม
CREATE OR REPLACE FUNCTION review_sell_tx(
  p_tx_id TEXT,
  p_decision TEXT,
  p_note TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_tx RECORD;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  SELECT * INTO v_tx FROM transactions WHERE id = p_tx_id AND type = 'SELL';
  IF v_tx IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found');
  END IF;
  IF v_tx.status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Must be PENDING');
  END IF;
  v_sale_user := v_tx.sale_user_id;

  IF p_decision = 'APPROVE' THEN
    UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
    PERFORM _notify_user('INFO', '✅ SELL ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                         v_sale_user, 'historysell', p_tx_id);
  ELSIF p_decision = 'REJECT' THEN
    UPDATE transactions SET status = 'REJECTED', note = p_note, updated_at = NOW() WHERE id = p_tx_id;
    PERFORM _notify_user('WARNING', '❌ SELL ของคุณถูกปฏิเสธ: ' || p_tx_id ||
                         CASE WHEN p_note IS NOT NULL THEN ' (' || p_note || ')' ELSE '' END,
                         v_sale_user, 'historysell', p_tx_id);
  ELSE
    RETURN jsonb_build_object('success', false, 'message', 'Invalid decision');
  END IF;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION review_sell_tx(TEXT, TEXT, TEXT) TO authenticated;


-- review_tradein_tx
CREATE OR REPLACE FUNCTION review_tradein_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_sale_user UUID;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;
  SELECT sale_user_id INTO v_sale_user FROM transactions
    WHERE id = p_tx_id AND type = 'TRADEIN' AND status = 'PENDING';
  IF v_sale_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found or not PENDING');
  END IF;
  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_tradein_tx(TEXT) TO authenticated;


-- review_exchange_tx
CREATE OR REPLACE FUNCTION review_exchange_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_sale_user UUID;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;
  SELECT sale_user_id INTO v_sale_user FROM transactions
    WHERE id = p_tx_id AND type = 'EXCHANGE' AND status = 'PENDING';
  IF v_sale_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found or not PENDING');
  END IF;
  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_exchange_tx(TEXT) TO authenticated;


-- review_withdraw_tx
CREATE OR REPLACE FUNCTION review_withdraw_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_sale_user UUID;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;
  SELECT sale_user_id INTO v_sale_user FROM transactions
    WHERE id = p_tx_id AND type = 'WITHDRAW' AND status = 'PENDING';
  IF v_sale_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found or not PENDING');
  END IF;
  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  PERFORM _notify_user('INFO', '✅ WITHDRAW ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_withdraw_tx(TEXT) TO authenticated;


-- ============================================================
-- #3: get_sales_with_shift — รายชื่อ Sales + สถานะกะ
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_with_shift()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_today_start := (date_trunc('day', NOW() AT TIME ZONE 'Asia/Bangkok') AT TIME ZONE 'Asia/Bangkok');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'username', u.username,
    'nickname', u.nickname,
    'role', u.role::text,
    'is_active', u.is_active,
    'shift_status', shift_status,
    'shift_amount', shift_amount,
    'shift_opened_at', shift_opened_at,
    'shift_closed_at', shift_closed_at
  ) ORDER BY u.role, u.nickname), '[]'::jsonb)
  INTO v_result
  FROM users u
  LEFT JOIN LATERAL (
    SELECT
      CASE
        WHEN cl.id IS NOT NULL THEN 'CLOSED'
        WHEN os.id IS NOT NULL THEN 'OPEN'
        ELSE 'NONE'
      END AS shift_status,
      os.amount AS shift_amount,
      os.date AS shift_opened_at,
      cl.created_at AS shift_closed_at
    FROM (
      SELECT id, amount, date FROM user_cashbook
      WHERE user_id = u.id AND type = 'OPEN_SHIFT' AND date >= v_today_start
      ORDER BY date DESC LIMIT 1
    ) os
    FULL OUTER JOIN (
      SELECT id, created_at FROM closes
      WHERE user_id = u.id AND date >= v_today_start
      ORDER BY date DESC LIMIT 1
    ) cl ON TRUE
  ) s ON TRUE
  WHERE u.is_active = TRUE AND u.role = 'Sales';

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_with_shift() TO authenticated;


-- ============================================================
-- #10: get_history_txs — เพิ่ม diff/ex_fee/switch_fee/premium จาก diffs
-- ============================================================
CREATE OR REPLACE FUNCTION get_history_txs(
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_limit INT DEFAULT 500
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF p_date_from IS NOT NULL THEN
    v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;
  IF p_date_to IS NOT NULL THEN
    v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'type', t.type,
    'status', t.status,
    'bill_id', t.bill_id,
    'phone', t.phone,
    'total', t.total,
    'paid', t.paid,
    'currency', t.currency,
    'sale_user_id', t.sale_user_id,
    'sale_nickname', u.nickname,
    'date', t.date,
    'diff', d.diff,
    'ex_fee', d.ex_fee,
    'switch_fee', d.switch_fee,
    'premium', d.premium,
    'items', (
      SELECT jsonb_agg(jsonb_build_object('productId', ti.product_id, 'qty', ti.qty, 'role', ti.item_role))
      FROM transaction_items ti WHERE ti.tx_id = t.id
    )
  ) ORDER BY t.date DESC), '[]'::jsonb)
  INTO v_result
  FROM transactions t
  LEFT JOIN users u ON u.id = t.sale_user_id
  LEFT JOIN diffs d ON d.tx_id = t.id
  WHERE (v_from IS NULL OR t.date >= v_from)
    AND (v_to IS NULL OR t.date <= v_to)
    AND (v_role <> 'Sales' OR t.sale_user_id = v_user_id)
  LIMIT p_limit;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_history_txs(DATE, DATE, INT) TO authenticated;


-- ============================================================
-- #7b: confirm_buyback_tx — เช็ค balance ก่อนจ่ายลูกค้า
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
  v_items JSONB;
  v_gold_g NUMERIC;
  v_move_id BIGINT;
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
    SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
      INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'OLD';
    v_gold_g := calc_items_gold_g(v_items);

    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, fulfilled, user_id, date)
    VALUES (p_tx_id, 'OLD', 'BUYBACK', 'IN', v_gold_g, v_price, FALSE, v_user_id, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN SELECT product_id, qty FROM transaction_items
                  WHERE tx_id = p_tx_id AND item_role = 'OLD' LOOP
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
-- #7c: stock_in_new_tx — เช็ค balance ก่อนจ่าย supplier
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
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_pay JSONB;
  v_ref_id TEXT;
  v_cb_id TEXT;
  v_weight NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- เช็ค balance ทุก payment ก่อนทำอะไรเลย (ห้ามทำบางส่วนแล้วเจอ error กลางคัน)
  FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    DECLARE
      v_method TEXT := v_pay->>'method';
      v_bank_name TEXT := v_pay->>'bank';
      v_cur TEXT := COALESCE(v_pay->>'currency', 'LAK');
      v_amount NUMERIC := (v_pay->>'amount')::numeric;
      v_fee_p NUMERIC := COALESCE((v_pay->>'fee')::numeric, 0);
      v_bank_id_chk UUID := NULL;
    BEGIN
      IF v_method = 'Bank' AND v_bank_name IS NOT NULL AND v_bank_name <> '' THEN
        SELECT id INTO v_bank_id_chk FROM banks WHERE name = v_bank_name LIMIT 1;
      END IF;
      IF NOT check_shop_balance(
        CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
        v_cur::currency_code, v_bank_id_chk, v_amount + v_fee_p
      ) THEN
        RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
      END IF;
    END;
  END LOOP;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
              || '-' || substring(md5(random()::text), 1, 4);

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
      v_fee_p NUMERIC := COALESCE((v_pay->>'fee')::numeric, 0);
      v_bank_id UUID := NULL;
    BEGIN
      IF v_method = 'Bank' AND v_bank_name IS NOT NULL AND v_bank_name <> '' THEN
        SELECT id INTO v_bank_id FROM banks WHERE name = v_bank_name LIMIT 1;
        IF v_bank_id IS NULL THEN
          INSERT INTO banks (name, is_active) VALUES (v_bank_name, TRUE)
          RETURNING id INTO v_bank_id;
        END IF;
      END IF;

      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                 || '-' || substring(md5(random()::text || v_method), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code,
              CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(p_note, 'Stock In NEW') || ' [' || v_ref_id || ']', NOW(), v_user_id);

      IF v_fee_p > 0 THEN
        v_cb_id := 'CB-FEE-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                   || '-' || substring(md5(random()::text), 1, 4);
        INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
        VALUES (v_cb_id, 'STOCK_IN_FEE', -v_fee_p, v_cur::currency_code, 'TRANSFER',
                v_bank_id, NULL, 'Stock In Fee [' || v_ref_id || ']', NOW(), v_user_id);
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
-- ทดสอบหลังรัน
-- ============================================================
--   SELECT * FROM check_shop_balance('CASH', 'LAK', NULL, 1);  -- ดูเงินสด LAK ≥ 1
--   SELECT * FROM get_sales_with_shift();                      -- list Sales + shift status
--   SELECT * FROM get_notifications();                         -- admin ควรเห็น manager noti
