-- ============================================================
-- Fix: "Database error querying schema" ตอน login
-- ============================================================
-- สาเหตุ: custom_access_token_hook เดิม
--   (1) ไม่ guard claims null → jsonb_set พังเงียบ
--   (2) public.users เปิด RLS → supabase_auth_admin อ่านไม่ได้
--   (3) ไม่ใช่ SECURITY DEFINER → bypass RLS ไม่ได้
--
-- รัน SQL นี้ใน Supabase SQL Editor
-- (ไม่ต้องลบ hook ใน Dashboard — แค่ replace function)
-- ============================================================

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  claims jsonb;
  user_role_val text;
  v_user_id uuid;
BEGIN
  BEGIN
    v_user_id := (event->>'user_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_user_id := NULL;
  END;

  IF v_user_id IS NOT NULL THEN
    BEGIN
      SELECT role::text INTO user_role_val
      FROM public.users
      WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN
      user_role_val := NULL;
    END;
  END IF;

  claims := COALESCE(event->'claims', '{}'::jsonb);

  IF claims->'app_metadata' IS NULL OR jsonb_typeof(claims->'app_metadata') <> 'object' THEN
    claims := jsonb_set(claims, '{app_metadata}', '{}'::jsonb, true);
  END IF;

  IF user_role_val IS NOT NULL THEN
    claims := jsonb_set(claims, '{app_metadata,user_role}', to_jsonb(user_role_val), true);
  END IF;

  RETURN jsonb_set(event, '{claims}', claims, true);
EXCEPTION WHEN OTHERS THEN
  RETURN event;
END;
$$;


-- เพิ่ม RLS policy ให้ supabase_auth_admin อ่าน users ได้
DROP POLICY IF EXISTS users_authadmin_read ON public.users;
CREATE POLICY users_authadmin_read ON public.users
  AS PERMISSIVE FOR SELECT
  TO supabase_auth_admin
  USING (true);


-- Re-grant สำคัญทุกระดับ
GRANT USAGE ON SCHEMA public TO supabase_auth_admin;
GRANT SELECT ON public.users TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM authenticated, anon, public;
