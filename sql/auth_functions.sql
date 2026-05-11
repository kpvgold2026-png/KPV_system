CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION hash_password(p_password TEXT)
RETURNS TEXT AS $$
  SELECT crypt(p_password, gen_salt('bf', 10));
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION verify_password(p_password TEXT, p_hash TEXT)
RETURNS BOOLEAN AS $$
  SELECT crypt(p_password, p_hash) = p_hash;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION login_user(
  p_username TEXT,
  p_password TEXT
)
RETURNS JSONB AS $$
DECLARE
  u RECORD;
BEGIN
  SELECT users.id, users.username, users.nickname, users.role::text AS role, users.password_hash, users.is_active
  INTO u
  FROM users
  WHERE users.username = p_username;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'User not found');
  END IF;

  IF NOT u.is_active THEN
    RETURN jsonb_build_object('success', false, 'message', 'User is inactive');
  END IF;

  IF NOT verify_password(p_password, u.password_hash) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid password');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'id', u.id,
    'username', u.username,
    'nickname', COALESCE(u.nickname, u.role),
    'role', u.role
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION login_user(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION login_user(TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION open_shift(
  p_user_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_id TEXT;
BEGIN
  v_id := 'SHIFT-' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '-' || substring(p_user_id::text, 1, 4);

  INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
  VALUES (v_id, p_user_id, 'OPEN_SHIFT', p_amount, 'LAK', 'CASH', 'Open shift', NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION open_shift(UUID, NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION set_user_password(
  p_user_id UUID,
  p_new_password TEXT
)
RETURNS VOID AS $$
BEGIN
  IF NOT (is_admin() OR p_user_id = current_user_id()) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;
  UPDATE users SET password_hash = hash_password(p_new_password)
  WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION set_user_password(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION create_user(
  p_username TEXT,
  p_password TEXT,
  p_nickname TEXT,
  p_role user_role
)
RETURNS UUID AS $$
DECLARE
  v_id UUID;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'Permission denied: admin only';
  END IF;
  INSERT INTO users (role, nickname, username, password_hash)
  VALUES (p_role, p_nickname, p_username, hash_password(p_password))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION create_user(TEXT, TEXT, TEXT, user_role) TO authenticated;

CREATE OR REPLACE FUNCTION reject_tx(p_tx_id TEXT, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_type tx_type;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;
  SELECT status, type INTO v_status, v_type FROM transactions WHERE id = p_tx_id;
  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status NOT IN ('PENDING', 'APPROVED') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot reject: ' || v_status);
  END IF;
  UPDATE transactions SET status = 'REJECTED', note = p_note, updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, note, approved_by_id)
  VALUES (p_tx_id, v_type::text, 'REJECTED', p_note, v_user_id);
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION reject_tx(TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION delete_tx(p_tx_id TEXT)
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
  IF v_payload IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
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

GRANT EXECUTE ON FUNCTION delete_tx(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION set_my_session(p_session TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  UPDATE users SET session_token = p_session, updated_at = NOW() WHERE id = v_user_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION set_my_session(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_my_session()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_session TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('session_token', NULL);
  END IF;
  SELECT session_token INTO v_session FROM users WHERE id = v_user_id;
  RETURN jsonb_build_object('session_token', v_session);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('session_token', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_my_session() TO authenticated;
