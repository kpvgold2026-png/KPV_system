-- ============================================================
-- Diagnose: เช็คสถานะ user ในระบบ auth
-- ============================================================
-- รันทีละ query ใน Supabase SQL Editor แล้วส่งผลกลับมาให้ผมดู
-- ============================================================


-- ============================================================
-- Q1: User ใหม่ที่เพิ่งสร้างผ่าน UI มีอยู่ครบทั้ง 3 ที่มั้ย ?
-- ============================================================
-- เปลี่ยน 'xxx' เป็น username ที่เพิ่งสร้าง
SELECT
  'public.users' AS source,
  u.id::text, u.username, u.role::text AS info, u.is_active::text AS extra
FROM public.users u
WHERE u.username = 'xxx'

UNION ALL

SELECT
  'auth.users',
  a.id::text, a.email, a.encrypted_password IS NOT NULL AS info, a.banned_until::text
FROM auth.users a
WHERE a.email = lower('xxx') || '@kpv.local'

UNION ALL

SELECT
  'auth.identities',
  i.user_id::text, i.provider, i.provider_id, i.identity_data::text
FROM auth.identities i
WHERE i.user_id IN (SELECT id FROM auth.users WHERE email = lower('xxx') || '@kpv.local');


-- ============================================================
-- Q2: ลอง login แบบใน SQL ตรงๆ — verify password ผ่านมั้ย ?
-- ============================================================
-- เปลี่ยน 'xxx' = username, 'yyy' = password
SELECT
  username,
  role::text,
  is_active,
  (password_hash = crypt('yyy', password_hash)) AS password_match
FROM public.users
WHERE username = 'xxx';


-- ============================================================
-- Q3: เช็ค schema ของ auth.users — มี column อะไรที่เป็น NOT NULL บ้าง
-- ============================================================
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'auth' AND table_name = 'users'
  AND is_nullable = 'NO'
ORDER BY ordinal_position;


-- ============================================================
-- Q4: เช็ค custom_access_token_hook ติดตั้งถูกมั้ย
-- ============================================================
SELECT
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  l.lanname AS language,
  p.prosecdef AS security_definer,
  pg_get_userbyid(p.proowner) AS owner
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'public' AND p.proname = 'custom_access_token_hook';


-- ============================================================
-- Q5: ลิสต์ user ทั้งหมด พร้อมสถานะแต่ละที่
-- ============================================================
SELECT
  COALESCE(u.username, '(missing public)') AS username,
  COALESCE(u.role::text, '-') AS public_role,
  COALESCE(u.is_active::text, '-') AS active,
  COALESCE(a.email, '(missing auth)') AS auth_email,
  COALESCE(a.banned_until::text, 'null') AS banned,
  COALESCE(a.raw_app_meta_data->>'user_role', '-') AS auth_role,
  (SELECT COUNT(*) FROM auth.identities i WHERE i.user_id = COALESCE(u.id, a.id)) AS identity_count,
  COALESCE(u.id, a.id)::text AS uid
FROM public.users u
FULL OUTER JOIN auth.users a ON a.id = u.id
ORDER BY u.created_at DESC NULLS LAST;
