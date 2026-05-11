# Migration to Supabase — Progress Log

## Step 1 (เสร็จแล้ว): Auth + API Layer
- `js/config.js` — ใหม่ (Supabase URL, ANON_KEY, JWT_SECRET, INACTIVITY_TIMEOUT_MINUTES)
- `js/jwt.js` — ใหม่ (HS256 sign/verify, ไม่มี exp — ใช้ inactivity check แทน)
- `js/api.js` — ใหม่ (Supabase REST + dbSelect/Insert/Update/Delete/Rpc)
- `js/auth.js` — ใหม่ (login ผ่าน RPC, JWT, inactivity timeout 60 นาที)
- `sql/schema.sql` — Schema ทั้งหมด + RLS
- `sql/auth_functions.sql` — login_user, open_shift, hash_password, ...
- `index.html` — เพิ่ม `<script src="js/jwt.js">` หลัง config

### Session policy
- JWT ไม่มี exp → token ใช้ได้ตลอดจนกว่า:
  - ผู้ใช้ไม่ขยับ ≥ 60 นาที (inactivity timeout)
  - ผู้ใช้กด logout
  - บัญชี login จากอีกเครื่อง (session_token เปลี่ยน)
- ปรับเวลาได้ที่ `CONFIG.INACTIVITY_TIMEOUT_MINUTES` ใน config.js

## Step 2 (เสร็จแล้ว): Sell Module
- `js/sell.js` — ใหม่ (อ่านจาก transactions table + เรียก RPC create_sell_tx, review_sell_tx)
- `js/payment.js` — patch openSellPayment + branch SELL ใช้ confirm_sell_tx RPC
- `sql/sell_functions.sql` — ใหม่
  - `generate_tx_id(type)` — สร้าง ID เช่น S-20260510-0001
  - `calc_items_gold_g(items)` — คำนวณ gold gram จาก items JSON
  - `get_wac_per_g()` — อ่าน WAC ปัจจุบัน
  - `create_sell_tx(...)` — สร้างรายการ + check stock
  - `review_sell_tx(id)` — Manager กด review
  - `confirm_sell_tx(id, paid, currency, method, bank_id, change)` — ลด stock, เพิ่ม cashbank, สร้าง diff (atomic)
  - `delete_sell_tx(id)` — Admin ลบ + audit log

## ⚠️ ที่ยังไม่ได้ทำ (Step ถัดไป)
- buyback.js + RPC create_buyback_tx (FIFO)
- tradein.js + RPC create_tradein_tx
- exchange.js + switch + free exchange
- withdraw.js
- stocknew.js + stockold.js + wac.js
- close.js, cashbank.js, dashboard.js, livereport.js
- notification.js, inventory.js, pricerate.js, products.js, accounting.js, diff.js, reports.js, review.js, historysell.js, usersetting.js

โมดูลเหล่านี้ยังเรียก `fetchSheetData(...)` กับ `callAppsScript(...)` อยู่ — จะพังจนกว่าจะถูก migrate
