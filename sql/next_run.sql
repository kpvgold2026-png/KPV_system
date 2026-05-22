-- ============================================================
-- next_run.sql — รวม fix 3 อัน รันครั้งเดียวจบ idempotent
-- ============================================================
-- 1) get_stock_summary  → fix carry double-count (BALANCE ติดลบ)
-- 2) approve_close_report → stock_moves.price = ราคาขาย ณ ตอนทำ tx
--                            (qty × weight_baht × sell_1baht)
-- 3) get_stock_moves     → สำหรับ OLD: คำนวณ price ของ OUT ด้วย FIFO
--                            (consume IN ตามลำดับเวลา)
-- ============================================================


-- ============================================================
-- 1) get_stock_summary — carry = stock_now − net(วันนี้)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_stock_summary(p_gold_type gold_type)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_carry JSONB;
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

  RETURN jsonb_build_object('carry', v_carry, 'in', v_in, 'out', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_summary(gold_type) TO authenticated;


-- ============================================================
-- 2) approve_close_report — price = SUM(qty × weight_baht × sell_1baht)
-- ============================================================
-- เปลี่ยนจาก ug.price_per_unit (BUYBACK=ราคาคืน, TRADEIN/EXCHANGE/FOC=0)
-- เป็นราคาขาย 1 baht ของ tx ตอนตี (transactions.sell_1baht)
-- → ทุก tx มีค่า ไม่ใช่แค่ BUYBACK
-- ============================================================
CREATE OR REPLACE FUNCTION approve_close_report(p_close_id TEXT, p_decision TEXT, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_new_status close_status;
  v_close_user UUID;
  v_nickname TEXT;
  v_close_date DATE;
  v_ref_id TEXT;
  v_total_qty NUMERIC := 0;
  v_total_gold_g NUMERIC := 0;
  v_total_value NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
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

  v_ref_id := 'CLOSE-' || COALESCE(v_nickname, 'unknown') || '-'
              || to_char(v_close_date, 'YYYYMMDD');

  -- ‼️ value ใหม่: SUM(qty × weight_baht × sell_1baht) ของ tx ต้นทาง
  --   เพราะ stock_moves.gold_g เก็บเป็น gram, sell_1baht คือราคาทอง 1 baht
  --   → qty × weight_baht (baht/unit) × sell_1baht (LAK/baht) = LAK
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
-- 3) get_stock_moves — OLD: คำนวณ price ของ OUT ด้วย FIFO
-- ============================================================
-- สำหรับ NEW: คงพฤติกรรมเดิม (อ่าน stock_moves.price ตรงๆ)
-- สำหรับ OLD: loop ทั้งประวัติ ASC ใช้ FIFO queue
--   IN  → push (gold_g, price/gold_g) เข้าหาง queue
--   OUT → pop จากหัว queue จน gold_g ครบ, รวม cost
--   ผลลัพธ์ใน range [v_from, v_to] เท่านั้น
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
  -- NEW gold: ใช้ logic เดิม (price อ่านจาก stock_moves.price ตรงๆ)
  ----------------------------------------------------------------
  IF p_gold_type = 'NEW' THEN
    SELECT
      COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0),
      COALESCE(SUM(CASE WHEN direction = 'IN' THEN COALESCE(price, 0) ELSE -COALESCE(price, 0) END), 0)
    INTO v_prev_w, v_prev_c
    FROM stock_moves
    WHERE gold_type = p_gold_type
      AND (date AT TIME ZONE 'Asia/Bangkok')::date < v_from;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', ref_id, 'type', type, 'dir', direction,
      'goldG', gold_g, 'price', COALESCE(price, 0),
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
-- ทดสอบหลังรัน
-- ============================================================
--   SELECT get_stock_summary('NEW');
--   SELECT get_stock_summary('OLD');
--   SELECT get_stock_moves('OLD');
--   SELECT get_stock_moves('OLD', '2026-05-01'::date, '2026-05-31'::date);
--
-- หลัง approve_close_report ครั้งใหม่ stock_moves OLD STOCK_IN จะมี price > 0
-- ส่วน STOCK_OUT/TRANSFER OUT จะแสดง price ตาม FIFO ที่ consume จาก IN
-- (row legacy ที่ IN price=0 จะยังเป็น 0 ตามเดิม)
