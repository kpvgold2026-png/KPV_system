-- KPV R20 only — (R20-1) จ่าย Buyback หลายรายการแบบ all-or-nothing + (R20-2) แก้ไขบิลที่จบแล้ว Admin เท่านั้น — รันหลัง r19_4_only.sql

-- ============================================================
-- [R20-1] confirm_buyback_multi_tx — จ่าย Buyback ทุกรายการใน RPC เดียว
--   เดิมหน้าเว็บเรียก confirm_buyback_tx ทีละรายการ → รายการแรกสำเร็จแล้วรายการถัดไป error
--     = รายการแรกค้างในบิล (เช่น เงินสด LAK) แม้ผู้ใช้จะแก้รายการแล้วกดจ่ายใหม่
--   ตอนนี้: รายการไหน error → RAISE → ยกเลิกทุกรายการของรอบนั้น (ไม่มีอะไรถูกบันทึก)
--   ธนาคาร: หา bank_id จากชื่อฝั่ง server (_resolve_bank_id) เหมือนบิลขาย
--   กันจ่ายเกิน: ยอดรวมรอบนี้ (เรทรับซื้อ) ต้องไม่เกินยอดค้างจริงของบิล
-- ============================================================
DROP FUNCTION IF EXISTS confirm_buyback_multi_tx(TEXT, JSONB, BOOLEAN);

CREATE FUNCTION confirm_buyback_multi_tx(
  p_tx_id TEXT, p_payments JSONB, p_allow_short BOOLEAN DEFAULT FALSE
)
RETURNS JSONB AS $$
DECLARE
  v_status tx_status;
  v_price NUMERIC;
  v_paid NUMERIC;
  v_thb NUMERIC;
  v_usd NUMERIC;
  v_sum_lak NUMERIC := 0;
  v_p JSONB;
  v_cur TEXT;
  v_amt NUMERIC;
  v_method TEXT;
  v_bank_id UUID;
  v_n INT;
  v_i INT := 0;
  v_res JSONB;
BEGIN
  IF p_payments IS NULL OR jsonb_typeof(p_payments) <> 'array' OR jsonb_array_length(p_payments) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ ไม่มีรายการชำระเงิน');
  END IF;
  v_n := jsonb_array_length(p_payments);

  SELECT t.status, t.price, COALESCE(t.paid, 0)
    INTO v_status, v_price, v_paid
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK'
  FOR UPDATE;

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
  END IF;

  SELECT thb_buy, usd_buy INTO v_thb, v_usd FROM price_rates ORDER BY date DESC LIMIT 1;

  FOR v_p IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    v_cur := UPPER(COALESCE(v_p->>'currency', 'LAK'));
    v_amt := COALESCE((v_p->>'amount')::NUMERIC, 0);
    v_sum_lak := v_sum_lak + v_amt * CASE WHEN v_cur = 'THB' THEN COALESCE(v_thb, 0)
                                          WHEN v_cur = 'USD' THEN COALESCE(v_usd, 0)
                                          ELSE 1 END;
  END LOOP;

  -- ยอดค้างจริงจาก DB (ไม่เชื่อยอดบนหน้าจอที่อาจค้างเก่า) — เผื่อปัดเศษ 1 LAK
  IF v_sum_lak > (v_price - v_paid) + 1 THEN
    RETURN jsonb_build_object('success', false, 'message',
      '❌ ยอดจ่ายเกินยอดค้าง! จ่าย: ' || to_char(ROUND(v_sum_lak), 'FM999,999,999,990')
      || ' LAK / ค้าง: ' || to_char(ROUND(v_price - v_paid), 'FM999,999,999,990') || ' LAK');
  END IF;

  BEGIN
    FOR v_p IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
      v_i := v_i + 1;
      v_cur := UPPER(COALESCE(v_p->>'currency', 'LAK'));
      v_amt := COALESCE((v_p->>'amount')::NUMERIC, 0);
      v_method := UPPER(COALESCE(v_p->>'method', 'CASH'));
      v_bank_id := NULL;
      IF v_method <> 'CASH' THEN
        v_bank_id := _resolve_bank_id(v_p->>'bank');
        IF v_bank_id IS NULL THEN
          RAISE EXCEPTION '❌ กรุณาเลือกธนาคาร';
        END IF;
      END IF;

      v_res := confirm_buyback_tx(
        p_tx_id, v_amt, v_cur::currency_code, v_method, v_bank_id, 0, 0,
        COALESCE(p_allow_short, FALSE) AND v_i = v_n
      );
      IF NOT COALESCE((v_res->>'success')::BOOLEAN, FALSE) THEN
        RAISE EXCEPTION '%', COALESCE(v_res->>'message', 'Unknown');
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    -- rollback ทุกรายการของรอบนี้ (ย้อนถึงจุดเริ่ม BEGIN block)
    RETURN jsonb_build_object('success', false, 'message', SQLERRM);
  END;

  RETURN v_res;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_buyback_multi_tx(TEXT, JSONB, BOOLEAN) TO authenticated;


