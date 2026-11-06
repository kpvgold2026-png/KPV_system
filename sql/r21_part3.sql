-- KPV R21 part 3/4 — รันตามลำดับ part1 → part4 (หลัง r20_only.sql) — Run without RLS
--   ‼️ รันหลัง r20_only.sql (edit_tx_payments ในไฟล์นี้มาจาก R20) — เลือก "Run without RLS"
--   ใช้ _next_admin_ref(prefix, op) + ตาราง admin_ref_counter (นับต่อปี แยกตาม op)
--   SI = รับทองใหม่ (STOCK_IN)      SH = เปิดกะ (SHIFT)          CL = ปิดกะ (CLOSE)
--   CB = เงินร้าน cashbank (CASHBANK)    UC = กระเป๋า Sales user_cashbook (USER_CASHBOOK)
--   CE = แก้การชำระบิล cashbank (CASHBANK_EDIT)   UE = แก้การชำระบิล user_cashbook (USER_CASHBOOK_EDIT)
--   (SE/TI/EX/BB/WD/TF/SO เป็นรูปแบบนี้อยู่แล้ว ไม่แก้) — ข้อมูลเก่าไม่แปลง เลขเดิมคงไว้

-- [R21] approve_close_report — อนุมัติปิดกะ: ใช้เลข CL เดิม + CB / UC (จาก next_run.sql)
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

  v_ref_id := p_close_id;  -- [R21] ใช้เลขปิดกะเดิม ไม่สร้าง CL ใหม่ตอนอนุมัติ

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
    v_uc_id := _next_admin_ref('UC', 'USER_CASHBOOK');
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_close_user, 'CASH_OUT', -v_cash.bal, v_cash.currency, 'CASH', 'ปิดกะ โอนเข้าร้าน ' || p_close_id, NOW());

    v_cb_id := _next_admin_ref('CB', 'CASHBANK');
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
    v_uc_id := _next_admin_ref('UC', 'USER_CASHBOOK');
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

-- [R21] transfer_user_cash_to_shop — Sales โอนเงินเข้าร้าน CB / UC (จาก next_run.sql)
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

    v_uc_id := _next_admin_ref('UC', 'USER_CASHBOOK');
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_user_id, 'CASH_OUT', -v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer to shop', NOW());

    v_cb_id := _next_admin_ref('CB', 'CASHBANK');
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer from user cash', NOW(), v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

