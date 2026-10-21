-- ============================================================
-- KPV — Round 17 (2026-10-21)
--  R17-1) Buyback จ่ายด้วย THB/USD แปลงแล้วไม่ลงตัวกับ Total LAK: ถ้ามีรายการสกุลอื่น และยอดค้าง
--         ≤ 500 LAK → ยืนยันได้ บิล COMPLETED, paid = Total, balance = 0 (เงินออกบันทึกตามจริง)
--         confirm_buyback_tx เพิ่ม p_allow_short (JS ส่ง TRUE เฉพาะรายการสุดท้ายเมื่อมีสกุลอื่น)
-- ============================================================
-- KPV — Round 16 (2026-10-15)  [แก้ทับของเดิมในไฟล์นี้ — รันทั้งไฟล์ได้เหมือนเดิม]
--  R16-1) ‼️ ปิดกะยอดโอนเกินจริง (เห็นยอดของวันก่อนรวมมาด้วย): approve_close_report กวาดกระเป๋า
--         Sales เฉพาะ method=CASH → แถวโอน (TRANSFER) ใน user_cashbook ไม่เคยถูกเคลียร์
--         แต่ get_close_cashbook / Report "เงินที่ถือ" ใช้ยอดสะสมทั้งกระเป๋า → ยอดโอนพอกขึ้นทุกวัน
--         แก้: approve ลงแถวหักล้างยอดโอนให้เป็น 0 (ไม่แตะ cashbank — เงินโอนเข้าร้านตั้งแต่ยืนยันบิล)
--         + บล็อก DO ท้ายไฟล์ ล้างยอดโอนค้างของกะที่ approve ไปแล้ว
--  R16-2) ทองเก่าตอนปิดกะไม่ตรงกับ tab Report — อิงยอด Report (user_gold_received settled=false):
--         + RPC ใหม่ get_close_old_gold → หน้าปิดกะ (close.js) ใช้แทน get_close_report.gold_received
--         + approve_close_report เอาเข้าสต๊อกเฉพาะทองที่รับมาก่อนเวลากดปิดกะ (closes.date)
--           กันทองของบิลหลังกดปิดกะ (เช่น Manager อนุมัติวันถัดไป) ถูกกวาดรวมเข้ากะนี้
--  R16-3) เงินที่ถือใน Report ไม่ตรงของจริง: approve กวาดเงินทั้งกระเป๋า ณ เวลาอนุมัติ → ถ้าอนุมัติช้า
--         (Sales เปิดกะใหม่/รับเงินบิลใหม่ไปแล้ว) เงินกะใหม่ถูกกวาดเข้าร้านไปด้วย Report เลยเหลือน้อยกว่าที่ถือจริง
--         แก้: กวาดเฉพาะแถว user_cashbook ที่ date <= เวลากดปิดกะ (ทั้งเงินสดและยอดโอน)
--  R16-4) Transfer OLD→NEW: PriceIn Stock New ≠ PriceOut Stock Old — หน้า Stock Old แสดง FIFO "ต่อกรัม"
--         (get_stock_moves) แต่ transfer บันทึก price จาก lot ต่อสินค้า (_consume_old_lots) → คนละสูตร
--         แก้: helper _old_fifo_out_cost (สูตรเดียวกับหน้าจอ) → transfer_old_to_new_tx / stock_out_old_tx ใช้เป็น price
--         + wac_state ใช้ค่าเดียวกัน ; บล็อก DO ท้ายไฟล์ปรับแถว TRANSFER เดิมให้ตรง (NEW IN = OLD OUT)
--  R16-5) "WAC ณ เวลาทำรายการ" ผิดในแถว STOCK_IN (NEW) / TRANSFER / STOCK_OUT — เก็บมูลค่า/g ของรายการเอง
--         แทน WAC ร้าน → เก็บ get_wac_per_g() ณ ตอนทำรายการ (ก่อนรายการมีผล) เหมือน SELL/TRADEIN/ปิดกะ
--         + บล็อก DO ท้ายไฟล์คำนวณย้อนหลังด้วยการไล่ stock_moves ตามเวลา
-- ============================================================


-- ============================================================
-- KPV — Round 15 (2026-09-03)  [แก้ทับของเดิมในไฟล์นี้ — รันทั้งไฟล์ได้เหมือนเดิม]
--  R15-1) WAC แหล่งเดียว — RPC ใหม่ get_wac_state() คืน wac_per_g + wac_per_baht
--         (= wac_per_g × 15 แบบไม่ปัดเศษ) จาก wac_state; get_dashboard_data ใช้ตัวเดียวกัน
--         tab WAC / Dashboard / Accounting เลิกคำนวณเองฝั่ง JS
--         + get_stock_move_detail: wac_per_baht = wac_per_g × 15 เสมอ (เดิมอ่านคอลัมน์ที่อาจเป็น 0)
--         + get_wac_per_g() นิยามชัดในไฟล์นี้ (new+old value ÷ new+old g)
--  R15-2) "ดึงก่อน เขียนทีหลัง" — confirm_sell/tradein/exchange/withdraw_tx + stock_in_new_tx
--         lock wac_state (FOR UPDATE) ก่อนอ่าน WAC/ราคา → serialize กับทุก tx ที่แตะสต๊อก
--         ค่าที่อ่านสะท้อนการเขียนก่อนหน้าครบ ไม่มีใครเขียนแทรกระหว่างอ่านกับเขียน
--  R15-3) [ยกเลิกโดย R15-9] Diff Trade-in: cost_diff = Difference ตอนสร้างรายการ
--  R15-9) Diff Trade-in: cost_diff = WAC/g ณ ตอนทำรายการ × น้ำหนักส่วนต่าง (ใหม่ − เก่า) g
--         diff = ขายใหม่ + premium − cost_diff − ขายเก่า ; recompute_diffs ใช้ snapshot wac_per_g
--         จาก stock_moves ของบิล (ไม่ใช่ WAC ปัจจุบัน) → ตัวเลขไม่เปลี่ยนตาม WAC วันหลัง
--  R15-4) ทองเก่าจาก Trade-in/Exchange: จำ "ราคาขายต่อชิ้น ณ ตอนทำรายการ" (PriceIn) ลง
--         user_gold_received.price_per_unit = _diff_sell_price(สินค้า, sell_1baht ของบิล)
--         (ราคาตามตารางสินค้า ปัดพัน → เลขลงตัว; 1 กรัมรวมค่ากำเหน็จ 120,000 เหมือนตารางขาย)
--         → approve ปิดกะตีมูลค่าเข้า Stock OLD / lot / wac_state ด้วยค่านี้ (เดิม = 0)
--         + _ug_cost_per_unit fallback แถวเก่าที่ยัง 0 → คำนวณจาก sell_1baht ของบิลต้นทาง
--         + แถว STOCK_IN (OLD) ตอนปิดกะเก็บ snapshot wac_per_g/wac_per_baht ด้วย
--  R15-5) ‼️ create_sell/buyback/tradein/exchange/withdraw_tx รับ p_sell_1baht มาแต่ "ไม่เคยบันทึก"
--         ลง transactions.sell_1baht (เป็น 0 ตลอด) → confirm_*/Diff/PriceIn ไปใช้ราคา "ปัจจุบัน"
--         แทนราคา ณ ตอนทำรายการ — แก้ให้เก็บ snapshot ตั้งแต่ตอนสร้างบิล
--         (helper _snapshot_sell_1baht: ค่าจาก JS ว่าง/0 → ใช้ราคาขายล่าสุดใน pricing ณ ตอนนั้น)
--  R15-6) ‼️ WAC/บาท ไม่ตรง (48,431,993 แทน 48,431,999): ทอง 1 กรัม weight_baht = 0.0666667
--         × 15 = 1.0000005 g → น้ำหนักรวมจริง 799.5001 g (จอโชว์ 799.50) → ทุกจุดคิดกรัมผ่าน
--         _gold_g() = ROUND(weight_baht × 15, 3) + sync น้ำหนักใน wac_state ให้ตรง stock_balances
--  R15-7) ‼️ Stock OLD/NEW ตารางสรุป: ปิดกะแล้วทองตั้งต้นติดลบ Balance = 0 — get_stock_summary
--         คืน carry = ตั้งต้น แต่ JS คิดว่าเป็นยอดปัจจุบันแล้วลบ IN ซ้ำ → RPC คืน balance เพิ่ม
--         JS ใช้ carry/balance ตรง ๆ
--  R15-8) มูลค่า Stock OLD ไม่ลงตัว (13.25 g = 42,762,199): 3 ต้นเหตุ
--         a) PriceIn 1 กรัม = 0.0666667 × sell_1baht (ไม่ลงตัว) → ใช้ _diff_sell_price (R15-4 ปรับ)
--         b) Buyback price ÷ จำนวนชิ้น (บิลผสม/หาร 3 ไม่ลงตัว) → แบ่งตามน้ำหนักจริงของแต่ละชิ้น
--         c) เศษน้ำหนัก 1.0000005 g ในแถวเก่า → FIFO ของ get_stock_moves ได้เศษ (R15-6 ล้างข้อมูลเดิม)
--         d) ตีมูลค่าย้อนหลัง lot/ug/stock_moves/wac_state ที่บันทึกด้วยสูตร a) ไปแล้ว (บล็อก DO ท้ายไฟล์)
--            เช่น CL26000001: 42,762,198.94 → 43,004,000 (1กรัม 3,348,000×2 + 1สลึง 12,103,000 + 2สลึง 24,205,000)
-- ============================================================


-- ============================================================
-- KPV — Round 14 (2026-08-20)  [แก้ทับของเดิมในไฟล์นี้ — รันทั้งไฟล์ได้เหมือนเดิม]
--  R14-1) get_live_report (Box Wealth) — แปลง THB/USD เป็น LAK ด้วย "เรทขาย"
--         (thb_sell/usd_sell) แทนเรทรับซื้อ
--  R14-2) get_dashboard_data — คืน pending_old_g/pending_old_pieces
--         = ทองเก่าที่ Sales ถืออยู่แต่ยังไม่ปิดกะ (ยังไม่เข้า stock_balances)
--         → TOTAL GOLD บน Dashboard แจงให้เห็นว่าทำไมยอดน้อยกว่าที่นับจากบิล
--  R14-4) get_live_report — เงินรวมของ Wealth ไม่นับเงินสดที่ Sales ถือ (user_cashbook)
--         กฎเดียวกับทองเก่ารอปิดกะ: ยังอยู่ในมือ Sales = ยังไม่ใช่ทรัพย์สินร้าน
--  R14-3) confirm_sell/tradein/exchange/withdraw_tx + _apply_confirm_payments
--         — ยืนยันบิลที่ยอดรวม = 0 ได้โดยไม่ต้องมีรายการชำระเงิน (Free Exchange)
--         ยอด > 0 ยังบังคับต้องมีรายการชำระเหมือนเดิม
-- ============================================================


-- ============================================================
-- KPV — Round 11 + 11.1 (2026-07-06)  [เขียนทับ next_run.sql เดิม — รัน idempotent ได้]
-- Round 11.1 (เพิ่มจาก R11 — user ยังไม่ได้รัน R11 รันไฟล์นี้ครั้งเดียวได้ครบ):
--  L1) Lot tracking ทองเก่า (FIFO): ตาราง old_gold_lots + backfill เปิดยอดจาก WAC
--      + _consume_old_lots + transfer_old_to_new_tx / stock_out_old_tx ตัดต้นทุนตาม lot จริง
--      + approve_close_report สร้าง lot ตอนทองเก่าเข้าสต๊อก (cost = sell_1baht ของ tx ต้นทาง)
--  L2) transfer_user_cash_to_shop — เช็คเงินในกระเป๋าพอฝั่ง server ก่อนโอน
--  L3) get_close_cashbook — คืนยอดคงเหลือสะสมทั้งกระเป๋า (= ยอดที่ approve จะกวาดจริง)
--  L4) นับ PARTIAL ใน sales_breakdown + dashboard (ให้ตรงกับตารางฝั่ง JS)
--  L5) _diff_sell_price — สินค้านอก G01–G07 คิดจาก weight_baht × ราคาขาย 1 บาท (เดิมคืน 0 เงียบๆ)
-- แก้ตามผล audit ทั้งระบบ:
--   1) confirm_sell/tradein/exchange/withdraw_tx → multi-payment (p_payments JSONB)
--      + FOR UPDATE กันยืนยันซ้ำ + เช็คสต๊อกก่อนตัด + หักเงินทอนออกจาก ledger
--   2) confirm_buyback_tx → แปลงยอดเป็น LAK ด้วยเรทรับซื้อ + ตัด fee ทิ้ง + lock
--   3) stock_out_old_tx → ตัดมูลค่า (old_value) ด้วย WAC เดียวกับ transfer + lock
--   4) TZ Asia/Bangkok ครบทุกจุด (sales_breakdown, wealth, recompute_diffs)
--   5) เปิด/ปิดกะกันซ้ำฝั่ง server + approve กันซ้ำ + cancel_pending_close (RPC ใหม่)
--   6) Diff ไม่นับ BUYBACK (get_diff_summary.total, get_dashboard_data.pl_diff)
--   7) create_exchange_tx validate บิล Free-Ex ฝั่ง server
--   8) role check: add_cashbank_entry, get_close_cashbook, open_shift
--   9) stock_in_new_tx ตัด fee ทิ้ง + ธนาคารไม่พบชื่อ → สร้างให้อัตโนมัติ
--  10) delete_tx บล็อค COMPLETED และ PARTIAL
-- ============================================================


-- ============================================================
-- 0) enum ใหม่: cashbank_type 'CHANGE' (รายการหักเงินทอน)
--    (ใช้ตอน runtime เท่านั้น — ADD VALUE ใน transaction ได้)
-- ============================================================
ALTER TYPE cashbank_type ADD VALUE IF NOT EXISTS 'CHANGE';


-- ============================================================
-- [R15-6] น้ำหนักกรัมต่อชิ้น "เป๊ะ" — _gold_g(weight_baht)
--   ‼️ ต้นเหตุ WAC/บาท ไม่ตรง: products.weight_baht ของ 1 กรัม = 0.0666667 บาท
--     × 15 = 1.0000005 g/แท่ง → สะสมหลายแท่งเป็นเศษ 0.0001 g ใน wac_state/stock_moves
--     (หน้าจอปัดน้ำหนักเป็น 2 ตำแหน่งเลยมองไม่เห็นเศษ แต่ WAC/บาท ที่หารด้วยน้ำหนักจริงเพี้ยน)
--   แก้: ทุกจุดใน SQL ที่คิดกรัมใช้ _gold_g() = ROUND(weight_baht × 15, 3)
--     10บาท=150 / 5=75 / 2=30 / 1=15 / 2สลึง=7.5 / 1สลึง=3.75 / 1กรัม=1.000 (ตรงกับ JS getGoldWeight)
--   + calc_items_gold_g ใช้ตัวเดียวกัน
--   + sync น้ำหนักใน wac_state ให้ตรง stock_balances (ท้ายไฟล์ — ล้างเศษเดิมครั้งเดียว)
-- ============================================================
CREATE OR REPLACE FUNCTION _gold_g(p_weight_baht NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT ROUND(COALESCE(p_weight_baht, 0) * 15, 3);
$$;
GRANT EXECUTE ON FUNCTION _gold_g(NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION calc_items_gold_g(p_items JSONB)
RETURNS NUMERIC AS $$
DECLARE
  v_total NUMERIC := 0;
  v_item JSONB;
  v_weight NUMERIC;
BEGIN
  IF p_items IS NULL THEN RETURN 0; END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT _gold_g(weight_baht) INTO v_weight FROM products
    WHERE id = (v_item->>'productId');
    v_total := v_total + (COALESCE(v_weight, 0) * (v_item->>'qty')::numeric);
  END LOOP;
  RETURN v_total;
END;
$$ LANGUAGE plpgsql STABLE;


-- ============================================================
-- L1.1) ตาราง lot ทองเก่า (FIFO ต้นทุนจริง)
--   1 lot = ทองเก่า 1 กลุ่ม (product × ราคารับซื้อ) ที่เข้าสต๊อกพร้อมกัน
--   เข้า: approve_close_report (materialize) / ออก: transfer, stock_out (FIFO เก่าสุดก่อน)
--   client อ่านได้อย่างเดียว — เขียนผ่าน RPC (SECURITY DEFINER) เท่านั้น
-- ============================================================
CREATE TABLE IF NOT EXISTS old_gold_lots (
  id BIGSERIAL PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  qty_in NUMERIC(18,4) NOT NULL,
  qty_left NUMERIC(18,4) NOT NULL,
  gold_g_per_unit NUMERIC(18,4) NOT NULL,
  cost_per_g NUMERIC(18,4) NOT NULL,
  source_ref TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_old_gold_lots_fifo
  ON old_gold_lots (product_id, date, id) WHERE qty_left > 0;

ALTER TABLE old_gold_lots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS old_gold_lots_read_all ON old_gold_lots;
CREATE POLICY old_gold_lots_read_all ON old_gold_lots
  FOR SELECT USING (current_user_id() IS NOT NULL);
GRANT SELECT ON old_gold_lots TO authenticated;

-- backfill เปิดยอด (ครั้งแรกเท่านั้น — ตารางว่าง): สต๊อก OLD ปัจจุบัน 1 lot/product
-- ที่ cost_per_g = WAC เฉลี่ยปัจจุบัน (lot เปิดยอดจะเก่าสุด → ถูกตัดก่อนโดยอัตโนมัติ)
INSERT INTO old_gold_lots (product_id, qty_in, qty_left, gold_g_per_unit, cost_per_g, source_ref, date)
SELECT sb.product_id, sb.qty, sb.qty, _gold_g(p.weight_baht),
       CASE WHEN COALESCE(w.old_gold_g, 0) > 0 THEN w.old_value / w.old_gold_g ELSE 0 END,
       'OPENING', NOW()
FROM stock_balances sb
JOIN products p ON p.id = sb.product_id
CROSS JOIN wac_state w
WHERE sb.gold_type = 'OLD' AND sb.qty > 0 AND w.id = 1
  AND NOT EXISTS (SELECT 1 FROM old_gold_lots);


-- ============================================================
-- L1.2) helper: ตัด lot ทองเก่าแบบ FIFO (เก่าสุดก่อน) คืนต้นทุนรวมที่ตัด
--   ⚠️ caller ต้องถือ lock wac_state (id=1 FOR UPDATE) อยู่แล้ว เพื่อ serialize
--   lot ไม่พอ (ข้อมูล drift) → ตัดเท่าที่มี ส่วนเกินคิดที่ WAC เฉลี่ยปัจจุบัน
--   internal เท่านั้น (REVOKE จาก client)
-- ============================================================
CREATE OR REPLACE FUNCTION _consume_old_lots(p_product_id TEXT, p_qty NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
  v_remain NUMERIC := COALESCE(p_qty, 0);
  v_lot RECORD;
  v_take NUMERIC;
  v_cost NUMERIC := 0;
  v_g NUMERIC;
  v_wac NUMERIC;
BEGIN
  IF v_remain <= 0 THEN RETURN 0; END IF;

  FOR v_lot IN
    SELECT id, qty_left, gold_g_per_unit, cost_per_g
    FROM old_gold_lots
    WHERE product_id = p_product_id AND qty_left > 0
    ORDER BY date, id
    FOR UPDATE
  LOOP
    EXIT WHEN v_remain <= 0;
    v_take := LEAST(v_lot.qty_left, v_remain);
    UPDATE old_gold_lots SET qty_left = qty_left - v_take WHERE id = v_lot.id;
    v_cost := v_cost + (v_take * v_lot.gold_g_per_unit * v_lot.cost_per_g);
    v_remain := v_remain - v_take;
  END LOOP;

  IF v_remain > 0 THEN
    SELECT _gold_g(weight_baht) INTO v_g FROM products WHERE id = p_product_id;
    SELECT CASE WHEN COALESCE(old_gold_g, 0) > 0 THEN old_value / old_gold_g ELSE 0 END
      INTO v_wac FROM wac_state WHERE id = 1;
    v_cost := v_cost + (v_remain * COALESCE(v_g, 0) * COALESCE(v_wac, 0));
  END IF;

  RETURN v_cost;
END;
$$;
REVOKE ALL ON FUNCTION _consume_old_lots(TEXT, NUMERIC) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.1) helper: หา bank_id จากชื่อ — ไม่พบ → สร้างแถวใหม่ (กันเงินหายจาก breakdown)
--      internal เท่านั้น (REVOKE จาก client)
-- ============================================================
CREATE OR REPLACE FUNCTION _resolve_bank_id(p_name TEXT)
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF p_name IS NULL OR TRIM(p_name) = '' THEN RETURN NULL; END IF;
  SELECT id INTO v_id FROM banks WHERE name = TRIM(p_name) LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO banks (name, is_active) VALUES (TRIM(p_name), TRUE) RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION _resolve_bank_id(TEXT) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.2) helper: ลงบัญชีรายการจ่ายทุก entry ของ confirm_*_tx
--   • transaction_payments ครบทุก entry (amount สกุลจริง)
--   • cashbank (เงินเข้าร้าน) — ยกเว้น Sales รับเงินสด (เข้ากระเป๋า Sales รอปิดกะ)
--   • user_cashbook (กระเป๋า Sales) — เมื่อผู้ทำรายการเป็น Sales
--   • คืน paid_lak = Σ(amount × rate) สำหรับบันทึกลง transactions.paid
--   internal เท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION _apply_confirm_payments(
  p_tx_id TEXT, p_payments JSONB, p_cb_type cashbank_type, p_note TEXT,
  p_user_id UUID, p_is_sales BOOLEAN
)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_e RECORD;
  v_method TEXT;
  v_bank_id UUID;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_paid_lak NUMERIC := 0;
  v_first_currency TEXT := NULL;
  v_n INT := 0;
