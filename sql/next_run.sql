-- ============================================================
-- next_run.sql — Round 7.5 (2026-05-25)
-- ============================================================
-- 1) admin_ref_counter — counter table สำหรับ TF/CL ref_id
-- 2) _next_admin_ref(prefix, op) — atomic increment + format SE26000001 style
-- 3) transfer_old_to_new_tx → ref_id = TF26000001
--                              + SELECT FOR UPDATE wac_state (lock concurrent)
-- 4) approve_close_report → ref_id = CL26000001
--                            + SELECT FOR UPDATE wac_state
-- 5) check_duplicate_bill_id(p_tx_id, p_bill_id) — แจ้ง Manager+Admin
--    ตอน create/update tx ถ้ามี bill_id ซ้ำตลอดกาล
-- ============================================================


-- ============================================================
-- 0) เพิ่ม enum value 'BILL_DUP' ใน notification_type (ถ้าเป็น enum)
--    PG14+ allows ALTER TYPE ADD VALUE in transaction
-- ============================================================
DO $$
DECLARE
  v_typname TEXT;
BEGIN
  SELECT typname INTO v_typname FROM pg_type
    WHERE typname IN ('notification_type','notif_type') LIMIT 1;
  IF v_typname IS NOT NULL THEN
    EXECUTE format('ALTER TYPE %I ADD VALUE IF NOT EXISTS ''BILL_DUP''', v_typname);
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- ถ้า type ไม่มี (text column) ก็ผ่าน
  NULL;
END$$;


-- ============================================================
-- 1) admin_ref_counter + RLS
--    เข้าถึงผ่าน _next_admin_ref (SECURITY DEFINER) เท่านั้น
--    → ENABLE RLS + REVOKE จาก authenticated เพื่อกัน client tampering
--    (pattern เดียวกับ bill_sequence)
-- ============================================================
CREATE TABLE IF NOT EXISTS admin_ref_counter (
  op_type   TEXT     NOT NULL,
  year      INT      NOT NULL,
  last_seq  INT      NOT NULL DEFAULT 0,
  PRIMARY KEY (op_type, year)
);

ALTER TABLE admin_ref_counter ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON admin_ref_counter FROM authenticated;
REVOKE ALL ON admin_ref_counter FROM anon;