-- ============================================================
-- [R20-2] แก้ไขบิลที่จบแล้ว (ยอดเงิน R19-3 / ยอดทอง R19-4) → Admin เท่านั้น
--   เดิม Manager/Admin ; ตอนนี้ Manager และ Sales แก้ไม่ได้
--   = ฟังก์ชันเดิมจาก r19_only.sql / r19_4_only.sql เปลี่ยนแค่เช็คสิทธิ์ is_admin() + ข้อความ
-- ============================================================
CREATE OR REPLACE FUNCTION get_tx_payment_edit_info(p_tx_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tx RECORD;
  v_led JSONB;
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', '❌ Admin เท่านั้นที่แก้ไขบิลได้');
  END IF;

  SELECT t.id, t.type::text AS type, t.status::text AS status, t.total, t.price,
         t.change_amount, t.phone
    INTO v_tx
  FROM transactions t WHERE t.id = p_tx_id;
  IF v_tx.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_tx.type NOT IN ('SELL', 'TRADEIN', 'EXCHANGE', 'WITHDRAW', 'BUYBACK') THEN
    RETURN jsonb_build_object('success', false, 'message', 'ธุรกรรมประเภทนี้แก้การชำระไม่ได้');
  END IF;
  IF v_tx.status NOT IN ('COMPLETED', 'PAID') THEN
    RETURN jsonb_build_object('success', false, 'message', 'แก้ได้เฉพาะบิลที่จบแล้ว (สถานะ ' || v_tx.status || ')');
  END IF;

  v_led := _tx_edit_ledger(p_tx_id);
  IF v_led ? 'blocked' THEN
    RETURN jsonb_build_object('success', false, 'message', v_led->>'blocked');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'type', v_tx.type,
    'phone', v_tx.phone,
    'total', CASE WHEN v_tx.type = 'BUYBACK' THEN COALESCE(v_tx.price, v_tx.total) ELSE v_tx.total END,
    'change', COALESCE(v_tx.change_amount, 0),
    'ledger', v_led,
    'payments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('method', tp.method, 'currency', tp.currency,
                                          'amount', tp.amount, 'bank', b.name))
      FROM transaction_payments tp LEFT JOIN banks b ON b.id = tp.bank_id
      WHERE tp.tx_id = p_tx_id), '[]'::jsonb),
    'edits', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('edited_at', e.edited_at, 'mode', e.mode, 'reason', e.reason,
                                          'by', COALESCE(NULLIF(TRIM(u.nickname), ''), u.username))
                       ORDER BY e.edited_at)
      FROM tx_payment_edits e LEFT JOIN users u ON u.id = e.edited_by_id
      WHERE e.tx_id = p_tx_id), '[]'::jsonb)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION get_tx_payment_edit_info(TEXT) TO authenticated;

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
      VALUES ('CB-EDIT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6),
              v_cb_type, v_d.delta, v_d.currency::currency_code, v_d.method, v_d.bank_id,
              p_tx_id, v_note, NOW(), v_editor);
    END IF;

    -- กระเป๋า Sales (SHIFT): ลงทุกช่องเหมือนตอนยืนยันบิล (โอน = แถวติดตาม เคลียร์ตอนปิดกะ)
    IF v_is_shift THEN
      INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
      VALUES ('UCB-EDIT-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6),
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
GRANT EXECUTE ON FUNCTION edit_tx_payments(TEXT, JSONB, NUMERIC, TEXT) TO authenticated;

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
