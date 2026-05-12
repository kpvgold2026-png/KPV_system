-- ============================================================
-- next_run.sql
-- ============================================================
-- Round 3 fixes
-- - #11 review_*_tx: 1-param signature ตรงกับ frontend, sets APPROVED,
--   notify Sales (notify error ไม่ rollback approve)
-- - #12 get_sales_with_shift: rewrite ให้ง่าย + ทนต่อ data edge case
-- - #13 _notify_user: exception-safe — error ไม่กระทบ caller
-- ============================================================


-- ============================================================
-- ลบ overload เก่าของ review_sell_tx ที่ผมเผลอสร้างใน round2
-- (3-param) → frontend ส่ง 1 param เลย ไม่เคยถูกเรียก
-- ============================================================
DROP FUNCTION IF EXISTS review_sell_tx(TEXT, TEXT, TEXT);


-- ============================================================
-- _notify_user: exception-safe helper
-- ============================================================
-- ถ้า insert notification fail → swallow error, ไม่ throw ออกมา
-- เพื่อไม่ให้ rollback การ approve transaction
CREATE OR REPLACE FUNCTION _notify_user(
  p_type notification_type,
  p_message TEXT,
  p_target_user UUID,
  p_tab TEXT,
  p_tx_id TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_target_user IS NULL THEN RETURN; END IF;
  BEGIN
    INSERT INTO notifications (type, message, target_user_id, tab, ref_tx_id, created_by_id)
    VALUES (p_type, p_message, p_target_user, p_tab, p_tx_id, current_user_id());
  EXCEPTION WHEN OTHERS THEN
    -- notify failure ไม่ blockการ approve
    NULL;
  END;
END;
$$;


-- ============================================================
-- #11: review_sell_tx — 1 param เท่านั้น (ตรงกับ frontend)
-- ============================================================
CREATE OR REPLACE FUNCTION review_sell_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  SELECT status, sale_user_id INTO v_status, v_sale_user
  FROM transactions WHERE id = p_tx_id AND type = 'SELL';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Already reviewed');
  END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'SELL', 'APPROVED', v_user_id);

  PERFORM _notify_user('INFO', '✅ SELL ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_sell_tx(TEXT) TO authenticated;


-- ============================================================
-- #11: review_tradein_tx
-- ============================================================
CREATE OR REPLACE FUNCTION review_tradein_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  SELECT status, sale_user_id INTO v_status, v_sale_user
  FROM transactions WHERE id = p_tx_id AND type = 'TRADEIN';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Already reviewed');
  END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'TRADEIN', 'APPROVED', v_user_id);

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_tradein_tx(TEXT) TO authenticated;


-- ============================================================
-- #11: review_exchange_tx
-- ============================================================
CREATE OR REPLACE FUNCTION review_exchange_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  SELECT status, sale_user_id INTO v_status, v_sale_user
  FROM transactions WHERE id = p_tx_id AND type = 'EXCHANGE';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Already reviewed');
  END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'EXCHANGE', 'APPROVED', v_user_id);

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_exchange_tx(TEXT) TO authenticated;


-- ============================================================
-- #11: review_withdraw_tx
-- ============================================================
CREATE OR REPLACE FUNCTION review_withdraw_tx(p_tx_id TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_status tx_status;
  v_sale_user UUID;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  SELECT status, sale_user_id INTO v_status, v_sale_user
  FROM transactions WHERE id = p_tx_id AND type = 'WITHDRAW';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'PENDING' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Already reviewed');
  END IF;

  UPDATE transactions SET status = 'APPROVED', updated_at = NOW() WHERE id = p_tx_id;
  INSERT INTO approvals (ref_id, ref_type, decision, approved_by_id)
  VALUES (p_tx_id, 'WITHDRAW', 'APPROVED', v_user_id);

  PERFORM _notify_user('INFO', '✅ WITHDRAW ของคุณได้รับการอนุมัติ: ' || p_tx_id,
                       v_sale_user, 'historysell', p_tx_id);

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION review_withdraw_tx(TEXT) TO authenticated;


-- ============================================================
-- #12: get_sales_with_shift — rewrite ให้เรียบง่ายและทนทาน
-- ============================================================
CREATE OR REPLACE FUNCTION get_sales_with_shift()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_today_start := (date_trunc('day', (NOW() AT TIME ZONE 'Asia/Bangkok'))) AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'username', u.username,
    'nickname', u.nickname,
    'role', u.role::text,
    'is_active', u.is_active,
    'shift_status', COALESCE(
      (SELECT CASE
                WHEN EXISTS (
                  SELECT 1 FROM closes c
                  WHERE c.user_id = u.id AND c.date >= v_today_start
                  AND c.status IN ('APPROVED', 'COMPLETED')
                ) THEN 'CLOSED'
                WHEN EXISTS (
                  SELECT 1 FROM user_cashbook uc
                  WHERE uc.user_id = u.id AND uc.type = 'OPEN_SHIFT'
                  AND uc.date >= v_today_start
                ) THEN 'OPEN'
                ELSE 'NONE'
              END
      ),
      'NONE'
    ),
    'shift_amount', (
      SELECT amount FROM user_cashbook
      WHERE user_id = u.id AND type = 'OPEN_SHIFT' AND date >= v_today_start
      ORDER BY date DESC LIMIT 1
    ),
    'shift_opened_at', (
      SELECT date FROM user_cashbook
      WHERE user_id = u.id AND type = 'OPEN_SHIFT' AND date >= v_today_start
      ORDER BY date DESC LIMIT 1
    )
  ) ORDER BY u.nickname), '[]'::jsonb)
  INTO v_result
  FROM users u
  WHERE u.is_active = TRUE AND u.role = 'Sales';

  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION get_sales_with_shift() TO authenticated;


-- ============================================================
-- get_history_txs: อ่าน ex_fee/switch_fee/premium/diff จาก transactions ตรง
-- (ก่อนหน้านี้ JOIN diffs ผิด → ค่าไม่ตรงกับที่ Sales กรอก)
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
    'currency', t.currency,
    'sale_user_id', t.sale_user_id,
    'sale_nickname', u.nickname,
    'date', t.date,
    'diff', t.diff_amount,
    'ex_fee', t.ex_fee,
    'switch_fee', t.switch_fee,
    'premium', t.premium,
    'fee', t.fee,
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
-- Realtime: เปิด INSERT events บน notifications สำหรับ Supabase Realtime
-- ============================================================
-- frontend จะ subscribe via postgres_changes → แจ้งเตือนเด้งทันที (<1s)
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE notifications;
EXCEPTION
  WHEN duplicate_object THEN NULL;   -- เพิ่มไปแล้ว
  WHEN undefined_object THEN NULL;   -- publication ยังไม่มี (เคสไม่น่าเกิดบน Supabase)
END $$;


-- ============================================================
-- ทดสอบหลังรัน
-- ============================================================
--   SELECT * FROM get_sales_with_shift();
--   -- ควรคืน array ของ Sales (ถ้าไม่มี Sales user → [])
--
--   -- ลอง approve tx แล้วเช็ค status:
--   SELECT id, type, status FROM transactions WHERE id = '<tx_id>';
--   -- ควรเป็น APPROVED
--
--   SELECT * FROM notifications ORDER BY created_at DESC LIMIT 10;
--   -- หลัง approve ควรเห็น row ใหม่ที่ target_user_id = sales user
--
--   -- เช็คว่า notifications อยู่ใน realtime publication:
--   SELECT schemaname, tablename FROM pg_publication_tables
--   WHERE pubname = 'supabase_realtime' AND tablename = 'notifications';
