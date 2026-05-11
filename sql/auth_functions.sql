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
RETURNS TABLE (
  id UUID,
  username TEXT,
  nickname TEXT,
  role TEXT
) AS $$
DECLARE
  u RECORD;
BEGIN
  SELECT users.id, users.username, users.nickname, users.role::text AS role, users.password_hash, users.is_active
  INTO u
  FROM users
  WHERE users.username = p_username;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF NOT u.is_active THEN
    RETURN;
  END IF;

  IF NOT verify_password(p_password, u.password_hash) THEN
    RETURN;
  END IF;

  id := u.id;
  username := u.username;
  nickname := u.nickname;
  role := u.role;
  RETURN NEXT;
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
