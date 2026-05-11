# Migration Log

## ✅ ระบบใช้ Supabase ครบทุกส่วน
ไม่มี reference ไปยัง Google Apps Script / Google Sheets เหลือในโค้ด

## ✅ Auth ย้ายไป Supabase Auth แล้ว
เลิกใช้ custom JWT (sign ฝั่ง client ด้วย secret ใน config) → ใช้ `supabase.auth.signInWithPassword()`

## 🚀 ขั้นตอน apply (ต้องทำตามลำดับนี้)

### 1. รัน SQL migration
ไปที่ Supabase Dashboard → SQL Editor → รันไฟล์ `sql/supabase_auth_migration.sql` ทั้งไฟล์

### 2. ย้าย user ที่มีอยู่
```sql
SELECT migrate_users_to_auth();
```
ตรวจสอบ:
```sql
SELECT u.username, u.role,
       a.email, a.raw_app_meta_data->>'user_role' AS auth_role,
       (a.id = u.id) AS id_match
FROM public.users u
LEFT JOIN auth.users a ON a.id = u.id
WHERE u.is_active;
```
ทุกแถวต้อง `id_match = true` และ `auth_role` ตรงกับ `role`

### 3. ตั้งค่า Supabase Dashboard
- **Authentication → Providers → Email**: ปิด "Confirm email"
- **Authentication → Hooks**: เพิ่ม "Customize Access Token" hook → Postgres function `public.custom_access_token_hook`
- **Authentication → JWT Settings**: ตั้ง Access Token Expiry = `86400` (24 ชั่วโมง)
- **Project Settings → API → JWT Secret**: กด **Rotate** → secret เก่าใน git history ใช้ปลอม token ไม่ได้อีก

### 4. ทดสอบ 1 user ก่อน
- เปิดหน้าเว็บ → login ด้วย username/password เดิม
- ถ้า login ได้ + เห็น dashboard → password migration สำเร็จ
- ถ้า login ไม่ได้ → password hash ไม่เข้ากัน ต้อง force reset แต่ละ user ผ่าน Supabase Dashboard

### 5. Deploy frontend
ไฟล์ที่เปลี่ยน:
- `index.html` — โหลด `@supabase/supabase-js@2` จาก CDN, ลบ `js/jwt.js` script
- `js/config.js` — ไม่มี `JWT_SECRET` อีกต่อไป, init `sb` (Supabase client) ที่นี่
- `js/jwt.js` — stub เปล่า (เก็บไฟล์เพื่อกัน cache เก่า 404)
- `js/api.js` — `_apiHeaders` ดึง access_token จาก `sb.auth.getSession()` ผ่าน `_cachedSession`
- `js/auth.js` — `login/logout/restoreSession` ใช้ `sb.auth.*`, kick-other-device ใช้ Supabase Realtime channel แทน raw WebSocket

## โครงสร้าง Auth ใหม่

### Login flow
```
ผู้ใช้พิมพ์ username + password
      │
      ▼
frontend แปลง: username → username@kpv.local
      │
      ▼
sb.auth.signInWithPassword({email, password})
      │
      ▼
Supabase Auth verify password (bcrypt) → sign JWT
      │ (ตอน sign เรียก custom_access_token_hook)
      │ ฉีด user_role จาก public.users.role เข้า claims.app_metadata.user_role
      ▼
SDK เก็บ session ใน localStorage (key: kpv-auth)
      │
      ▼
frontend ดึงข้อมูล user จาก public.users → set currentUser
      │
      ▼
generate sessionId → set_my_session() + broadcast 'kick'
```

### Session lifecycle
- Access token หมดอายุ 24 ชม. → SDK auto-refresh ผ่าน refresh token
- Inactivity 60 นาที (ตั้งใน `CONFIG.INACTIVITY_TIMEOUT_MINUTES`) → call `signOut()` + reload
- Login จากอีกเครื่อง → `users.session_token` เปลี่ยน → เครื่องอื่น poll/Realtime → kick

### RLS
- `auth.uid()` คืน UUID ตรงกับ `public.users.id` (เพราะ migration ใช้ id เดียวกัน)
- `current_user_id()` → `SELECT auth.uid()`
- `current_user_role()` → อ่านจาก `claims.app_metadata.user_role` (ถูก inject โดย custom_access_token_hook) + fallback อ่าน `users.role` ตรง ๆ
- Policy ทั้งหมดที่ใช้ `current_user_id()` / `current_user_role()` ยังทำงานเหมือนเดิม

### Sync trigger
- `trg_sync_user_to_auth` บน `public.users` — ทุกครั้งที่ INSERT/UPDATE username, password_hash, role, nickname → sync ไป `auth.users` ให้
- หมายความว่า `create_user()`, `set_user_password()`, `save_user()` RPCs เดิมยังใช้ได้ ไม่ต้องแก้

## ⚠️ Edge cases ที่ควรรู้

- **Username มี `@` อยู่แล้ว**: frontend จะใช้ตรง ๆ ไม่ append `@kpv.local` (กันชนกับ email จริง)
- **Offline ตอน refresh token**: SDK auto-refresh ตอนใกล้หมดอายุ (~5 นาทีก่อน) ถ้า offline ช่วงนั้น user จะถูก kick ตอน online กลับมา — กระทบน้อยเพราะ TTL 24 ชม.
- **localStorage เก่าค้าง**: ถ้าเปิดเว็บแล้วเจอ `jwt` key ค้างจากระบบเก่า — เด้งกลับหน้า login แล้ว login ใหม่ก็เคลียร์เอง