BEGIN
  FOR v_e IN
    SELECT UPPER(COALESCE(elem->>'method', 'CASH')) AS m,
           UPPER(COALESCE(NULLIF(elem->>'currency', ''), 'LAK')) AS cur,
           (elem->>'amount')::numeric AS amount,
           COALESCE(NULLIF((elem->>'rate')::numeric, 0), 1) AS rate,
           elem->>'bank' AS bank_name
    FROM jsonb_array_elements(p_payments) elem
  LOOP
    CONTINUE WHEN v_e.amount IS NULL OR v_e.amount <= 0;

    v_method := CASE WHEN v_e.m = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END;
    v_bank_id := CASE WHEN v_method = 'TRANSFER' THEN _resolve_bank_id(v_e.bank_name) ELSE NULL END;
    IF v_first_currency IS NULL THEN v_first_currency := v_e.cur; END IF;
    v_paid_lak := v_paid_lak + (v_e.amount * v_e.rate);

    INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
    VALUES (p_tx_id, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id, p_user_id);

    IF NOT (p_is_sales AND v_method = 'CASH') THEN
      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                 || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, p_cb_type, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id,
              p_tx_id, p_note, NOW(), p_user_id);
    END IF;

    IF p_is_sales THEN
      v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                  || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
      INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
      VALUES (v_ucb_id, p_user_id, p_cb_type, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id,
              p_tx_id, p_note, NOW());
    END IF;

    v_n := v_n + 1;
  END LOOP;

  -- [R14-3] ไม่มีรายการที่ยอด > 0 → ไม่ error ที่นี่ (บิลยอด 0 ต้องผ่านได้)
  --   caller เป็นคนตัดสินใจ โดยดู entries เทียบกับยอดรวมของบิล

  RETURN jsonb_build_object('paid_lak', v_paid_lak,
                            'first_currency', COALESCE(v_first_currency, 'LAK'),
                            'entries', v_n);
END;
$$;
REVOKE ALL ON FUNCTION _apply_confirm_payments(TEXT, JSONB, cashbank_type, TEXT, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- 0.3) helper: หักเงินทอน (เงินสด LAK เสมอ) ออกจาก ledger เดียวกับที่เงินเข้า
--   Sales → user_cashbook ตัวเอง / Manager,Admin → cashbank ร้าน
--   คืน NULL = สำเร็จ, คืนข้อความ = เงินไม่พอทอน (caller ต้อง RAISE เพื่อ rollback)
--   internal เท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION _apply_change_deduction(
  p_tx_id TEXT, p_change NUMERIC, p_user_id UUID, p_is_sales BOOLEAN
)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v_id TEXT;
BEGIN
  IF p_change IS NULL OR p_change <= 0 THEN RETURN NULL; END IF;

  IF p_is_sales THEN
    IF NOT check_user_cash_balance(p_user_id, 'LAK', p_change) THEN
      RETURN '❌ เงินสด LAK ในกระเป๋าไม่พอทอน ' || to_char(p_change, 'FM999,999,999,990') || ' LAK';
    END IF;
    v_id := 'UCB-CHG-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
            || '-' || substring(md5(p_tx_id || random()::text), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, ref_tx_id, note, date)
    VALUES (v_id, p_user_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW());
  ELSE
    IF NOT check_shop_balance('CASH', 'LAK', NULL, p_change) THEN
      RETURN '❌ เงินสด LAK ในร้านไม่พอทอน ' || to_char(p_change, 'FM999,999,999,990') || ' LAK';
    END IF;
    v_id := 'CB-CHG-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
            || '-' || substring(md5(p_tx_id || random()::text), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, ref_tx_id, note, date, created_by_id)
    VALUES (v_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW(), p_user_id);
  END IF;

  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION _apply_change_deduction(TEXT, NUMERIC, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- ข้อ9) stock_in_new_tx — ตัด fee ทิ้ง (p_fee คงไว้ใน signature เพื่อ compat แต่ ignore)
--   + ธนาคารไม่พบชื่อ → สร้างอัตโนมัติ (_resolve_bank_id)
--   (คงพฤติกรรม R9: เช็คยอดร้านพอก่อนหัก ต่อ วิธีจ่าย×สกุล×ธนาคาร)
-- ============================================================
CREATE OR REPLACE FUNCTION stock_in_new_tx(
  p_items JSONB,
  p_note TEXT,
  p_cost NUMERIC,
  p_payments JSONB,
  p_fee NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_pay JSONB;
  v_ref_id TEXT;
  v_cb_id TEXT;
  v_chk RECORD;
  v_chk_bank_id UUID;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_admin() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- ตรวจสินค้า + รวมน้ำหนัก
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    DECLARE v_weight NUMERIC;
    BEGIN
      SELECT _gold_g(weight_baht) INTO v_weight FROM products WHERE id = v_item.pid;
      IF v_weight IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
      END IF;
      v_total_g := v_total_g + (v_weight * v_item.qty);
    END;
  END LOOP;

  -- ‼️ เช็คยอดเงินในร้านพอก่อนหัก (ไม่รวม fee — เลิกใช้ fee แล้ว)
  FOR v_chk IN
    SELECT
      CASE WHEN UPPER(pe.elem->>'method') = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END AS m,
      COALESCE(pe.elem->>'currency', 'LAK') AS cur,
      NULLIF(pe.elem->>'bank', '') AS bankname,
      SUM( (pe.elem->>'amount')::numeric ) AS need
    FROM jsonb_array_elements(p_payments) AS pe(elem)
    GROUP BY 1, 2, 3
  LOOP
    v_chk_bank_id := NULL;
    IF v_chk.m = 'TRANSFER' AND v_chk.bankname IS NOT NULL THEN
      v_chk_bank_id := _resolve_bank_id(v_chk.bankname);
    END IF;
    IF NOT check_shop_balance(v_chk.m, v_chk.cur::currency_code, v_chk_bank_id, v_chk.need) THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ เงินในร้านไม่พอ: ต้องจ่าย ' || to_char(v_chk.need, 'FM999,999,999,990') || ' ' || v_chk.cur ||
        CASE WHEN v_chk.m = 'CASH' THEN ' (เงินสด)' ELSE ' (' || COALESCE(v_chk.bankname, 'ธนาคาร') || ')' END);
    END IF;
  END LOOP;

  -- [R15-2] LOCK wac_state ก่อนเขียน — serialize กับ confirm_* ที่กำลังอ่าน WAC อยู่
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  -- [R16-5] wac_per_g = WAC ของร้าน ณ ตอนทำรายการ (ก่อนรับเข้า) — เดิมเก็บ p_cost ÷ g (= มูลค่า/g ของรายการเอง)
  VALUES (v_ref_id, 'NEW', 'STOCK_IN', 'IN', v_total_g, p_cost,
          get_wac_per_g(), get_wac_per_g() * 15,
          TRUE, v_user_id, p_note, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_item.pid, 'NEW', v_item.qty, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
  END LOOP;

  INSERT INTO wac_state (id, new_gold_g, new_value, updated_at)
  VALUES (1, v_total_g, p_cost, NOW())
  ON CONFLICT (id)
  DO UPDATE SET new_gold_g = wac_state.new_gold_g + v_total_g,
                new_value = wac_state.new_value + p_cost,
                updated_at = NOW();

  -- หักเงินออกจากร้าน (cashbank) ต่อรายการจ่าย — ไม่มีแถว fee อีกต่อไป
  FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    DECLARE
      v_method TEXT := v_pay->>'method';
      v_bank_name TEXT := v_pay->>'bank';
      v_cur TEXT := COALESCE(v_pay->>'currency', 'LAK');
      v_amount NUMERIC := (v_pay->>'amount')::numeric;
      v_rate NUMERIC := COALESCE((v_pay->>'rate')::numeric, 1);
      v_bank_id UUID := NULL;
    BEGIN
      IF UPPER(v_method) <> 'CASH' THEN
        v_bank_id := _resolve_bank_id(v_bank_name);
      END IF;

      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_method), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code, v_rate,
              CASE WHEN UPPER(v_method) = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(NULLIF(p_note, ''), 'Stock In NEW') || ' [ref:' || v_ref_id || ']',
              NOW(), v_user_id);
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Stock In สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION stock_in_new_tx(JSONB, TEXT, NUMERIC, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ8) get_close_cashbook — เพิ่ม role check (ดูของตัวเอง หรือ Manager/Admin)
--   (คง Bangkok filter จาก R9)
-- ============================================================
CREATE OR REPLACE FUNCTION get_close_cashbook(p_user_id UUID, p_date DATE)
RETURNS TABLE (
  amount NUMERIC,
  currency TEXT,
  method TEXT,
  bank_id UUID,
  bank_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_user_id IS DISTINCT FROM current_user_id() AND NOT is_manager_or_admin() THEN
    RETURN;  -- ไม่ใช่เจ้าของข้อมูลและไม่ใช่ Manager/Admin → ไม่คืนอะไร
  END IF;

  -- [R11.1] คืน "ทั้งกระเป๋าสะสม" ไม่ filter วัน (p_date รับไว้เพื่อ signature compat)
  -- เหตุผล: approve_close_report กวาดยอดสะสมทั้งกระเป๋า → เลขที่ Sales เห็น/Manager
  -- อนุมัติ ต้องเท่ากับเงินที่ย้ายจริง (หลังปิดกะทุกครั้งกระเป๋าเป็น 0 อยู่แล้ว
  -- ดังนั้นยอดสะสม = ยอดตั้งแต่ปิดกะครั้งก่อน)
  RETURN QUERY
  SELECT ucb.amount, ucb.currency::text, ucb.method, ucb.bank_id, b.name
  FROM user_cashbook ucb
  LEFT JOIN banks b ON b.id = ucb.bank_id
  WHERE ucb.user_id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION get_close_cashbook(UUID, DATE) TO authenticated;


-- ============================================================
-- [R16-2] get_close_old_gold — ทองเก่าที่ Sales ถืออยู่ (ยังไม่ปิดกะ) ต่อสินค้า
--   แหล่งเดียวกับ tab Report (get_live_report_sales_breakdown.old_gold) และ
--   approve_close_report (user_gold_received settled=false) → หน้าปิดกะ / Manager review /
--   ทองที่เข้าสต๊อกตอนอนุมัติ ตรงกันทั้งหมด (เดิมหน้าปิดกะใช้ get_close_report.gold_received)
-- ============================================================
CREATE OR REPLACE FUNCTION get_close_old_gold(p_user_id UUID)
RETURNS TABLE (product_id TEXT, qty NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_user_id IS DISTINCT FROM current_user_id() AND NOT is_manager_or_admin() THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT ug.product_id::text, SUM(ug.qty)::numeric
  FROM user_gold_received ug
  WHERE ug.user_id = p_user_id AND ug.settled = FALSE
  GROUP BY ug.product_id;
END;
$$;
GRANT EXECUTE ON FUNCTION get_close_old_gold(UUID) TO authenticated;


-- ============================================================
-- get_live_report (Box Wealth) — คงเดิมจาก R9 (diff = ปัจจุบัน − เมื่อวาน)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB AS $$
DECLARE
  v_today DATE;
  v_today_start TIMESTAMPTZ;
  v_current NUMERIC := 0;
  v_yest NUMERIC := 0;
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_today_start := (v_today::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_current FROM stock_moves;

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_yest FROM stock_moves WHERE date < v_today_start;

  RETURN jsonb_build_object(
    'netTotal', v_current,
    'carryForward', v_yest,
    'diff', v_current - v_yest
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;


-- ============================================================
-- ข้อ4) get_live_report_sales_breakdown — TZ Bangkok ครบทุก CTE
--   เดิม open_shift_today เป็น Bangkok แล้ว แต่ tx/gold/cash/close ยังใช้ ::date (UTC)
--   → ธุรกรรม/ปิดกะช่วง 00:00–06:59 น. ไทย ตกไปอยู่เมื่อวาน (สถานะกะ/ยอดเงินผิด)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report_sales_breakdown(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  WITH active_sales AS (
    SELECT u.id AS user_id,
           COALESCE(NULLIF(TRIM(u.nickname), ''), u.username) AS nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
      AND COALESCE(u.is_active, TRUE) = TRUE
  ),
  open_shift_today AS (
    SELECT DISTINCT user_id
    FROM user_cashbook
    WHERE type = 'OPEN_SHIFT' AND (date AT TIME ZONE 'Asia/Bangkok')::date = v_today
  ),
  tx_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(t.total) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')), 0) AS sell_money,
      COUNT(*) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')) AS sell_count,
      COALESCE(SUM(CASE WHEN t.type='BUYBACK' THEN COALESCE(t.price, t.total) ELSE 0 END), 0) AS buyback_money,
      COUNT(*) FILTER (WHERE t.type='BUYBACK') AS buyback_count,
      COALESCE(SUM(t.total) FILTER (WHERE t.type='WITHDRAW'), 0) AS withdraw_money,
      COUNT(*) FILTER (WHERE t.type='WITHDRAW') AS withdraw_count
    FROM transactions t
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    GROUP BY t.sale_user_id
  ),
  gold_g_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW') AND ti.item_role='NEW'), 0) AS sell_gold_g,
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type='BUYBACK' AND ti.item_role='OLD'), 0) AS bb_gold_g,
      COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (WHERE t.type='WITHDRAW' AND ti.item_role='NEW'), 0) AS wd_gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    GROUP BY t.sale_user_id
  ),
  old_gold_per_sale AS (
    SELECT
      ug.user_id AS sale_user_id,
      jsonb_object_agg(ug.product_id, ug.qty_sum) AS gold_qty
    FROM (
      SELECT user_id, product_id, SUM(qty) AS qty_sum
      FROM user_gold_received
      WHERE settled = FALSE
      GROUP BY user_id, product_id
    ) ug
    GROUP BY ug.user_id
  ),
  cash_per_sale AS (
    SELECT
      ucb.user_id,
      jsonb_build_object(
        'Cash', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='USD'), 0)
        ),
        'BCEL', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='USD'), 0)
        ),
        'LDB', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        ),
        'Other', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        )
      ) AS cash_breakdown
    FROM user_cashbook ucb
    LEFT JOIN banks b ON b.id = ucb.bank_id
    -- [R12] "เงินที่ถือ" = ยอดสะสมทั้งกระเป๋า (ไม่ filter วัน) ให้เป็นสถานะปัจจุบัน
    --       เหมือน old_gold (settled=false) — หลังปิดกะ+approve กระเป๋าถูกกวาดเป็น 0
    --       ดังนั้นยอดสะสม = เงินที่ Sales ถืออยู่จริงตอนนี้ (p_date_* ยังใช้กับยอด tx/ทอง)
    GROUP BY ucb.user_id
  ),
  close_status AS (
    SELECT
      c.user_id,
      MAX(CASE WHEN c.status='PENDING' THEN 'PENDING'
               WHEN c.status='APPROVED' THEN 'CLOSED'
               ELSE NULL END) AS s
    FROM closes c
    WHERE (c.date AT TIME ZONE 'Asia/Bangkok')::date = v_today
    GROUP BY c.user_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'user_id',         a.user_id,
      'nickname',        a.nickname,
      'shift_status',    COALESCE(cs.s, CASE WHEN ost.user_id IS NOT NULL THEN 'OPEN' ELSE 'NOT_OPEN' END),
      'sell_money',      COALESCE(tps.sell_money, 0),
      'sell_count',      COALESCE(tps.sell_count, 0),
      'sell_gold_g',     COALESCE(ggs.sell_gold_g, 0),
      'buyback_money',   COALESCE(tps.buyback_money, 0),
      'buyback_count',   COALESCE(tps.buyback_count, 0),
      'buyback_gold_g',  COALESCE(ggs.bb_gold_g, 0),
      'withdraw_money',  COALESCE(tps.withdraw_money, 0),
      'withdraw_count',  COALESCE(tps.withdraw_count, 0),
      'withdraw_gold_g', COALESCE(ggs.wd_gold_g, 0),
      'old_gold',        COALESCE(ogs.gold_qty, '{}'::jsonb),
      'cash_breakdown',  COALESCE(cps.cash_breakdown, '{}'::jsonb)
    )
  )
  INTO v_result
  FROM active_sales a
  LEFT JOIN open_shift_today ost ON ost.user_id = a.user_id
  LEFT JOIN tx_per_sale tps ON tps.sale_user_id = a.user_id
  LEFT JOIN gold_g_per_sale ggs ON ggs.sale_user_id = a.user_id
  LEFT JOIN old_gold_per_sale ogs ON ogs.sale_user_id = a.user_id
  LEFT JOIN cash_per_sale cps ON cps.user_id = a.user_id
  LEFT JOIN close_status cs ON cs.user_id = a.user_id;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION get_live_report_sales_breakdown(DATE, DATE) TO authenticated;


-- ============================================================
-- DIFF helpers — คงเดิมจาก R9 (สูตรชีทเก่า)
-- ============================================================
-- [R11.1] สินค้านอก G01–G07 → คิด pro-rata จาก weight_baht × ราคาขาย 1 บาท (เดิมคืน 0 เงียบๆ)
--   (เปลี่ยน IMMUTABLE → STABLE เพราะ lookup ตาราง products)
-- ============================================================
-- [R15-1] WAC — แหล่งเดียว (wac_state)
--   get_wac_per_g()   = (new_value + old_value) ÷ (new_gold_g + old_gold_g)  ไม่ปัดเศษ
--   get_wac_state()   = RPC ให้ JS ใช้: คืนตัวเลขดิบของ wac_state + wac_per_g + wac_per_baht
--                       wac_per_baht = wac_per_g × 15 (คูณจากค่าไม่ปัดเศษ — ปัดตอนแสดงผลเท่านั้น)
--   ทุกที่ที่ต้องใช้ WAC (confirm_*, recompute_diffs, Dashboard, tab WAC, Accounting)
--   ต้องผ่าน 2 ฟังก์ชันนี้เท่านั้น — ห้ามคำนวณเองจาก stock_moves
-- ============================================================
CREATE OR REPLACE FUNCTION get_wac_per_g()
RETURNS NUMERIC AS $$
DECLARE
  v_total_g NUMERIC;
  v_total_value NUMERIC;
BEGIN
  SELECT (COALESCE(new_gold_g, 0) + COALESCE(old_gold_g, 0)),
         (COALESCE(new_value, 0) + COALESCE(old_value, 0))
    INTO v_total_g, v_total_value
  FROM wac_state WHERE id = 1;

  IF v_total_g IS NULL OR v_total_g <= 0 THEN RETURN 0; END IF;
  RETURN v_total_value / v_total_g;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_wac_state()
RETURNS JSONB AS $$
DECLARE
  v_w RECORD;
  v_wac NUMERIC;
BEGIN
  IF current_user_id() IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  SELECT COALESCE(new_gold_g, 0) AS new_gold_g, COALESCE(new_value, 0) AS new_value,
         COALESCE(old_gold_g, 0) AS old_gold_g, COALESCE(old_value, 0) AS old_value,
         updated_at
    INTO v_w
  FROM wac_state WHERE id = 1;

  v_wac := get_wac_per_g();

  RETURN jsonb_build_object(
    'success', true,
    'new_gold_g', COALESCE(v_w.new_gold_g, 0),
    'new_value',  COALESCE(v_w.new_value, 0),
    'old_gold_g', COALESCE(v_w.old_gold_g, 0),
    'old_value',  COALESCE(v_w.old_value, 0),
    'total_g',    COALESCE(v_w.new_gold_g, 0) + COALESCE(v_w.old_gold_g, 0),
    'total_value', COALESCE(v_w.new_value, 0) + COALESCE(v_w.old_value, 0),
    'wac_per_g',  v_wac,
    'wac_per_baht', v_wac * 15,
    'updated_at', v_w.updated_at
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_wac_state() TO authenticated;


-- ============================================================
-- [R15-5] snapshot ราคาขาย 1 บาท "ณ ตอนสร้างบิล" ลง transactions.sell_1baht
--   ทุก create_*_tx เดิมรับ p_sell_1baht แต่ไม่ได้ INSERT → คอลัมน์เป็น 0 ตลอด
--   ผล: confirm_* (Diff ขายใหม่/ขายเก่า), PriceIn ทองเก่า [R15-4], recompute_diffs
--   ไป fallback ราคาปัจจุบันแทนราคาตอนทำรายการ
--   body ด้านล่าง = เวอร์ชันที่รันอยู่ใน DB (data.xlsx) + เพิ่ม sell_1baht เท่านั้น
-- ============================================================
ALTER TABLE transactions ADD COLUMN IF NOT EXISTS sell_1baht NUMERIC DEFAULT 0;

CREATE OR REPLACE FUNCTION _snapshot_sell_1baht(p_from_client NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(p_from_client, 0),
                  (SELECT sell_1baht FROM pricing ORDER BY date DESC LIMIT 1),
                  0);
$$;
REVOKE ALL ON FUNCTION _snapshot_sell_1baht(NUMERIC) FROM PUBLIC, anon, authenticated;

-- ----- create_sell_tx -----
CREATE OR REPLACE FUNCTION public.create_sell_tx(p_phone text, p_bill_id text, p_items jsonb, p_total numeric, p_premium numeric, p_sell_1baht numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_s1b NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;

    SELECT qty INTO v_stock FROM stock_balances
    WHERE product_id = v_pid AND gold_type = 'NEW';

    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'สต็อกไม่พอสำหรับ ' || v_pid || ' (มี ' || COALESCE(v_stock, 0) || ' ต้องการ ' || v_qty || ')'
      );
    END IF;
  END LOOP;

  v_s1b := _snapshot_sell_1baht(p_sell_1baht);
  v_tx_id := generate_tx_id('SELL');

  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, premium, currency, sell_1baht, date)
  VALUES (v_tx_id, 'SELL', 'PENDING', p_bill_id, p_phone, v_user_id, p_total, p_premium, 'LAK', v_s1b, NOW());

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (
      v_tx_id, 'NEW',
      v_item->>'productId',
      (v_item->>'qty')::numeric
    );
  END LOOP;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New SELL waiting for review: ' || v_tx_id, 'Manager', 'sell', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_sell_tx(text, text, jsonb, numeric, numeric, numeric) TO authenticated;

