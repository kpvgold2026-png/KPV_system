-- ============================================================
-- Admin User Management Fix
-- ============================================================
-- ปัญหา: save_user เดิม insert แค่ public.users
-- ทำให้ user ใหม่ login ผ่าน Supabase Auth ไม่ได้
-- (auth.users ไม่มี entry แม้ trigger sync จะตั้งไว้แล้ว
--  trigger อาจไม่ทำงานเพราะ permission/owner ของ function)
--
-- วิธีแก้: ให้ save_user เขียน auth.users ตรง ๆ
--         delete_user_soft → ban ใน auth.users ด้วย
--
-- วิธีใช้:
--   1. เปิด Supabase Dashboard → SQL Editor
--   2. รัน SQL ไฟล์นี้ทั้งหมด
--   3. ทดสอบสร้าง user ผ่าน tab User Setting ในแอป
-- ============================================================


-- ============================================================
-- save_user: สร้าง/แก้ไข user ทั้ง public.users และ auth.users
-- ============================================================
CREATE OR REPLACE FUNCTION save_user(
  p_user_id UUID,
  p_role user_role,
  p_nickname TEXT,
  p_username TEXT,
  p_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_existing UUID;
  v_new_id UUID;
  v_email TEXT;
  v_hash TEXT;
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;

  IF p_username IS NULL OR length(trim(p_username)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Username required');
  END IF;

  v_email := lower(trim(p_username)) || '@kpv.local';

  IF p_user_id IS NULL THEN
    -- ===== สร้างใหม่ =====
    SELECT id INTO v_existing FROM public.users WHERE username = p_username;
    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Username already exists');
    END IF;
    IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) THEN
      RETURN jsonb_build_object('success', false, 'message', 'Email already exists in auth.users');
    END IF;
    IF p_password IS NULL OR length(p_password) = 0 THEN
      RETURN jsonb_build_object('success', false, 'message', 'Password required for new user');
    END IF;

    v_new_id := gen_random_uuid();
    v_hash := hash_password(p_password);

    -- auth.users ก่อน
    INSERT INTO auth.users (
      id, instance_id, aud, role,
      email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    )
    VALUES (
      v_new_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'authenticated', 'authenticated',
      v_email, v_hash, NOW(),
      jsonb_build_object(
        'provider', 'email',
        'providers', jsonb_build_array('email'),
        'user_role', p_role::text
      ),
      jsonb_build_object('username', p_username, 'nickname', p_nickname),
      NOW(), NOW()
    );

    -- auth.identities (จำเป็น — Supabase ใช้ดู provider ของ user)
    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    VALUES (
      gen_random_uuid(),
      v_new_id,
      v_new_id::text,
      jsonb_build_object(
        'sub', v_new_id::text,
        'email', v_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      NOW(), NOW(), NOW()
    );

    -- public.users (id เดียวกัน)
    INSERT INTO public.users (id, role, nickname, username, password_hash, is_active)
    VALUES (v_new_id, p_role, p_nickname, p_username, v_hash, TRUE);

    RETURN jsonb_build_object('success', true, 'message', 'User created', 'user_id', v_new_id);

  ELSE
    -- ===== แก้ไข =====
    v_hash := CASE
      WHEN p_password IS NULL OR length(p_password) = 0 THEN NULL
      ELSE hash_password(p_password)
    END;

    UPDATE public.users SET
      role = p_role,
      nickname = p_nickname,
      username = p_username,
      password_hash = COALESCE(v_hash, password_hash),
      updated_at = NOW()
    WHERE id = p_user_id;

    UPDATE auth.users SET
      email = v_email,
      encrypted_password = COALESCE(v_hash, encrypted_password),
      raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object(
             'provider', 'email',
             'providers', jsonb_build_array('email'),
             'user_role', p_role::text
           ),
      raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object('username', p_username, 'nickname', p_nickname),
      updated_at = NOW()
    WHERE id = p_user_id;

    -- sync email ใน auth.identities ด้วย (เผื่อเปลี่ยน username)
    -- ถ้ายังไม่มี identity row → สร้างให้
    IF EXISTS (SELECT 1 FROM auth.identities WHERE user_id = p_user_id AND provider = 'email') THEN
      UPDATE auth.identities SET
        identity_data = COALESCE(identity_data, '{}'::jsonb)
          || jsonb_build_object(
               'sub', p_user_id::text,
               'email', v_email,
               'email_verified', true
             ),
        updated_at = NOW()
      WHERE user_id = p_user_id AND provider = 'email';
    ELSE
      INSERT INTO auth.identities (
        id, user_id, provider_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
      )
      VALUES (
        gen_random_uuid(),
        p_user_id,
        p_user_id::text,
        jsonb_build_object(
          'sub', p_user_id::text,
          'email', v_email,
          'email_verified', true,
          'phone_verified', false
        ),
        'email',
        NOW(), NOW(), NOW()
      );
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'User updated');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION save_user(UUID, user_role, TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- delete_user_soft: soft delete + ban ใน auth.users
-- ============================================================
-- ไม่ลบ row จริง → preserve foreign key history
-- แต่ ban ใน auth.users → ล็อกอินไม่ได้
CREATE OR REPLACE FUNCTION delete_user_soft(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;

  IF p_user_id = current_user_id() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot delete yourself');
  END IF;

  UPDATE public.users
    SET is_active = FALSE, updated_at = NOW()
    WHERE id = p_user_id;

  UPDATE auth.users
    SET banned_until = 'infinity'::timestamptz,
        updated_at = NOW()
    WHERE id = p_user_id;

  RETURN jsonb_build_object('success', true, 'message', 'User deleted');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION delete_user_soft(UUID) TO authenticated;


-- ============================================================
-- restore_user: เปิดใช้ user ที่เคยถูกลบ
-- ============================================================
CREATE OR REPLACE FUNCTION restore_user(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;

  UPDATE public.users
    SET is_active = TRUE, updated_at = NOW()
    WHERE id = p_user_id;

  UPDATE auth.users
    SET banned_until = NULL, updated_at = NOW()
    WHERE id = p_user_id;

  RETURN jsonb_build_object('success', true, 'message', 'User restored');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION restore_user(UUID) TO authenticated;


-- ============================================================
-- Backfill: เติม auth.identities ให้ user เก่าที่ migrate มาแต่ยังขาด
-- ============================================================
-- รันครั้งเดียวพอ — user เก่าที่เคย login ผ่าน Supabase ได้ปกติจะมีอยู่แล้ว
-- แต่ใส่ไว้กันเหนียวเผื่อมี row ที่ยังไม่มี identity
INSERT INTO auth.identities (
  id, user_id, provider_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at
)
SELECT
  gen_random_uuid(),
  a.id,
  a.id::text,
  jsonb_build_object(
    'sub', a.id::text,
    'email', a.email,
    'email_verified', true,
    'phone_verified', false
  ),
  'email',
  NOW(), NOW(), NOW()
FROM auth.users a
WHERE a.email IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM auth.identities i
    WHERE i.user_id = a.id AND i.provider = 'email'
  );


-- ============================================================
-- ทดสอบหลัง apply (รันใน SQL Editor)
-- ============================================================
--   SELECT u.username, u.role, u.is_active,
--          a.email, a.banned_until,
--          a.raw_app_meta_data->>'user_role' AS auth_role,
--          (a.id = u.id) AS id_match
--   FROM public.users u
--   LEFT JOIN auth.users a ON a.id = u.id
--   ORDER BY u.created_at DESC;
--
-- ทุก row ต้อง id_match=true และ auth_role ตรงกับ role
-- row ที่ is_active=false ต้องมี banned_until ไม่ NULL
