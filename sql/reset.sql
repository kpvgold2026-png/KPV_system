-- ============================================================
-- reset.sql — รีเซ็ตข้อมูลเริ่มสด เป็น 0 ทุกอย่าง (อัปเดต 2026-10-28)
-- ============================================================
-- ผลลัพธ์หลังรัน:
--   - ลบทุก tx + diff + cashbank + user_cashbook + closes + notifications
--     + stock_moves + stock_transfers + inventory_snapshots + approvals
--     + user_gold_received + daily_reports + audit_logs
--     + admin_ref_counter + bill_sequence + old_gold_lots
--     + tx_payment_edits + tx_gold_edits (ประวัติแก้บิล)
--   - ‼️ ไม่ทำรายการ STOCK_IN bootstrap — ทุกอย่างเริ่มที่ 0
--   - ทองเก่า (OLD) = 0 (ทุก product ที่มีในตาราง products)
--   - ทองใหม่ (NEW) = 0 (ทุก product ที่มีในตาราง products)
--   - wac_state ทั้งหมด = 0 (new/old gold_g + value)
--   - ไม่มี opening cash — cashbank ว่าง (ยอดทุกสกุล = 0)
--   - bill_sequence + admin_ref_counter reset (เลขบิล/เลขอ้างอิงเริ่ม 1 ใหม่)
--
-- ไม่แตะ (master data): users, products, banks, pricing, price_rates, app_config
--   หมายเหตุ: banks.balance ไม่ต้อง reset — ยอดธนาคารคำนวณสดจาก cashbank
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
DELETE FROM notifications;          -- notification_reads ตกไปเองผ่าน CASCADE
DELETE FROM transactions;

-- ============================================================
-- 1.1) ตารางที่เพิ่มมาทีหลัง (แต่ละรอบ) — safe ถ้ายังไม่มี table
--   bill_sequence      = counter เลขบิล SE/TI/EX/BB/WD (Round 4)
--   admin_ref_counter  = counter SI/SO/CB/TF/CL       (Round 7.5)
--   old_gold_lots      = lot ทองเก่า FIFO             (Round 11.1)
--   daily_reports      = wealth snapshot รายวัน       (Round 12)
--   audit_logs         = ‼️ ต้องล้างด้วย — แท็บ "รายการที่ถูกลบ" (utils.js
--                        loadDeletedList) อ่านจากตารางนี้ ถ้าไม่ล้างแต่ reset
--                        bill_sequence เลขบิลใหม่จะซ้ำกับ ref_id ของบิลที่ลบไปแล้ว
--   tx_payment_edits   = ประวัติแก้การชำระเงินบิล   (Round 19)
--   tx_gold_edits      = ประวัติแก้รายการทองบิล     (Round 19)
--                        ไม่ล้าง → บิลใหม่ที่ได้เลขซ้ำจะโชว์ประวัติแก้ของบิลเก่า
-- ============================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'bill_sequence', 'admin_ref_counter', 'old_gold_lots', 'daily_reports', 'audit_logs',
    'tx_payment_edits', 'tx_gold_edits'
  ] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DELETE FROM public.%I', t);
    END IF;
  END LOOP;
END $$;


-- ============================================================
-- 2) Reset stock_balances → NEW 0, OLD 0 (ทุก product ในตาราง products)
--    ดึงจาก products โดยตรง — เพิ่มสินค้าใหม่ทีหลังก็ไม่ตกหล่น
-- ============================================================
DELETE FROM stock_balances;
INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
SELECT p.id, g.gt::gold_type, 0, NOW()
FROM products p
CROSS JOIN (VALUES ('NEW'), ('OLD')) AS g(gt);


-- ============================================================
-- 3) Reset wac_state → ทั้งหมด = 0 (upsert — ไม่พึ่งว่ามีแถว id=1 อยู่ก่อน)
-- ============================================================
INSERT INTO wac_state (id, new_gold_g, new_value, old_gold_g, old_value, updated_at)
VALUES (1, 0, 0, 0, 0, NOW())
ON CONFLICT (id) DO UPDATE SET
  new_gold_g = 0,
  new_value  = 0,
  old_gold_g = 0,
  old_value  = 0,
  updated_at = NOW();


-- ============================================================
-- 4) ไม่มี opening cash + ไม่ทำ STOCK_IN bootstrap
--    → ทุกอย่างเริ่มที่ 0 (cashbank ลบหมดในขั้นที่ 1 แล้ว)
-- ============================================================


COMMIT;


-- ============================================================
-- ตรวจสอบหลังรัน
-- ============================================================
--   -- สต็อก (ต้องได้ 0 ทุกแถว, จำนวนแถว = products × 2)
--   SELECT product_id, gold_type, qty FROM stock_balances ORDER BY gold_type, product_id;
--
--   -- WAC (ต้อง 0 ทั้งหมด)
--   SELECT new_gold_g, new_value, old_gold_g, old_value,
--          new_value / NULLIF(new_gold_g, 0) AS new_wac_per_g
--   FROM wac_state WHERE id = 1;
--
--   -- ต้องว่างทั้งหมด (คาดหวัง 0 ทุกช่อง)
--   SELECT (SELECT COUNT(*) FROM transactions)   AS tx,
--          (SELECT COUNT(*) FROM stock_moves)    AS moves,
--          (SELECT COUNT(*) FROM cashbank)       AS cashbank,
--          (SELECT COUNT(*) FROM user_cashbook)  AS user_cashbook,
--          (SELECT COUNT(*) FROM closes)         AS closes,
--          (SELECT COUNT(*) FROM old_gold_lots)  AS old_lots,
--          (SELECT COUNT(*) FROM audit_logs)     AS audit_logs,
--          (SELECT COUNT(*) FROM bill_sequence)  AS bill_seq,
--          (SELECT COUNT(*) FROM tx_payment_edits) AS pay_edits,
--          (SELECT COUNT(*) FROM tx_gold_edits)  AS gold_edits;
--
--   -- payment breakdown (ต้องว่าง)
--   SELECT type, currency, amount, method, note FROM cashbank ORDER BY date ASC;