-- ----- create_buyback_tx -----
CREATE OR REPLACE FUNCTION public.create_buyback_tx(p_phone text, p_bill_id text, p_items jsonb, p_price numeric, p_fee numeric, p_sell_1baht numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_s1b NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  v_s1b := _snapshot_sell_1baht(p_sell_1baht);
  v_tx_id := generate_tx_id('BUYBACK');

  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, price, fee, balance, currency, sell_1baht, date)
  VALUES (v_tx_id, 'BUYBACK', 'PENDING', p_bill_id, p_phone, v_user_id, p_price, p_price, COALESCE(p_fee, 0), p_price, 'LAK', v_s1b, NOW());

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('PAYMENT', 'New BUYBACK waiting for payment: ' || v_tx_id, 'Manager', 'buyback', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_buyback_tx(text, text, jsonb, numeric, numeric, numeric) TO authenticated;

-- ----- create_tradein_tx -----
CREATE OR REPLACE FUNCTION public.create_tradein_tx(p_phone text, p_bill_id text, p_old_items jsonb, p_new_items jsonb, p_foc_items jsonb, p_foc_bill_ref text, p_difference numeric, p_premium numeric, p_foc_premium_deduct numeric, p_total numeric, p_sell_1baht numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_s1b NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances
    WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อกไม่พอ ' || v_pid);
    END IF;
  END LOOP;

  v_s1b := _snapshot_sell_1baht(p_sell_1baht);
  v_tx_id := generate_tx_id('TRADEIN');

  INSERT INTO transactions (
    id, type, status, bill_id, phone, sale_user_id,
    diff_amount, premium, foc_premium_deduct, foc_bill_ref,
    total, currency, sell_1baht, date
  )
  VALUES (
    v_tx_id, 'TRADEIN', 'PENDING', p_bill_id, p_phone, v_user_id,
    p_difference, p_premium, COALESCE(p_foc_premium_deduct, 0), NULLIF(p_foc_bill_ref, ''),
    p_total, 'LAK', v_s1b, NOW()
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_old_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  IF p_foc_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_foc_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'FOC', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New TRADEIN waiting for review: ' || v_tx_id, 'Manager', 'tradein', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_tradein_tx(text, text, jsonb, jsonb, jsonb, text, numeric, numeric, numeric, numeric, numeric) TO authenticated;

-- ----- create_withdraw_tx -----
CREATE OR REPLACE FUNCTION public.create_withdraw_tx(p_phone text, p_bill_id text, p_items jsonb, p_premium numeric, p_total numeric, p_withdraw_code text, p_sell_1baht numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_s1b NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อกไม่พอ ' || v_pid);
    END IF;
  END LOOP;

  v_s1b := _snapshot_sell_1baht(p_sell_1baht);
  v_tx_id := generate_tx_id('WITHDRAW');

  INSERT INTO transactions (id, type, status, bill_id, phone, sale_user_id, total, premium, withdraw_code, currency, sell_1baht, date)
  VALUES (v_tx_id, 'WITHDRAW', 'PENDING', p_bill_id, p_phone, v_user_id, p_total, COALESCE(p_premium, 0), p_withdraw_code, 'LAK', v_s1b, NOW());

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New WITHDRAW waiting for review: ' || v_tx_id, 'Manager', 'withdraw', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_withdraw_tx(text, text, jsonb, numeric, numeric, text, numeric) TO authenticated;
-- (create_exchange_tx แก้ในบล็อก "ข้อ7" ด้านล่าง — เพิ่ม sell_1baht เช่นกัน)


CREATE OR REPLACE FUNCTION _diff_sell_price(p_pid TEXT, p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT CASE p_pid
    WHEN 'G01' THEN ROUND(p_s1b * 10 / 1000.0) * 1000
    WHEN 'G02' THEN ROUND(p_s1b * 5  / 1000.0) * 1000
    WHEN 'G03' THEN ROUND(p_s1b * 2  / 1000.0) * 1000
    WHEN 'G04' THEN ROUND(p_s1b       / 1000.0) * 1000
    WHEN 'G05' THEN ROUND((p_s1b / 2) / 1000.0) * 1000
    WHEN 'G06' THEN ROUND((p_s1b / 4) / 1000.0) * 1000
    WHEN 'G07' THEN CEIL((p_s1b / 15.0 + 120000) / 1000.0) * 1000
    ELSE COALESCE(
      (SELECT ROUND((p_s1b * p.weight_baht) / 1000.0) * 1000
       FROM products p WHERE p.id = p_pid),
      0)
    END;
$$;

CREATE OR REPLACE FUNCTION _diff_items_sell_total(p_tx_id TEXT, p_roles TEXT[], p_s1b NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(ti.qty * _diff_sell_price(ti.product_id, p_s1b)), 0)
  FROM transaction_items ti
  WHERE ti.tx_id = p_tx_id AND ti.item_role::text = ANY(p_roles);
$$;

CREATE OR REPLACE FUNCTION _diff_sell_1baht(p_tx_sell_1baht NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(p_tx_sell_1baht, 0),
                  (SELECT sell_1baht FROM pricing ORDER BY date DESC LIMIT 1),
                  0);
$$;


-- ============================================================
-- ข้อ1) confirm_sell_tx — multi-payment
--   signature ใหม่: (p_tx_id, p_payments JSONB, p_change) — DROP ตัวเก่า
--   + FOR UPDATE แถว tx (กันยืนยันซ้ำ 2 เครื่อง)
--   + เช็คสต๊อกพอก่อนตัด (FOR UPDATE)
--   + หักเงินทอนออกจาก ledger (helper 0.3)
--   Diff: คงสูตร R9 — diff = ขายใหม่ + premium − (น้ำหนักใหม่ × WAC)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_sell_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_sell_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_sell_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_phone TEXT;
  v_premium NUMERIC;
  v_sell_1baht NUMERIC := 0;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  -- [R14-3] อนุญาตยืนยันโดยไม่มีรายการชำระเงินได้ ถ้ายอดรวมของบิล = 0
  --   (เช่น Free Exchange / เปลี่ยนฟรี — ลูกค้าไม่ต้องจ่ายเพิ่ม)
  --   ตรงนี้เช็คแค่ "รูปแบบ" ส่วนเช็คว่าต้องมีเงินหรือไม่ ย้ายไปหลังอ่าน total
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  SELECT t.status, t.total, t.phone, t.premium, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_phone, v_premium, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'SELL'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Transaction not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  -- [R14-3] ยอดรวม > 0 → ต้องมีรายการชำระเงินอย่างน้อย 1 รายการ (ยอด 0 = ผ่านได้)
  IF jsonb_array_length(p_payments) = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- [R15-2] LOCK wac_state "ก่อนอ่าน" WAC — ทุก tx ที่แตะสต๊อก/WAC ต่อคิวผ่าน row นี้
  --   → ค่าที่อ่านด้านล่างสะท้อนการเขียนของ tx ก่อนหน้าครบ และไม่มีใครเขียนแทรกจนกว่าเราจะ commit
  --   ลำดับ: lock → อ่าน (สต๊อก, น้ำหนัก, WAC, ราคาขาย) → เขียน (payments, stock, wac_state, diffs)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  -- ‼️ เช็คสต๊อกพอก่อนตัด (ไม่พอ = ไม่แตะอะไรเลย tx คง APPROVED)
  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);

  -- ลงบัญชีทุกรายการจ่าย (transaction_payments + cashbank/user_cashbook)
  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'SELL', 'Sell ' || p_tx_id, v_user_id, v_is_sales);

  -- [R14-3] ยอด > 0 แต่ไม่มีรายการชำระที่ยอดมากกว่า 0 → rollback
  IF (v_pay->>'entries')::int = 0 AND COALESCE(v_total, 0) > 0 THEN
    RAISE EXCEPTION 'ไม่มีรายการชำระเงินที่ยอดมากกว่า 0';
  END IF;

  -- เงินทอน — หักออกจากกระเป๋าเดียวกับที่เงินสดเข้า (ไม่พอ = rollback ทั้งบิล)
  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  -- [R13-8] price = ต้นทุนที่ตัดออก (น้ำหนัก × WAC) ไม่ใช่ยอดขาย — StockMove เป็นบัญชีต้นทุนล้วน
  --   ยอดขายเก็บที่ transactions.total อยู่แล้ว
  VALUES (p_tx_id, 'NEW', 'SELL', 'OUT', v_gold_g, v_cost, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_gold_g, new_value = new_value - v_cost, updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): sell_value = ขายใหม่ ; diff = ขายใหม่ + premium − ต้นทุน WAC
  v_diff := v_new_sell_total + COALESCE(v_premium, 0) - v_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'SELL', v_new_sell_total, 0, 0, COALESCE(v_premium, 0), v_cost, 0, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = 0, switch_fee = 0, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = 0, diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'cost', v_cost, 'diff', v_diff);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_sell_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_tradein_tx — multi-payment (เหมือน sell + ทองเก่าเข้า user_gold_received)
--   Diff: diff = ขายใหม่ + premium − ((ใหม่−เก่า)×WAC) − ขายเก่า
-- ============================================================
DROP FUNCTION IF EXISTS confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_tradein_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_tradein_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_diff_amount NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_cost_diff NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_old_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  -- [R14-3] อนุญาตยืนยันโดยไม่มีรายการชำระเงินได้ ถ้ายอดรวมของบิล = 0
  --   (เช่น Free Exchange / เปลี่ยนฟรี — ลูกค้าไม่ต้องจ่ายเพิ่ม)
  --   ตรงนี้เช็คแค่ "รูปแบบ" ส่วนเช็คว่าต้องมีเงินหรือไม่ ย้ายไปหลังอ่าน total
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  SELECT t.status, t.total, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0), COALESCE(t.diff_amount, 0)
    INTO v_status, v_total, v_premium, v_sale_user, v_sell_1baht, v_diff_amount
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'TRADEIN'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  -- [R14-3] ยอดรวม > 0 → ต้องมีรายการชำระเงินอย่างน้อย 1 รายการ (ยอด 0 = ผ่านได้)
  IF jsonb_array_length(p_payments) = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- [R15-2] LOCK wac_state "ก่อนอ่าน" — ดึงสต๊อก/WAC/ราคาให้ครบก่อน แล้วค่อยเขียนทั้งหมด
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_new_gold_g := calc_items_gold_g(v_new_items);

  SELECT COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)), 0) INTO v_old_gold_g
  FROM transaction_items ti JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'FOC');

  v_wac_per_g := get_wac_per_g();
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);
  v_old_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['OLD','FOC'], v_s1b);

  -- [R15-9] Cost(ส่วนต่าง) = WAC ณ ตอนทำรายการ (WAC/g ที่อ่านหลัง lock ด้านบน) × น้ำหนักส่วนต่าง (ใหม่ − เก่า) g
  --   (R15-3 เคยเปลี่ยนเป็น diff_amount — user สั่งกลับมาใช้ WAC × น้ำหนัก)
  --   ค่า WAC ตัวเดียวกันถูก snapshot ลง stock_moves.wac_per_g ของบิลนี้ → recompute_diffs ใช้ค่านั้นซ้ำได้
  v_cost_diff := (v_new_gold_g - v_old_gold_g) * v_wac_per_g;

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'TRADEIN', 'Tradein ' || p_tx_id, v_user_id, v_is_sales);

  -- [R14-3] ยอด > 0 แต่ไม่มีรายการชำระที่ยอดมากกว่า 0 → rollback
  IF (v_pay->>'entries')::int = 0 AND COALESCE(v_total, 0) > 0 THEN
    RAISE EXCEPTION 'ไม่มีรายการชำระเงินที่ยอดมากกว่า 0';
  END IF;

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  -- [R13-8] price = ต้นทุนทองใหม่ที่ออกไป "เต็มน้ำหนัก" × WAC (ไม่ใช่ยอดที่ลูกค้าจ่าย)
  --   ‼️ คนละตัวกับ v_cost_diff ของชีท Diff ที่คิดเฉพาะส่วนต่างน้ำหนัก
  VALUES (p_tx_id, 'NEW', 'TRADEIN', 'OUT', v_new_gold_g, v_new_gold_g * v_wac_per_g, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  -- [R15-4] ทองเก่าที่รับ: จำ "ราคาขายต่อชิ้น ณ ตอนทำรายการ" (PriceIn) = _diff_sell_price(สินค้า, sell_1baht ของบิล)
  --   = ราคาขายตามตารางสินค้า (ปัดพัน, 1 กรัมรวมค่ากำเหน็จ) → เลขลงตัวและตรงกับ Cost(ทองเก่า) ใน Diff
  --   ใช้ตีมูลค่าเข้า Stock OLD / lot / wac_state ตอน Manager approve ปิดกะ (เดิมบันทึก 0)
  --   ‼️ ห้ามใช้ weight_baht × sell_1baht — 1 กรัม (0.0666667 บาท) จะได้เศษไม่ลงตัว
  FOR v_item IN SELECT ti.product_id, ti.qty, p.weight_baht
                FROM transaction_items ti JOIN products p ON p.id = ti.product_id
                WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'FOC') LOOP
    INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id, price_per_unit, settled)
    VALUES (COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty, 'TRADEIN', p_tx_id, NOW(), v_user_id,
            _diff_sell_price(v_item.product_id, v_s1b), FALSE);
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - (v_new_gold_g * v_wac_per_g),
        updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): cost_diff = (ใหม่−เก่า)g × WAC ณ ตอนทำรายการ [R15-9] ; cost_old_gold = ขายเก่า
  v_diff := v_new_sell_total + COALESCE(v_premium, 0) - v_cost_diff - v_old_sell_total;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'TRADEIN', v_new_sell_total, 0, 0, COALESCE(v_premium, 0), v_cost_diff, v_old_sell_total, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = 0, switch_fee = 0, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณเรียบร้อย: ' || p_tx_id, v_sale_user, 'tradein', p_tx_id);
  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_exchange_tx — multi-payment
--   Diff: diff = ขายใหม่ + exFee + swFee + premium − ขายเก่า (ไม่คิด WAC)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_exchange_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_exchange_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_ex_fee NUMERIC;
  v_switch_fee NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_s1b NUMERIC;
  v_new_sell_total NUMERIC;
  v_old_sell_total NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_diff NUMERIC;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  -- [R14-3] อนุญาตยืนยันโดยไม่มีรายการชำระเงินได้ ถ้ายอดรวมของบิล = 0
  --   (เช่น Free Exchange / เปลี่ยนฟรี — ลูกค้าไม่ต้องจ่ายเพิ่ม)
  --   ตรงนี้เช็คแค่ "รูปแบบ" ส่วนเช็คว่าต้องมีเงินหรือไม่ ย้ายไปหลังอ่าน total
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  -- [R14-3] ยอดรวม > 0 → ต้องมีรายการชำระเงินอย่างน้อย 1 รายการ (ยอด 0 = ผ่านได้)
  IF jsonb_array_length(p_payments) = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- [R15-2] LOCK wac_state "ก่อนอ่าน" — ดึงสต๊อก/WAC/ราคาให้ครบก่อน แล้วค่อยเขียนทั้งหมด
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_new_gold_g := calc_items_gold_g(v_new_items);

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  v_s1b := _diff_sell_1baht(v_sell_1baht);
  v_new_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['NEW'], v_s1b);
  v_old_sell_total := _diff_items_sell_total(p_tx_id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'EXCHANGE', 'Exchange ' || p_tx_id, v_user_id, v_is_sales);

  -- [R14-3] ยอด > 0 แต่ไม่มีรายการชำระที่ยอดมากกว่า 0 → rollback
  IF (v_pay->>'entries')::int = 0 AND COALESCE(v_total, 0) > 0 THEN
    RAISE EXCEPTION 'ไม่มีรายการชำระเงินที่ยอดมากกว่า 0';
  END IF;

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  -- [R13-8] price = ต้นทุนที่ตัดออก (น้ำหนัก × WAC) ไม่ใช่ค่าธรรมเนียมที่ลูกค้าจ่าย
  VALUES (p_tx_id, 'NEW', 'EXCHANGE', 'OUT', v_new_gold_g, v_new_cost, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  -- [R15-4] ทองเก่าที่รับ: จำ PriceIn ต่อชิ้น = ราคาขายตามตารางสินค้า ณ ตอนทำรายการ (เดิมบันทึก 0)
  FOR v_item IN SELECT ti.product_id, ti.qty, p.weight_baht
                FROM transaction_items ti JOIN products p ON p.id = ti.product_id
                WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'SWITCH', 'FREE_EX') LOOP
    INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id, price_per_unit, settled)
    VALUES (COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty, 'EXCHANGE', p_tx_id, NOW(), v_user_id,
            _diff_sell_price(v_item.product_id, v_s1b), FALSE);
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  -- DIFF (ชีท): ไม่คิด WAC (cost_diff=0)
  v_diff := v_new_sell_total + COALESCE(v_ex_fee, 0) + COALESCE(v_switch_fee, 0) + COALESCE(v_premium, 0) - v_old_sell_total;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_new_sell_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0),
          0, v_old_sell_total, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = 0, cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณเรียบร้อย: ' || p_tx_id, v_sale_user, 'exchange', p_tx_id);
  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ1) confirm_withdraw_tx — multi-payment (Diff = 0 ทุกค่า ตาม R9)
-- ============================================================
DROP FUNCTION IF EXISTS confirm_withdraw_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);
DROP FUNCTION IF EXISTS confirm_withdraw_tx(TEXT, JSONB, NUMERIC);

CREATE FUNCTION confirm_withdraw_tx(p_tx_id TEXT, p_payments JSONB, p_change NUMERIC DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_is_sales BOOLEAN;
  v_status tx_status;
  v_total NUMERIC;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_stock NUMERIC;
  v_pay JSONB;
  v_change NUMERIC := COALESCE(p_change, 0);
  v_err TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);

  -- [R14-3] อนุญาตยืนยันโดยไม่มีรายการชำระเงินได้ ถ้ายอดรวมของบิล = 0
  --   (เช่น Free Exchange / เปลี่ยนฟรี — ลูกค้าไม่ต้องจ่ายเพิ่ม)
  --   ตรงนี้เช็คแค่ "รูปแบบ" ส่วนเช็คว่าต้องมีเงินหรือไม่ ย้ายไปหลังอ่าน total
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  SELECT t.status, t.total INTO v_status, v_total
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'WITHDRAW'
  FOR UPDATE;

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED'); END IF;

  -- [R14-3] ยอดรวม > 0 → ต้องมีรายการชำระเงินอย่างน้อย 1 รายการ (ยอด 0 = ผ่านได้)
  IF jsonb_array_length(p_payments) = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- [R15-2] LOCK wac_state "ก่อนอ่าน" — ดึงสต๊อก/WAC ให้ครบก่อน แล้วค่อยเขียนทั้งหมด
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  FOR v_item IN SELECT ti.product_id, ti.qty FROM transaction_items ti
                WHERE ti.tx_id = p_tx_id AND ti.item_role = 'NEW' LOOP
    SELECT sb.qty INTO v_stock FROM stock_balances sb
      WHERE sb.product_id = v_item.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ สต็อก NEW ไม่พอ: ' || v_item.product_id);
    END IF;
  END LOOP;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';
  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  v_pay := _apply_confirm_payments(p_tx_id, p_payments, 'WITHDRAW', 'Withdraw ' || p_tx_id, v_user_id, v_is_sales);

  -- [R14-3] ยอด > 0 แต่ไม่มีรายการชำระที่ยอดมากกว่า 0 → rollback
  IF (v_pay->>'entries')::int = 0 AND COALESCE(v_total, 0) > 0 THEN
    RAISE EXCEPTION 'ไม่มีรายการชำระเงินที่ยอดมากกว่า 0';
  END IF;

  v_err := _apply_change_deduction(p_tx_id, v_change, v_user_id, v_is_sales);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION '%', v_err; END IF;

  UPDATE transactions
    SET status = 'COMPLETED',
        paid = (v_pay->>'paid_lak')::numeric,
        change_amount = v_change,
        currency = (v_pay->>'first_currency')::currency_code,
        updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  -- [R13-8] price = ต้นทุนที่ตัดออก (น้ำหนัก × WAC) ไม่ใช่ยอดที่ลูกค้าจ่าย
  VALUES (p_tx_id, 'NEW', 'WITHDRAW', 'OUT', v_gold_g, v_cost, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_gold_g, new_value = new_value - v_cost, updated_at = NOW()
    WHERE id = 1;

  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'WITHDRAW', 0, 0, 0, 0, 0, 0, 0, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = 0, ex_fee = 0, switch_fee = 0, premium = 0,
        cost_diff = 0, cost_old_gold = 0, diff = 0;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_withdraw_tx(TEXT, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ2) confirm_buyback_tx — แก้ 3 บัค (คง signature เดิม + DEFAULT)
--   • สะสมยอดจ่ายเป็น LAK: paid += p_paid × เรทรับซื้อ (เดิมบวกเลขดิบข้ามสกุล)
--   • fee เลิกใช้ — ignore p_fee (คง param ไว้เพื่อ compat, ไม่ insert แถว fee)
--   • FOR UPDATE แถว tx กันยืนยันพร้อมกัน
--   (การเทียบ method ใช้ UPPER อยู่แล้ว — JS ส่ง 'CASH'/'BANK')
-- ============================================================
-- [R17-1] p_allow_short: ยอดค้าง ≤ 500 LAK (จ่ายด้วยสกุลอื่น) → ปิดบิลเป็น COMPLETED, paid = price
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);

