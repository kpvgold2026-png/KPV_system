-- KPV R21 part 4/4 — รันตามลำดับ part1 → part4 (หลัง r20_only.sql) — Run without RLS
--   ‼️ รันหลัง r20_only.sql (edit_tx_payments ในไฟล์นี้มาจาก R20) — เลือก "Run without RLS"
--   ใช้ _next_admin_ref(prefix, op) + ตาราง admin_ref_counter (นับต่อปี แยกตาม op)
--   SI = รับทองใหม่ (STOCK_IN)      SH = เปิดกะ (SHIFT)          CL = ปิดกะ (CLOSE)
--   CB = เงินร้าน cashbank (CASHBANK)    UC = กระเป๋า Sales user_cashbook (USER_CASHBOOK)
--   CE = แก้การชำระบิล cashbank (CASHBANK_EDIT)   UE = แก้การชำระบิล user_cashbook (USER_CASHBOOK_EDIT)
--   (SE/TI/EX/BB/WD/TF/SO เป็นรูปแบบนี้อยู่แล้ว ไม่แก้) — ข้อมูลเก่าไม่แปลง เลขเดิมคงไว้

-- [R21] edit_tx_payments — แก้การชำระบิล CE / UE (จาก r20_only.sql)
CREATE OR REPLACE FUNCTION edit_tx_payments(
  p_tx_id TEXT, p_payments JSONB, p_change NUMERIC, p_reason TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_editor UUID;
  v_tx RECORD;
  v_led JSONB;
  v_mode TEXT;
  v_user UUID;
  v_is_shift BOOLEAN;
  v_payer UUID;
  v_sign NUMERIC;
  v_cb_type cashbank_type;
  v_total NUMERIC;
  v_change NUMERIC := ROUND(COALESCE(p_change, 0));
  v_old_change NUMERIC;
  v_new_paid NUMERIC := 0;
  v_over NUMERIC;
  v_first_cur TEXT := NULL;
  v_old_payments JSONB;
  v_new_payments JSONB := '[]'::jsonb;
  v_new JSONB := '[]'::jsonb;
  v_deltas JSONB := '[]'::jsonb;
  v_e RECORD;
  v_d RECORD;
  v_method TEXT;
  v_bank_id UUID;
  v_note TEXT;
  v_n INT := 0;
  v_ok BOOLEAN;
BEGIN
  v_editor := current_user_id();
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ Admin เท่านั้นที่แก้ไขบิลได้');
  END IF;
  IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'message', 'กรุณาระบุเหตุผลที่แก้ไข');
  END IF;
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'message', 'รูปแบบรายการชำระเงินไม่ถูกต้อง');
  END IF;

  -- [LOCK] กันแก้บิลเดียวกันพร้อมกัน
  SELECT t.id, t.type::text AS type, t.status::text AS status, t.total, t.price,
         COALESCE(t.change_amount, 0) AS change_amount, t.sale_user_id
    INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id
  FOR UPDATE;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้การชำระไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;

  -- [LOCK] กันอนุมัติปิดกะแทรกระหว่างแก้ (approve_close_report lock row นี้เหมือนกัน)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_led := _tx_edit_ledger(p_tx_id);
  IF v_led ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_led->>'blocked');
  END IF;
  v_mode := v_led->>'mode';
  v_user := (v_led->>'user_id')::uuid;
  v_is_shift := (v_mode = 'SHIFT');

  SELECT tp.paid_by_id INTO v_payer FROM transaction_payments tp WHERE tp.tx_id = p_tx_id LIMIT 1;
  v_payer := COALESCE(v_user, v_payer, v_editor);

  -- เงินเข้า (+1) : SELL/TRADEIN/EXCHANGE/WITHDRAW ; เงินออก (−1) : BUYBACK
  v_sign := CASE WHEN v_tx.type = 'BUYBACK' THEN -1 ELSE 1 END;
  v_cb_type := v_tx.type::cashbank_type;
  v_total := CASE WHEN v_tx.type = 'BUYBACK' THEN COALESCE(v_tx.price, v_tx.total) ELSE v_tx.total END;
  v_old_change := v_tx.change_amount;
  IF v_tx.type = 'BUYBACK' THEN v_change := 0; END IF;
  IF v_change < 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'เงินทอนต้องไม่ติดลบ');
  END IF;

  -- รายการใหม่
  FOR v_e IN
    SELECT UPPER(COALESCE(elem->>'method', 'CASH')) AS m,
           UPPER(COALESCE(NULLIF(elem->>'currency', ''), 'LAK')) AS cur,
           (elem->>'amount')::numeric AS amount,
           COALESCE(NULLIF((elem->>'rate')::numeric, 0), 1) AS rate,
           elem->>'bank' AS bank_name
    FROM jsonb_array_elements(p_payments) elem
  LOOP
    CONTINUE WHEN v_e.amount IS NULL OR v_e.amount <= 0;
    IF v_e.cur NOT IN ('LAK', 'THB', 'USD') THEN
      RETURN jsonb_build_object('success', false, 'message', 'สกุลเงินไม่ถูกต้อง: ' || v_e.cur);
    END IF;
    v_method := CASE WHEN v_e.m = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END;
    IF v_method = 'TRANSFER' AND COALESCE(TRIM(v_e.bank_name), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'message', 'รายการโอนต้องระบุธนาคาร');
    END IF;
    v_bank_id := CASE WHEN v_method = 'TRANSFER' THEN _resolve_bank_id(v_e.bank_name) ELSE NULL END;
    IF v_first_cur IS NULL THEN v_first_cur := v_e.cur; END IF;
    v_new_paid := v_new_paid + v_e.amount * CASE WHEN v_e.cur = 'LAK' THEN 1 ELSE v_e.rate END;
    v_new := v_new || jsonb_build_object('method', v_method, 'currency', v_e.cur,
                                         'bank_id', v_bank_id, 'amount', v_e.amount);
    v_new_payments := v_new_payments || jsonb_build_object('method', v_method, 'currency', v_e.cur,
                                         'amount', v_e.amount, 'rate', v_e.rate, 'bank', v_e.bank_name);
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 AND COALESCE(v_total, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'ไม่มีรายการชำระเงิน');
  END IF;

  -- ยอดต้องครบเหมือนตอนยืนยันบิล
  IF v_tx.type = 'BUYBACK' THEN
    IF v_new_paid > v_total + 1 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดจ่ายเกิน Total (' || to_char(v_new_paid, 'FM999,999,999,990') || ' > ' || to_char(v_total, 'FM999,999,999,990') || ' LAK)');
    END IF;
    IF v_total - v_new_paid > 500 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดจ่ายยังไม่ครบ ขาดอีก ' || to_char(v_total - v_new_paid, 'FM999,999,999,990') || ' LAK');
    END IF;
  ELSE
    IF v_new_paid < v_total - 1 THEN
      RETURN jsonb_build_object('success', false, 'message',
        '❌ ยอดชำระยังไม่ครบ ขาดอีก ' || to_char(v_total - v_new_paid, 'FM999,999,999,990') || ' LAK');
    END IF;
    -- เงินทอนปัด 1,000 (roundChangeLak) → ต่างจากยอดเกินได้ไม่เกิน 1,000
    v_over := GREATEST(v_new_paid - v_total, 0);
    IF v_change > v_over + 500 OR v_change < v_over - 1000 THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินทอนไม่ตรงกับยอดที่ชำระเกิน');
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('method', tp.method, 'currency', tp.currency,
                                               'amount', tp.amount, 'bank', b.name, 'paid_by_id', tp.paid_by_id)), '[]'::jsonb)
    INTO v_old_payments
  FROM transaction_payments tp LEFT JOIN banks b ON b.id = tp.bank_id
  WHERE tp.tx_id = p_tx_id;

  -- ส่วนต่างต่อ (วิธีจ่าย × สกุล × ธนาคาร) = ใหม่ − เดิม (เงินทอน = เงินสด LAK ทิศตรงข้าม)
  FOR v_d IN
    WITH eff AS (
      SELECT CASE WHEN UPPER(tp.method::text) = 'CASH' THEN 'CASH' ELSE 'TRANSFER' END AS method,
             tp.currency::text AS currency, tp.bank_id, -v_sign * tp.amount AS amt
      FROM transaction_payments tp WHERE tp.tx_id = p_tx_id
      UNION ALL
      SELECT 'CASH', 'LAK', NULL::uuid, v_old_change WHERE v_old_change > 0
      UNION ALL
      SELECT x->>'method', x->>'currency', NULLIF(x->>'bank_id', '')::uuid, v_sign * (x->>'amount')::numeric
      FROM jsonb_array_elements(v_new) x
      UNION ALL
      SELECT 'CASH', 'LAK', NULL::uuid, -v_change WHERE v_change > 0
    )
    SELECT eff.method, eff.currency, eff.bank_id, b.name AS bank_name, SUM(eff.amt) AS delta
    FROM eff LEFT JOIN banks b ON b.id = eff.bank_id
    GROUP BY eff.method, eff.currency, eff.bank_id, b.name
    HAVING ABS(SUM(eff.amt)) > 0.000001
    ORDER BY SUM(eff.amt)
  LOOP
    -- ช่องที่ยอดลดลง → ต้องมีเงินพอ
    IF v_d.delta < 0 THEN
      IF v_is_shift AND v_d.method = 'CASH' THEN
        v_ok := check_user_cash_balance(v_user, v_d.currency::currency_code, -v_d.delta);
      ELSE
        v_ok := check_shop_balance(v_d.method, v_d.currency::currency_code, v_d.bank_id, -v_d.delta);
      END IF;
      IF NOT v_ok THEN
        RAISE EXCEPTION '❌ % % % ไม่พอหัก % % — แก้ไขไม่ได้',
          CASE WHEN v_is_shift AND v_d.method = 'CASH'
               THEN 'เงินสดในกระเป๋า ' || COALESCE(v_led->>'nickname', 'Sales')
               WHEN v_d.method = 'CASH' THEN 'เงินสดในร้าน'
               ELSE 'เงินในบัญชีร้าน' END,
          CASE WHEN v_d.method = 'CASH' THEN '' ELSE COALESCE(v_d.bank_name, '') END,
          v_d.currency, to_char(-v_d.delta, 'FM999,999,999,990.99'), v_d.currency;
      END IF;
    END IF;

    v_note := 'แก้ไขการชำระ ' || p_tx_id;

    -- เงินร้าน: ทุกช่อง ยกเว้นเงินสดที่อยู่ในกระเป๋า Sales (SHIFT)
    IF NOT (v_is_shift AND v_d.method = 'CASH') THEN
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (_next_admin_ref('CE', 'CASHBANK_EDIT'),
              v_cb_type, v_d.delta, v_d.currency::currency_code, v_d.method, v_d.bank_id,
              p_tx_id, v_note, NOW(), v_editor);
    END IF;

    -- กระเป๋า Sales (SHIFT): ลงทุกช่องเหมือนตอนยืนยันบิล (โอน = แถวติดตาม เคลียร์ตอนปิดกะ)
    IF v_is_shift THEN
      INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
      VALUES (_next_admin_ref('UE', 'USER_CASHBOOK_EDIT'),
              v_user, v_cb_type, v_d.delta, v_d.currency::currency_code, v_d.method, v_d.bank_id,
              p_tx_id, v_note, NOW());
    END IF;

    v_deltas := v_deltas || jsonb_build_object('method', v_d.method, 'currency', v_d.currency,
                                               'bank', v_d.bank_name, 'delta', v_d.delta);
  END LOOP;

  -- แทนรายการจ่ายของบิล (Report/ตารางช่องทางรับเงินอ่านจากตารางนี้)
  DELETE FROM transaction_payments WHERE tx_id = p_tx_id;
  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  SELECT p_tx_id, (x->>'amount')::numeric, (x->>'currency')::currency_code, x->>'method',
         NULLIF(x->>'bank_id', '')::uuid, v_payer
  FROM jsonb_array_elements(v_new) x;

  IF v_tx.type = 'BUYBACK' THEN
    -- ยอดค้าง ≤ 500 LAK ถือว่าจ่ายครบ (R19-1) → paid = price คงเดิม (ต้นทุนทองเก่าไม่เปลี่ยน)
    UPDATE transactions SET paid = v_total, balance = 0, updated_at = NOW() WHERE id = p_tx_id;
  ELSE
    UPDATE transactions
      SET paid = v_new_paid, change_amount = v_change,
          currency = COALESCE(v_first_cur, 'LAK')::currency_code, updated_at = NOW()
      WHERE id = p_tx_id;
  END IF;

  INSERT INTO tx_payment_edits (tx_id, mode, ledger_user_id, old_payments, new_payments,
                                old_change, new_change, deltas, reason, edited_by_id)
  VALUES (p_tx_id, v_mode, v_user, v_old_payments, v_new_payments,
          v_old_change, v_change, v_deltas, TRIM(p_reason), v_editor);

  IF v_is_shift AND jsonb_array_length(v_deltas) > 0 THEN
    PERFORM _notify_user('INFO', '✏️ Admin แก้ไขการชำระเงินบิล ' || p_tx_id || ' — ยอดในกระเป๋าของคุณถูกปรับ',
                         v_user, LOWER(v_tx.type), p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'mode', v_mode, 'deltas', v_deltas);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

