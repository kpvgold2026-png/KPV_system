-- KPV R19-4 only — แก้ไขรายการทองบิลที่จบแล้ว (น้ำหนักรวมต่อกลุ่มต้องเท่าเดิม) — รันหลัง r19_only.sql

-- ============================================================
-- [R19-4] แก้ไขรายการทองของบิลที่จบแล้ว (Manager/Admin เท่านั้น)
--   เงื่อนไข: น้ำหนักรวม (กรัม) ของแต่ละกลุ่มต้องเท่าเดิม — ทองใหม่ (NEW) / ทองเก่าแต่ละชนิด (OLD, FOC, SWITCH, FREE_EX)
--     เช่น 1 บาท x1 → 2 สลึง x2 ; เงินของบิล (total/paid/diff) ไม่เปลี่ยน
--     ต้นทุน WAC ไม่เปลี่ยน (น้ำหนักเท่าเดิม) → แก้แค่ "จำนวนแท่งต่อสินค้า"
--   ทองใหม่ (NEW)  → คืนสต๊อก NEW ชิ้นเดิม + ตัดชิ้นใหม่ (สต๊อกไม่พอ = แก้ไม่ได้) + แก้รายการใน stock_move ของบิล
--   ทองเก่า (user_gold_received ของบิล):
--     ยังไม่เข้าสต๊อก (กะยังไม่ปิด) → แทนรายการที่ Sales ถือ (มูลค่ารวมเท่าเดิม แบ่งตามน้ำหนัก)
--     ส่งปิดกะแล้วรออนุมัติ          → ห้ามแก้ (ยอดทองในใบปิดกะส่งไปแล้ว)
--     เข้าสต๊อก OLD แล้ว (อนุมัติ)   → ปรับ Stock OLD ต่อสินค้า + ย้าย lot (มูลค่ารวมเท่าเดิม) — สต๊อกไม่พอ = แก้ไม่ได้
--   เก็บประวัติทุกครั้งใน tx_gold_edits
-- ============================================================
CREATE TABLE IF NOT EXISTS tx_gold_edits (
  id BIGSERIAL PRIMARY KEY,
  tx_id TEXT NOT NULL,
  old_items JSONB,
  new_items JSONB,
  old_gold_state TEXT,
  reason TEXT,
  edited_by_id UUID,
  edited_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tx_gold_edits_tx ON tx_gold_edits (tx_id, edited_at);

ALTER TABLE tx_gold_edits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tx_gold_edits FROM anon, authenticated;
REVOKE ALL ON SEQUENCE tx_gold_edits_id_seq FROM anon, authenticated;


-- สถานะทองเก่าของบิล: NONE / HELD (Sales ถืออยู่) / STOCK (เข้าสต๊อกแล้ว) หรือห้ามแก้ — internal เท่านั้น
CREATE OR REPLACE FUNCTION _tx_old_gold_state(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_n INT;
  v_n_settled INT;
  v_n_close INT;
  v_user UUID;
  v_min TIMESTAMPTZ;
  v_close_id TEXT;
  v_nick TEXT;
BEGIN
  SELECT COUNT(*), COUNT(*) FILTER (WHERE settled), COUNT(DISTINCT settled_close_id),
         (MIN(user_id::text))::uuid, MIN(date), MIN(settled_close_id)
    INTO v_n, v_n_settled, v_n_close, v_user, v_min, v_close_id
  FROM user_gold_received WHERE ref_tx_id = p_tx_id;

  IF COALESCE(v_n, 0) = 0 THEN
    RETURN jsonb_build_object('state', 'NONE');
  END IF;
  IF v_n_settled > 0 AND v_n_settled < v_n THEN
    RETURN jsonb_build_object('blocked', '❌ ทองเก่าของบิลนี้เข้าสต๊อกไปบางส่วน แก้ไขไม่ได้');
  END IF;
  IF v_n_settled = v_n THEN
    IF v_n_close > 1 THEN
      RETURN jsonb_build_object('blocked', '❌ ทองเก่าของบิลนี้เข้าสต๊อกหลายรอบปิดกะ แก้ไขไม่ได้');
    END IF;
    RETURN jsonb_build_object('state', 'STOCK', 'close_id', v_close_id);
  END IF;

  SELECT COALESCE(NULLIF(TRIM(nickname), ''), username) INTO v_nick FROM users WHERE id = v_user;
  SELECT id INTO v_close_id FROM closes
  WHERE user_id = v_user AND status = 'PENDING' AND date >= v_min
  ORDER BY date LIMIT 1;
  IF v_close_id IS NOT NULL THEN
    RETURN jsonb_build_object('blocked',
      '❌ ' || COALESCE(v_nick, 'Sales') || ' ส่งปิดกะแล้ว (' || v_close_id || ') รอ Manager อนุมัติ — อนุมัติหรือปฏิเสธการปิดกะก่อนจึงจะแก้ทองเก่าได้');
  END IF;
  RETURN jsonb_build_object('state', 'HELD', 'user_id', v_user, 'nickname', v_nick);
END;
$$;
REVOKE ALL ON FUNCTION _tx_old_gold_state(TEXT) FROM PUBLIC, anon, authenticated;


-- ข้อมูลสำหรับเปิดหน้าแก้ทอง
CREATE OR REPLACE FUNCTION get_tx_gold_edit_info(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tx RECORD;
  v_og JSONB;
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ Admin เท่านั้นที่แก้ไขบิลได้');
  END IF;
  SELECT t.id, t.type::text AS type, t.status::text AS status, t.phone INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้ทองไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;

  v_og := _tx_old_gold_state(p_tx_id);
  IF v_og ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_og->>'blocked');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'type', v_tx.type,
    'phone', v_tx.phone,
    'old_gold', v_og,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('role', ti.item_role, 'productId', ti.product_id, 'qty', ti.qty)
                       ORDER BY ti.item_role, ti.product_id)
      FROM transaction_items ti WHERE ti.tx_id = p_tx_id), '[]'::jsonb),
    'edits', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('edited_at', e.edited_at, 'reason', e.reason,
                                          'by', COALESCE(NULLIF(TRIM(u.nickname), ''), u.username))
                       ORDER BY e.edited_at)
      FROM tx_gold_edits e LEFT JOIN users u ON u.id = e.edited_by_id
      WHERE e.tx_id = p_tx_id), '[]'::jsonb)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_tx_gold_edit_info(TEXT) TO authenticated;