CREATE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_fee NUMERIC DEFAULT 0, p_change NUMERIC DEFAULT 0,
  p_allow_short BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_price NUMERIC;
  v_total_paid NUMERIC;
  v_new_balance NUMERIC;
  v_new_status tx_status;
  v_total_qty NUMERIC := 0;
  v_price_per_unit NUMERIC := 0;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_sale_user UUID;
  v_old_gold_g NUMERIC := 0;
  v_sell_1baht NUMERIC := 0;
  v_old_cost NUMERIC := 0;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_pay_from_drawer BOOLEAN;
  v_cb_method TEXT;
  v_rate NUMERIC := 1;
  v_paid_lak NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_pay_from_drawer := (v_is_sales AND v_is_cash);
  v_cb_method := CASE WHEN v_is_cash THEN 'CASH' ELSE 'TRANSFER' END;

  IF p_paid IS NULL OR p_paid <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- ‼️ เรทรับซื้อ (ร้านจ่ายเงินออก): THB→thb_buy, USD→usd_buy — สะสม paid เป็น LAK
  IF p_currency <> 'LAK' THEN
    SELECT CASE WHEN p_currency = 'THB' THEN thb_buy
                WHEN p_currency = 'USD' THEN usd_buy END
      INTO v_rate
    FROM price_rates ORDER BY date DESC LIMIT 1;
    IF v_rate IS NULL OR v_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยังไม่ได้ตั้งเรทรับซื้อ ' || p_currency || '/LAK — โปรดตั้งเรทใน Price Rate ก่อน');
    END IF;
  END IF;
  v_paid_lak := p_paid * v_rate;

  -- [LOCK] กันจ่ายบิลเดียวกันพร้อมกัน 2 เครื่อง
  SELECT t.status, t.price, t.paid, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_price, v_total_paid, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK'
  FOR UPDATE;

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
  END IF;

  -- เช็คเงินพอจ่าย (สกุลจริงที่จ่าย): Sales+เงินสด → กระเป๋า Sales ; อื่นๆ → เงินร้าน
  IF v_pay_from_drawer THEN
    IF NOT check_user_cash_balance(v_user_id, p_currency, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในกระเป๋าของคุณไม่พอจ่าย Buyback');
    END IF;
  ELSE
    IF NOT check_shop_balance(v_cb_method, p_currency, p_bank_id, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินในร้านไม่พอ โปรดติดต่อ Admin');
    END IF;
  END IF;

  v_total_paid := COALESCE(v_total_paid, 0) + v_paid_lak;
  v_new_balance := v_price - v_total_paid;

  IF v_new_balance <= 0 THEN
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
  ELSIF COALESCE(p_allow_short, FALSE) AND p_currency <> 'LAK' AND v_new_balance <= 500 THEN
    -- [R17-1] เศษจากการแปลงสกุล ≤ 500 LAK → ถือว่าจ่ายครบตาม Total
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
    v_total_paid := v_price;
  ELSE
    v_new_status := 'PARTIAL';
  END IF;

  UPDATE transactions
  SET status = v_new_status, paid = v_total_paid, balance = v_new_balance,
      fee = 0, change_amount = COALESCE(p_change, 0), updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, v_cb_method, p_bank_id, v_user_id);

  -- เงินออกจากร้าน (cashbank): เฉพาะกรณีไม่ใช่ "เงินสดจากกระเป๋า Sales" (amount = สกุลจริง)
  IF NOT v_pay_from_drawer THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): หักเงินที่จ่ายออก (สกุลจริง)
  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW());
  END IF;

  -- [R12.1] บันทึกทองเก่าที่รับ "ตั้งแต่จ่ายครั้งแรก" (เดิมบันทึกเฉพาะจ่ายครบ →
  --   บิลค้างยอด PARTIAL ไม่ถูกบันทึกเลย ทองไม่เข้า Stock Old ตอนอนุมัติปิดกะ)
  --   ลูกค้าส่งมอบทองตั้งแต่ตกลงขาย จึงบันทึกเต็มจำนวนตอนจ่ายงวดแรก
  --   เช็ค EXISTS กันบันทึกซ้ำงวดถัดไป + ครอบคลุมบิล PARTIAL เก่าที่ค้างอยู่
  SELECT COALESCE(SUM(ti.qty), 0),
         COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)), 0)
    INTO v_total_qty, v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD';

  -- [R15-8] PriceIn ต่อชิ้นของ Buyback = เงินที่จ่ายจริงของบิล "แบ่งตามน้ำหนัก" แต่ละชิ้น
  --   เดิม = price ÷ จำนวนชิ้น (บิลผสมหลายขนาด → 10 บาท กับ 1 กรัม ได้ราคาต่อชิ้นเท่ากัน = ผิด)
  --   ผลรวมทุกชิ้น = price ของบิลพอดี (ปัดทศนิยม 2 ตำแหน่ง)
  IF NOT EXISTS (SELECT 1 FROM user_gold_received WHERE ref_tx_id = p_tx_id) THEN
    FOR v_item IN SELECT ti.product_id, ti.qty, _gold_g(p.weight_baht) AS g
                  FROM transaction_items ti JOIN products p ON p.id = ti.product_id
                  WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD' LOOP
      v_price_per_unit := CASE WHEN v_old_gold_g > 0
                               THEN ROUND(v_price * v_item.g / v_old_gold_g, 2)
                               WHEN v_total_qty > 0 THEN ROUND(v_price / v_total_qty, 2)
                               ELSE 0 END;
      INSERT INTO user_gold_received (
        user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
        price_per_unit, settled
      )
      VALUES (
        COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
        'BUYBACK', p_tx_id, NOW(), v_user_id,
        v_price_per_unit, FALSE
      );
    END LOOP;
  END IF;

  IF v_new_status = 'COMPLETED' THEN
    v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

    INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, 0, 0, 0,
            0, v_old_cost,
            ((-v_price) - v_old_cost), NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
          switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
          cost_diff = EXCLUDED.cost_diff,
          cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

    PERFORM _notify_user('PAYMENT', '💰 BUYBACK ของคุณจ่ายเงินเรียบร้อย: ' || p_tx_id,
                         v_sale_user, 'buyback', p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'status', v_new_status, 'balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN) TO authenticated;


-- ============================================================
-- [R16-4] helper: ต้นทุน FIFO "ต่อกรัม" ของทองเก่าที่จะตัดออกถัดไป p_gold_g กรัม
--   สูตรเดียวกับ PriceOut ที่ get_stock_moves('OLD') แสดง (เดิน stock_moves OLD ตาม date,id
--   IN = เพิ่มก้อน (price ÷ gold_g) / OUT = ตัดก้อนเก่าสุดก่อน) → แล้วตัดต่ออีก p_gold_g
--   transfer_old_to_new_tx / stock_out_old_tx ใช้ค่านี้เป็น price → PriceIn Stock New = PriceOut Stock Old
--   ⚠️ caller ต้องถือ lock wac_state และเรียก "ก่อน" INSERT แถว OUT ของตัวเอง
-- ============================================================
CREATE OR REPLACE FUNCTION _old_fifo_out_cost(p_gold_g NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE
  v_qty NUMERIC[] := '{}';
  v_unit NUMERIC[] := '{}';
  v_head INT := 1;
  v_row RECORD;
  v_remaining NUMERIC;
  v_cost NUMERIC := 0;
  v_take NUMERIC;
BEGIN
  FOR v_row IN
    SELECT direction, gold_g, COALESCE(price, 0) AS price
    FROM stock_moves
    WHERE gold_type = 'OLD'
    ORDER BY date ASC, id ASC
  LOOP
    IF v_row.direction = 'IN' THEN
      v_qty := v_qty || v_row.gold_g;
      v_unit := v_unit || CASE WHEN v_row.gold_g > 0 THEN v_row.price / v_row.gold_g ELSE 0 END;
    ELSE
      v_remaining := v_row.gold_g;
      WHILE v_remaining > 0 AND v_head <= COALESCE(array_length(v_qty, 1), 0) LOOP
        v_take := LEAST(v_qty[v_head], v_remaining);
        v_qty[v_head] := v_qty[v_head] - v_take;
        v_remaining := v_remaining - v_take;
        IF v_qty[v_head] <= 0 THEN v_head := v_head + 1; END IF;
      END LOOP;
    END IF;
  END LOOP;

  v_remaining := COALESCE(p_gold_g, 0);
  WHILE v_remaining > 0 AND v_head <= COALESCE(array_length(v_qty, 1), 0) LOOP
    v_take := LEAST(v_qty[v_head], v_remaining);
    v_cost := v_cost + v_take * v_unit[v_head];
    v_qty[v_head] := v_qty[v_head] - v_take;
    v_remaining := v_remaining - v_take;
    IF v_qty[v_head] <= 0 THEN v_head := v_head + 1; END IF;
  END LOOP;

  RETURN v_cost;
END;
$$;
REVOKE ALL ON FUNCTION _old_fifo_out_cost(NUMERIC) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- L1.3) transfer_old_to_new_tx — เปลี่ยนต้นทุนจาก WAC เฉลี่ย → FIFO ราย lot
--   (base: เวอร์ชันล่าสุดจาก git cf4fbbd — คง lock/ref/โครงเดิมทั้งหมด)
--   consumed_cost = Σ ต้นทุนจริงของ lot ที่ถูกตัด (เก่าสุดก่อน ต่อ product)
-- ============================================================
CREATE OR REPLACE FUNCTION transfer_old_to_new_tx(p_items JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
  v_old_wac NUMERIC;
  v_consumed_cost NUMERIC := 0;
  v_wac_now NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- [LOCK] serialize ทุก tx ที่แตะ wac/stock ผ่าน row นี้
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('TF', 'TRANSFER');

  -- 1) total weight + ตรวจสต็อก OLD พอ (FOR UPDATE) — ห้าม mutate ก่อน validate ครบ
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT _gold_g(weight_baht) INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances
      WHERE product_id = v_item.pid AND gold_type = 'OLD'
      FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  -- 2) ตัด lot FIFO ต่อ product → ต้นทุนจริงรวม (หลัง validate ผ่านครบแล้วเท่านั้น)
  -- [R16-4] ต้นทุน = FIFO ต่อกรัม (สูตรเดียวกับ PriceOut ที่หน้า Stock Old แสดง) — คำนวณก่อน INSERT แถว OUT
  --   lot ยังตัดเหมือนเดิมเพื่อเก็บจำนวนคงเหลือต่อสินค้า แต่ไม่ใช้ต้นทุนจาก lot แล้ว
  v_consumed_cost := _old_fifo_out_cost(v_total_g);
  v_wac_now := get_wac_per_g();
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    PERFORM _consume_old_lots(v_item.pid, v_item.qty);
  END LOOP;
  v_old_wac := CASE WHEN v_total_g > 0 THEN v_consumed_cost / v_total_g ELSE 0 END;

  -- 3) INSERT OLD/OUT
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price,
                           wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  -- [R16-5] wac_per_g = WAC ของร้าน ณ ตอนทำรายการ (transfer ไม่เปลี่ยน WAC รวม) — เดิมเก็บต้นทุน/g ของรายการเอง
  VALUES (v_ref_id, 'OLD', 'TRANSFER', 'OUT', v_total_g, v_consumed_cost,
          v_wac_now, v_wac_now * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
      WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  -- 4) INSERT NEW/IN
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price,
                           wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'NEW', 'TRANSFER', 'IN', v_total_g, v_consumed_cost,
          v_wac_now, v_wac_now * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.pid, v_item.qty);
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_item.pid, 'NEW', v_item.qty, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
  END LOOP;

  -- 5) UPDATE wac_state — sync ทั้ง qty และ value (value ตามต้นทุน lot จริง)
  UPDATE wac_state
  SET old_gold_g = GREATEST(0, COALESCE(old_gold_g, 0) - v_total_g),
      old_value  = GREATEST(0, COALESCE(old_value, 0)  - v_consumed_cost),
      new_gold_g = COALESCE(new_gold_g, 0) + v_total_g,
      new_value  = COALESCE(new_value, 0)  + v_consumed_cost,
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Transfer สำเร็จ',
    'ref_id', v_ref_id,
    'consumed_cost', v_consumed_cost,
    'old_wac_per_g', v_old_wac
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION transfer_old_to_new_tx(JSONB) TO authenticated;


-- ============================================================
-- ข้อ3) stock_out_old_tx — ตัดมูลค่า (old_value) + lock
--   R11.1: ต้นทุนที่ตัดเปลี่ยนจาก WAC เฉลี่ย → FIFO ราย lot (เหมือน transfer)
-- ============================================================
CREATE OR REPLACE FUNCTION stock_out_old_tx(p_items JSONB, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_total_g NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_weight NUMERIC;
  v_stock NUMERIC;
  v_old_wac NUMERIC;
  v_consumed_cost NUMERIC := 0;
  v_wac_now NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- [LOCK] serialize ทุก tx ที่แตะ wac/stock ผ่าน row นี้
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('SO', 'STOCK_OUT');

  -- ตรวจสินค้า + เช็คสต๊อกพอ (FOR UPDATE) — ห้าม mutate ก่อน validate ครบ
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT _gold_g(weight_baht) INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    SELECT qty INTO v_stock FROM stock_balances
      WHERE product_id = v_item.pid AND gold_type = 'OLD'
      FOR UPDATE;
    IF v_stock IS NULL OR v_stock < v_item.qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อก OLD ไม่พอ: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  -- ตัด lot FIFO ต่อ product → ต้นทุนจริงรวม (หลัง validate ผ่านครบแล้วเท่านั้น)
  -- [R16-4] ต้นทุน = FIFO ต่อกรัม (สูตรเดียวกับ PriceOut ที่หน้า Stock Old แสดง) — คำนวณก่อน INSERT แถว OUT
  --   lot ยังตัดเหมือนเดิมเพื่อเก็บจำนวนคงเหลือต่อสินค้า แต่ไม่ใช้ต้นทุนจาก lot แล้ว
  v_consumed_cost := _old_fifo_out_cost(v_total_g);
  v_wac_now := get_wac_per_g();
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    PERFORM _consume_old_lots(v_item.pid, v_item.qty);
  END LOOP;
  v_old_wac := CASE WHEN v_total_g > 0 THEN v_consumed_cost / v_total_g ELSE 0 END;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  -- [R16-5] wac_per_g = WAC ของร้าน ณ ตอนทำรายการ (ก่อนตัดออก)
  VALUES (v_ref_id, 'OLD', 'STOCK_OUT', 'OUT', v_total_g, v_consumed_cost,
          v_wac_now, v_wac_now * 15, TRUE, v_user_id, p_note, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.pid, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.pid AND gold_type = 'OLD';
  END LOOP;

  -- ตัดทั้งน้ำหนักและมูลค่า (เดิมตัดแค่น้ำหนัก)
  UPDATE wac_state
  SET old_gold_g = GREATEST(0, COALESCE(old_gold_g, 0) - v_total_g),
      old_value  = GREATEST(0, COALESCE(old_value, 0)  - v_consumed_cost),
      updated_at = NOW()
  WHERE id = 1;

  RETURN jsonb_build_object('success', true, 'message', 'Stock Out สำเร็จ', 'ref_id', v_ref_id,
                            'consumed_cost', v_consumed_cost, 'old_wac_per_g', v_old_wac);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION stock_out_old_tx(JSONB, TEXT) TO authenticated;


-- ============================================================
-- ข้อ4) recompute_diffs — Bangkok + ใช้วันที่ของ tx จริง (เดิมใส่ NOW() ทำแถวเก่าย้ายมาวันนี้)
--   ⚠️ ใช้ WAC + ราคาขายปัจจุบัน (เหมือนชีท) → แถวเก่าสะท้อนเรตปัจจุบัน
--   เรียกเอง: SELECT recompute_diffs('2026-01-01','2026-12-31');
-- ============================================================
CREATE OR REPLACE FUNCTION recompute_diffs(p_from DATE, p_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_t RECORD;
  v_wac NUMERIC := get_wac_per_g();
  v_wac_tx NUMERIC;
  v_s1b NUMERIC;
  v_new_g NUMERIC;
  v_old_g NUMERIC;
  v_new_sell NUMERIC;
  v_old_sell NUMERIC;
  v_cost_diff NUMERIC;
  v_diff NUMERIC;
  v_n INT := 0;
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager/Admin only');
  END IF;

  FOR v_t IN
    SELECT id, type, date, COALESCE(premium,0) AS premium, COALESCE(ex_fee,0) AS ex_fee,
           COALESCE(switch_fee,0) AS switch_fee, COALESCE(sell_1baht,0) AS sell_1baht,
           COALESCE(diff_amount,0) AS diff_amount
    FROM transactions
    WHERE type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW')
      AND status IN ('COMPLETED','PAID')
      AND (date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_from AND p_to
  LOOP
    v_s1b := _diff_sell_1baht(v_t.sell_1baht);

    SELECT COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)),0) INTO v_new_g
    FROM transaction_items ti JOIN products p ON p.id = ti.product_id
    WHERE ti.tx_id = v_t.id AND ti.item_role = 'NEW';

    IF v_t.type = 'SELL' THEN
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_cost_diff := v_new_g * v_wac;
      v_diff := v_new_sell + v_t.premium - v_cost_diff;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'SELL', v_new_sell, 0, 0, v_t.premium, v_cost_diff, 0, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=0, switch_fee=0,
        premium=EXCLUDED.premium, cost_diff=EXCLUDED.cost_diff, cost_old_gold=0, diff=EXCLUDED.diff;

    ELSIF v_t.type = 'TRADEIN' THEN
      SELECT COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)),0) INTO v_old_g
      FROM transaction_items ti JOIN products p ON p.id = ti.product_id
      WHERE ti.tx_id = v_t.id AND ti.item_role IN ('OLD','FOC');
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_old_sell := _diff_items_sell_total(v_t.id, ARRAY['OLD','FOC'], v_s1b);
      -- [R15-9] cost_diff = (ใหม่−เก่า)g × WAC "ณ ตอนทำรายการ" — ใช้ snapshot wac_per_g ที่ confirm
      --   บันทึกไว้ใน stock_moves ของบิลนี้ (แถวเก่าที่ไม่มี snapshot → WAC ปัจจุบัน)
      SELECT NULLIF(sm.wac_per_g, 0) INTO v_wac_tx
      FROM stock_moves sm
      WHERE sm.ref_id = v_t.id AND sm.gold_type = 'NEW' AND sm.direction = 'OUT'
      ORDER BY sm.date DESC LIMIT 1;
      v_cost_diff := (v_new_g - v_old_g) * COALESCE(v_wac_tx, v_wac);
      v_diff := v_new_sell + v_t.premium - v_cost_diff - v_old_sell;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'TRADEIN', v_new_sell, 0, 0, v_t.premium, v_cost_diff, v_old_sell, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=0, switch_fee=0,
        premium=EXCLUDED.premium, cost_diff=EXCLUDED.cost_diff, cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSIF v_t.type = 'EXCHANGE' THEN
      v_new_sell := _diff_items_sell_total(v_t.id, ARRAY['NEW'], v_s1b);
      v_old_sell := _diff_items_sell_total(v_t.id, ARRAY['OLD','SWITCH','FREE_EX'], v_s1b);
      v_diff := v_new_sell + v_t.ex_fee + v_t.switch_fee + v_t.premium - v_old_sell;
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'EXCHANGE', v_new_sell, v_t.ex_fee, v_t.switch_fee, v_t.premium, 0, v_old_sell, v_diff, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=EXCLUDED.sell_value, ex_fee=EXCLUDED.ex_fee,
        switch_fee=EXCLUDED.switch_fee, premium=EXCLUDED.premium, cost_diff=0,
        cost_old_gold=EXCLUDED.cost_old_gold, diff=EXCLUDED.diff;

    ELSE  -- WITHDRAW
      INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
      VALUES (v_t.id, 'WITHDRAW', 0, 0, 0, 0, 0, 0, 0, v_t.date)
      ON CONFLICT (tx_id) DO UPDATE SET sell_value=0, ex_fee=0, switch_fee=0, premium=0,
        cost_diff=0, cost_old_gold=0, diff=0;
    END IF;

    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'recomputed', v_n);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION recompute_diffs(DATE, DATE) TO authenticated;


