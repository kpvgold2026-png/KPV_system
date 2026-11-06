-- KPV R21 part 2/4 — รันตามลำดับ part1 → part4 (หลัง r20_only.sql) — Run without RLS
--   ‼️ รันหลัง r20_only.sql (edit_tx_payments ในไฟล์นี้มาจาก R20) — เลือก "Run without RLS"
--   ใช้ _next_admin_ref(prefix, op) + ตาราง admin_ref_counter (นับต่อปี แยกตาม op)
--   SI = รับทองใหม่ (STOCK_IN)      SH = เปิดกะ (SHIFT)          CL = ปิดกะ (CLOSE)
--   CB = เงินร้าน cashbank (CASHBANK)    UC = กระเป๋า Sales user_cashbook (USER_CASHBOOK)
--   CE = แก้การชำระบิล cashbank (CASHBANK_EDIT)   UE = แก้การชำระบิล user_cashbook (USER_CASHBOOK_EDIT)
--   (SE/TI/EX/BB/WD/TF/SO เป็นรูปแบบนี้อยู่แล้ว ไม่แก้) — ข้อมูลเก่าไม่แปลง เลขเดิมคงไว้

-- [R21] stock_in_new_tx — รับทองใหม่ SI + เงินจ่าย CB (จาก next_run.sql)
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

  v_ref_id := _next_admin_ref('SI', 'STOCK_IN');

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

      v_cb_id := _next_admin_ref('CB', 'CASHBANK');
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

-- [R21] open_shift — เปิดกะ SH + เงินร้าน CB (จาก next_run.sql)
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

  v_id := _next_admin_ref('SH', 'SHIFT');
  v_cb_id := _next_admin_ref('CB', 'CASHBANK');

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

-- [R21] submit_close_report — ส่งปิดกะ CL (นับลำดับ) (จาก next_run.sql)
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

  v_close_id := _next_admin_ref('CL', 'CLOSE');

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

