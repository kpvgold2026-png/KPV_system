-- ============================================================
-- reset.sql — รีเซ็ตข้อมูลเริ่มสด เป็น 0 ทุกอย่าง (อัปเดต 2026-06-11)
-- ============================================================
-- ผลลัพธ์หลังรัน:
--   - ลบทุก tx + diff + cashbank + user_cashbook + closes + notifications
--     + stock_moves + stock_transfers + inventory_snapshots + approvals
--     + user_gold_received + admin_ref_counter
--   - ‼️ ไม่ทำรายการ STOCK_IN bootstrap — ทุกอย่างเริ่มที่ 0
--   - ทองเก่า (OLD) = 0 (ทุก product)
--   - ทองใหม่ (NEW) = 0 (ทุก product)
--   - wac_state ทั้งหมด = 0 (new/old gold_g + value)
--   - ไม่มี opening cash — cashbank ว่าง (ยอดทุกสกุล = 0)
--   - bill_sequence reset (เลขบิลเริ่ม 1 ใหม่)
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
DELETE FROM stock_transfer_items;
DELETE FROM stock_transfers;
DELETE FROM inventory_snapshots;
DELETE FROM user_gold_received;
DELETE FROM cashbank;
DELETE FROM user_cashbook;
DELETE FROM closes;
DELETE FROM approvals;
DELETE FROM notifications;
DELETE FROM transactions;
DELETE FROM bill_sequence;
DELETE FROM daily_reports;

-- reset ตัวนับเลขอ้างอิง SI/SO/CB/TF/CL (Round 7.5+) — safe ถ้ายังไม่มี table
DO $$ BEGIN
  IF to_regclass('public.admin_ref_counter') IS NOT NULL THEN
    DELETE FROM admin_ref_counter;
  END IF;
END $$;


-- ============================================================
-- 2) Reset stock_balances → NEW 0, OLD 0 (ทุก product)
-- ============================================================
DELETE FROM stock_balances;
INSERT INTO stock_balances (product_id, gold_type, qty, updated_at) VALUES
  ('G01', 'NEW', 0, NOW()),
  ('G02', 'NEW', 0, NOW()),
  ('G03', 'NEW', 0, NOW()),
  ('G04', 'NEW', 0, NOW()),
  ('G05', 'NEW', 0, NOW()),
  ('G06', 'NEW', 0, NOW()),
  ('G07', 'NEW', 0, NOW()),
  ('G01', 'OLD', 0, NOW()),
  ('G02', 'OLD', 0, NOW()),
  ('G03', 'OLD', 0, NOW()),
  ('G04', 'OLD', 0, NOW()),
  ('G05', 'OLD', 0, NOW()),
  ('G06', 'OLD', 0, NOW()),
  ('G07', 'OLD', 0, NOW());


-- ============================================================
-- 3) Reset wac_state → ทั้งหมด = 0
-- ============================================================
UPDATE wac_state SET
  new_gold_g = 0,
  new_value  = 0,
  old_gold_g = 0,
  old_value  = 0,
  updated_at = NOW()
WHERE id = 1;


-- ============================================================
-- 4) ไม่มี opening cash + ไม่ทำ STOCK_IN bootstrap
--    → ทุกอย่างเริ่มที่ 0 (cashbank ลบหมดในขั้นที่ 1 แล้ว)
-- ============================================================


COMMIT;


-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
--   -- สต็อก
--   SELECT product_id, gold_type, qty FROM stock_balances ORDER BY gold_type, product_id;
--
--   -- WAC
--   SELECT new_gold_g, new_value, old_gold_g, old_value,
--          new_value / NULLIF(new_gold_g, 0) AS new_wac_per_g
--   FROM wac_state WHERE id = 1;
--
--   -- stock_moves bootstrap
--   SELECT ref_id, gold_type, type, direction, gold_g, price, wac_per_g
--   FROM stock_moves ORDER BY date DESC LIMIT 1;
--
--   -- payment breakdown
--   SELECT type, currency, amount, rate, amount * rate AS lak_eq, method, note
--   FROM cashbank ORDER BY date ASC;
--
--   -- net cash balance (LAK equivalent)
--   SELECT currency,
--          SUM(CASE WHEN type LIKE '%IN%' OR type LIKE 'BANK_DEPOSIT'  THEN amount ELSE 0 END) AS cash_in,
--          SUM(CASE WHEN type LIKE '%OUT%' OR type LIKE 'BANK_WITHDRAW' THEN amount ELSE 0 END) AS cash_out
--   FROM cashbank WHERE method = 'CASH' GROUP BY currency;