-- ============================================================
-- ข้อ5) open_shift — กันเปิดกะซ้ำวันเดียวกัน (Bangkok) + role check
--   คืน already_open:true ให้ frontend ปิด modal เงียบๆ (auth.js รองรับแล้ว)
-- ============================================================
CREATE OR REPLACE FUNCTION open_shift(
  p_user_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id TEXT;
  v_cb_id TEXT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- เปิดกะแทนคนอื่นได้เฉพาะ Manager/Admin
  IF p_user_id IS DISTINCT FROM current_user_id() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'เปิดกะได้เฉพาะของตัวเอง');
  END IF;

  -- ‼️ กันเปิดกะซ้ำ (วันนี้ตามเวลาไทย) — กัน float โดนหัก 2 รอบ
  IF EXISTS (
    SELECT 1 FROM user_cashbook
    WHERE user_id = p_user_id AND type = 'OPEN_SHIFT'
      AND (date AT TIME ZONE 'Asia/Bangkok')::date = (NOW() AT TIME ZONE 'Asia/Bangkok')::date
  ) THEN
    RETURN jsonb_build_object('success', false, 'already_open', true, 'message', 'เปิดกะวันนี้ไปแล้ว');
  END IF;

  IF NOT check_shop_balance('CASH', 'LAK', NULL, p_amount) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในร้านไม่พอ โปรดติดต่อ Admin');
  END IF;

  v_id := 'SHIFT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS')
          || '-' || substring(p_user_id::text, 1, 4);
  v_cb_id := 'CB-' || v_id;

  INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
  VALUES (v_cb_id, 'OPEN_SHIFT', -p_amount, 'LAK', 'CASH',
          'Open shift: ' || v_id, NOW(), p_user_id);

  INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
  VALUES (v_id, p_user_id, 'OPEN_SHIFT', p_amount, 'LAK', 'CASH', 'Open shift', NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION open_shift(UUID, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ5) submit_close_report — กันส่งปิดกะซ้ำวันเดียวกัน (Bangkok)
-- ============================================================
CREATE OR REPLACE FUNCTION submit_close_report(
  p_date DATE,
  p_cash_summary JSONB,
  p_bank_summary JSONB,
  p_gold_summary JSONB,
  p_total_tx INT,
  p_total_amount NUMERIC,
  p_note TEXT
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_close_id TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  -- ‼️ กันปิดกะซ้ำ: มี PENDING/APPROVED ของวันนี้ (เวลาไทย) อยู่แล้ว → ไม่รับซ้ำ
  IF EXISTS (
    SELECT 1 FROM closes
    WHERE user_id = v_user_id
      AND status IN ('PENDING', 'APPROVED')
      AND (date AT TIME ZONE 'Asia/Bangkok')::date = (NOW() AT TIME ZONE 'Asia/Bangkok')::date
  ) THEN
    RETURN jsonb_build_object('success', false, 'message',
      '❌ ส่งปิดกะของวันนี้ไปแล้ว (รออนุมัติหรืออนุมัติแล้ว)');
  END IF;

  v_close_id := 'CL-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  INSERT INTO closes (id, user_id, date, status, total_tx, total_amount,
                      cash_summary, bank_summary, gold_summary, note)
  VALUES (v_close_id, v_user_id, NOW(), 'PENDING', p_total_tx, p_total_amount,
          p_cash_summary, p_bank_summary, p_gold_summary, p_note);

  INSERT INTO notifications (type, message, target_role, tab, created_by_id)
  VALUES ('CLOSE', 'New CLOSE shift waiting for approval: ' || v_close_id, 'Manager', 'close', v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_close_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION submit_close_report(DATE, JSONB, JSONB, JSONB, INT, NUMERIC, TEXT) TO authenticated;


-- ============================================================
-- [R13-7 → R15-4] helper: มูลค่าต่อชิ้น (PriceIn) ของทองเก่าที่รับมา — ใช้ตีมูลค่าเข้า Stock OLD
--   BUYBACK          → เงินที่ร้านจ่ายจริงต่อชิ้น (price_per_unit ที่ confirm_buyback_tx บันทึกไว้)
--   TRADEIN/EXCHANGE → ราคาขายต่อชิ้นตามตารางสินค้า ณ ตอนทำรายการ = _diff_sell_price(สินค้า, sell_1baht ของบิล)
--                      (price_per_unit ที่ confirm_tradein/exchange_tx บันทึกไว้ [R15-4])
--   fallback แถวเก่าที่ price_per_unit ว่าง/0:
--     BUYBACK          → transactions.price ÷ จำนวนชิ้นของบิลนั้น
--     TRADEIN/EXCHANGE → _diff_sell_price(สินค้า, sell_1baht ของบิลต้นทาง) (ไม่มี → ราคาขายล่าสุด)
--   internal เท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION _ug_cost_per_unit(p_ug_id BIGINT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(ug.price_per_unit, 0),
    CASE
      WHEN ug.type = 'BUYBACK' THEN
        COALESCE((SELECT t.price FROM transactions t WHERE t.id = ug.ref_tx_id), 0)
        / NULLIF((SELECT SUM(u2.qty) FROM user_gold_received u2
                  WHERE u2.ref_tx_id = ug.ref_tx_id), 0)
      WHEN ug.type IN ('TRADEIN', 'EXCHANGE') THEN
        _diff_sell_price(ug.product_id,
          _diff_sell_1baht(COALESCE((SELECT t.sell_1baht FROM transactions t WHERE t.id = ug.ref_tx_id), 0)))
      ELSE 0 END,
    0)
  FROM user_gold_received ug
  WHERE ug.id = p_ug_id;
$$;
REVOKE ALL ON FUNCTION _ug_cost_per_unit(BIGINT) FROM PUBLIC, anon, authenticated;


-- ============================================================
-- ข้อ5) approve_close_report — FOR UPDATE + guard เฉพาะ PENDING
--   (กัน approve ซ้ำ / approve แถวที่ Sales ยกเลิกไปแล้ว / 2 Manager กดพร้อมกัน)
--   [R13-7] ตีราคาทองเก่าเข้าสต๊อกด้วย "เงินที่จ่ายซื้อจริง" แทนราคาขาย
-- ============================================================
CREATE OR REPLACE FUNCTION approve_close_report(
  p_close_id TEXT,
  p_decision TEXT,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_close_user UUID;
  v_close_date DATE;
  v_close_ts TIMESTAMPTZ;
  v_cur_status close_status;
  v_nickname TEXT;
  v_new_status close_status;
  v_total_qty NUMERIC;
  v_total_gold_g NUMERIC;
  v_total_value NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
  v_cash RECORD;
  v_uc_id TEXT;
  v_cb_id TEXT;
  v_cash_moved JSONB := '{}'::jsonb;
  v_wac_now NUMERIC := 0;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  v_new_status := CASE WHEN p_decision = 'APPROVE'
                       THEN 'APPROVED'::close_status
                       ELSE 'REJECTED'::close_status END;

  -- [LOCK] + อ่านสถานะปัจจุบัน
  SELECT c.user_id, c.date::date, c.date, c.status, u.nickname
    INTO v_close_user, v_close_date, v_close_ts, v_cur_status, v_nickname
    FROM closes c JOIN users u ON u.id = c.user_id
    WHERE c.id = p_close_id
    FOR UPDATE OF c;

  IF v_close_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Close not found');
  END IF;

  -- ‼️ ดำเนินการได้เฉพาะ PENDING เท่านั้น
  IF v_cur_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message',
      'รายการปิดกะนี้ถูกดำเนินการไปแล้ว (สถานะ ' || v_cur_status || ')');
  END IF;

  UPDATE closes SET status = v_new_status, approved_by_id = v_user_id,
                    approved_at = NOW(), approval_note = p_note
    WHERE id = p_close_id;

  IF v_new_status = 'REJECTED' THEN
    PERFORM _notify_user('WARNING', '❌ ปิดกะถูกปฏิเสธ: ' || p_close_id ||
                         CASE WHEN p_note IS NOT NULL THEN ' (' || p_note || ')' ELSE '' END,
                         v_close_user, 'close', NULL);
    RETURN jsonb_build_object('success', true);
  END IF;

  -- [LOCK] เฉพาะตอน APPROVE (materialize stock)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('CL', 'CLOSE');

  -- [R13-7 → R15-4] มูลค่าทองเก่าที่เข้าร้าน (PriceIn) — ดึงจาก user_gold_received.price_per_unit
  --   BUYBACK          → เงินที่จ่ายต่อชิ้น (confirm_buyback_tx บันทึก)
  --   TRADEIN/EXCHANGE → มูลค่าขายตอนทำรายการ = weight_baht × sell_1baht ของบิล (confirm_* บันทึก)
  --   แถวเก่าที่ยัง 0 → _ug_cost_per_unit คำนวณ fallback จากบิลต้นทางให้
  --   ‼️ ลำดับ: อ่าน (ยอดรวม + WAC ปัจจุบัน) ให้ครบก่อน แล้วค่อยเขียน stock_moves/lot/wac_state
  SELECT
    COALESCE(SUM(ug.qty), 0),
    COALESCE(SUM(ug.qty * _gold_g(p.weight_baht)), 0),
    COALESCE(SUM(ug.qty * _ug_cost_per_unit(ug.id)), 0)
    INTO v_total_qty, v_total_gold_g, v_total_value
  FROM user_gold_received ug
  JOIN products p ON p.id = ug.product_id
  WHERE ug.user_id = v_close_user
    AND ug.settled = FALSE
    AND ug.date <= v_close_ts;  -- [R16-2] เฉพาะที่รับมาก่อนกดปิดกะ (= ยอด Report ตอนนั้น)

  -- snapshot WAC ณ เวลาที่ทองเก่าเข้าร้าน (ก่อนบวกยอดนี้เข้า) — โชว์ใน detail ของแถว STOCK_IN
  v_wac_now := get_wac_per_g();

  IF v_total_qty > 0 THEN
    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
    VALUES (v_ref_id, 'OLD', 'STOCK_IN', 'IN', v_total_gold_g, v_total_value,
            v_wac_now, v_wac_now * 15, TRUE, v_close_user, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN
      SELECT product_id, SUM(qty) AS qty
      FROM user_gold_received
      WHERE user_id = v_close_user AND settled = FALSE AND date <= v_close_ts
      GROUP BY product_id
    LOOP
      INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.product_id, v_item.qty);

      INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
      VALUES (v_item.product_id, 'OLD', v_item.qty, NOW())
      ON CONFLICT (product_id, gold_type)
      DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
    END LOOP;

    -- [R13-7 → R15-4] lot ทองเก่า (FIFO): 1 lot ต่อ (product × PriceIn ต่อชิ้น)
    --   cost_per_g = PriceIn ต่อชิ้น ÷ น้ำหนักต่อชิ้น (Trade-in/Exchange = sell_1baht/15 ของบิล)
    --   Σ(qty × g/unit × cost_per_g) = Σ(qty × ต้นทุนต่อชิ้น) = v_total_value เป๊ะ
    INSERT INTO old_gold_lots (product_id, qty_in, qty_left, gold_g_per_unit, cost_per_g, source_ref, date)
    SELECT ug.product_id, SUM(ug.qty), SUM(ug.qty), _gold_g(p.weight_baht),
           _ug_cost_per_unit(ug.id) / (_gold_g(p.weight_baht)), p_close_id, NOW()
    FROM user_gold_received ug
    JOIN products p ON p.id = ug.product_id
    WHERE ug.user_id = v_close_user AND ug.settled = FALSE AND ug.date <= v_close_ts
    GROUP BY ug.product_id, p.weight_baht, _ug_cost_per_unit(ug.id);

    UPDATE wac_state
      SET old_gold_g = COALESCE(old_gold_g, 0) + v_total_gold_g,
          old_value  = COALESCE(old_value, 0) + v_total_value,
          updated_at = NOW()
      WHERE id = 1;

    UPDATE user_gold_received
      SET settled = TRUE, settled_at = NOW(), settled_close_id = p_close_id
      WHERE user_id = v_close_user AND settled = FALSE AND date <= v_close_ts;
  END IF;

  -- โอนเงินสดที่ Sales ถืออยู่ (user_cashbook method=CASH) เข้าร้านอัตโนมัติ
  FOR v_cash IN
    SELECT currency, SUM(amount) AS bal
    FROM user_cashbook
    WHERE user_id = v_close_user AND method = 'CASH'
      AND date <= v_close_ts  -- [R16-3] เฉพาะเงินก่อนกดปิดกะ (= ยอดที่ส่งปิดกะ / Report ตอนนั้น)
    GROUP BY currency
    HAVING SUM(amount) > 0
  LOOP
    v_uc_id := 'UC-CLS-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_cash.currency::text), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_close_user, 'CASH_OUT', -v_cash.bal, v_cash.currency, 'CASH', 'ปิดกะ โอนเข้าร้าน ' || p_close_id, NOW());

    v_cb_id := 'CB-CLS-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_cash.currency::text), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_cash.bal, v_cash.currency, 'CASH', 'ปิดกะ ' || p_close_id || ' โอนเงินสดจาก ' || v_nickname, NOW(), v_user_id);

    v_cash_moved := v_cash_moved || jsonb_build_object(v_cash.currency::text, v_cash.bal);
  END LOOP;

  -- [R16-1] เคลียร์ยอดโอน (method<>CASH) ในกระเป๋า Sales ให้เป็น 0 ด้วย
  --   เงินโอนเข้าบัญชีร้าน (cashbank) ตั้งแต่ตอนยืนยันบิลแล้ว → ลงแค่ user_cashbook ไม่แตะ cashbank
  --   เดิมกวาดเฉพาะ CASH → ยอดโอนค้างสะสมข้ามวัน ปิดกะวันถัดไปเลยเห็นยอดโอนของวันก่อนรวมมาด้วย
  FOR v_cash IN
    SELECT currency, method, bank_id, SUM(amount) AS bal
    FROM user_cashbook
    WHERE user_id = v_close_user AND method <> 'CASH'
      AND date <= v_close_ts  -- [R16-3]
    GROUP BY currency, method, bank_id
    HAVING SUM(amount) <> 0
  LOOP
    v_uc_id := 'UC-CLT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_cash.currency::text || COALESCE(v_cash.bank_id::text, '')), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, note, date)
    VALUES (v_uc_id, v_close_user, 'CASH_OUT', -v_cash.bal, v_cash.currency, v_cash.method, v_cash.bank_id, 'ปิดกะ เคลียร์ยอดโอน ' || p_close_id, NOW());
  END LOOP;

  PERFORM _notify_user('INFO', '✅ ปิดกะของคุณได้รับการอนุมัติ: ' || p_close_id,
                       v_close_user, 'close', NULL);

  RETURN jsonb_build_object(
    'success', true,
    'materialized_ref', CASE WHEN v_total_qty > 0 THEN v_ref_id ELSE NULL END,
    'materialized_qty', v_total_qty,
    'materialized_value', v_total_value,
    'cash_moved', v_cash_moved
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION approve_close_report(TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- ข้อ5) cancel_pending_close — RPC ใหม่ (แทนการ dbDelete จาก client)
--   ลบได้เฉพาะของตัวเอง + สถานะ PENDING เท่านั้น (กัน race กับ Manager approve)
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_pending_close(p_close_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id TEXT;
BEGIN
  DELETE FROM closes
  WHERE id = p_close_id
    AND user_id = current_user_id()
    AND status = 'PENDING'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message',
      'ไม่พบรายการปิดกะที่รออนุมัติ (อาจถูกอนุมัติ/ปฏิเสธไปแล้ว)');
  END IF;

  RETURN jsonb_build_object('success', true, 'id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION cancel_pending_close(TEXT) TO authenticated;


-- ============================================================
-- L2) transfer_user_cash_to_shop — เช็คเงินสดในกระเป๋าพอฝั่ง server ก่อนโอน
--   (base: เวอร์ชันล่าสุดจาก git a12fb4f — เช็คครบทุกสกุลก่อน ไม่พอ = ไม่ทำอะไรเลย)
--   ตัวที่ deploy อยู่อาจเป็นเวอร์ชันเก่าที่ไม่เช็ค → รันทับให้ชัวร์
-- ============================================================
CREATE OR REPLACE FUNCTION transfer_user_cash_to_shop(p_transfers JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_t RECORD;
  v_uc_id TEXT;
  v_cb_id TEXT;
  v_bal NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  -- รอบที่ 1: เช็คว่าเงินสดในกระเป๋าพอทุกสกุลก่อน (ถ้าไม่พอ → ไม่ทำอะไรเลย)
  FOR v_t IN SELECT (value->>'currency') AS currency, (value->>'amount')::numeric AS amount
             FROM jsonb_array_elements(p_transfers) LOOP
    IF v_t.amount <= 0 THEN CONTINUE; END IF;
    SELECT COALESCE(SUM(amount), 0) INTO v_bal
    FROM user_cashbook
    WHERE user_id = v_user_id AND method = 'CASH' AND currency = v_t.currency::currency_code;
    IF v_bal < v_t.amount THEN
      RETURN jsonb_build_object('success', false,
        'message', '❌ เงินสด ' || v_t.currency || ' ในกระเป๋าไม่พอ (มี ' || v_bal || ' ต้องการ ' || v_t.amount || ')');
    END IF;
  END LOOP;

  -- รอบที่ 2: หักจากกระเป๋า Sales แล้วเพิ่มเข้าร้าน
  FOR v_t IN SELECT (value->>'currency') AS currency, (value->>'amount')::numeric AS amount
             FROM jsonb_array_elements(p_transfers) LOOP
    IF v_t.amount <= 0 THEN CONTINUE; END IF;

    v_uc_id := 'UC-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_user_id, 'CASH_OUT', -v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer to shop', NOW());

    v_cb_id := 'CB-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer from user cash', NOW(), v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION transfer_user_cash_to_shop(JSONB) TO authenticated;


-- ============================================================
-- ข้อ6) get_diff_summary — total ไม่รวม BUYBACK (ตาม tab Diff ที่ตัด BUYBACK แล้ว)
--   rows ยังคืนครบทุก type (frontend กรองเอง)
-- ============================================================
CREATE OR REPLACE FUNCTION get_diff_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_rows JSONB;
  v_total NUMERIC := 0;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(diff), 0) INTO v_total
  FROM diffs WHERE date BETWEEN v_from AND v_to AND type <> 'BUYBACK';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tx_id', d.tx_id,
    'type', d.type,
    'sell_value', d.sell_value,
    'ex_fee', d.ex_fee,
    'switch_fee', d.switch_fee,
    'premium', d.premium,
    'cost_diff', d.cost_diff,
    'cost_old_gold', d.cost_old_gold,
    'diff', d.diff,
    'date', d.date
  ) ORDER BY d.date DESC), '[]'::jsonb)
  INTO v_rows
  FROM diffs d
  WHERE d.date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_diff_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- ข้อ7) create_exchange_tx
--   [R13] ยกเลิกการ validate บิล Free-Ex ทั้งฝั่ง server และ JS
--   → free_ex_bill_ref บันทึกไว้เป็นข้อมูลอ้างอิงอย่างเดียว
-- ============================================================
CREATE OR REPLACE FUNCTION create_exchange_tx(
  p_phone TEXT,
  p_bill_id TEXT,
  p_new_items JSONB,
  p_old_exchange_items JSONB,
  p_switch_items JSONB,
  p_free_ex_items JSONB,
  p_exchange_fee NUMERIC,
  p_switch_fee NUMERIC,
  p_premium NUMERIC,
  p_total NUMERIC,
  p_free_ex_bill_ref TEXT,
  p_sell_1baht NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_tx_id TEXT;
  v_user_id UUID;
  v_item JSONB;
  v_pid TEXT;
  v_qty NUMERIC;
  v_stock NUMERIC;
  v_ref_id TEXT;
  v_ref_date TIMESTAMPTZ;
  v_avail NUMERIC;
  v_fi RECORD;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    v_pid := v_item->>'productId';
    v_qty := (v_item->>'qty')::numeric;
    SELECT qty INTO v_stock FROM stock_balances WHERE product_id = v_pid AND gold_type = 'NEW';
    IF v_stock IS NULL OR v_stock < v_qty THEN
      RETURN jsonb_build_object('success', false, 'message', 'สต็อกไม่พอ ' || v_pid);
    END IF;
  END LOOP;

  -- [R13] ตัดการตรวจสอบบิล Free-Ex ออกทั้งหมดตามที่ user สั่ง
  --   (เดิมเช็ค: บิลมีจริง+ชำระแล้ว / ไม่เกิน 30 วัน / ยังไม่เคยใช้ / จำนวนชิ้นพอ)
  --   ตอนนี้ free_ex_bill_ref เป็นแค่ข้อมูลอ้างอิงที่บันทึกไว้เฉย ๆ ไม่บล็อกการทำรายการ

  v_tx_id := generate_tx_id('EXCHANGE');

  -- [R15-5] snapshot ราคาขาย ณ ตอนสร้างบิล
  INSERT INTO transactions (
    id, type, status, bill_id, phone, sale_user_id,
    ex_fee, switch_fee, premium, free_ex_bill_ref,
    total, currency, sell_1baht, date
  )
  VALUES (
    v_tx_id, 'EXCHANGE', 'PENDING', p_bill_id, p_phone, v_user_id,
    COALESCE(p_exchange_fee, 0), COALESCE(p_switch_fee, 0), COALESCE(p_premium, 0), NULLIF(TRIM(COALESCE(p_free_ex_bill_ref, '')), ''),
    p_total, 'LAK', _snapshot_sell_1baht(p_sell_1baht), NOW()
  );

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_new_items) LOOP
    INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
    VALUES (v_tx_id, 'NEW', v_item->>'productId', (v_item->>'qty')::numeric);
  END LOOP;

  IF p_old_exchange_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_old_exchange_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'OLD', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  IF p_switch_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_switch_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'SWITCH', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  IF p_free_ex_items IS NOT NULL THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_free_ex_items) LOOP
      INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
      VALUES (v_tx_id, 'FREE_EX', v_item->>'productId', (v_item->>'qty')::numeric);
    END LOOP;
  END IF;

  INSERT INTO notifications (type, message, target_role, tab, ref_tx_id, created_by_id)
  VALUES ('APPROVAL', 'New EXCHANGE waiting for review: ' || v_tx_id, 'Manager', 'exchange', v_tx_id, v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION create_exchange_tx(TEXT, TEXT, JSONB, JSONB, JSONB, JSONB, NUMERIC, NUMERIC, NUMERIC, NUMERIC, TEXT, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ8) add_cashbank_entry — เพิ่ม role check (Manager/Admin เท่านั้น)
--   (คงพฤติกรรม R10: balance check ก่อนหัก + Other Expense THB/USD เก็บเรท)
-- ============================================================
DROP FUNCTION IF EXISTS add_cashbank_entry(cashbank_type, NUMERIC, currency_code, TEXT, TEXT, TEXT, NUMERIC);
DROP FUNCTION IF EXISTS add_cashbank_entry(TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC);

CREATE OR REPLACE FUNCTION add_cashbank_entry(
  p_type TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_method TEXT,
  p_bank_name TEXT,
  p_note TEXT,
  p_rate NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bank_id UUID := NULL;
  v_cb_id TEXT;
  v_is_deduct BOOLEAN;
  v_eff_currency TEXT := UPPER(p_currency);
  v_eff_amount NUMERIC := ABS(COALESCE(p_amount, 0));
  v_rate NUMERIC := COALESCE(NULLIF(p_rate, 0), 1);
  v_note TEXT := COALESCE(p_note, '');
  v_sell_rate NUMERIC;
  v_orig_amount NUMERIC := ABS(COALESCE(p_amount, 0));
  v_signed_amount NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  -- ‼️ เงินร้านแตะได้เฉพาะ Manager/Admin (เดิมทุก authenticated เรียกตรงได้)
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;
  IF v_eff_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'จำนวนเงินต้องมากกว่า 0');
  END IF;

  -- หา bank_id (สร้างใหม่ถ้ายังไม่มี)
  IF p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    v_bank_id := _resolve_bank_id(p_bank_name);
  END IF;

  -- Other Expense กรอก THB/USD → เก็บสกุลตามจริง + เรทขายล่าสุดในคอลัมน์ rate
  IF p_type = 'OTHER_EXPENSE' AND v_eff_currency <> 'LAK' THEN
    SELECT CASE WHEN v_eff_currency = 'THB' THEN thb_sell
                WHEN v_eff_currency = 'USD' THEN usd_sell
                ELSE NULL END
      INTO v_sell_rate
    FROM price_rates
    ORDER BY date DESC
    LIMIT 1;

    IF v_sell_rate IS NULL OR v_sell_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยังไม่ได้ตั้งเรทขาย ' || v_eff_currency || '/LAK — โปรดตั้งเรทใน Price Rate ก่อนบันทึก Other Expense');
    END IF;

    v_rate := v_sell_rate;
    v_note := TRIM(BOTH ' ' FROM
              COALESCE(NULLIF(v_note, '') || ' ', '')
              || '[= ' || to_char(ROUND(v_orig_amount * v_sell_rate), 'FM999,999,999,990') || ' LAK @ '
              || to_char(v_sell_rate, 'FM999,999,990.######') || ' (Sell)]');
  END IF;

  v_is_deduct := p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE');

  -- เช็คยอดเงินในร้านพอก่อนหัก — ห้ามติดลบ
  IF v_is_deduct THEN
    IF NOT check_shop_balance(p_method, v_eff_currency::currency_code, v_bank_id, v_eff_amount) THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ เงินในร้านไม่พอ: ต้องจ่าย ' || to_char(v_eff_amount, 'FM999,999,999,990') || ' ' || v_eff_currency ||
        CASE WHEN UPPER(COALESCE(p_method, '')) = 'CASH' THEN ' (เงินสด)'
             ELSE ' (' || COALESCE(NULLIF(p_bank_name, ''), 'ธนาคาร') || ')' END);
    END IF;
  END IF;

  v_signed_amount := CASE WHEN v_is_deduct THEN -v_eff_amount ELSE v_eff_amount END;

  v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
             || '-' || substring(md5(random()::text), 1, 6);

  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type::cashbank_type, v_signed_amount, v_eff_currency::currency_code, v_rate,
          p_method, v_bank_id, v_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION add_cashbank_entry(TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, NUMERIC) TO authenticated;


