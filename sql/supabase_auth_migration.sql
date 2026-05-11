-- ============================================================
-- Supabase Auth Migration
-- ============================================================
-- ย้ายระบบ login จาก custom JWT (HS256 sign ฝั่ง client) → Supabase Auth
--
-- ลำดับการ apply (ทำตามนี้เท่านั้น):
--   1. รัน SQL ทั้งไฟล์นี้ใน Supabase SQL Editor (สิทธิ์ service role)
--   2. รัน: SELECT migrate_users_to_auth();
--   3. ไปที่ Supabase Dashboard → Authentication → Providers → Email
--      ปิด "Confirm email"
--   4. ไปที่ Authentication → Hooks
--      เพิ่ม "Custom Access Token" hook → Postgres function:
--        public.custom_access_token_hook
--   5. ไปที่ Authentication → Settings (JWT Settings)
--      ตั้ง "Access token expiry" = 86400 (24 ชั่วโมง)
--   6. ไปที่ Project Settings → API → Rotate JWT Secret
--      (จะ invalidate ทุก JWT เก่าที่ sign ด้วย secret เดิมใน config.js)
--   7. Deploy โค้ด frontend ใหม่
-- ============================================================


-- ============================================================
-- Step 1: Migration function — copy public.users → auth.users
-- ============================================================
-- จุดสำคัญ: ใช้ id เดียวกับ public.users.id เพื่อไม่ต้องแก้ FK ทุก table
-- password_hash จาก gen_salt('bf', 10) เข้ากันได้กับ auth.users.encrypted_password
-- (Supabase Auth ใช้ bcrypt verify อยู่แล้ว)

CREATE OR REPLACE FUNCTION migrate_users_to_auth()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count INT := 0;
  v_skipped INT := 0;
  v_user RECORD;
BEGIN
  FOR v_user IN
    SELECT u.id, u.username, u.password_hash, u.role, u.nickname, u.created_at, u.updated_at
    FROM public.users u
    WHERE u.is_active = TRUE
  LOOP
    IF EXISTS (SELECT 1 FROM auth.users a WHERE a.id = v_user.id) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO auth.users (
      id, instance_id, aud, role,
      email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    )
    VALUES (
      v_user.id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'authenticated',
      'authenticated',
      lower(v_user.username) || '@kpv.local',
      v_user.password_hash,
      NOW(),
      jsonb_build_object(
        'provider', 'email',
        'providers', jsonb_build_array('email'),
        'user_role', v_user.role::text
      ),
      jsonb_build_object(
        'username', v_user.username,
        'nickname', v_user.nickname
      ),
      v_user.created_at,
      COALESCE(v_user.updated_at, v_user.created_at)
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'migrated', v_count, 'skipped', v_skipped);
END;
$$;

REVOKE ALL ON FUNCTION migrate_users_to_auth() FROM PUBLIC;


-- ============================================================
-- Step 2: Update RLS helpers to use auth.uid() + app_metadata claim
-- ============================================================

CREATE OR REPLACE FUNCTION current_user_id() RETURNS UUID AS $$
  SELECT auth.uid()
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION current_user_role() RETURNS user_role AS $$
DECLARE
  r TEXT;
  v_role user_role;
BEGIN
  r := NULLIF(current_setting('request.jwt.claims', true)::json->'app_metadata'->>'user_role', '');
  IF r IS NOT NULL THEN
    BEGIN
      RETURN r::user_role;
    EXCEPTION WHEN OTHERS THEN
      r := NULL;
    END;
  END IF;

  SELECT role INTO v_role FROM public.users WHERE id = auth.uid() LIMIT 1;
  RETURN v_role;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================
-- Step 3: Custom Access Token Hook
-- ============================================================
-- ฟังก์ชันนี้ Supabase Auth จะเรียกตอน sign JWT
-- ฉีด user_role จาก public.users เข้าใน claims.app_metadata.user_role
-- หลัง deploy ต้องไป config ที่ Dashboard → Auth → Hooks

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  claims jsonb;
  user_role_val text;
BEGIN
  SELECT role::text INTO user_role_val
  FROM public.users
  WHERE id = (event->>'user_id')::uuid;

  claims := event->'claims';
  IF user_role_val IS NOT NULL THEN
    IF claims->'app_metadata' IS NULL THEN
      claims := jsonb_set(claims, '{app_metadata}', '{}'::jsonb);
    END IF;
    claims := jsonb_set(claims, '{app_metadata,user_role}', to_jsonb(user_role_val));
  END IF;

  RETURN jsonb_set(event, '{claims}', claims);
END;
$$;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
GRANT SELECT ON public.users TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;


-- ============================================================
-- Step 4: Sync trigger — รักษาความสอดคล้องระหว่าง public.users กับ auth.users
-- ============================================================
-- เมื่อสร้าง user ผ่าน create_user() RPC → ต้อง insert auth.users ด้วย
-- เมื่อ update role/password ที่ public.users → sync ไป auth.users
-- (เก็บไว้เพื่อให้ create_user ใน auth_functions.sql ยังใช้ได้)

CREATE OR REPLACE FUNCTION sync_user_to_auth() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = NEW.id) THEN
      INSERT INTO auth.users (
        id, instance_id, aud, role,
        email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at
      ) VALUES (
        NEW.id,
        '00000000-0000-0000-0000-000000000000'::uuid,
        'authenticated', 'authenticated',
        lower(NEW.username) || '@kpv.local',
        NEW.password_hash,
        NOW(),
        jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'user_role', NEW.role::text),
        jsonb_build_object('username', NEW.username, 'nickname', NEW.nickname),
        NEW.created_at,
        COALESCE(NEW.updated_at, NEW.created_at)
      );
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE auth.users SET
      email = lower(NEW.username) || '@kpv.local',
      encrypted_password = NEW.password_hash,
      raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('user_role', NEW.role::text),
      raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('username', NEW.username, 'nickname', NEW.nickname),
      updated_at = NOW()
    WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_sync_user_to_auth ON public.users;
CREATE TRIGGER trg_sync_user_to_auth
  AFTER INSERT OR UPDATE OF username, password_hash, role, nickname
  ON public.users
  FOR EACH ROW EXECUTE FUNCTION sync_user_to_auth();


-- ============================================================
-- Step 5: Verification queries (run แล้วดูผล)
-- ============================================================
-- ก่อน apply: SELECT migrate_users_to_auth();
-- หลัง apply ลองรัน:
--
--   SELECT u.username, u.role,
--          a.email, a.raw_app_meta_data->>'user_role' AS auth_role,
--          a.id = u.id AS id_match
--   FROM public.users u
--   LEFT JOIN auth.users a ON a.id = u.id
--   WHERE u.is_active;
--
-- ทุกแถวควรมี id_match=true และ auth_role = role
