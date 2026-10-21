-- KPV R16 only (R16-1..5)

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