-- ============================================================
-- ข้อ10) delete_tx — บล็อคทั้ง COMPLETED และ PARTIAL
--   (BUYBACK PARTIAL จ่ายเงินออกไปแล้วบางส่วน — ลบแล้วเงินค้างแบบไร้ที่มา)
-- ============================================================
CREATE OR REPLACE FUNCTION delete_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_payload JSONB;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;
  SELECT row_to_json(t)::jsonb INTO v_payload FROM transactions t WHERE id = p_tx_id;
  IF v_payload IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  -- [R12] แนบรายการทอง (เก่า/ใหม่) ลง payload เพื่อให้ Deleted List แสดงได้
  v_payload := v_payload || jsonb_build_object('items', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id', ti.product_id, 'qty', ti.qty, 'item_role', ti.item_role)), '[]'::jsonb)
    FROM transaction_items ti WHERE ti.tx_id = p_tx_id
  ));
  SELECT status INTO v_status FROM transactions WHERE id = p_tx_id;
  IF v_status IN ('COMPLETED', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot delete: transaction has payments (' || v_status || ')');
  END IF;
  INSERT INTO audit_logs (table_name, ref_id, action, payload, user_id)
  VALUES ('transactions', p_tx_id, 'DELETE', v_payload, v_user_id);
  DELETE FROM transactions WHERE id = p_tx_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION delete_tx(TEXT) TO authenticated;


-- ============================================================
-- ข้อ4) get_wealth_summary — ขอบวันแบบ Bangkok (เดิม CURRENT_DATE/::date = UTC
--   → วันตัดที่ 07:00 เช้าไทย, แถววันนี้โผล่ช้า และไม่ตรงกับ Box Wealth)
-- ============================================================
CREATE OR REPLACE FUNCTION get_wealth_summary(p_days INT DEFAULT 30)
RETURNS TABLE (date DATE, carry NUMERIC, net NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  RETURN QUERY
  WITH dates AS (
    SELECT generate_series(
      (v_today - (p_days - 1))::date,
      v_today,
      '1 day'::interval
    )::date AS d
  ),
  daily_net AS (
    SELECT d.d AS dd,
      COALESCE(
        -- [R12] ใช้ snapshot ที่ล็อกไว้ตอนเที่ยงคืน (cron) ก่อน — วันไหนไม่มีค่อยคำนวณสด
        (SELECT dr.net FROM daily_reports dr WHERE dr.date::date = d.d),
        (SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
         FROM stock_moves sm
         WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= d.d),
        0
      ) AS net_val
    FROM dates d
  )
  SELECT dn.dd AS date,
         COALESCE(LAG(dn.net_val) OVER (ORDER BY dn.dd), 0)::NUMERIC AS carry,
         dn.net_val AS net
  FROM daily_net dn
  ORDER BY dn.dd DESC;
END;
$$;
GRANT EXECUTE ON FUNCTION get_wealth_summary(INT) TO authenticated;


-- ============================================================
-- ข้อ6) get_dashboard_data — pl_diff ไม่รวม BUYBACK
--   (คงส่วนอื่นตาม R10: Other Expense รวมเป็น LAK ด้วย rate)
-- ============================================================
CREATE OR REPLACE FUNCTION get_dashboard_data(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_wac JSONB;
  v_pl_diff NUMERIC := 0;
  v_other_expense NUMERIC := 0;
  v_new_pieces NUMERIC := 0;
  v_new_g NUMERIC := 0;
  v_old_pieces NUMERIC := 0;
  v_old_g NUMERIC := 0;
  v_pend_pieces NUMERIC := 0;
  v_pend_g NUMERIC := 0;
  v_cash JSONB;
  v_banks JSONB;
  v_sales JSONB;
  v_buybacks JSONB;
  v_withdraws JSONB;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  -- [R15-1] WAC จากแหล่งเดียว — มี wac_per_g / wac_per_baht (×15 ไม่ปัดเศษ) มาให้ JS ใช้ตรง ๆ
  v_wac := get_wac_state();

  -- ‼️ P/L Diff ไม่รวม BUYBACK (ตามนโยบาย tab Diff)
  SELECT COALESCE(SUM(diff), 0) INTO v_pl_diff
  FROM diffs WHERE date BETWEEN v_from AND v_to AND type <> 'BUYBACK';

  SELECT COALESCE(SUM(ABS(amount) * COALESCE(rate, 1)), 0) INTO v_other_expense
  FROM cashbank WHERE type = 'OTHER_EXPENSE' AND date BETWEEN v_from AND v_to;

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * _gold_g(p.weight_baht)), 0)
  INTO v_new_pieces, v_new_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'NEW';

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * _gold_g(p.weight_baht)), 0)
  INTO v_old_pieces, v_old_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'OLD';

  -- [R14-2] ทองเก่าที่ Sales รับมาแล้วแต่ยังไม่ปิดกะ — ยังไม่เข้า stock_balances
  --   ‼️ นี่คือสาเหตุที่ TOTAL GOLD น้อยกว่าที่นับจากบิลจริง (materialize ตอน approve ปิดกะ)
  SELECT
    COALESCE(SUM(ug.qty), 0),
    COALESCE(SUM(ug.qty * _gold_g(p.weight_baht)), 0)
  INTO v_pend_pieces, v_pend_g
  FROM user_gold_received ug JOIN products p ON p.id = ug.product_id
  WHERE COALESCE(ug.settled, FALSE) = FALSE;

  SELECT COALESCE(jsonb_object_agg(currency, total), '{}'::jsonb) INTO v_cash FROM (
    SELECT currency::text, COALESCE(SUM(amount), 0) AS total
    FROM cashbank WHERE method = 'CASH' GROUP BY currency
  ) t;

  SELECT COALESCE(jsonb_object_agg(bank_name, balances), '{}'::jsonb) INTO v_banks FROM (
    SELECT b.name AS bank_name,
           COALESCE(
             jsonb_object_agg(cb.currency, COALESCE(cb.total, 0))
               FILTER (WHERE cb.currency IS NOT NULL),
             '{}'::jsonb
           ) AS balances
    FROM banks b
    LEFT JOIN (
      SELECT bank_id, currency::text AS currency, SUM(amount) AS total
      FROM cashbank
      WHERE method <> 'CASH' AND bank_id IS NOT NULL
      GROUP BY bank_id, currency
    ) cb ON cb.bank_id = b.id
    WHERE b.is_active = TRUE
    GROUP BY b.name
  ) t;

  SELECT jsonb_build_object(
    'sell', COALESCE(SUM(CASE WHEN type = 'SELL' THEN total ELSE 0 END), 0),
    'sell_count', COALESCE(SUM(CASE WHEN type = 'SELL' THEN 1 ELSE 0 END), 0),
    'tradein', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN total ELSE 0 END), 0),
    'tradein_count', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN 1 ELSE 0 END), 0),
    'exchange', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN total ELSE 0 END), 0),
    'exchange_count', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN 1 ELSE 0 END), 0)
  ) INTO v_sales
  FROM transactions
  WHERE type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1] นับ PARTIAL ให้ตรงตาราง JS
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_buybacks
  FROM transactions
  WHERE type = 'BUYBACK' AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1]
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_withdraws
  FROM transactions
  WHERE type = 'WITHDRAW' AND status IN ('COMPLETED', 'PAID', 'PARTIAL')  -- [R11.1]
    AND date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'wac', COALESCE(v_wac, '{}'::jsonb),
    'pl_diff', v_pl_diff,
    'other_expense', v_other_expense,
    'new_pieces', v_new_pieces,
    'new_g', v_new_g,
    'old_pieces', v_old_pieces,
    'old_g', v_old_g,
    'pending_old_pieces', v_pend_pieces,
    'pending_old_g', v_pend_g,
    'cash', v_cash,
    'banks', v_banks,
    'sales', v_sales,
    'buybacks', v_buybacks,
    'withdraws', v_withdraws
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_dashboard_data(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Accounting — get_incomplete_summary (แก้ buyback ไม่มีน้ำหนัก g)
--   เดิม gold_g = SUM(... ) FILTER (item_role='NEW') → buyback ที่มีแต่ item OLD
--   ได้ 0 g เสมอ. แก้: buyback ใช้ OLD, type อื่นใช้ NEW (ทองที่ออกจากสต๊อก)
--   + ตัดวันแบบ Asia/Bangkok ให้ตรงกับ get_dashboard_data
-- ============================================================
CREATE OR REPLACE FUNCTION get_incomplete_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  WITH tx_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, t.total,
           COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)) FILTER (
             WHERE (t.type = 'BUYBACK' AND ti.item_role = 'OLD')
                OR (t.type <> 'BUYBACK' AND ti.item_role = 'NEW')
           ), 0) AS gold_g
    FROM transactions t
    LEFT JOIN transaction_items ti ON ti.tx_id = t.id
    LEFT JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status NOT IN ('COMPLETED', 'PAID', 'REJECTED')
    GROUP BY t.id, t.type, t.total
  )
  SELECT jsonb_build_object(
    'total_money', COALESCE(SUM(total), 0),
    'total_gold_g', COALESCE(SUM(gold_g), 0),
    'sell',     jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='SELL'),0),     'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='SELL'),0),     'count', COUNT(*) FILTER (WHERE tx_type='SELL')),
    'tradein',  jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='TRADEIN'),0),  'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'),0),  'count', COUNT(*) FILTER (WHERE tx_type='TRADEIN')),
    'exchange', jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='EXCHANGE'),0), 'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE'),0), 'count', COUNT(*) FILTER (WHERE tx_type='EXCHANGE')),
    'withdraw', jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='WITHDRAW'),0), 'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='WITHDRAW'),0), 'count', COUNT(*) FILTER (WHERE tx_type='WITHDRAW')),
    'buyback',  jsonb_build_object('money', COALESCE(SUM(total) FILTER (WHERE tx_type='BUYBACK'),0),  'gold_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='BUYBACK'),0),  'count', COUNT(*) FILTER (WHERE tx_type='BUYBACK'))
  ) INTO v_result FROM tx_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_incomplete_summary(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Accounting — get_sales_gold_grams_v2 (ให้ตรง money ใน Box Sell)
--   เดิม status IN ('COMPLETED','PAID') + t.date::date (UTC)
--   → ไม่ sync กับ get_dashboard_data.sales (นับ PARTIAL + TZ ไทย)
--   → ต้นทุน/Diff ของ SELL เพี้ยนช่วงคาบเกี่ยววัน. แก้ให้เงื่อนไขตรงกัน
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_gold_grams_v2(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_result JSONB;
BEGIN
  WITH item_g AS (
    SELECT t.id AS tx_id, t.type AS tx_type, ti.item_role,
           SUM(ti.qty * _gold_g(p.weight_baht)) AS gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    GROUP BY t.id, t.type, ti.item_role
  )
  SELECT jsonb_build_object(
    'sell_new_g',     COALESCE(SUM(gold_g) FILTER (WHERE tx_type='SELL'     AND item_role='NEW'), 0),
    'tradein_new_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'  AND item_role='NEW'), 0),
    'tradein_old_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='TRADEIN'  AND item_role IN ('OLD','FOC')), 0),
    'exchange_new_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE' AND item_role='NEW'), 0),
    'exchange_old_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='EXCHANGE' AND item_role IN ('OLD','SWITCH','FREE_EX')), 0),
    'buyback_old_g',  COALESCE(SUM(gold_g) FILTER (WHERE tx_type='BUYBACK'  AND item_role='OLD'), 0),
    'withdraw_new_g', COALESCE(SUM(gold_g) FILTER (WHERE tx_type='WITHDRAW' AND item_role='NEW'), 0)
  ) INTO v_result FROM item_g;
  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION get_sales_gold_grams_v2(DATE, DATE) TO authenticated;


-- ============================================================
-- [R12] Wealth snapshot รายวัน (บันทึกยอดทองล็อกไว้ทุกเที่ยงคืนเวลาไทย)
--   daily_reports เก็บ net = ทองคงเหลือสะสม (g) สิ้นวันนั้น, carry = สิ้นวันก่อน
--   get_wealth_summary จะอ่าน snapshot ก่อน (วันไหนไม่มีค่อยคำนวณสด)
-- ============================================================
-- ให้แน่ใจว่าตารางมีคอลัมน์ + unique(date) สำหรับ upsert
ALTER TABLE daily_reports ADD COLUMN IF NOT EXISTS carry NUMERIC DEFAULT 0;
ALTER TABLE daily_reports ADD COLUMN IF NOT EXISTS net   NUMERIC DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS uq_daily_reports_date ON daily_reports(date);

-- ฟังก์ชันบันทึก snapshot ของ "วันที่ระบุ" (default = เมื่อวาน เวลาไทย
-- เพราะ cron รัน 00:05 เวลาไทย → บันทึกยอดสิ้นวันที่เพิ่งจบ)
CREATE OR REPLACE FUNCTION snapshot_daily_wealth(p_date DATE DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_date  DATE := COALESCE(p_date, ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 1));
  v_net   NUMERIC;
  v_carry NUMERIC;
BEGIN
  SELECT COALESCE(SUM(CASE WHEN direction='IN' THEN gold_g ELSE -gold_g END), 0) INTO v_net
    FROM stock_moves WHERE (date AT TIME ZONE 'Asia/Bangkok')::date <= v_date;
  SELECT COALESCE(SUM(CASE WHEN direction='IN' THEN gold_g ELSE -gold_g END), 0) INTO v_carry
    FROM stock_moves WHERE (date AT TIME ZONE 'Asia/Bangkok')::date <= v_date - 1;
  INSERT INTO daily_reports (date, carry, net) VALUES (v_date, v_carry, v_net)
  ON CONFLICT (date) DO UPDATE SET carry = EXCLUDED.carry, net = EXCLUDED.net;
END;
$$;
GRANT EXECUTE ON FUNCTION snapshot_daily_wealth(DATE) TO authenticated;

-- Backfill ครั้งเดียวตอน deploy: ล็อกยอด 60 วันย้อนหลัง (ไม่ทับของเดิมที่มีแล้ว)
INSERT INTO daily_reports (date, carry, net)
SELECT g::date AS d,
       COALESCE((SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
                 FROM stock_moves sm WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= g::date - 1), 0),
       COALESCE((SELECT SUM(CASE WHEN sm.direction='IN' THEN sm.gold_g ELSE -sm.gold_g END)
                 FROM stock_moves sm WHERE (sm.date AT TIME ZONE 'Asia/Bangkok')::date <= g::date), 0)
FROM generate_series(
       ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 60),
       ((NOW() AT TIME ZONE 'Asia/Bangkok')::date - 1),
       '1 day'::interval) g
ON CONFLICT (date) DO NOTHING;

-- ตั้ง pg_cron: รันทุกวัน 17:05 UTC = 00:05 เวลาไทย (บันทึกยอดของวันที่เพิ่งจบ)
-- ห่อด้วย exception handling: ถ้า pg_cron ไม่พร้อม (สิทธิ์/ยังไม่เปิด) จะแค่ SKIP
-- ไม่ทำให้ทั้งสคริปต์ rollback → ค่อยเปิด pg_cron ที่ Dashboard แล้วรันบล็อกนี้ซ้ำ
DO $cronsetup$
BEGIN
  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
  BEGIN
    PERFORM cron.unschedule('kpv-daily-wealth');   -- ถ้าเคยตั้งไว้ → ลบก่อน
  EXCEPTION WHEN OTHERS THEN NULL;                  -- ยังไม่เคยตั้ง → ข้าม
  END;
  PERFORM cron.schedule('kpv-daily-wealth', '5 17 * * *', 'SELECT snapshot_daily_wealth();');
  RAISE NOTICE '✅ ตั้ง pg_cron kpv-daily-wealth (00:05 เวลาไทย) สำเร็จ';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '⚠️ ข้ามการตั้ง pg_cron: %  → เปิด pg_cron ที่ Dashboard→Database→Extensions แล้วรันบล็อกนี้ใหม่', SQLERRM;
END
$cronsetup$;


-- ============================================================
-- [R12.1] Single-device session (1 user = 1 เครื่อง)
--   JS (auth.js) มีระบบ kick อยู่แล้ว: login เครื่องใหม่ → broadcast เตะเครื่องเก่า
--   + poll get_my_session ทุก 10 วิ — บล็อกนี้ ensure ฝั่ง DB ให้ครบ (idempotent)
-- ============================================================
ALTER TABLE users ADD COLUMN IF NOT EXISTS session_token TEXT;

CREATE OR REPLACE FUNCTION set_my_session(p_session TEXT)
RETURNS JSONB AS $$
DECLARE v_user_id UUID;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;
  UPDATE users SET session_token = p_session, updated_at = NOW() WHERE id = v_user_id;
  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION set_my_session(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_my_session()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_session TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('session_token', NULL);
  END IF;
  SELECT session_token INTO v_session FROM users WHERE id = v_user_id;
  RETURN jsonb_build_object('session_token', v_session);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('session_token', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_my_session() TO authenticated;


-- ============================================================
-- ============================================================
-- [R13] 2026-08-03 — รอบแก้ 13 (append ต่อท้าย R12.1 — รันทั้งไฟล์ได้เหมือนเดิม)
--   1) get_sales_gold_grams  — Old In ขาด SWITCH/FREE_EX (Exchange) → Report/Accounting เพี้ยน
--   2) get_history_txs       — เพิ่ม change_amount/price/balance/refs (เงินทอนต่อบิลอ่านค่าไม่ได้)
--   3) get_payment_channel_summary — ตารางช่องทางรับเงิน (Cash/BCEL/LDB/Other × LAK/THB/USD)
--   4) create_exchange_tx    — ตัดเงื่อนไขตรวจสอบบิล Free-Ex ออก (เก็บ ref ไว้เฉย ๆ)
-- ============================================================