-- แก้รายการทอง — p_items = รายการทั้งบิล [{role, productId, qty}] (ทุกกลุ่ม แม้กลุ่มที่ไม่แก้)
CREATE OR REPLACE FUNCTION edit_tx_gold(p_tx_id TEXT, p_items JSONB, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_editor UUID;
  v_tx RECORD;
  v_og JSONB;
  v_state TEXT;
  v_r RECORD;
  v_old_items JSONB;
  v_new_items JSONB;
  v_n_moves INT;
  v_move_id BIGINT;
  v_stock NUMERIC;
  v_value NUMERIC;
  v_total_g NUMERIC;
  v_tpl RECORD;
  v_cost NUMERIC := 0;
  v_add_g NUMERIC := 0;
  v_changed BOOLEAN;
BEGIN
  v_editor := current_user_id();
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ Admin เท่านั้นที่แก้ไขบิลได้');
  END IF;
  IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'message', 'กรุณาระบุเหตุผลที่แก้ไข');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการทองไม่ถูกต้อง');
  END IF;

  -- [LOCK] บิล + wac_state (คิวเดียวกับทุก tx ที่แตะสต๊อก / อนุมัติปิดกะ)
  SELECT t.id, t.type::text AS type, t.status::text AS status, t.sale_user_id INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id
  FOR UPDATE;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้ทองไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_og := _tx_old_gold_state(p_tx_id);
  IF v_og ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_og->>'blocked');
  END IF;
  v_state := v_og->>'state';

  -- รายการใหม่ (รวมแถวซ้ำ product × role) → ตารางชั่วคราว
  DROP TABLE IF EXISTS _ge_new;
  --   typed_role = ค่า item_role ชนิดเดียวกับคอลัมน์เดิม (NULL = กลุ่มที่บิลนี้ไม่มี)
  CREATE TEMP TABLE _ge_new ON COMMIT DROP AS
  SELECT g.role, g.product_id, g.qty,
         (SELECT ti.item_role FROM transaction_items ti
          WHERE ti.tx_id = p_tx_id AND ti.item_role::text = g.role LIMIT 1) AS typed_role
  FROM (
    SELECT UPPER(TRIM(x->>'role')) AS role, TRIM(x->>'productId') AS product_id,
           SUM((x->>'qty')::numeric) AS qty
    FROM jsonb_array_elements(p_items) x
    GROUP BY 1, 2
  ) g;
  DELETE FROM _ge_new WHERE qty = 0;

  IF EXISTS (SELECT 1 FROM _ge_new WHERE qty < 0 OR qty <> TRUNC(qty)) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ จำนวนต้องเป็นจำนวนเต็มบวก');
  END IF;
  IF EXISTS (SELECT 1 FROM _ge_new n WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.id = n.product_id)) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ ไม่พบสินค้า');
  END IF;
  IF EXISTS (SELECT 1 FROM _ge_new WHERE typed_role IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ เพิ่มกลุ่มทองที่บิลนี้ไม่มีไม่ได้');
  END IF;

  -- ‼️ น้ำหนักรวมแต่ละกลุ่มต้องเท่าเดิม
  FOR v_r IN
    WITH o AS (
      SELECT ti.item_role::text AS role, SUM(ti.qty * _gold_g(p.weight_baht)) AS g
      FROM transaction_items ti JOIN products p ON p.id = ti.product_id
      WHERE ti.tx_id = p_tx_id GROUP BY 1
    ), n AS (
      SELECT n.role, SUM(n.qty * _gold_g(p.weight_baht)) AS g
      FROM _ge_new n JOIN products p ON p.id = n.product_id GROUP BY 1
    )
    SELECT o.role, o.g AS old_g, COALESCE(n.g, 0) AS new_g
    FROM o LEFT JOIN n ON n.role = o.role
  LOOP
    IF ABS(v_r.old_g - v_r.new_g) > 0.001 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ น้ำหนักรวมกลุ่ม ' || v_r.role || ' ต้องเท่าเดิม (เดิม ' || to_char(v_r.old_g, 'FM999,990.00')
        || ' g / ใหม่ ' || to_char(v_r.new_g, 'FM999,990.00') || ' g)');
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('role', ti.item_role, 'productId', ti.product_id, 'qty', ti.qty)
                            ORDER BY ti.item_role, ti.product_id), '[]'::jsonb)
    INTO v_old_items FROM transaction_items ti WHERE ti.tx_id = p_tx_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('role', role, 'productId', product_id, 'qty', qty)
                            ORDER BY role, product_id), '[]'::jsonb)
    INTO v_new_items FROM _ge_new;

  SELECT EXISTS (
    (SELECT item_role::text, product_id, qty FROM transaction_items WHERE tx_id = p_tx_id
     EXCEPT SELECT role, product_id, qty FROM _ge_new)
    UNION ALL
    (SELECT role, product_id, qty FROM _ge_new
     EXCEPT SELECT item_role::text, product_id, qty FROM transaction_items WHERE tx_id = p_tx_id)
  ) INTO v_changed;
  IF NOT v_changed THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการที่เปลี่ยน');
  END IF;

  -- ===== ทองใหม่ (NEW) — สต๊อก NEW ต่อสินค้า: + เดิม − ใหม่ =====
  FOR v_r IN
    WITH d AS (
      SELECT product_id, -qty AS dq FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW'
      UNION ALL
      SELECT product_id, qty FROM _ge_new WHERE role = 'NEW'
    )
    SELECT product_id, SUM(dq) AS dq FROM d GROUP BY product_id HAVING SUM(dq) <> 0
    ORDER BY SUM(dq) DESC
  LOOP
    IF v_r.dq > 0 THEN
      SELECT sb.qty INTO v_stock FROM stock_balances sb
        WHERE sb.product_id = v_r.product_id AND sb.gold_type = 'NEW' FOR UPDATE;
      IF v_stock IS NULL OR v_stock < v_r.dq THEN
        RAISE EXCEPTION '❌ สต๊อก NEW ไม่พอ: % (มี % ต้องใช้ %)', v_r.product_id, COALESCE(v_stock, 0), v_r.dq;
      END IF;
    END IF;
    INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
    VALUES (v_r.product_id, 'NEW', -v_r.dq, NOW())
    ON CONFLICT (product_id, gold_type)
    DO UPDATE SET qty = stock_balances.qty - v_r.dq, updated_at = NOW();
  END LOOP;

  IF EXISTS (SELECT 1 FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW') THEN
    SELECT COUNT(*), MIN(id) INTO v_n_moves, v_move_id
    FROM stock_moves WHERE ref_id = p_tx_id AND gold_type = 'NEW';
    IF v_n_moves = 1 THEN
      DELETE FROM stock_move_items WHERE move_id = v_move_id;
      INSERT INTO stock_move_items (move_id, product_id, qty)
      SELECT v_move_id, product_id, qty FROM _ge_new WHERE role = 'NEW';
    END IF;
  END IF;

  -- ===== ทองเก่า (user_gold_received ของบิล) =====
  IF v_state IN ('HELD', 'STOCK') THEN
    -- มูลค่ารวมเดิม (PriceIn) → แบ่งให้รายการใหม่ตามน้ำหนัก (ผลรวมเท่าเดิม)
    SELECT COALESCE(SUM(ug.qty * _ug_cost_per_unit(ug.id)), 0) INTO v_value
    FROM user_gold_received ug WHERE ug.ref_tx_id = p_tx_id;
    SELECT COALESCE(SUM(n.qty * _gold_g(p.weight_baht)), 0) INTO v_total_g
    FROM _ge_new n JOIN products p ON p.id = n.product_id WHERE n.role <> 'NEW';

    SELECT ug.user_id, ug.type, ug.date, ug.created_by_id, ug.settled, ug.settled_at, ug.settled_close_id
      INTO v_tpl
    FROM user_gold_received ug WHERE ug.ref_tx_id = p_tx_id ORDER BY ug.id LIMIT 1;

    IF v_state = 'STOCK' THEN
      -- Stock OLD ต่อสินค้า: ตัดชิ้นเดิมออก (lot FIFO) แล้วเพิ่มชิ้นใหม่ด้วยต้นทุนรวมเท่าที่ตัด
      FOR v_r IN
        WITH d AS (
          SELECT product_id, -qty AS dq FROM user_gold_received WHERE ref_tx_id = p_tx_id
          UNION ALL
          SELECT product_id, qty FROM _ge_new WHERE role <> 'NEW'
        )
        SELECT d.product_id, SUM(d.dq) AS dq, _gold_g(p.weight_baht) AS g
        FROM d JOIN products p ON p.id = d.product_id
        GROUP BY d.product_id, p.weight_baht HAVING SUM(d.dq) < 0
      LOOP
        SELECT sb.qty INTO v_stock FROM stock_balances sb
          WHERE sb.product_id = v_r.product_id AND sb.gold_type = 'OLD' FOR UPDATE;
        IF v_stock IS NULL OR v_stock < -v_r.dq THEN
          RAISE EXCEPTION '❌ สต๊อก OLD ไม่พอ: % (มี % ต้องตัด %) — ทองชิ้นเดิมอาจถูกขาย/โอนออกไปแล้ว',
            v_r.product_id, COALESCE(v_stock, 0), -v_r.dq;
        END IF;
        v_cost := v_cost + _consume_old_lots(v_r.product_id, -v_r.dq);
        UPDATE stock_balances SET qty = qty + v_r.dq, updated_at = NOW()
          WHERE product_id = v_r.product_id AND gold_type = 'OLD';
      END LOOP;

      SELECT COALESCE(SUM(dq * g), 0) INTO v_add_g FROM (
        SELECT SUM(d.dq) AS dq, _gold_g(p.weight_baht) AS g
        FROM (SELECT product_id, -qty AS dq FROM user_gold_received WHERE ref_tx_id = p_tx_id
              UNION ALL
              SELECT product_id, qty FROM _ge_new WHERE role <> 'NEW') d
        JOIN products p ON p.id = d.product_id
        GROUP BY d.product_id, p.weight_baht HAVING SUM(d.dq) > 0) a;

      FOR v_r IN
        WITH d AS (
          SELECT product_id, -qty AS dq FROM user_gold_received WHERE ref_tx_id = p_tx_id
          UNION ALL
          SELECT product_id, qty FROM _ge_new WHERE role <> 'NEW'
        )
        SELECT d.product_id, SUM(d.dq) AS dq, _gold_g(p.weight_baht) AS g
        FROM d JOIN products p ON p.id = d.product_id
        GROUP BY d.product_id, p.weight_baht HAVING SUM(d.dq) > 0
      LOOP
        INSERT INTO stock_balances (product_id, gold_type, qty, updated_at)
        VALUES (v_r.product_id, 'OLD', v_r.dq, NOW())
        ON CONFLICT (product_id, gold_type)
        DO UPDATE SET qty = stock_balances.qty + v_r.dq, updated_at = NOW();

        INSERT INTO old_gold_lots (product_id, qty_in, qty_left, gold_g_per_unit, cost_per_g, source_ref, date)
        VALUES (v_r.product_id, v_r.dq, v_r.dq, v_r.g,
                CASE WHEN v_add_g > 0 THEN v_cost / v_add_g ELSE 0 END,
                COALESCE(v_tpl.settled_close_id, '') || ' EDIT ' || p_tx_id, NOW());
      END LOOP;
      -- wac_state ไม่เปลี่ยน: น้ำหนักเท่าเดิม และมูลค่าที่ตัดออก = มูลค่าที่เพิ่มเข้า
    END IF;

    DELETE FROM user_gold_received WHERE ref_tx_id = p_tx_id;
    INSERT INTO user_gold_received (user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
                                    price_per_unit, settled, settled_at, settled_close_id)
    SELECT v_tpl.user_id, n.product_id, SUM(n.qty), v_tpl.type, p_tx_id, v_tpl.date, v_tpl.created_by_id,
           CASE WHEN v_total_g > 0 THEN ROUND(v_value * _gold_g(p.weight_baht) / v_total_g, 2) ELSE 0 END,
           v_tpl.settled, v_tpl.settled_at, v_tpl.settled_close_id
    FROM _ge_new n JOIN products p ON p.id = n.product_id
    WHERE n.role <> 'NEW'
    GROUP BY n.product_id, p.weight_baht;
  END IF;

  -- แทนรายการทองของบิล
  DELETE FROM transaction_items WHERE tx_id = p_tx_id;
  INSERT INTO transaction_items (tx_id, item_role, product_id, qty)
  SELECT p_tx_id, typed_role, product_id, qty FROM _ge_new;

  UPDATE transactions SET updated_at = NOW() WHERE id = p_tx_id;

  INSERT INTO tx_gold_edits (tx_id, old_items, new_items, old_gold_state, reason, edited_by_id)
  VALUES (p_tx_id, v_old_items, v_new_items, v_state, TRIM(p_reason), v_editor);

  IF v_state = 'HELD' THEN
    PERFORM _notify_user('INFO', '✏️ Admin แก้ไขรายการทองบิล ' || p_tx_id || ' — ทองเก่าที่คุณถือถูกปรับ',
                         (v_og->>'user_id')::uuid, LOWER(v_tx.type), p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'old_gold_state', v_state);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION edit_tx_gold(TEXT, JSONB, TEXT) TO authenticated;
