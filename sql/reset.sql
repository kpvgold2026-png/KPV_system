-- ============================================================
-- reset.sql — รีเซ็ตข้อมูลเริ่มสด (Round 7.4)
-- ============================================================
-- ผลลัพธ์หลังรัน:
--   - ลบทุก tx + diff + cashbank + user_cashbook + closes + notifications
--     + stock_moves + user_gold_received
--   - ทองเก่า (OLD) = 0 (ทุก product)
--   - ทองใหม่ (NEW) = 10 ชิ้น ต่อ product (G01-G07)
--     → INSERT stock_moves STOCK_IN จำลอง (1 บิล รวมทุก product)
--     → wac_state.new_gold_g / new_value sync ตาม WAC สมมติ 3,300,000 LAK/g
--   - Opening cash: LAK 10B / THB 5,000,000 / USD 500,000 (CASH_IN)
--   - STOCK_IN payment breakdown: Cash LAK 50% / Cash THB 15% / Cash USD 35%
--     (หักจาก opening → balance หลัง reset เหลือพอใช้)
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
DELETE FROM user_gold_received;
DELETE FROM cashbank;
DELETE FROM user_cashbook;
DELETE FROM closes;
DELETE FROM notifications;
DELETE FROM transactions;
DELETE FROM bill_sequence;
DELETE FROM daily_reports;


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
-- 3) Reset wac_state → OLD = 0, NEW = computed below
-- ============================================================
UPDATE wac_state SET
  new_gold_g = 0,
  new_value  = 0,
  old_gold_g = 0,
  old_value  = 0,
  updated_at = NOW()
WHERE id = 1;


-- ============================================================
-- 4) Opening cash balance (CASH_IN — valid enum)
--   LAK 10B / THB 5M / USD 500K — พอจ่ายค่า STOCK_IN bootstrap
-- ============================================================
INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date)
VALUES
  ('CB-OPEN-LAK-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'CASH_IN', 10000000000, 'LAK', 1,     'CASH', NULL, NULL, 'Opening balance', NOW()),
  ('CB-OPEN-THB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'CASH_IN', 5000000,     'THB', 685,   'CASH', NULL, NULL, 'Opening balance', NOW()),
  ('CB-OPEN-USD-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS'),
   'CASH_IN', 500000,      'USD', 22070, 'CASH', NULL, NULL, 'Opening balance', NOW());


-- ============================================================
-- 5) STOCK_IN bootstrap — จำลอง tx เข้าทอง NEW 10 ชิ้น/product
--   WAC สมมติ = 3,300,000 LAK/g (≈ ตลาดจริง)
--   total_g = Σ(weight_baht × 15 × 10) จาก products
--   payments breakdown: Cash LAK 50% / THB 15% / USD 35%
-- ============================================================
DO $$
DECLARE
  v_wac NUMERIC := 3300000;        -- LAK/g สมมติ
  v_total_g NUMERIC;
  v_total_cost NUMERIC;
  v_move_id BIGINT;
  v_ref_id TEXT;
  v_prod RECORD;
  v_ts TEXT;
BEGIN
  v_ts := to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS');
  v_ref_id := 'STOCKIN-RESET-' || v_ts;

  -- total weight (10 ชิ้น/product × weight_baht × 15)
  SELECT COALESCE(SUM(weight_baht * 15 * 10), 0)
    INTO v_total_g
    FROM products;

  v_total_cost := v_total_g * v_wac;

  -- stock_moves header
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g,
                           price, wac_per_g, wac_per_baht, fulfilled, date, note)
  VALUES (v_ref_id, 'NEW', 'STOCK_IN', 'IN', v_total_g,
          v_total_cost, v_wac, v_wac * 15, TRUE, NOW(), 'Reset bootstrap stock-in')
  RETURNING id INTO v_move_id;

  -- stock_move_items: 10 ชิ้น per product
  FOR v_prod IN SELECT id FROM products ORDER BY id LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
    VALUES (v_move_id, v_prod.id, 10);
  END LOOP;

  -- sync wac_state.new
  UPDATE wac_state
     SET new_gold_g = v_total_g,
         new_value  = v_total_cost,
         updated_at = NOW()
   WHERE id = 1;

  -- payment breakdown — link ผ่าน note [ref:...] (FK ref_tx_id ใช้กับ STOCK_IN ไม่ได้
  -- เพราะ STOCK_IN ref_id ไม่ได้อยู่ใน transactions table)
  -- get_stock_move_detail ค้นเจอผ่าน LIKE '%[ref:...]%'
  -- Cash LAK 50%
  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date)
  VALUES ('CB-' || v_ref_id || '-LAK', 'CASH_OUT',
          ROUND(v_total_cost * 0.50), 'LAK', 1, 'CASH', NULL,
          NULL, 'STOCK_IN: Cash LAK [ref:' || v_ref_id || ']', NOW());

  -- Cash THB 15%  (THB amount = LAK / 685)
  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date)
  VALUES ('CB-' || v_ref_id || '-THB', 'CASH_OUT',
          ROUND(v_total_cost * 0.15 / 685), 'THB', 685, 'CASH', NULL,
          NULL, 'STOCK_IN: Cash THB [ref:' || v_ref_id || ']', NOW());

  -- Cash USD 35%
  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date)
  VALUES ('CB-' || v_ref_id || '-USD', 'CASH_OUT',
          ROUND(v_total_cost * 0.35 / 22070), 'USD', 22070, 'CASH', NULL,
          NULL, 'STOCK_IN: Cash USD [ref:' || v_ref_id || ']', NOW());
END$$;


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
