# Migration to Supabase — Progress Log

## ✅ Migration เสร็จสมบูรณ์

ทุกโมดูลเรียก Supabase REST/RPC ผ่าน `dbSelect/dbInsert/dbUpdate/dbDelete/dbRpc` ใน `js/api.js` ทั้งหมดแล้ว — ไม่มี reference ไปยัง Google Apps Script / Google Sheets (`fetchSheetData`, `callAppsScript`) เหลืออยู่ในโค้ด

### Layered structure
- `js/config.js` — Supabase URL, ANON_KEY, JWT_SECRET, INACTIVITY_TIMEOUT_MINUTES, product/price constants
- `js/jwt.js` — HS256 sign/verify (ไม่มี exp — ใช้ inactivity check แทน)
- `js/utils.js` — Helpers (date, format, items parsing, transaction detail/delete/audit list)
- `js/api.js` — Supabase REST wrapper + cache
- `js/auth.js` — Login ผ่าน RPC `login_user`, JWT, inactivity timeout, session enforcement (poll + Realtime WS)
- Business modules (sell, buyback, tradein, exchange, withdraw, stock*, close, cashbank, dashboard, livereport, diff, reports, review, historysell, accounting, notification, inventory, pricerate, products, usersetting, payment) — เรียก Supabase ทั้งหมด

### SQL artifacts (apply ไปที่ Supabase)
- `sql/schema.sql` — Schema + RLS ทุก table
- `sql/auth_functions.sql` — `login_user`, `open_shift`, `hash_password`, `verify_password`, `create_user`, `reject_tx`, `delete_tx`, `set_my_session`, `get_my_session`
- `sql/sell_functions.sql` — `generate_tx_id`, `calc_items_gold_g`, `get_wac_per_g`, `create_sell_tx`, `review_sell_tx`, `confirm_sell_tx`, `delete_sell_tx`
- `sql/buyback_functions.sql` — buyback RPCs (FIFO matching)
- `sql/tradein_functions.sql` — tradein RPCs
- `sql/exchange_functions.sql` — exchange / switch / free-exchange RPCs
- `sql/withdraw_functions.sql` — withdraw RPCs
- `sql/stock_functions.sql` — stock in/out / transfer
- `sql/admin_functions.sql` — `update_pricing`, `add_price_rate`, `add_cashbank_entry`, `get_cashbank_balances`, `list_users`, `save_user`, `delete_user_soft`, `get_notifications`, `mark_notifications_read`
- `sql/report_functions.sql` — รายงานวัน / diff / wealth

### Session policy
- JWT ไม่มี `exp` → token ใช้ได้ตลอดจนกว่า:
  - ผู้ใช้ไม่ขยับ ≥ `CONFIG.INACTIVITY_TIMEOUT_MINUTES` (default 60 นาที) → kick
  - ผู้ใช้กด logout
  - บัญชี login จากอีกเครื่อง (`users.session_token` เปลี่ยน → poll + Realtime broadcast แจ้ง kick)

## ⚠️ ข้อสังเกตด้าน security

JWT secret (`CONFIG.JWT_SECRET`) ฝังอยู่ใน `js/config.js` ฝั่ง client — ใครก็ปลอม JWT ที่ถือ `user_role=Admin` ได้ ทำให้ RLS ที่อาศัย `current_setting('request.jwt.claims')` ถูก bypass ได้ทั้งหมด

ก่อนใช้งานจริง production ควร:
- ย้ายการ sign JWT ไปฝั่ง server (Edge Function / Supabase Auth Hook) หรือใช้ Supabase Auth + custom claims โดยตรง
- เปลี่ยน JWT_SECRET (และ rotate ใน Supabase project setting)
