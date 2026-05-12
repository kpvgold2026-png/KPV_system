-- ============================================================
-- Diagnose: เช็คสถานะ user ในระบบ auth
-- ============================================================
-- รันทีละ query ใน Supabase SQL Editor แล้วส่งผลกลับมาให้ผมดู
-- ============================================================


-- ============================================================
-- Q1: user 'u4' (ที่สร้างใหม่) อยู่ครบทั้ง 3 ที่มั้ย ?
-- ============================================================
SELECT 'public.users' AS source,
       u.id::text AS uid, u.username AS field1, u.role::text AS field2, u.is_active::text AS field3
FROM public.users u WHERE u.username = 'u4'
UNION ALL
SELECT 'auth.users',
       a.id::text, a.email, (a.encrypted_password IS NOT NULL)::text, COALESCE(a.banned_until::text, 'null')
FROM auth.users a WHERE a.email = 'u4@kpv.local'
UNION ALL
SELECT 'auth.identities',
       i.user_id::text, i.provider, i.provider_id, left(i.identity_data::text, 80)
FROM auth.identities i
WHERE i.user_id IN (SELECT id FROM auth.users WHERE email = 'u4@kpv.local');


-- ============================================================
-- Q2: เปรียบเทียบ user ใหม่ (u4) vs admin เก่าที่ login ได้
-- ============================================================
-- เปลี่ยน 'admin' เป็น username admin ที่ login ได้
SELECT
  a.email,
  a.aud, a.role, a.instance_id::text,
  a.email_confirmed_at IS NOT NULL AS email_confirmed,
  a.confirmation_token, a.recovery_token,
  a.email_change_token_new, a.email_change,
  a.raw_app_meta_data, a.raw_user_meta_data,
  a.banned_until::text,
  a.is_super_admin,
  a.created_at
FROM auth.users a
WHERE a.email IN ('u4@kpv.local', 'admin@kpv.local')
ORDER BY a.email;


-- ============================================================
-- Q3: ทดสอบ hook function กับ user u4 โดยตรง
-- ============================================================
-- ถ้า hook พังเมื่อเจอ user u4 → จะเห็น error / output แปลก
SELECT public.custom_access_token_hook(
  jsonb_build_object(
    'user_id', (SELECT id::text FROM auth.users WHERE email = 'u4@kpv.local'),
    'claims', jsonb_build_object(
      'sub', (SELECT id::text FROM auth.users WHERE email = 'u4@kpv.local'),
      'email', 'u4@kpv.local',
      'role', 'authenticated',
      'aud', 'authenticated'
    )
  )
);


-- ============================================================
-- Q4: hook function ติดตั้งถูกมั้ย + owner เป็นใคร
-- ============================================================
SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  p.prosecdef AS security_definer,
  pg_get_userbyid(p.proowner) AS owner,
  p.proconfig AS config
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'custom_access_token_hook';


-- ============================================================
-- Q5: เช็ค schema auth.identities — มี column อะไรบ้าง
-- ============================================================
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'auth' AND table_name = 'identities'
ORDER BY ordinal_position;


-- ============================================================
-- Q6a: เปรียบเทียบ TUUUUKKK field ของ auth.users (u4 vs admin)
-- ============================================================
-- แสดงเฉพาะ field ที่ "ต่าง" → จะได้รู้ว่าอะไรขาดไป
-- เปลี่ยน admin@... เป็น email admin จริง
WITH u4 AS (SELECT to_jsonb(t.*) AS r FROM auth.users t WHERE email = 'u4@kpv.local'),
     ad AS (SELECT to_jsonb(t.*) AS r FROM auth.users t WHERE email = 'admin@kpv.local')
SELECT k AS field, u4.r->k AS u4_value, ad.r->k AS admin_value
FROM u4, ad, jsonb_object_keys(u4.r) k
WHERE (u4.r->k) IS DISTINCT FROM (ad.r->k);


-- ============================================================
-- Q6b: เปรียบเทียบทุก field ของ auth.identities (u4 vs admin)
-- ============================================================
WITH u4 AS (
  SELECT to_jsonb(t.*) AS r
  FROM auth.identities t
  WHERE user_id = (SELECT id FROM auth.users WHERE email = 'u4@kpv.local')
),
ad AS (
  SELECT to_jsonb(t.*) AS r
  FROM auth.identities t
  WHERE user_id = (SELECT id FROM auth.users WHERE email = 'admin@kpv.local')
)
SELECT k AS field, u4.r->k AS u4_value, ad.r->k AS admin_value
FROM u4, ad, jsonb_object_keys(u4.r) k
WHERE (u4.r->k) IS DISTINCT FROM (ad.r->k);


-- ============================================================
-- Q7: verify password hash ของ u4 ตรงรหัสที่ตั้งไว้มั้ย ?
-- ============================================================
-- เปลี่ยน 'u4' หลัง crypt() เป็น password ที่ตั้งตอนสร้าง
SELECT
  email,
  (encrypted_password = crypt('u4', encrypted_password)) AS pwd_match,
  left(encrypted_password, 7) AS hash_prefix
FROM auth.users
WHERE email = 'u4@kpv.local';


-- ============================================================
-- Q8: ลิสต์ user ทั้งหมด — เทียบ public.users vs auth.users
-- ============================================================
SELECT
  COALESCE(u.username, '(no public)') AS username,
  COALESCE(u.role::text, '-') AS public_role,
  COALESCE(u.is_active::text, '-') AS active,
  COALESCE(a.email, '(no auth)') AS auth_email,
  COALESCE(a.raw_app_meta_data->>'user_role', '-') AS auth_role,
  COALESCE(a.banned_until::text, '-') AS banned,
  (SELECT COUNT(*) FROM auth.identities i WHERE i.user_id = COALESCE(u.id, a.id)) AS n_identities
FROM public.users u
FULL OUTER JOIN auth.users a ON a.id = u.id
ORDER BY COALESCE(u.created_at, a.created_at) DESC;
