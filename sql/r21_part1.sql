-- KPV R21 part 1/4 — รันตามลำดับ part1 → part4 (หลัง r20_only.sql) — Run without RLS
--   ‼️ รันหลัง r20_only.sql (edit_tx_payments ในไฟล์นี้มาจาก R20) — เลือก "Run without RLS"
--   ใช้ _next_admin_ref(prefix, op) + ตาราง admin_ref_counter (นับต่อปี แยกตาม op)
--   SI = รับทองใหม่ (STOCK_IN)      SH = เปิดกะ (SHIFT)          CL = ปิดกะ (CLOSE)
--   CB = เงินร้าน cashbank (CASHBANK)    UC = กระเป๋า Sales user_cashbook (USER_CASHBOOK)
--   CE = แก้การชำระบิล cashbank (CASHBANK_EDIT)   UE = แก้การชำระบิล user_cashbook (USER_CASHBOOK_EDIT)
--   (SE/TI/EX/BB/WD/TF/SO เป็นรูปแบบนี้อยู่แล้ว ไม่แก้) — ข้อมูลเก่าไม่แปลง เลขเดิมคงไว้

-- [R21] _apply_confirm_payments — เงินร้าน CB / กระเป๋า Sales UC ตอนยืนยันบิล (จาก next_run.sql)
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
      v_cb_id := _next_admin_ref('CB', 'CASHBANK');
      INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, p_cb_type, v_e.amount, v_e.cur::currency_code, v_method, v_bank_id,
              p_tx_id, p_note, NOW(), p_user_id);
    END IF;

    IF p_is_sales THEN
      v_ucb_id := _next_admin_ref('UC', 'USER_CASHBOOK');
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

-- [R21] _apply_change_deduction — เงินทอน CB / UC (จาก next_run.sql)
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
    v_id := _next_admin_ref('UC', 'USER_CASHBOOK');
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, ref_tx_id, note, date)
    VALUES (v_id, p_user_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW());
  ELSE
    IF NOT check_shop_balance('CASH', 'LAK', NULL, p_change) THEN
      RETURN '❌ เงินสด LAK ในร้านไม่พอทอน ' || to_char(p_change, 'FM999,999,999,990') || ' LAK';
    END IF;
    v_id := _next_admin_ref('CB', 'CASHBANK');
    INSERT INTO cashbank (id, type, amount, currency, method, ref_tx_id, note, date, created_by_id)
    VALUES (v_id, 'CHANGE', -p_change, 'LAK', 'CASH', p_tx_id, 'เงินทอน ' || p_tx_id, NOW(), p_user_id);
  END IF;

  RETURN NULL;
END;
$$;

-- [R21] confirm_buyback_tx — จ่ายซื้อคืน CB / UC (จาก next_run.sql)
CREATE OR REPLACE FUNCTION confirm_buyback_tx(
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
  ELSIF COALESCE(p_allow_short, FALSE) AND v_new_balance <= 500 THEN
    -- [R19-1] ยอดค้าง ≤ 500 LAK (ทุกสกุล รวม LAK) → ถือว่าจ่ายครบตาม Total
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
    v_cb_id := _next_admin_ref('CB', 'CASHBANK');
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): หักเงินที่จ่ายออก (สกุลจริง)
  IF v_is_sales THEN
    v_ucb_id := _next_admin_ref('UC', 'USER_CASHBOOK');
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

-- [R21] add_cashbank_entry — รายการเงินร้านที่ Admin เพิ่มเอง CB (จาก next_run.sql)
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

  v_cb_id := _next_admin_ref('CB', 'CASHBANK');

  INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, note, date, created_by_id)
  VALUES (v_cb_id, p_type::cashbank_type, v_signed_amount, v_eff_currency::currency_code, v_rate,
          p_method, v_bank_id, v_note, NOW(), v_user_id);

  RETURN jsonb_build_object('success', true, 'id', v_cb_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

