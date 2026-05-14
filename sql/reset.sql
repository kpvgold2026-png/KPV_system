-- ============================================================
-- reset.sql — รีเซ็ตข้อมูลเริ่มสด
-- ============================================================
-- ผลลัพธ์หลังรัน:
--   - ลบทุก tx + diff + cashbank + user_cashbook + closes + notifications + stock_moves + user_gold_received
--   - ทองเก่า (OLD) = 0 (ทุก product)
--   - ทองใหม่ (NEW) = 10 ชิ้น ต่อ product (G01-G07)
--   - เงินสด: LAK = 1,000,000,000 | THB = 100,000 | USD = 100,000
--   - bill_sequence reset (เลขบิลเริ่ม 1 ใหม่)
--   - wac_state reset (new_gold_g คำนวณจาก stock ใหม่, value = 0)
-- ============================================================

BEGIN;

-- ============================================================
-- 1) ลบข้อมูลธุรกรรมทั้งหมด (เรียงตาม FK dependency)
-- ============================================================
DELETE FROM transaction_payments;
DELETE FROM transaction_items;
DELETE FROM diffs;
DELETE FROM stock_move_items;
DELETE FROM stock_moves;
DELETE FROM user_gold_received;
DELETE FROM cashbank;
DELETE FROM user_cashbook;
DELETE FROM closes;
DELETE FROM notifications;
DELETE FROM transactions;
DELETE FROM bill_sequence;
DELETE FROM daily_reports;

-- (ถ้ามี pending_transfers / deleted_records ก็ uncomment)
-- DELETE FROM pending_transfers;
-- DELETE FROM deleted_records;


-- ============================================================
-- 2) Reset stock_balances → NEW 10 ชิ้น/product, OLD 0
-- ============================================================
DELETE FROM stock_balances;
INSERT INTO stock_balances (product_id, gold_type, qty, updated_at) VALUES
  ('G01', 'NEW', 10, NOW()),
  ('G02', 'NEW', 10, NOW()),
  ('G03', 'NEW', 10, NOW()),
  ('G04', 'NEW', 10, NOW()),
  ('G05', 'NEW', 10, NOW()),
  ('G06', 'NEW', 10, NOW()),
  ('G07', 'NEW', 10, NOW()),
  ('G01', 'OLD', 0, NOW()),
  ('G02', 'OLD', 0, NOW()),
  ('G03', 'OLD', 0, NOW()),
  ('G04', 'OLD', 0, NOW()),
  ('G05', 'OLD', 0, NOW()),
  ('G06', 'OLD', 0, NOW()),
  ('G07', 'OLD', 0, NOW());


-- ============================================================
-- 3) Reset wac_state
--   new_gold_g คำนวณอัตโนมัติจาก stock_balances ใหม่
--   value = 0 (ไม่มีต้นทุนเริ่มต้น)
-- ============================================================
UPDATE wac_state SET
  new_gold_g = (
    SELECT COALESCE(SUM(sb.qty * p.weight_baht * 15), 0)
    FROM stock_balances sb
    JOIN products p ON p.id = sb.product_id
    WHERE sb.gold_type = 'NEW'
  ),
  new_value  = 0,
  old_gold_g = 0,
  old_value  = 0,
  updated_at = NOW()
WHERE id = 1;


-- ============================================================
-- 4) เพิ่ม Opening Balance เข้า cashbank
--   LAK = 1,000,000,000 / THB = 100,000 / USD = 100,000 (Cash method)
-- ⚠️ ถ้า cashbank.type เป็น enum ที่ไม่รับ 'OPENING_BALANCE'
--    ให้เปลี่ยนเป็นค่าที่ valid (เช่น 'DEPOSIT' / 'ADJUSTMENT' / 'INCOME')
-- ============================================================
INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
VALUES
  ('CB-OPEN-LAK-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'OPENING_BALANCE', 1000000000, 'LAK', 'CASH', NULL, NULL, 'Opening balance reset', NOW()),
  ('CB-OPEN-THB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'OPENING_BALANCE', 100000, 'THB', 'CASH', NULL, NULL, 'Opening balance reset', NOW()),
  ('CB-OPEN-USD-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'OPENING_BALANCE', 100000, 'USD', 'CASH', NULL, NULL, 'Opening balance reset', NOW());


COMMIT;


-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
--   SELECT product_id, gold_type, qty FROM stock_balances ORDER BY gold_type, product_id;
--   SELECT * FROM wac_state WHERE id = 1;
--   SELECT type, currency, method, SUM(amount) AS total FROM cashbank GROUP BY type, currency, method;
--   SELECT COUNT(*) AS tx_count FROM transactions;
--   SELECT COUNT(*) AS diff_count FROM diffs;
--   SELECT * FROM bill_sequence;  -- ควรว่าง