-- ============================================================
-- [R13-1] get_sales_gold_grams — ทองเก่าเข้าต้องรวม SWITCH + FREE_EX ด้วย
--   เดิมนับแค่ OLD/FOC → Exchange ที่เป็น SWITCH/FREE_EX หายทั้งก้อน
--   ทำให้ tab Report: "OLD IN", "NET SELL", ตารางทองรายสินค้า ต่ำกว่าจริง
--   + นับ PARTIAL + ตัดวันแบบ Asia/Bangkok ให้ตรงกับ get_dashboard_data / v2
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_gold_grams(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sales_old_g NUMERIC := 0;
  v_sales_new_g NUMERIC := 0;
  v_bb_old_g NUMERIC := 0;
  v_wd_new_g NUMERIC := 0;
BEGIN
  SELECT
    COALESCE(SUM(CASE WHEN ti.item_role IN ('OLD','FOC','SWITCH','FREE_EX')
                      THEN ti.qty * _gold_g(p.weight_baht) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN ti.item_role = 'NEW'
                      THEN ti.qty * _gold_g(p.weight_baht) ELSE 0 END), 0)
  INTO v_sales_old_g, v_sales_new_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    AND (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to;

  SELECT COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)), 0) INTO v_bb_old_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type = 'BUYBACK' AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    AND ti.item_role = 'OLD'
    AND (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to;

  SELECT COALESCE(SUM(ti.qty * _gold_g(p.weight_baht)), 0) INTO v_wd_new_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type = 'WITHDRAW' AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    AND ti.item_role = 'NEW'
    AND (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to;

  RETURN jsonb_build_object(
    'sales_old_g', v_sales_old_g,
    'sales_new_g', v_sales_new_g,
    'buyback_old_g', v_bb_old_g,
    'withdraw_new_g', v_wd_new_g
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_sales_gold_grams(DATE, DATE) TO authenticated;


-- ============================================================
-- [R13-2] get_history_txs — เพิ่มฟิลด์ที่ฝั่ง JS ต้องใช้แต่เดิมไม่ส่งมา
--   change_amount (เงินทอนต่อบิล — เดิมไม่มี → History Sell แสดงไม่ได้)
--   price/balance (buyback), note, foc_bill_ref, foc_premium_deduct,
--   free_ex_bill_ref, withdraw_code
-- ============================================================
CREATE OR REPLACE FUNCTION get_history_txs(
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_limit INT DEFAULT 500
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF p_date_from IS NOT NULL THEN
    v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;
  IF p_date_to IS NOT NULL THEN
    v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'type', t.type,
    'status', t.status,
    'bill_id', t.bill_id,
    'phone', t.phone,
    'total', t.total,
    'paid', t.paid,
    'change_amount', COALESCE(t.change_amount, 0),
    'price', COALESCE(t.price, 0),
    'balance', COALESCE(t.balance, 0),
    'currency', t.currency,
    'sale_user_id', t.sale_user_id,
    'sale_nickname', u.nickname,
    'date', t.date,
    'diff', t.diff_amount,
    'ex_fee', t.ex_fee,
    'switch_fee', t.switch_fee,
    'premium', t.premium,
    'fee', t.fee,
    'note', t.note,
    'foc_bill_ref', t.foc_bill_ref,
    'foc_premium_deduct', COALESCE(t.foc_premium_deduct, 0),
    'free_ex_bill_ref', t.free_ex_bill_ref,
    'withdraw_code', t.withdraw_code,
    'items', (
      SELECT jsonb_agg(jsonb_build_object('productId', ti.product_id, 'qty', ti.qty, 'role', ti.item_role))
      FROM transaction_items ti WHERE ti.tx_id = t.id
    )
  ) ORDER BY t.date DESC), '[]'::jsonb)
  INTO v_result
  FROM transactions t
  LEFT JOIN users u ON u.id = t.sale_user_id
  WHERE (v_from IS NULL OR t.date >= v_from)
    AND (v_to IS NULL OR t.date <= v_to)
    AND (v_role <> 'Sales' OR t.sale_user_id = v_user_id)
  LIMIT p_limit;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_history_txs(DATE, DATE, INT) TO authenticated;


-- ============================================================
-- [R13-3] get_payment_channel_summary — ตาราง "ยอดเงินที่ได้รับจากการขาย"
--   / "ยอดเงินที่จ่าย Buyback" แยกช่องทาง × สกุลเงิน (ตามรูปที่ user ส่ง)
--   อ่านจาก transaction_payments (ของจริงต่อบิล) → ครอบคลุมทั้ง Sales/Manager/Admin
--   sales   = SELL + TRADEIN + EXCHANGE, buyback = BUYBACK, withdraw แยกไว้ต่างหาก
--   change  = เงินทอนรวม (LAK, เงินสด) ของบิลฝั่งขาย — เอาไปหักในแถวรวมฝั่ง JS
-- ============================================================
CREATE OR REPLACE FUNCTION get_payment_channel_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_blocks JSONB;
  v_change NUMERIC := 0;
BEGIN
  WITH pay AS (
    SELECT CASE t.type::text
             WHEN 'BUYBACK'  THEN 'buyback'
             WHEN 'WITHDRAW' THEN 'withdraw'
             ELSE 'sales'
           END AS grp_key,
           CASE
             WHEN UPPER(COALESCE(tp.method, 'CASH')) = 'CASH' THEN 'Cash'
             WHEN b.name ILIKE 'BCEL%' THEN 'BCEL'
             WHEN b.name ILIKE 'LDB%'  THEN 'LDB'
             ELSE 'Other'
           END AS channel,
           tp.currency::text AS cur,
           tp.amount AS amount
    FROM transaction_payments tp
    JOIN transactions t ON t.id = tp.tx_id
    LEFT JOIN banks b ON b.id = tp.bank_id
    WHERE t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
      AND t.type IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK')
      AND (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to
  ),
  grp AS (
    SELECT grp_key, channel,
           COALESCE(SUM(amount) FILTER (WHERE cur = 'LAK'), 0) AS lak,
           COALESCE(SUM(amount) FILTER (WHERE cur = 'THB'), 0) AS thb,
           COALESCE(SUM(amount) FILTER (WHERE cur = 'USD'), 0) AS usd
    FROM pay GROUP BY grp_key, channel
  ),
  byg AS (
    SELECT grp_key,
           jsonb_object_agg(channel, jsonb_build_object('LAK', lak, 'THB', thb, 'USD', usd)) AS blk
    FROM grp GROUP BY grp_key
  )
  SELECT COALESCE(jsonb_object_agg(grp_key, blk), '{}'::jsonb) INTO v_blocks FROM byg;

  SELECT COALESCE(SUM(COALESCE(t.change_amount, 0)), 0) INTO v_change
  FROM transactions t
  WHERE t.type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND t.status IN ('COMPLETED', 'PAID', 'PARTIAL')
    AND (t.date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN p_date_from AND p_date_to;

  RETURN jsonb_build_object(
    'sales',    COALESCE(v_blocks->'sales',    '{}'::jsonb),
    'buyback',  COALESCE(v_blocks->'buyback',  '{}'::jsonb),
    'withdraw', COALESCE(v_blocks->'withdraw', '{}'::jsonb),
    'change_lak', v_change
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_payment_channel_summary(DATE, DATE) TO authenticated;


-- [R13-4] create_exchange_tx — ตัดเงื่อนไขตรวจสอบบิล Free-Ex ออก
--   แก้ในตัวฟังก์ชันเดิมด้านบน (หัวข้อ "ข้อ7") ไม่ได้ประกาศซ้ำที่นี่


-- ============================================================
-- [R13-5] get_live_report (Box Wealth) — เพิ่ม "เงินคิดเป็นทอง"
--   เดิมคืนแต่ทองในสต๊อก (g) → Box Wealth ไม่ผูกกับเงินเลย
--   ใหม่: ความมั่งคั่งรวม (g) = ทองในสต๊อก + (เงินทั้งหมด ÷ ราคาทอง 1 g)
--     เงินทั้งหมด (LAK) = cashbank ทุกช่องทาง/ทุกสกุล (‼️ [R14-4] ไม่รวมเงินสดที่ Sales ถือ)
--       - [R14-1] THB/USD แปลงเป็น LAK ด้วย "เรทขาย" ล่าสุด (thb_sell/usd_sell) ตามที่ user สั่ง
--         (เดิมใช้เรทรับซื้อ thb_buy/usd_buy → ตีมูลค่าต่ำกว่าจริง)
--       - [R14-4] ตัด user_cashbook ออกทั้งหมด — เงินที่ Sales ถือยังไม่นับเป็นของร้าน
--         (กฎเดียวกับทองเก่ารอปิดกะ) → เข้ายอดตอน approve ปิดกะแล้วเงินไหลเข้า cashbank
--     ราคาทอง 1 g = sell_1baht ล่าสุด ÷ 15
--   คืนทั้งยอดวันนี้และยอดสิ้นวันก่อน เพื่อให้ Box คำนวณส่วนต่างได้
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_today DATE;
  v_today_start TIMESTAMPTZ;
  v_gold_now NUMERIC := 0;
  v_gold_prev NUMERIC := 0;
  v_money_now NUMERIC := 0;
  v_money_prev NUMERIC := 0;
  v_s1b NUMERIC := 0;
  v_price_g NUMERIC := 0;
  v_thb_sell NUMERIC := 0;
  v_usd_sell NUMERIC := 0;
  v_money_g_now NUMERIC := 0;
  v_money_g_prev NUMERIC := 0;
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_today_start := (v_today::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';

  -- ทองในสต๊อก (g)
  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_gold_now FROM stock_moves;
  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_gold_prev FROM stock_moves WHERE date < v_today_start;

  -- เรทแลกเงิน + ราคาทองล่าสุด
  SELECT COALESCE(thb_sell, 0), COALESCE(usd_sell, 0) INTO v_thb_sell, v_usd_sell
  FROM price_rates ORDER BY date DESC LIMIT 1;
  SELECT COALESCE(sell_1baht, 0) INTO v_s1b FROM pricing ORDER BY date DESC LIMIT 1;
  v_price_g := CASE WHEN COALESCE(v_s1b, 0) > 0 THEN v_s1b / 15.0 ELSE 0 END;

  -- เงินทั้งหมด (LAK) — ปัจจุบัน
  SELECT COALESCE(SUM(amount * CASE currency
           WHEN 'THB' THEN COALESCE(NULLIF(v_thb_sell, 0), 1)
           WHEN 'USD' THEN COALESCE(NULLIF(v_usd_sell, 0), 1)
           ELSE 1 END), 0)
    INTO v_money_now FROM cashbank;
  -- [R14-4] ‼️ ไม่นับเงินสดที่ Sales ถืออยู่ (user_cashbook) — ตรงกับกฎของทองเก่า:
  --   ของที่ยังอยู่ในมือ Sales ยังไม่ถือเป็นทรัพย์สินร้าน จนกว่า Manager จะ approve ปิดกะ
  --   (ตอน approve เงินถูกกวาดเข้า cashbank → ถึงจะโผล่ในยอดนี้)

  -- เงินทั้งหมด (LAK) — สิ้นวันก่อน
  SELECT COALESCE(SUM(amount * CASE currency
           WHEN 'THB' THEN COALESCE(NULLIF(v_thb_sell, 0), 1)
           WHEN 'USD' THEN COALESCE(NULLIF(v_usd_sell, 0), 1)
           ELSE 1 END), 0)
    INTO v_money_prev FROM cashbank WHERE date < v_today_start;
  -- [R14-4] ไม่นับ user_cashbook เช่นกัน (ดูเหตุผลด้านบน)

  IF v_price_g > 0 THEN
    v_money_g_now  := v_money_now  / v_price_g;
    v_money_g_prev := v_money_prev / v_price_g;
  END IF;

  RETURN jsonb_build_object(
    -- ‼️ คงคีย์เดิมไว้ (ทองล้วน) เพื่อไม่ให้ของเดิมที่อ่านอยู่พัง
    'netTotal', v_gold_now,
    'carryForward', v_gold_prev,
    'diff', v_gold_now - v_gold_prev,
    -- ใหม่: ฝั่งเงิน + ความมั่งคั่งรวม
    'goldPricePerG', v_price_g,
    'moneyLak', v_money_now,
    'moneyLakPrev', v_money_prev,
    'moneyGoldG', v_money_g_now,
    'moneyGoldGPrev', v_money_g_prev,
    'wealthG', v_gold_now + v_money_g_now,
    'wealthGPrev', v_gold_prev + v_money_g_prev,
    'wealthDiff', (v_gold_now + v_money_g_now) - (v_gold_prev + v_money_g_prev)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;


-- ============================================================
-- [R15-7] get_stock_summary — คืนทั้ง carry (ตั้งต้น) และ balance (ปัจจุบัน) แยกกันชัด ๆ
--   ‼️ ต้นเหตุ "ปิดกะแล้ว Old Gold เข้า แต่ทองตั้งต้นติดลบ Balance = 0":
--     RPC เดิมคืน carry = stock_balances − net(วันนี้) = ยอดตั้งต้น
--     แต่ JS (R14-2) เข้าใจว่า carry = ยอดปัจจุบัน → คิด ตั้งต้น = carry − IN + OUT อีกรอบ
--     → ตั้งต้น = 0 − IN (ติดลบ) และ Balance โชว์ = carry = 0
--   แก้: คืน carry = ตั้งต้น, balance = stock_balances.qty (ปัจจุบัน), in/out = วันนี้
--        JS ใช้ตรง ๆ: ตั้งต้น = carry ; Balance = balance (ไม่คำนวณซ้อน)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_stock_summary(p_gold_type gold_type)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_carry JSONB;
  v_balance JSONB;
  v_in JSONB;
  v_out JSONB;
  v_today_local DATE;
BEGIN
  v_today_local := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;

  SELECT COALESCE(jsonb_object_agg(product_id, total_qty), '{}'::jsonb)
  INTO v_in
  FROM (
    SELECT smi.product_id, SUM(smi.qty) AS total_qty
    FROM stock_move_items smi
    JOIN stock_moves sm ON sm.id = smi.move_id
    WHERE sm.gold_type = p_gold_type
      AND sm.direction = 'IN'
      AND (sm.date AT TIME ZONE 'Asia/Bangkok')::date = v_today_local
    GROUP BY smi.product_id
  ) t;

  SELECT COALESCE(jsonb_object_agg(product_id, total_qty), '{}'::jsonb)
  INTO v_out
  FROM (
    SELECT smi.product_id, SUM(smi.qty) AS total_qty
    FROM stock_move_items smi
    JOIN stock_moves sm ON sm.id = smi.move_id
    WHERE sm.gold_type = p_gold_type
      AND sm.direction = 'OUT'
      AND (sm.date AT TIME ZONE 'Asia/Bangkok')::date = v_today_local
    GROUP BY smi.product_id
  ) t;

  -- ยอดปัจจุบัน (stock_balances)
  SELECT COALESCE(jsonb_object_agg(product_id, qty), '{}'::jsonb)
  INTO v_balance
  FROM stock_balances
  WHERE gold_type = p_gold_type;

  -- ยอดตั้งต้น = ปัจจุบัน − net(วันนี้)
  SELECT COALESCE(jsonb_object_agg(product_id, opening_qty), '{}'::jsonb)
  INTO v_carry
  FROM (
    SELECT
      sb.product_id,
      sb.qty - COALESCE((
        SELECT SUM(CASE WHEN sm.direction = 'IN' THEN smi.qty ELSE -smi.qty END)
        FROM stock_moves sm
        JOIN stock_move_items smi ON smi.move_id = sm.id
        WHERE sm.gold_type = p_gold_type
          AND smi.product_id = sb.product_id
          AND (sm.date AT TIME ZONE 'Asia/Bangkok')::date = v_today_local
      ), 0) AS opening_qty
    FROM stock_balances sb
    WHERE sb.gold_type = p_gold_type
  ) t;

  RETURN jsonb_build_object('carry', v_carry, 'balance', v_balance, 'in', v_in, 'out', v_out);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_stock_summary(gold_type) TO authenticated;


-- ============================================================
-- [R15-1] get_stock_move_detail — WAC/บาท = WAC/g × 15 เสมอ
--   เดิม: COALESCE(sm.wac_per_baht, wac_per_g × 15) — คอลัมน์ default 0 (ไม่ใช่ NULL)
--   → แถวที่บันทึกแค่ wac_per_g (เช่น STOCK_IN OLD ตอนปิดกะรุ่นเก่า) โชว์ WAC/บาท = 0
--   ตอนนี้คิดจาก wac_per_g ที่เก็บไว้เสมอ (คอลัมน์ wac_per_baht เหลือไว้เป็นข้อมูลอ้างอิง)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text);
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text, text);

CREATE OR REPLACE FUNCTION public.get_stock_move_detail(
  p_ref_id TEXT,
  p_gold_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_move RECORD;
  v_items JSONB;
  v_payments JSONB;
  v_price_per_g NUMERIC := 0;
  v_price_per_baht NUMERIC := 0;
  v_wac_per_g NUMERIC := 0;
  v_wac_per_baht NUMERIC := 0;
BEGIN
  SELECT sm.id, sm.ref_id, sm.gold_type, sm.type, sm.direction,
         sm.gold_g, sm.price, sm.wac_per_g, sm.wac_per_baht,
         sm.date, sm.note
    INTO v_move
    FROM stock_moves sm
    WHERE sm.ref_id = p_ref_id
      AND (p_gold_type IS NULL OR sm.gold_type::text = p_gold_type)
    ORDER BY CASE WHEN sm.direction = 'IN' THEN 0 ELSE 1 END,
             sm.date ASC
    LIMIT 1;

  IF v_move.id IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object('productId', smi.product_id, 'qty', smi.qty)
           ORDER BY smi.product_id
         ), '[]'::jsonb)
    INTO v_items
    FROM stock_move_items smi
    WHERE smi.move_id = v_move.id;

  IF v_move.gold_g > 0 THEN
    v_price_per_g := COALESCE(v_move.price, 0) / v_move.gold_g;
    v_price_per_baht := v_price_per_g * 15;
  END IF;

  -- WAC/g ที่ snapshot ไว้ตอนทำรายการ → WAC/บาท คูณ 15 จากค่าไม่ปัดเศษ
  v_wac_per_g := COALESCE(v_move.wac_per_g, 0);
  IF v_wac_per_g = 0 AND COALESCE(v_move.wac_per_baht, 0) <> 0 THEN
    v_wac_per_g := v_move.wac_per_baht / 15.0;   -- แถวเก่าที่มีแต่ /บาท
  END IF;
  v_wac_per_baht := v_wac_per_g * 15;

  -- payments: ผูกผ่าน ref_tx_id ตรง ๆ หรือ [ref:..] ใน note (STOCK_IN/TRANSFER/bootstrap)
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'type', cb.type,
             'method', cb.method,
             'bank', COALESCE(b.name, ''),
             'currency', cb.currency,
             'amount', cb.amount,
             'rate', COALESCE(cb.rate, 1),
             'lak', cb.amount * COALESCE(cb.rate, 1)
           )
           ORDER BY cb.date ASC, cb.id ASC
         ), '[]'::jsonb)
    INTO v_payments
    FROM cashbank cb
    LEFT JOIN banks b ON b.id = cb.bank_id
    WHERE cb.ref_tx_id = p_ref_id
       OR cb.note LIKE '%[ref:' || p_ref_id || ']%';

  RETURN jsonb_build_object(
    'found', true,
    'ref_id', v_move.ref_id,
    'gold_type', v_move.gold_type,
    'type', v_move.type,
    'direction', v_move.direction,
    'gold_g', v_move.gold_g,
    'price', v_move.price,
    'price_per_g', v_price_per_g,
    'price_per_baht', v_price_per_baht,
    'wac_per_g', v_wac_per_g,
    'wac_per_baht', v_wac_per_baht,
    'date', v_move.date,
    'note', v_move.note,
    'items', v_items,
    'payments', v_payments
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_stock_move_detail(text, text) TO authenticated;


-- ============================================================
-- [R13-6] get_stock_moves — NEW: หักต้นทุนตอนขายออกด้วย "ต้นทุน" ไม่ใช่ "ราคาขาย"
--   ‼️ ต้นเหตุที่ WAC เพี้ยน:
--     confirm_sell/tradein/exchange/withdraw_tx เก็บ stock_moves.price ของแถว OUT
--     = v_total (ยอดที่ลูกค้าจ่าย = ราคาขาย) ไม่ใช่ต้นทุน
--     แต่หน้า Stock(NEW)/tab WAC คิด "มูลค่าคงเหลือ = Σprice(IN) − Σprice(OUT)"
--     → หักด้วยราคาขาย (รวมกำไร) ทุกบิล ⇒ มูลค่าต่ำกว่าจริง ⇒ WAC/g ต่ำกว่าจริง
--   [R13-8] แก้ที่ต้นทางแล้ว (confirm_* เขียน price = ต้นทุน) แต่ยังต้องเก็บบล็อกนี้ไว้
--     เพราะ "แถวเก่า" ที่บันทึกราคาขายไปแล้วไม่ได้ backfill (user สั่งไม่ต้อง)
--   แก้ตอนอ่าน (ไม่แตะข้อมูลเดิม): OUT ของ NEW ใช้ wac_per_g × gold_g
--     (แต่ละแถวมี snapshot wac_per_g ณ เวลาทำรายการอยู่แล้ว)
--     แถวเก่าที่ wac_per_g ว่าง/0 → fallback ใช้ price เดิม
--     แถวใหม่ (R13-8) ค่าทั้งสองเท่ากันอยู่แล้ว → ไม่มีผลอะไร
--   ผลลัพธ์: tab WAC จะตรงกับ wac_state (Dashboard/Accounting) ที่หักด้วย WAC×g อยู่แล้ว
--   คืนฟิลด์ 'salePrice' เพิ่มไว้ เผื่ออยากโชว์ยอดขายคู่กัน
--   ‼️ ฝั่ง OLD คงเดิม (คิด FIFO จากราคา IN ตอนอ่าน — ถูกตามหลักอยู่แล้ว)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_stock_moves(
  p_gold_type gold_type,
  p_date_from date DEFAULT NULL,
  p_date_to date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_today_local DATE;
  v_from DATE;
  v_to DATE;
  v_prev_w NUMERIC := 0;
  v_prev_c NUMERIC := 0;
  v_moves JSONB;

  -- FIFO state (สำหรับ OLD)
  v_fifo JSONB := '[]'::jsonb;
  v_row RECORD;
  v_results JSONB := '[]'::jsonb;
  v_unit NUMERIC;
  v_remaining NUMERIC;
  v_cost NUMERIC;
  v_head_qty NUMERIC;
  v_head_unit NUMERIC;
  v_display_price NUMERIC;
  v_row_date DATE;
BEGIN
  v_today_local := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_from := COALESCE(p_date_from, v_today_local);
  v_to := COALESCE(p_date_to, v_today_local);

  ----------------------------------------------------------------
  -- NEW gold: IN = ต้นทุนซื้อเข้าจริง / OUT = WAC × น้ำหนัก (fallback: price)
  ----------------------------------------------------------------
  IF p_gold_type = 'NEW' THEN
    SELECT
      COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0),
      COALESCE(SUM(CASE WHEN direction = 'IN'
                        THEN COALESCE(price, 0)
                        ELSE -COALESCE(NULLIF(wac_per_g, 0) * gold_g, price, 0) END), 0)
    INTO v_prev_w, v_prev_c
    FROM stock_moves
    WHERE gold_type = p_gold_type
      AND (date AT TIME ZONE 'Asia/Bangkok')::date < v_from;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', ref_id, 'type', type, 'dir', direction,
      'goldG', gold_g,
      'price', CASE WHEN direction = 'IN'
                    THEN COALESCE(price, 0)
                    ELSE COALESCE(NULLIF(wac_per_g, 0) * gold_g, price, 0) END,
      -- ค่าดิบที่เก็บในตาราง: แถวก่อน R13-8 = ราคาขาย / ตั้งแต่ R13-8 = ต้นทุน (เท่ากับ price ด้านบน)
      'rawPrice', COALESCE(price, 0),
      'date', date, 'note', note
    ) ORDER BY date), '[]'::jsonb)
    INTO v_moves
    FROM stock_moves
    WHERE gold_type = p_gold_type
      AND (date AT TIME ZONE 'Asia/Bangkok')::date BETWEEN v_from AND v_to;

    RETURN jsonb_build_object('prevW', v_prev_w, 'prevC', v_prev_c, 'moves', v_moves);
  END IF;

  ----------------------------------------------------------------
  -- OLD gold: FIFO compute price (per gold_g, ไม่ break ต่อ product)
  ----------------------------------------------------------------
  FOR v_row IN
    SELECT id, ref_id, type, direction, gold_g, COALESCE(price, 0) AS price, date, note
    FROM stock_moves
    WHERE gold_type = 'OLD'
    ORDER BY date ASC, id ASC
  LOOP
    v_row_date := (v_row.date AT TIME ZONE 'Asia/Bangkok')::date;

    IF v_row.direction = 'IN' THEN
      v_unit := CASE WHEN v_row.gold_g > 0
                     THEN v_row.price / v_row.gold_g
                     ELSE 0 END;
      v_fifo := v_fifo || jsonb_build_array(jsonb_build_object(
        'qty', v_row.gold_g,
        'unit', v_unit
      ));
      v_display_price := v_row.price;
    ELSE
      v_remaining := v_row.gold_g;
      v_cost := 0;
      WHILE v_remaining > 0 AND jsonb_array_length(v_fifo) > 0 LOOP
        v_head_qty := (v_fifo->0->>'qty')::numeric;
        v_head_unit := (v_fifo->0->>'unit')::numeric;
        IF v_head_qty <= v_remaining THEN
          v_cost := v_cost + v_head_qty * v_head_unit;
          v_remaining := v_remaining - v_head_qty;
          v_fifo := v_fifo - 0;
        ELSE
          v_cost := v_cost + v_remaining * v_head_unit;
          v_fifo := jsonb_set(v_fifo, ARRAY['0','qty'],
                              to_jsonb(v_head_qty - v_remaining));
          v_remaining := 0;
        END IF;
      END LOOP;
      v_display_price := v_cost;
    END IF;

    -- prev/results split
    IF v_row_date < v_from THEN
      IF v_row.direction = 'IN' THEN
        v_prev_w := v_prev_w + v_row.gold_g;
        v_prev_c := v_prev_c + v_display_price;
      ELSE
        v_prev_w := v_prev_w - v_row.gold_g;
        v_prev_c := v_prev_c - v_display_price;
      END IF;
    ELSIF v_row_date <= v_to THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'id', v_row.ref_id,
        'type', v_row.type,
        'dir', v_row.direction,
        'goldG', v_row.gold_g,
        'price', v_display_price,
        'date', v_row.date,
        'note', v_row.note
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('prevW', v_prev_w, 'prevC', v_prev_c, 'moves', v_results);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_stock_moves(gold_type, date, date) TO authenticated;