-- [R21] _tx_edit_ledger — ไม่นับแถวแก้บิล (เลขเก่า UCB-EDIT- และเลขใหม่ UE) (จาก r19_only.sql)
CREATE OR REPLACE FUNCTION _tx_edit_ledger(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_n_users INT;
  v_user UUID;
  v_min TIMESTAMPTZ;
  v_max TIMESTAMPTZ;
  v_c1_id TEXT; v_c1_st close_status;
  v_c2_id TEXT;
  v_nick TEXT;
BEGIN
  -- แถวของบิลในกระเป๋า Sales (ไม่นับแถวที่เกิดจากการแก้บิลเอง)
  SELECT COUNT(DISTINCT user_id), (MIN(user_id::text))::uuid, MIN(date), MAX(date)
    INTO v_n_users, v_user, v_min, v_max
  FROM user_cashbook
  WHERE ref_tx_id = p_tx_id AND id NOT LIKE 'UCB-EDIT-%' AND id NOT LIKE 'UE%';

  IF COALESCE(v_n_users, 0) = 0 THEN
    RETURN jsonb_build_object('mode', 'SHOP');
  END IF;
  IF v_n_users > 1 THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้มี Sales รับเงินหลายคน แก้ไขไม่ได้');
  END IF;
  IF EXISTS (SELECT 1 FROM transaction_payments
             WHERE tx_id = p_tx_id AND paid_by_id IS DISTINCT FROM v_user) THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้มีทั้ง Sales และ Manager รับ/จ่ายเงิน แก้ไขไม่ได้');
  END IF;

  SELECT COALESCE(NULLIF(TRIM(nickname), ''), username) INTO v_nick FROM users WHERE id = v_user;

  -- กะแรกที่ปิดหลังจ่ายเงินของบิลนี้ (เงินก่อนเวลากดปิดกะถูกกวาดเข้าร้านตอนอนุมัติ)
  SELECT id, status INTO v_c1_id, v_c1_st FROM closes
  WHERE user_id = v_user AND status IN ('PENDING', 'APPROVED') AND date >= v_min
  ORDER BY date LIMIT 1;
  SELECT id INTO v_c2_id FROM closes
  WHERE user_id = v_user AND status IN ('PENDING', 'APPROVED') AND date >= v_max
  ORDER BY date LIMIT 1;

  IF v_c1_id IS DISTINCT FROM v_c2_id THEN
    RETURN jsonb_build_object('blocked', '❌ บิลนี้จ่ายเงินข้ามกะ แก้ไขไม่ได้');
  END IF;
  IF v_c1_id IS NULL THEN
    RETURN jsonb_build_object('mode', 'SHIFT', 'user_id', v_user, 'nickname', v_nick);
  END IF;
  IF v_c1_st = 'PENDING' THEN
    RETURN jsonb_build_object('blocked',
      '❌ ' || COALESCE(v_nick, 'Sales') || ' ส่งปิดกะแล้ว (' || v_c1_id || ') รอ Manager อนุมัติ — อนุมัติหรือปฏิเสธการปิดกะก่อนจึงจะแก้บิลได้');
  END IF;
  RETURN jsonb_build_object('mode', 'SHOP', 'user_id', v_user, 'nickname', v_nick, 'close_id', v_c1_id);
END;
$$;