-- ============================================================
-- 2) _next_admin_ref — atomic counter → "TF26000001"
-- ============================================================
CREATE OR REPLACE FUNCTION public._next_admin_ref(p_prefix TEXT, p_op TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_year INT := EXTRACT(YEAR FROM (NOW() AT TIME ZONE 'Asia/Bangkok'))::INT;
  v_yy   INT := MOD(v_year, 100);
  v_seq  INT;
BEGIN
  INSERT INTO admin_ref_counter (op_type, year, last_seq)
  VALUES (p_op, v_year, 1)
  ON CONFLICT (op_type, year)
  DO UPDATE SET last_seq = admin_ref_counter.last_seq + 1
  RETURNING last_seq INTO v_seq;

  RETURN p_prefix || lpad(v_yy::text, 2, '0') || lpad(v_seq::text, 6, '0');
END;
$$;

-- ไม่ GRANT ให้ authenticated โดยตรง — เรียกผ่าน RPC อื่น (SECURITY DEFINER) เท่านั้น
REVOKE ALL ON FUNCTION public._next_admin_ref(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._next_admin_ref(TEXT, TEXT) FROM authenticated;


-- ============================================================
-- 3) transfer_old_to_new_tx — TF26000001 + DB lock
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
  v_old_value NUMERIC;
  v_old_gold_g NUMERIC;
  v_old_wac NUMERIC;
  v_consumed_cost NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  -- [LOCK] serialize ทุก tx ที่แตะ wac/stock ผ่าน row นี้
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  -- new format: TF + YY + seq6 (ขยับจาก TRF-YYYYMMDDHHMMSS-xxxx)
  v_ref_id := _next_admin_ref('TF', 'TRANSFER');

  -- 1) total weight + ตรวจสต็อก OLD พอ (FOR UPDATE)
  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
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

  -- 2) READ OLD WAC ก่อน mutate
  SELECT COALESCE(old_value, 0), COALESCE(old_gold_g, 0)
    INTO v_old_value, v_old_gold_g
    FROM wac_state WHERE id = 1;

  v_old_wac := CASE WHEN v_old_gold_g > 0 THEN v_old_value / v_old_gold_g ELSE 0 END;
  v_consumed_cost := v_old_wac * v_total_g;

  -- 3) INSERT OLD/OUT
  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price,
                           wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'OLD', 'TRANSFER', 'OUT', v_total_g, v_consumed_cost,
          v_old_wac, v_old_wac * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
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
          v_old_wac, v_old_wac * 15, TRUE, v_user_id, 'Transfer OLD->NEW', NOW())
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

  -- 5) UPDATE wac_state — sync ทั้ง qty และ value
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
-- 4) approve_close_report — CL26000001 + DB lock
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
  v_nickname TEXT;
  v_new_status close_status;
  v_total_qty NUMERIC;
  v_total_gold_g NUMERIC;
  v_total_value NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_ref_id TEXT;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  v_new_status := CASE WHEN p_decision = 'APPROVE'
                       THEN 'APPROVED'::close_status
                       ELSE 'REJECTED'::close_status END;

  SELECT c.user_id, c.date::date, u.nickname
    INTO v_close_user, v_close_date, v_nickname
    FROM closes c JOIN users u ON u.id = c.user_id
    WHERE c.id = p_close_id;

  IF v_close_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Close not found');
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

  -- new format: CL26000001 (เก่า: CLOSE-nickname-YYYYMMDD)
  v_ref_id := _next_admin_ref('CL', 'CLOSE');

  SELECT
    COALESCE(SUM(ug.qty), 0),
    COALESCE(SUM(ug.qty * p.weight_baht * 15), 0),
    COALESCE(SUM(ug.qty * p.weight_baht * COALESCE(tx.sell_1baht, 0)), 0)
    INTO v_total_qty, v_total_gold_g, v_total_value
  FROM user_gold_received ug
  JOIN products p ON p.id = ug.product_id
  LEFT JOIN transactions tx ON tx.id = ug.ref_tx_id
  WHERE ug.user_id = v_close_user
    AND ug.settled = FALSE;

  IF v_total_qty > 0 THEN
    INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, fulfilled, user_id, date)
    VALUES (v_ref_id, 'OLD', 'STOCK_IN', 'IN', v_total_gold_g, v_total_value, TRUE, v_close_user, NOW())
    RETURNING id INTO v_move_id;

    FOR v_item IN
      SELECT product_id, SUM(qty) AS qty
      FROM user_gold_received
      WHERE user_id = v_close_user AND settled = FALSE
      GROUP BY product_id
    LOOP
      INSERT INTO stock_move_items (move_id, product_id, qty)
      VALUES (v_move_id, v_item.product_id, v_item.qty);

      INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
      VALUES (v_item.product_id, 'OLD', v_item.qty, NOW())
      ON CONFLICT (product_id, gold_type)
      DO UPDATE SET qty = stock_balances.qty + v_item.qty, updated_at = NOW();
    END LOOP;

    UPDATE wac_state
      SET old_gold_g = COALESCE(old_gold_g, 0) + v_total_gold_g,
          old_value  = COALESCE(old_value, 0) + v_total_value,
          updated_at = NOW()
      WHERE id = 1;

    UPDATE user_gold_received
      SET settled = TRUE, settled_at = NOW(), settled_close_id = p_close_id
      WHERE user_id = v_close_user AND settled = FALSE;
  END IF;

  PERFORM _notify_user('INFO', '✅ ปิดกะของคุณได้รับการอนุมัติ: ' || p_close_id,
                       v_close_user, 'close', NULL);

  RETURN jsonb_build_object(
    'success', true,
    'materialized_ref', CASE WHEN v_total_qty > 0 THEN v_ref_id ELSE NULL END,
    'materialized_qty', v_total_qty,
    'materialized_value', v_total_value
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION approve_close_report(TEXT, TEXT, TEXT) TO authenticated;


-- ============================================================
-- 5) check_duplicate_bill_id(p_bill_id)
--    เรียกหลัง create tx; ถ้ามี bill_id ซ้ำตลอดกาล (≥ 2 รายการ) → notify
--    Manager+Admin. กัน notify ซ้ำผ่าน UNIQUE (type, ref_tx_id) implicit
--    ด้วย check ว่ามี notification BILL_DUP สำหรับ tx ล่าสุดแล้วหรือยัง
-- ============================================================
DROP FUNCTION IF EXISTS public.check_duplicate_bill_id(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.check_duplicate_bill_id(TEXT);

CREATE OR REPLACE FUNCTION public.check_duplicate_bill_id(
  p_bill_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count INT;
  v_latest_tx TEXT;
  v_prev_tx TEXT;
  v_msg TEXT;
  v_admin RECORD;
  v_already_notified BOOLEAN;
BEGIN
  IF p_bill_id IS NULL OR p_bill_id = '' THEN
    RETURN jsonb_build_object('dup', false);
  END IF;

  SELECT COUNT(*) INTO v_count
    FROM transactions WHERE bill_id = p_bill_id;

  IF v_count < 2 THEN
    RETURN jsonb_build_object('dup', false);
  END IF;

  -- เอา 2 ตัวล่าสุด
  SELECT id INTO v_latest_tx FROM transactions
    WHERE bill_id = p_bill_id ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_prev_tx   FROM transactions
    WHERE bill_id = p_bill_id ORDER BY created_at DESC OFFSET 1 LIMIT 1;

  -- กัน notify ซ้ำ: ถ้ามี BILL_DUP สำหรับ tx ล่าสุดแล้วก็ skip
  SELECT EXISTS (
    SELECT 1 FROM notifications
    WHERE type = 'BILL_DUP' AND ref_tx_id = v_latest_tx
  ) INTO v_already_notified;

  IF v_already_notified THEN
    RETURN jsonb_build_object('dup', true, 'already_notified', true,
                              'bill_id', p_bill_id);
  END IF;

  v_msg := '⚠️ Bill ID ซ้ำ: ' || p_bill_id || ' (' || v_count || ' รายการ — ล่าสุด ' ||
           v_latest_tx || ' / ก่อนหน้า ' || v_prev_tx || ')';

  FOR v_admin IN
    SELECT id FROM users WHERE role IN ('Admin', 'Manager') AND active = TRUE
  LOOP
    INSERT INTO notifications (type, message, target_user_id, target_role,
                               related_tab, ref_tx_id, created_at, status)
    VALUES ('BILL_DUP', v_msg, v_admin.id, NULL,
            'historysell', v_latest_tx, NOW(), 'UNREAD');
  END LOOP;

  RETURN jsonb_build_object(
    'dup', true,
    'bill_id', p_bill_id,
    'count', v_count,
    'latest_tx', v_latest_tx,
    'prev_tx', v_prev_tx
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('dup', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_duplicate_bill_id(TEXT) TO authenticated;


-- ============================================================
-- 6) get_bill_dup_detail(p_bill_id) — ใช้ตอนกดแจ้งเตือน
--    คืนรายการทั้งหมดที่ใช้ bill_id เดียวกัน
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_bill_dup_detail(p_bill_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_txs JSONB;
BEGIN
  -- เฉพาะ Manager+Admin (Sales ไม่ควรเห็น tx ของคนอื่น)
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('bill_id', p_bill_id, 'txs', '[]'::jsonb,
                              'error', 'Manager or Admin only');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'type', t.type,
    'bill_id', t.bill_id,
    'phone', t.phone,
    'total', t.total,
    'status', t.status,
    'sales_nickname', u.nickname,
    'created_at', t.created_at
  ) ORDER BY t.created_at ASC), '[]'::jsonb)
  INTO v_txs
  FROM transactions t
  LEFT JOIN users u ON u.id = t.user_id
  WHERE t.bill_id = p_bill_id;

  RETURN jsonb_build_object('bill_id', p_bill_id, 'txs', v_txs);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_bill_dup_detail(TEXT) TO authenticated;


-- ============================================================
-- ทดสอบหลังรัน
-- ============================================================
--   SELECT _next_admin_ref('TF', 'TRANSFER'); -- → TF26000001, TF26000002, ...
--   SELECT _next_admin_ref('CL', 'CLOSE');    -- → CL26000001
--
--   -- bill_id dup
--   SELECT check_duplicate_bill_id('SE26000099', '12345');
--   SELECT get_bill_dup_detail('12345');
--
--   -- ตรวจ admin_ref_counter
--   SELECT * FROM admin_ref_counter ORDER BY year DESC, op_type;
