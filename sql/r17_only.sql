-- KPV R17 only (R17-1) — Buyback: ยอดค้าง ≤ 500 LAK เมื่อจ่ายด้วยสกุลอื่น → ปิดบิลตาม Total

-- [R17-1] p_allow_short: ยอดค้าง ≤ 500 LAK (จ่ายด้วยสกุลอื่น) → ปิดบิลเป็น COMPLETED, paid = price
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC);

CREATE FUNCTION confirm_buyback_tx(
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
  ELSIF COALESCE(p_allow_short, FALSE) AND p_currency <> 'LAK' AND v_new_balance <= 500 THEN
    -- [R17-1] เศษจากการแปลงสกุล ≤ 500 LAK → ถือว่าจ่ายครบตาม Total
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
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): หักเงินที่จ่ายออก (สกุลจริง)
  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
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
GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC, BOOLEAN) TO authenticated;
