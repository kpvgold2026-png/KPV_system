CREATE OR REPLACE FUNCTION update_pricing(p_sell_1baht NUMERIC, p_note TEXT DEFAULT NULL)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;
  IF p_sell_1baht IS NULL OR p_sell_1baht <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid price');
  END IF;
  INSERT INTO pricing (sell_1baht, buyback_1baht, note, date, updated_by)
  VALUES (p_sell_1baht, 0, p_note, NOW(), v_user_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION update_pricing(NUMERIC, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION add_price_rate(
  p_thb_sell NUMERIC,
  p_usd_sell NUMERIC,
  p_thb_buy NUMERIC,
  p_usd_buy NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;
  INSERT INTO price_rates (thb_sell, usd_sell, thb_buy, usd_buy, date, updated_by)
  VALUES (p_thb_sell, p_usd_sell, p_thb_buy, p_usd_buy, NOW(), v_user_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION add_price_rate(NUMERIC, NUMERIC, NUMERIC, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION add_cashbank_entry(
  p_type cashbank_type,
  p_amount NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_name TEXT,
  p_note TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_bank_id UUID := NULL;
  v_cb_id TEXT;
  v_signed_amount NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  IF p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    SELECT id INTO v_bank_id FROM banks WHERE name = p_bank_name LIMIT 1;
  END IF;

  v_signed_amount := CASE
    WHEN p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE') THEN -ABS(p_amount)
    WHEN p_type IN ('CASH_IN', 'BANK_IN', 'BANK_DEPOSIT', 'OTHER_INCOME') THEN ABS(p_amount)
    ELSE p_amount
  END;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text), 1, 6);

  INSERT INTO cashbank (id, type, amount, currency, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type, v_signed_amount, p_currency, p_method, v_bank_id, p_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION add_cashbank_entry(cashbank_type, NUMERIC, currency_code, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_cashbank_balances()
RETURNS JSONB AS $$
DECLARE
  v_result JSONB := '{}'::jsonb;
  v_cash JSONB;
  v_banks JSONB;
BEGIN
  SELECT jsonb_object_agg(currency, total) INTO v_cash FROM (
    SELECT currency::text, COALESCE(SUM(amount), 0) AS total
    FROM cashbank WHERE method = 'CASH' GROUP BY currency
  ) t;

  SELECT jsonb_object_agg(bank_name, balances) INTO v_banks FROM (
    SELECT b.name AS bank_name,
           jsonb_object_agg(cb.currency, COALESCE(cb.total, 0)) AS balances
    FROM banks b
    LEFT JOIN (
      SELECT bank_id, currency::text, SUM(amount) AS total
      FROM cashbank
      WHERE method <> 'CASH' AND bank_id IS NOT NULL
      GROUP BY bank_id, currency
    ) cb ON cb.bank_id = b.id
    WHERE b.is_active = TRUE
    GROUP BY b.name
  ) t;

  RETURN jsonb_build_object(
    'cash', COALESCE(v_cash, '{}'::jsonb),
    'banks', COALESCE(v_banks, '{}'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_cashbank_balances() TO authenticated;

CREATE OR REPLACE FUNCTION list_users()
RETURNS JSONB AS $$
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;
  RETURN jsonb_build_object('success', true, 'data', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id,
      'role', role,
      'nickname', nickname,
      'username', username,
      'is_active', is_active
    ) ORDER BY role, nickname), '[]'::jsonb)
    FROM users WHERE is_active = TRUE
  ));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION list_users() TO authenticated;

CREATE OR REPLACE FUNCTION save_user(
  p_user_id UUID,
  p_role user_role,
  p_nickname TEXT,
  p_username TEXT,
  p_password TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_caller UUID;
  v_existing UUID;
BEGIN
  v_caller := current_user_id();
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;

  IF p_user_id IS NULL THEN
    SELECT id INTO v_existing FROM users WHERE username = p_username;
    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Username already exists');
    END IF;
    INSERT INTO users (role, nickname, username, password_hash, is_active)
    VALUES (p_role, p_nickname, p_username, hash_password(p_password), TRUE);
    RETURN jsonb_build_object('success', true, 'message', 'User created');
  ELSE
    UPDATE users SET
      role = p_role,
      nickname = p_nickname,
      username = p_username,
      password_hash = CASE WHEN p_password IS NULL OR p_password = '' THEN password_hash ELSE hash_password(p_password) END,
      updated_at = NOW()
    WHERE id = p_user_id;
    RETURN jsonb_build_object('success', true, 'message', 'User updated');
  END IF;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION save_user(UUID, user_role, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION delete_user_soft(p_user_id UUID)
RETURNS JSONB AS $$
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;
  UPDATE users SET is_active = FALSE, updated_at = NOW() WHERE id = p_user_id;
  RETURN jsonb_build_object('success', true, 'message', 'User deleted');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION delete_user_soft(UUID) TO authenticated;

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
    AND (n.target_user_id = v_user_id OR (n.target_role IS NOT NULL AND n.target_role::text = v_role::text))
    AND n.created_at > NOW() - INTERVAL '7 days'
  LIMIT 50;

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_notifications() TO authenticated;

CREATE OR REPLACE FUNCTION mark_notifications_read()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false);
  END IF;

  INSERT INTO notification_reads (notification_id, user_id, read_at)
  SELECT n.id, v_user_id, NOW()
  FROM notifications n
  LEFT JOIN notification_reads nr ON nr.notification_id = n.id AND nr.user_id = v_user_id
  WHERE nr.user_id IS NULL
    AND n.created_by_id IS DISTINCT FROM v_user_id
    AND (n.target_user_id = v_user_id OR (n.target_role IS NOT NULL AND n.target_role::text = v_role::text))
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION mark_notifications_read() TO authenticated;