-- ============================================================
-- [R15-6] ล้างเศษน้ำหนัก 1 กรัม (1.0000005 g) ในข้อมูลเดิม — แตะเฉพาะ "น้ำหนัก" ไม่แตะมูลค่า
--   1) stock_moves.gold_g = Σ(qty × _gold_g) จาก stock_move_items (เฉพาะแถวที่มี items และต่างกัน < 0.01 g)
--      → get_stock_moves (FIFO ของ OLD คิด unit = price ÷ gold_g) ไม่เหลือเศษทศนิยมจาก 1.0000005
--   2) old_gold_lots.gold_g_per_unit → _gold_g ; ปรับ cost_per_g ให้มูลค่า lot เท่าเดิมเป๊ะ
-- ============================================================
UPDATE stock_moves sm
SET gold_g = t.g
FROM (
  SELECT smi.move_id, SUM(smi.qty * _gold_g(p.weight_baht)) AS g
  FROM stock_move_items smi JOIN products p ON p.id = smi.product_id
  GROUP BY smi.move_id
) t
WHERE t.move_id = sm.id
  AND sm.gold_g IS DISTINCT FROM t.g
  AND ABS(COALESCE(sm.gold_g, 0) - t.g) < 0.01;

UPDATE old_gold_lots l
SET cost_per_g = CASE WHEN _gold_g(p.weight_baht) > 0
                      THEN (l.gold_g_per_unit * l.cost_per_g) / _gold_g(p.weight_baht)
                      ELSE l.cost_per_g END,
    gold_g_per_unit = _gold_g(p.weight_baht)
FROM products p
WHERE p.id = l.product_id
  AND l.gold_g_per_unit IS DISTINCT FROM _gold_g(p.weight_baht)
  AND ABS(l.gold_g_per_unit - _gold_g(p.weight_baht)) < 0.01;

-- ============================================================
-- [R15-8d] ตีมูลค่าย้อนหลัง: ทองเก่า Trade-in/Exchange ที่ price_per_unit ถูกบันทึกด้วยสูตร
--   weight_baht × sell_1baht (R15-4 รุ่นแรก — 1 กรัม = 3,227,349.47 ไม่ลงตัว)
--   → ปรับเป็น _diff_sell_price(สินค้า, sell_1baht ของบิล) ให้เหมือนรายการใหม่
--   ครอบคลุม: user_gold_received (ยังไม่ปิดกะ + ปิดแล้ว), old_gold_lots, stock_moves (แถว STOCK_IN OLD
--   ของปิดกะนั้น — จับคู่ด้วย date เดียวกับ lot เพราะ approve สร้างทั้งคู่ใน tx เดียว NOW() เท่ากัน), wac_state.old_value
--   รันซ้ำได้: แถวที่ค่าตรงแล้วจะถูกข้าม (CONTINUE)
--   ‼️ เฉพาะบิลที่มี sell_1baht > 0 (บิลก่อน R15-5 ไม่มี → ไม่แตะ ตามที่ตกลงว่าไม่ย้อนแก้ของเก่า)
-- ============================================================
DO $$
DECLARE
  r RECORD;
  v_new NUMERIC;
  v_delta NUMERIC;
  v_lot_date TIMESTAMPTZ;
BEGIN
  FOR r IN
    SELECT ug.id, ug.product_id, ug.qty, ug.price_per_unit AS old_ppu,
           COALESCE(ug.settled, FALSE) AS settled, ug.settled_close_id, t.sell_1baht
    FROM user_gold_received ug
    JOIN transactions t ON t.id = ug.ref_tx_id
    WHERE ug.type IN ('TRADEIN', 'EXCHANGE')
      AND COALESCE(t.sell_1baht, 0) > 0
    ORDER BY ug.id
  LOOP
    v_new := _diff_sell_price(r.product_id, r.sell_1baht);
    CONTINUE WHEN r.old_ppu IS NOT DISTINCT FROM v_new;

    UPDATE user_gold_received SET price_per_unit = v_new WHERE id = r.id;

    IF r.settled AND r.settled_close_id IS NOT NULL THEN
      v_delta := r.qty * (v_new - COALESCE(r.old_ppu, 0));

      -- lot ของปิดกะนั้น สินค้าเดียวกัน ที่ยังถือต้นทุนเก่าอยู่ (ชิ้นถัดไปของ lot เดียวกันจะไม่ match ซ้ำ)
      UPDATE old_gold_lots l
        SET cost_per_g = v_new / NULLIF(l.gold_g_per_unit, 0)
        WHERE l.source_ref = r.settled_close_id
          AND l.product_id = r.product_id
          AND ABS(l.cost_per_g * l.gold_g_per_unit - COALESCE(r.old_ppu, 0)) < 0.01;

      SELECT MIN(l.date) INTO v_lot_date FROM old_gold_lots l WHERE l.source_ref = r.settled_close_id;

      UPDATE stock_moves sm
        SET price = COALESCE(sm.price, 0) + v_delta
        WHERE sm.gold_type = 'OLD' AND sm.type = 'STOCK_IN' AND sm.direction = 'IN'
          AND v_lot_date IS NOT NULL AND sm.date = v_lot_date;

      UPDATE wac_state
        SET old_value = COALESCE(old_value, 0) + v_delta, updated_at = NOW()
        WHERE id = 1;
    END IF;
  END LOOP;
END $$;


-- ============================================================
-- [R15-6] sync น้ำหนักใน wac_state ให้ตรงกับ stock_balances × _gold_g (ล้างเศษ 0.0001 g เดิม)
--   แตะเฉพาะ "น้ำหนัก" (new_gold_g/old_gold_g) — มูลค่า (new_value/old_value) ไม่แตะ
--   รันซ้ำได้: ถ้าตรงอยู่แล้วก็ไม่เปลี่ยนอะไร
-- ============================================================
UPDATE wac_state w
SET new_gold_g = COALESCE((SELECT SUM(sb.qty * _gold_g(p.weight_baht))
                           FROM stock_balances sb JOIN products p ON p.id = sb.product_id
                           WHERE sb.gold_type = 'NEW'), 0),
    old_gold_g = COALESCE((SELECT SUM(sb.qty * _gold_g(p.weight_baht))
                           FROM stock_balances sb JOIN products p ON p.id = sb.product_id
                           WHERE sb.gold_type = 'OLD'), 0),
    updated_at = NOW()
WHERE w.id = 1
  AND (w.new_gold_g IS DISTINCT FROM COALESCE((SELECT SUM(sb.qty * _gold_g(p.weight_baht))
                                               FROM stock_balances sb JOIN products p ON p.id = sb.product_id
                                               WHERE sb.gold_type = 'NEW'), 0)
    OR w.old_gold_g IS DISTINCT FROM COALESCE((SELECT SUM(sb.qty * _gold_g(p.weight_baht))
                                               FROM stock_balances sb JOIN products p ON p.id = sb.product_id
                                               WHERE sb.gold_type = 'OLD'), 0));


-- ============================================================
-- [R16-1] ล้างยอดโอนที่ค้างในกระเป๋า Sales จากกะที่ approve ไปแล้ว (ก่อนมี R16-1)
--   ต่อ user: รวมแถว method<>CASH ที่ date <= เวลา approve ปิดกะล่าสุด → ลงแถวหักล้างให้เป็น 0
--   แถวหักล้างลงวันที่ = approved_at → รันซ้ำได้ (รอบสองยอดรวมเป็น 0 แล้วจะถูกข้าม)
--   รายการโอนหลังปิดกะล่าสุด (กะปัจจุบัน / กะที่ยังไม่ได้ approve) ไม่แตะ
-- ============================================================
DO $r16$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    WITH last_close AS (
      SELECT user_id, MAX(approved_at) AS at
      FROM closes
      WHERE status = 'APPROVED' AND approved_at IS NOT NULL
      GROUP BY user_id
    )
    SELECT ucb.user_id, ucb.currency, ucb.method, ucb.bank_id, lc.at, SUM(ucb.amount) AS bal
    FROM user_cashbook ucb
    JOIN last_close lc ON lc.user_id = ucb.user_id
    WHERE ucb.method <> 'CASH' AND ucb.date <= lc.at
    GROUP BY ucb.user_id, ucb.currency, ucb.method, ucb.bank_id, lc.at
    HAVING SUM(ucb.amount) <> 0
  LOOP
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, note, date)
    VALUES ('UC-CLT-FIX-' || substring(md5(random()::text || r.user_id::text || COALESCE(r.bank_id::text, '') || r.currency::text), 1, 10),
            r.user_id, 'CASH_OUT', -r.bal, r.currency, r.method, r.bank_id,
            'R16-1 เคลียร์ยอดโอนค้างจากกะที่ปิดแล้ว', r.at);
  END LOOP;
END $r16$;


-- ============================================================
-- [R16-4] ปรับแถวเดิม: price ของ TRANSFER / STOCK_OUT (OLD OUT) = FIFO ต่อกรัม (= PriceOut ที่หน้าจอแสดง)
--   TRANSFER → แถว NEW IN (ref เดียวกัน) = ค่าเดียวกัน ; wac_state ปรับตามส่วนต่าง
--     new_value += Δ (เฉพาะ TRANSFER) ; old_value −= Δ (ตัดมูลค่าออกจาก OLD ตามจริง)
--   FIFO ไม่ขึ้นกับ price ของแถว OUT → อัปเดตระหว่างเดินได้ ; รันซ้ำได้ (Δ = 0 ถูกข้าม)
-- ============================================================
DO $r16b$
DECLARE
  v_qty NUMERIC[] := '{}';
  v_unit NUMERIC[] := '{}';
  v_head INT := 1;
  v_row RECORD;
  v_remaining NUMERIC;
  v_cost NUMERIC;
  v_take NUMERIC;
  v_delta NUMERIC;
BEGIN
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  FOR v_row IN
    SELECT id, ref_id, type, direction, gold_g, COALESCE(price, 0) AS price
    FROM stock_moves
    WHERE gold_type = 'OLD'
    ORDER BY date ASC, id ASC
  LOOP
    IF v_row.direction = 'IN' THEN
      v_qty := v_qty || v_row.gold_g;
      v_unit := v_unit || CASE WHEN v_row.gold_g > 0 THEN v_row.price / v_row.gold_g ELSE 0 END;
      CONTINUE;
    END IF;

    v_remaining := v_row.gold_g;
    v_cost := 0;
    WHILE v_remaining > 0 AND v_head <= COALESCE(array_length(v_qty, 1), 0) LOOP
      v_take := LEAST(v_qty[v_head], v_remaining);
      v_cost := v_cost + v_take * v_unit[v_head];
      v_qty[v_head] := v_qty[v_head] - v_take;
      v_remaining := v_remaining - v_take;
      IF v_qty[v_head] <= 0 THEN v_head := v_head + 1; END IF;
    END LOOP;

    CONTINUE WHEN v_row.type NOT IN ('TRANSFER', 'STOCK_OUT');
    v_delta := v_cost - v_row.price;
    CONTINUE WHEN ABS(v_delta) < 0.005;

    UPDATE stock_moves SET price = v_cost WHERE id = v_row.id;

    IF v_row.type = 'TRANSFER' THEN
      UPDATE stock_moves SET price = v_cost
        WHERE ref_id = v_row.ref_id AND gold_type = 'NEW' AND type = 'TRANSFER' AND direction = 'IN';
      UPDATE wac_state SET new_value = COALESCE(new_value, 0) + v_delta, updated_at = NOW() WHERE id = 1;
    END IF;
    UPDATE wac_state SET old_value = COALESCE(old_value, 0) - v_delta, updated_at = NOW() WHERE id = 1;
  END LOOP;
END $r16b$;


-- ============================================================
-- [R16-5] ปรับ "WAC ณ เวลาทำรายการ" ของแถวเดิม STOCK_IN (NEW) / TRANSFER / STOCK_OUT
--   เดิมเก็บมูลค่า/g ของรายการเอง → คำนวณ WAC ย้อนหลังด้วยการไล่ stock_moves ทั้งหมด (NEW+OLD)
--   ตามเวลา: WAC ก่อนรายการ = Σมูลค่า ÷ Σกรัม ของทุกแถวก่อนหน้า (IN +price / OUT −price)
--   (wac_state เริ่มจาก 0 ตอน reset และทุกการเปลี่ยนผ่าน stock_moves → ไล่ซ้ำได้ค่าเดียวกัน)
--   แถวที่เวลาเดียวกัน (คู่ TRANSFER OLD OUT/NEW IN) ใช้ WAC ก่อนกลุ่มนั้น
--   แตะแค่คอลัมน์แสดงผล wac_per_g/wac_per_baht ของ 3 ประเภทนี้ (ไม่มีสูตรไหนใช้คำนวณต่อ) ; รันซ้ำได้
-- ============================================================
DO $r16c$
DECLARE
  v_row RECORD;
  v_g NUMERIC := 0;
  v_v NUMERIC := 0;
  v_prev_date TIMESTAMPTZ := NULL;
  v_wac_before NUMERIC := 0;
BEGIN
  FOR v_row IN
    SELECT id, type, gold_type, direction, gold_g, COALESCE(price, 0) AS price, date, wac_per_g
    FROM stock_moves
    ORDER BY date ASC, id ASC
  LOOP
    IF v_prev_date IS DISTINCT FROM v_row.date THEN
      v_wac_before := CASE WHEN v_g > 0 THEN v_v / v_g ELSE 0 END;
      v_prev_date := v_row.date;
    END IF;

    IF (v_row.type = 'STOCK_IN' AND v_row.gold_type = 'NEW') OR v_row.type IN ('TRANSFER', 'STOCK_OUT') THEN
      IF ABS(COALESCE(v_row.wac_per_g, 0) - v_wac_before) >= 0.005 THEN
        UPDATE stock_moves SET wac_per_g = v_wac_before, wac_per_baht = v_wac_before * 15
          WHERE id = v_row.id;
      END IF;
    END IF;

    IF v_row.direction = 'IN' THEN
      v_g := v_g + COALESCE(v_row.gold_g, 0);
      v_v := v_v + v_row.price;
    ELSE
      v_g := v_g - COALESCE(v_row.gold_g, 0);
      v_v := v_v - v_row.price;
    END IF;
  END LOOP;
END $r16c$;


-- ============================================================
-- [R14-2] 🔍 DIAGNOSTIC — ตรวจว่า "ทอง" แต่ละที่ตรงกันมั้ย
--   รันได้ตลอด (SELECT ล้วน ไม่แก้ข้อมูล) — รันทั้งไฟล์ก็แค่พ่นผลลัพธ์ออกมา
--   อ่านผล:
--     balances_g   = ที่ tab Stock (NEW/OLD) และกล่อง TOTAL GOLD ใช้  (stock_balances)
--     moves_net_g  = ที่ Box Wealth / tab Wealth ใช้                  (stock_moves สะสม)
--     pending_g    = ทองเก่าที่ Sales ถือ ยังไม่ปิดกะ                  (user_gold_received settled=false)
--     wac_state_g  = ตัวเลขที่กล่อง WAC ใช้
--   ‼️ balances_g กับ moves_net_g ต้องเท่ากัน ถ้าต่าง = สองตารางหลุด sync ต้อง recompute
--   ‼️ pending_g ไม่อยู่ในทั้ง 2 ตัว (ตั้งใจ — เข้าสต๊อกตอน Manager approve ปิดกะ)
-- ============================================================
SELECT jsonb_build_object(
  'balances_g', (
    SELECT jsonb_object_agg(gt, g) FROM (
      SELECT sb.gold_type::text AS gt, SUM(sb.qty * _gold_g(p.weight_baht)) AS g
      FROM stock_balances sb JOIN products p ON p.id = sb.product_id
      GROUP BY sb.gold_type) t),
  'moves_net_g', (
    SELECT jsonb_object_agg(gt, g) FROM (
      SELECT sm.gold_type::text AS gt,
             SUM(CASE WHEN sm.direction = 'IN' THEN sm.gold_g ELSE -sm.gold_g END) AS g
      FROM stock_moves sm GROUP BY sm.gold_type) t),
  'pending_g', COALESCE((
    SELECT SUM(ug.qty * _gold_g(p.weight_baht))
    FROM user_gold_received ug JOIN products p ON p.id = ug.product_id
    WHERE COALESCE(ug.settled, FALSE) = FALSE), 0),
  'pending_by_user', COALESCE((
    SELECT jsonb_object_agg(nick, g) FROM (
      SELECT COALESCE(u.nickname, ug.user_id::text) AS nick,
             SUM(ug.qty * _gold_g(p.weight_baht)) AS g
      FROM user_gold_received ug
      JOIN products p ON p.id = ug.product_id
      LEFT JOIN users u ON u.id = ug.user_id
      WHERE COALESCE(ug.settled, FALSE) = FALSE
      GROUP BY 1) t), '{}'::jsonb),
  'wac_state_g', (SELECT jsonb_build_object('new_g', new_gold_g, 'old_g', old_gold_g,
                                            'total_g', COALESCE(new_gold_g,0) + COALESCE(old_gold_g,0))
                  FROM wac_state WHERE id = 1),
  'balances_by_product', (
    SELECT jsonb_object_agg(k, qty) FROM (
      SELECT sb.gold_type::text || '-' || sb.product_id AS k, SUM(sb.qty) AS qty
      FROM stock_balances sb GROUP BY 1) t),
  'pending_by_product', COALESCE((
    SELECT jsonb_object_agg(product_id, qty) FROM (
      SELECT ug.product_id, SUM(ug.qty) AS qty
      FROM user_gold_received ug
      WHERE COALESCE(ug.settled, FALSE) = FALSE
      GROUP BY 1) t), '{}'::jsonb),
  -- ---- ฝั่งเงิน ----
  --   shop_money = เงินของร้านจริง (cashbank) = ที่ Box Wealth ใช้
  --   sales_cash = เงินสดที่ Sales ถืออยู่ — [R14-4] ไม่นับเข้า Wealth จนกว่าจะปิดกะ
  'shop_money', COALESCE((
    SELECT jsonb_object_agg(cur, amt) FROM (
      SELECT currency::text AS cur, SUM(amount) AS amt FROM cashbank GROUP BY 1) t), '{}'::jsonb),
  'sales_cash', COALESCE((
    SELECT jsonb_object_agg(cur, amt) FROM (
      SELECT currency::text AS cur, SUM(amount) AS amt
      FROM user_cashbook WHERE method = 'CASH' GROUP BY 1) t), '{}'::jsonb),
  'sales_cash_by_user', COALESCE((
    SELECT jsonb_object_agg(nick, amt) FROM (
      SELECT COALESCE(u.nickname, ucb.user_id::text) AS nick, SUM(ucb.amount) AS amt
      FROM user_cashbook ucb LEFT JOIN users u ON u.id = ucb.user_id
      WHERE ucb.method = 'CASH' AND ucb.currency = 'LAK'
      GROUP BY 1) t), '{}'::jsonb)
) AS gold_diagnostic;
