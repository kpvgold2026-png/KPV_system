-- ============================================================
-- ROUND 8 — next_run.sql  (รันทับไฟล์เดิม / รันทั้งไฟล์ใน Supabase SQL Editor)
-- ============================================================
-- โจทย์รอบนี้:
--  • โมเดลเงินใหม่: เงินสด (CASH) ที่ Sales ได้มา → อยู่ที่กระเป๋า Sales
--    (user_cashbook) เท่านั้น ไม่เข้า cashbank ร้านทันที.  เงินโอน (BANK)
--    → เข้าร้าน (cashbank) โดยตรง.  Manager/Admin → เข้าร้านทุกกรณี.
--  • ข้อ6: confirm_buyback_tx — แก้บั๊ก method 'Cash' (เทียบ case ผิด) ที่ทำให้
--    จ่าย Buyback เงินสดไม่ได้ + จ่ายจากกระเป๋า Sales ถ้าเป็น Sales+เงินสด
--  • ข้อ4: transfer_user_cash_to_shop — เพิ่ม check ฝั่ง server ว่าเงินพอ
--  • ข้อ8: approve_close_report — อนุมัติปิดกะแล้วโอนเงินสดที่ Sales ถือเข้าร้านอัตโนมัติ
--  • ข้อ9: get_live_report (Box Wealth) — ทองเมื่อวาน − ทองปัจจุบัน (จาก stock_moves)
--  • ข้อ3: get_live_report_sales_breakdown — สถานะกะดูจาก OPEN_SHIFT จริง + กรอง user ที่ใช้งานอยู่
-- ============================================================


-- ============================================================
-- helper: check_user_cash_balance — เงินสดในกระเป๋า Sales (user_cashbook) พอไหม
-- ============================================================
CREATE OR REPLACE FUNCTION check_user_cash_balance(
  p_user_id UUID,
  p_currency currency_code,
  p_amount NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RETURN TRUE; END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_balance
  FROM user_cashbook
  WHERE user_id = p_user_id AND method = 'CASH' AND currency = p_currency;
  RETURN v_balance >= p_amount;
END;
$$;
GRANT EXECUTE ON FUNCTION check_user_cash_balance(UUID, currency_code, NUMERIC) TO authenticated;


-- ============================================================
-- 0) add_cashbank_entry — ข้อ1: เงินออก (OUT) ต้องเก็บเป็นค่าลบ
--    เดิมเก็บบวกหมดทุก type → get_cashbank_balances (SUM(amount)) คิดยอดผิด
--    OUT = CASH_OUT / BANK_WITHDRAW / OTHER_EXPENSE → เก็บ -amount
--    IN  = CASH_IN / BANK_DEPOSIT / OTHER_INCOME    → เก็บ +amount
-- ============================================================
CREATE OR REPLACE FUNCTION public.add_cashbank_entry(
  p_type TEXT,
  p_amount NUMERIC,
  p_currency TEXT,
  p_method TEXT,
  p_bank_name TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL,
  p_rate NUMERIC DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_user_id UUID;
  v_id TEXT;
  v_bank_id UUID;
  v_rate NUMERIC;
  v_signed_amount NUMERIC;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Auth required');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Amount must be > 0');
  END IF;

  IF UPPER(p_currency) = 'LAK' THEN
    v_rate := 1;
  ELSE
    v_rate := COALESCE(p_rate, 0);
    IF v_rate <= 0 THEN
      RETURN jsonb_build_object('success', false, 'message',
              'Rate ต้อง > 0 สำหรับสกุล ' || p_currency);
    END IF;
  END IF;

  IF p_method = 'BANK' AND p_bank_name IS NOT NULL AND p_bank_name <> '' THEN
    SELECT id INTO v_bank_id FROM banks WHERE name = p_bank_name LIMIT 1;
  END IF;

  -- เงินออก → ค่าลบ
  v_signed_amount := CASE
    WHEN p_type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE') THEN -ABS(p_amount)
    ELSE ABS(p_amount)
  END;

  v_id := _next_admin_ref('CB', 'CASHBANK');

  INSERT INTO cashbank (id, type, amount, currency, rate, method,
                        bank_id, ref_tx_id, note, date)
  VALUES (v_id, p_type::cashbank_type, v_signed_amount, UPPER(p_currency)::currency_code,
          v_rate, p_method, v_bank_id, NULL, p_note, NOW());

  RETURN jsonb_build_object('success', true, 'id', v_id, 'lak', v_signed_amount * v_rate);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.add_cashbank_entry(text, numeric, text, text, text, text, numeric) TO authenticated;

-- one-time migration (idempotent): แก้ row เงินออกเก่าที่เก็บค่าบวกให้เป็นลบ
UPDATE cashbank SET amount = -amount
WHERE type IN ('CASH_OUT', 'BANK_OUT', 'BANK_WITHDRAW', 'OTHER_EXPENSE') AND amount > 0;


-- ============================================================
-- 1) confirm_sell_tx — เงินสด Sales เข้ากระเป๋าเท่านั้น (ไม่เข้า cashbank)
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_sell_tx(
  p_tx_id TEXT,
  p_paid NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_id UUID,
  p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_phone TEXT;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_premium NUMERIC;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);  -- เงินสดของ Sales → ไม่เข้า cashbank ร้าน

  SELECT t.status, t.total, t.phone, t.premium INTO v_status, v_total, v_phone, v_premium
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'SELL';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
  INTO v_items
  FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  UPDATE transactions
  SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
      currency = p_currency, updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'SELL', 'OUT', v_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN
    SELECT product_id, qty FROM transaction_items
    WHERE tx_id = p_tx_id AND item_role = 'NEW'
  LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty)
    VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
  SET new_gold_g = new_gold_g - v_gold_g,
      new_value = new_value - v_cost,
      updated_at = NOW()
  WHERE id = 1;

  -- เงินเข้าร้าน (cashbank): เฉพาะกรณีไม่ใช่ "เงินสดของ Sales"
  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): บันทึกทุกธุรกรรมของ Sales (ใช้คิดยอดถือ/รายงาน)
  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'SELL', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Sell ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_cost;
  INSERT INTO diffs (tx_id, type, sell_value, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'SELL', v_total, COALESCE(v_premium, 0), v_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'cost', v_cost, 'diff', v_diff);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_sell_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 2) confirm_buyback_tx — แก้บั๊ก 'Cash' + จ่ายจากกระเป๋า Sales ถ้า Sales+เงินสด
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_buyback_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_fee NUMERIC, p_change NUMERIC
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
  v_first_payment BOOLEAN;
  v_sale_user UUID;
  v_old_gold_g NUMERIC := 0;
  v_sell_1baht NUMERIC := 0;
  v_old_cost NUMERIC := 0;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_pay_from_drawer BOOLEAN;
  v_cb_method TEXT;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_pay_from_drawer := (v_is_sales AND v_is_cash);  -- Sales จ่ายเงินสดจากกระเป๋าตัวเอง
  v_cb_method := CASE WHEN v_is_cash THEN 'CASH' ELSE 'TRANSFER' END;

  SELECT t.status, t.price, t.paid, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_price, v_total_paid, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'BUYBACK';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Transaction not found');
  END IF;
  IF v_status NOT IN ('PENDING', 'PARTIAL') THEN
    RETURN jsonb_build_object('success', false, 'message', 'Cannot confirm: status is ' || v_status);
  END IF;

  -- เช็คเงินพอจ่าย: Sales+เงินสด → ดูกระเป๋า Sales ; กรณีอื่น → ดูเงินร้าน
  IF v_pay_from_drawer THEN
    IF NOT check_user_cash_balance(v_user_id, p_currency, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินสดในกระเป๋าของคุณไม่พอจ่าย Buyback');
    END IF;
  ELSE
    IF NOT check_shop_balance(v_cb_method, p_currency, p_bank_id, p_paid) THEN
      RETURN jsonb_build_object('success', false, 'message', '❌ เงินในร้านไม่พอ โปรดติดต่อ Admin');
    END IF;
  END IF;

  v_first_payment := (v_total_paid IS NULL OR v_total_paid = 0);
  v_total_paid := COALESCE(v_total_paid, 0) + p_paid;
  v_new_balance := v_price - v_total_paid;

  IF v_new_balance <= 0 THEN
    v_new_status := 'COMPLETED';
    v_new_balance := 0;
  ELSE
    v_new_status := 'PARTIAL';
  END IF;

  UPDATE transactions
  SET status = v_new_status, paid = v_total_paid, balance = v_new_balance,
      fee = COALESCE(p_fee, 0), change_amount = COALESCE(p_change, 0), updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  -- เงินออกจากร้าน (cashbank): เฉพาะกรณีไม่ใช่ "เงินสดจากกระเป๋า Sales"
  IF NOT v_pay_from_drawer THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- ค่าธรรมเนียมโอน (ถ้ามี) เป็นค่าใช้จ่ายของร้านเสมอ
  IF COALESCE(p_fee, 0) > 0 AND v_first_payment THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-FEE-' || substring(md5(p_tx_id), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'BUYBACK_FEE', p_fee, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback fee ' || p_tx_id, NOW(), v_user_id);
  END IF;

  -- กระเป๋า Sales (user_cashbook): หักเงินที่จ่ายออก (ทุก method ของ Sales เพื่อรายงาน)
  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'BUYBACK', -p_paid, p_currency, v_cb_method,
            p_bank_id, p_tx_id, 'Buyback ' || p_tx_id, NOW());
  END IF;

  IF v_new_status = 'COMPLETED' THEN
    SELECT COALESCE(SUM(ti.qty), 0),
           COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
      INTO v_total_qty, v_old_gold_g
    FROM transaction_items ti
    JOIN products p ON p.id = ti.product_id
    WHERE ti.tx_id = p_tx_id AND ti.item_role = 'OLD';

    IF v_total_qty > 0 THEN
      v_price_per_unit := v_price / v_total_qty;
    END IF;

    v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

    FOR v_item IN SELECT product_id, qty FROM transaction_items
                  WHERE tx_id = p_tx_id AND item_role = 'OLD' LOOP
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

    INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, fee, cost_diff, cost_old_gold, diff, date)
    VALUES (p_tx_id, 'BUYBACK', -v_price, 0, 0, 0, COALESCE(p_fee, 0),
            0, v_old_cost,
            ((-v_price) + 0 + 0 + 0 - 0 - v_old_cost), NOW())
    ON CONFLICT (tx_id) DO UPDATE
      SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
          switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
          fee = EXCLUDED.fee, cost_diff = EXCLUDED.cost_diff,
          cost_old_gold = EXCLUDED.cost_old_gold, diff = EXCLUDED.diff;

    PERFORM _notify_user('PAYMENT', '💰 BUYBACK ของคุณจ่ายเงินเรียบร้อย: ' || p_tx_id,
                         v_sale_user, 'buyback', p_tx_id);
  END IF;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id, 'status', v_new_status, 'balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_buyback_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC, NUMERIC) TO authenticated;


-- ============================================================
-- 3) confirm_tradein_tx — เงินสด Sales เข้ากระเป๋าเท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_tradein_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_diff_amount NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_old_cost NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.diff_amount, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_diff_amount, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'TRADEIN';

  IF v_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not found');
  END IF;
  IF v_status <> 'APPROVED' THEN
    RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first');
  END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_new_gold_g := calc_items_gold_g(v_new_items);

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
    INTO v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'FOC');

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
        currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'TRADEIN', 'OUT', v_new_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'FOC') LOOP
    INSERT INTO user_gold_received (
      user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
      price_per_unit, settled
    )
    VALUES (
      COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
      'TRADEIN', p_tx_id, NOW(), v_user_id,
      0, FALSE
    );
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'TRADEIN', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Tradein ' || p_tx_id, NOW());
  END IF;

  v_diff := COALESCE(v_diff_amount, 0) + 0 + 0 + COALESCE(v_premium, 0) - v_new_cost - v_old_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'TRADEIN', COALESCE(v_diff_amount, 0), 0, 0, COALESCE(v_premium, 0),
          v_new_cost, v_old_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold,
        diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ TRADE-IN ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'tradein', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_tradein_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 4) confirm_exchange_tx — เงินสด Sales เข้ากระเป๋าเท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_exchange_tx(
  p_tx_id TEXT, p_paid NUMERIC, p_currency currency_code,
  p_method TEXT, p_bank_id UUID, p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_ex_fee NUMERIC;
  v_switch_fee NUMERIC;
  v_premium NUMERIC;
  v_sale_user UUID;
  v_sell_1baht NUMERIC := 0;
  v_new_items JSONB;
  v_new_gold_g NUMERIC;
  v_old_gold_g NUMERIC := 0;
  v_wac_per_g NUMERIC;
  v_new_cost NUMERIC;
  v_old_cost NUMERIC := 0;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.ex_fee, t.switch_fee, t.premium, t.sale_user_id, COALESCE(t.sell_1baht, 0)
    INTO v_status, v_total, v_ex_fee, v_switch_fee, v_premium, v_sale_user, v_sell_1baht
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'EXCHANGE';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED first'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
    INTO v_new_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_new_gold_g := calc_items_gold_g(v_new_items);

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0)
    INTO v_old_gold_g
  FROM transaction_items ti
  JOIN products p ON p.id = ti.product_id
  WHERE ti.tx_id = p_tx_id AND ti.item_role IN ('OLD', 'SWITCH', 'FREE_EX');

  v_wac_per_g := get_wac_per_g();
  v_new_cost := v_new_gold_g * v_wac_per_g;
  v_old_cost := (v_sell_1baht / 15.0) * v_old_gold_g;

  UPDATE transactions
    SET status = 'COMPLETED', paid = p_paid, change_amount = p_change,
        currency = p_currency, updated_at = NOW()
    WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'EXCHANGE', 'OUT', v_new_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role = 'NEW' LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  FOR v_item IN SELECT product_id, qty FROM transaction_items
                WHERE tx_id = p_tx_id AND item_role IN ('OLD', 'SWITCH', 'FREE_EX') LOOP
    INSERT INTO user_gold_received (
      user_id, product_id, qty, type, ref_tx_id, date, created_by_id,
      price_per_unit, settled
    )
    VALUES (
      COALESCE(v_sale_user, v_user_id), v_item.product_id, v_item.qty,
      'EXCHANGE', p_tx_id, NOW(), v_user_id,
      0, FALSE
    );
  END LOOP;

  UPDATE wac_state
    SET new_gold_g = new_gold_g - v_new_gold_g,
        new_value = new_value - v_new_cost,
        updated_at = NOW()
    WHERE id = 1;

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
               || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'EXCHANGE', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Exchange ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total + COALESCE(v_ex_fee, 0) + COALESCE(v_switch_fee, 0) + COALESCE(v_premium, 0) - v_new_cost - v_old_cost;
  INSERT INTO diffs (tx_id, type, sell_value, ex_fee, switch_fee, premium, cost_diff, cost_old_gold, diff, date)
  VALUES (p_tx_id, 'EXCHANGE', v_total, COALESCE(v_ex_fee, 0), COALESCE(v_switch_fee, 0), COALESCE(v_premium, 0),
          v_new_cost, v_old_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, ex_fee = EXCLUDED.ex_fee,
        switch_fee = EXCLUDED.switch_fee, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, cost_old_gold = EXCLUDED.cost_old_gold,
        diff = EXCLUDED.diff;

  PERFORM _notify_user('INFO', '✅ EXCHANGE ของคุณเรียบร้อย: ' || p_tx_id,
                       v_sale_user, 'exchange', p_tx_id);

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_exchange_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 5) confirm_withdraw_tx — เงินสด Sales เข้ากระเป๋าเท่านั้น
-- ============================================================
CREATE OR REPLACE FUNCTION confirm_withdraw_tx(
  p_tx_id TEXT,
  p_paid NUMERIC,
  p_currency currency_code,
  p_method TEXT,
  p_bank_id UUID,
  p_change NUMERIC
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_status tx_status;
  v_total NUMERIC;
  v_premium NUMERIC;
  v_items JSONB;
  v_gold_g NUMERIC;
  v_wac_per_g NUMERIC;
  v_cost NUMERIC;
  v_move_id BIGINT;
  v_item RECORD;
  v_cb_id TEXT;
  v_ucb_id TEXT;
  v_diff NUMERIC;
  v_is_cash BOOLEAN;
  v_is_sales BOOLEAN;
  v_skip_cashbank BOOLEAN;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_is_cash := (UPPER(COALESCE(p_method, '')) = 'CASH');
  v_is_sales := (v_role = 'Sales' OR v_role IS NULL);
  v_skip_cashbank := (v_is_sales AND v_is_cash);

  SELECT t.status, t.total, t.premium INTO v_status, v_total, v_premium
  FROM transactions t WHERE t.id = p_tx_id AND t.type = 'WITHDRAW';

  IF v_status IS NULL THEN RETURN jsonb_build_object('success', false, 'message', 'Not found'); END IF;
  IF v_status <> 'APPROVED' THEN RETURN jsonb_build_object('success', false, 'message', 'Must be APPROVED'); END IF;

  SELECT jsonb_agg(jsonb_build_object('productId', product_id, 'qty', qty))
  INTO v_items FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW';

  v_gold_g := calc_items_gold_g(v_items);
  v_wac_per_g := get_wac_per_g();
  v_cost := v_gold_g * v_wac_per_g;

  UPDATE transactions
  SET status = 'COMPLETED', paid = p_paid, change_amount = p_change, currency = p_currency, updated_at = NOW()
  WHERE id = p_tx_id;

  INSERT INTO transaction_payments (tx_id, amount, currency, method, bank_id, paid_by_id)
  VALUES (p_tx_id, p_paid, p_currency, p_method, p_bank_id, v_user_id);

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, date)
  VALUES (p_tx_id, 'NEW', 'WITHDRAW', 'OUT', v_gold_g, v_total, v_wac_per_g, v_wac_per_g * 15, TRUE, v_user_id, NOW())
  RETURNING id INTO v_move_id;

  FOR v_item IN
    SELECT product_id, qty FROM transaction_items WHERE tx_id = p_tx_id AND item_role = 'NEW'
  LOOP
    INSERT INTO stock_move_items (move_id, product_id, qty) VALUES (v_move_id, v_item.product_id, v_item.qty);
    UPDATE stock_balances SET qty = qty - v_item.qty, updated_at = NOW()
    WHERE product_id = v_item.product_id AND gold_type = 'NEW';
  END LOOP;

  UPDATE wac_state
  SET new_gold_g = new_gold_g - v_gold_g,
      new_value = new_value - v_cost,
      updated_at = NOW()
  WHERE id = 1;

  IF NOT v_skip_cashbank THEN
    v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO cashbank (id, type, amount, currency, method, bank_id, ref_tx_id, note, date, created_by_id)
    VALUES (v_cb_id, 'WITHDRAW', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Withdraw ' || p_tx_id, NOW(), v_user_id);
  END IF;

  IF v_is_sales THEN
    v_ucb_id := 'UCB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(p_tx_id || random()::text), 1, 6);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, bank_id, ref_tx_id, note, date)
    VALUES (v_ucb_id, v_user_id, 'WITHDRAW', p_paid, p_currency, p_method, p_bank_id, p_tx_id, 'Withdraw ' || p_tx_id, NOW());
  END IF;

  v_diff := v_total - v_cost;
  INSERT INTO diffs (tx_id, type, sell_value, premium, cost_diff, diff, date)
  VALUES (p_tx_id, 'WITHDRAW', v_total, COALESCE(v_premium, 0), v_cost, v_diff, NOW())
  ON CONFLICT (tx_id) DO UPDATE
    SET sell_value = EXCLUDED.sell_value, premium = EXCLUDED.premium,
        cost_diff = EXCLUDED.cost_diff, diff = EXCLUDED.diff;

  RETURN jsonb_build_object('success', true, 'id', p_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION confirm_withdraw_tx(TEXT, NUMERIC, currency_code, TEXT, UUID, NUMERIC) TO authenticated;


-- ============================================================
-- 6) transfer_user_cash_to_shop — เพิ่ม check ฝั่ง server ว่าเงินสดในกระเป๋าพอ
-- ============================================================
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

    v_uc_id := 'UC-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO user_cashbook (id, user_id, type, amount, currency, method, note, date)
    VALUES (v_uc_id, v_user_id, 'CASH_OUT', -v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer to shop', NOW());

    v_cb_id := 'CB-TRF-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_t.currency), 1, 4);
    INSERT INTO cashbank (id, type, amount, currency, method, note, date, created_by_id)
    VALUES (v_cb_id, 'CASH_IN', v_t.amount, v_t.currency::currency_code, 'CASH', 'Transfer from user cash', NOW(), v_user_id);
  END LOOP;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION transfer_user_cash_to_shop(JSONB) TO authenticated;


-- ============================================================
-- 7) approve_close_report — อนุมัติปิดกะ → materialize ทองเก่า + โอนเงินสด Sales เข้าร้านอัตโนมัติ
-- ============================================================
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

  -- [LOCK] เฉพาะตอน APPROVE (materialize stock)
  PERFORM 1 FROM wac_state WHERE id = 1 FOR UPDATE;

  v_ref_id := _next_admin_ref('CL', 'CLOSE');

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

  -- ‼️ ข้อ8: โอนเงินสดที่ Sales ถืออยู่ (user_cashbook method=CASH) เข้าร้านอัตโนมัติ
  --   (เงินโอน/bank ไม่ต้อง เพราะ Sales ไม่ได้ถือไว้ — เข้าร้านตั้งแต่ตอนทำธุรกรรมแล้ว)
  FOR v_cash IN
    SELECT currency, SUM(amount) AS bal
    FROM user_cashbook
    WHERE user_id = v_close_user AND method = 'CASH'
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


-- ============================================================
-- 8) get_live_report (Box Wealth) — ทองเมื่อวาน − ทองปัจจุบัน (จาก stock_moves)
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB AS $$
DECLARE
  v_today DATE;
  v_today_start TIMESTAMPTZ;   -- = สิ้นสุดเมื่อวาน
  v_current NUMERIC := 0;      -- ทองคงเหลือปัจจุบัน (g)
  v_yest NUMERIC := 0;         -- ทองคงเหลือสิ้นวันเมื่อวาน (g)
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_today_start := (v_today::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';

  -- ทองคงเหลือ = ผลรวมสะสมของ stock_moves (IN เป็นบวก, OUT เป็นลบ)
  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_current FROM stock_moves;

  SELECT COALESCE(SUM(CASE WHEN direction = 'IN' THEN gold_g ELSE -gold_g END), 0)
    INTO v_yest FROM stock_moves WHERE date < v_today_start;

  RETURN jsonb_build_object(
    'netTotal', v_current,           -- ทองปัจจุบัน
    'carryForward', v_yest,          -- ทองเมื่อวาน (ยอดยกมา)
    'diff', v_yest - v_current       -- เมื่อวาน − ปัจจุบัน (บวก = ทองลดลงวันนี้)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;


-- ============================================================
-- 9) get_live_report_sales_breakdown — สถานะกะดูจาก OPEN_SHIFT จริง + กรอง user ใช้งานอยู่
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_report_sales_breakdown(
  p_date_from DATE, p_date_to DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
  v_today DATE := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
BEGIN
  WITH active_sales AS (
    SELECT u.id AS user_id, u.nickname
    FROM users u
    WHERE LOWER(u.role::text) IN ('sales', 'user')
      AND u.is_active = TRUE                       -- ‼️ ข้อ3: เอาเฉพาะ user ที่ใช้งานอยู่
  ),
  open_shift_today AS (
    -- เปิดกะจริง = มี record OPEN_SHIFT ใน user_cashbook วันนี้
    SELECT DISTINCT user_id
    FROM user_cashbook
    WHERE type = 'OPEN_SHIFT' AND date::date = v_today
  ),
  tx_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(t.total) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')), 0) AS sell_money,
      COUNT(*) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE')) AS sell_count,
      COALESCE(SUM(CASE WHEN t.type='BUYBACK' THEN COALESCE(t.price, t.total) ELSE 0 END), 0) AS buyback_money,
      COUNT(*) FILTER (WHERE t.type='BUYBACK') AS buyback_count,
      COALESCE(SUM(t.total) FILTER (WHERE t.type='WITHDRAW'), 0) AS withdraw_money,
      COUNT(*) FILTER (WHERE t.type='WITHDRAW') AS withdraw_count
    FROM transactions t
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID')
    GROUP BY t.sale_user_id
  ),
  gold_g_per_sale AS (
    SELECT
      t.sale_user_id,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type IN ('SELL','TRADEIN','EXCHANGE','WITHDRAW') AND ti.item_role='NEW'), 0) AS sell_gold_g,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type='BUYBACK' AND ti.item_role='OLD'), 0) AS bb_gold_g,
      COALESCE(SUM(ti.qty * p.weight_baht * 15) FILTER (WHERE t.type='WITHDRAW' AND ti.item_role='NEW'), 0) AS wd_gold_g
    FROM transactions t
    JOIN transaction_items ti ON ti.tx_id = t.id
    JOIN products p ON p.id = ti.product_id
    WHERE t.date::date BETWEEN p_date_from AND p_date_to
      AND t.status IN ('COMPLETED', 'PAID')
    GROUP BY t.sale_user_id
  ),
  old_gold_per_sale AS (
    SELECT
      ug.user_id AS sale_user_id,
      jsonb_object_agg(ug.product_id, ug.qty_sum) AS gold_qty
    FROM (
      SELECT user_id, product_id, SUM(qty) AS qty_sum
      FROM user_gold_received
      WHERE settled = FALSE
      GROUP BY user_id, product_id
    ) ug
    GROUP BY ug.user_id
  ),
  cash_per_sale AS (
    SELECT
      ucb.user_id,
      jsonb_build_object(
        'Cash', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method='CASH' AND ucb.currency='USD'), 0)
        ),
        'BCEL', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'BCEL%' AND ucb.currency='USD'), 0)
        ),
        'LDB', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE b.name ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        ),
        'Other', jsonb_build_object(
          'LAK', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='LAK'), 0),
          'THB', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='THB'), 0),
          'USD', COALESCE(SUM(ucb.amount) FILTER (WHERE ucb.method<>'CASH' AND b.name IS NOT NULL AND b.name NOT ILIKE 'BCEL%' AND b.name NOT ILIKE 'LDB%' AND ucb.currency='USD'), 0)
        )
      ) AS cash_breakdown
    FROM user_cashbook ucb
    LEFT JOIN banks b ON b.id = ucb.bank_id
    WHERE ucb.date::date BETWEEN p_date_from AND p_date_to
    GROUP BY ucb.user_id
  ),
  close_status AS (
    SELECT
      c.user_id,
      MAX(CASE WHEN c.status='PENDING' THEN 'PENDING'
               WHEN c.status='APPROVED' THEN 'CLOSED'
               ELSE NULL END) AS s
    FROM closes c
    WHERE c.date::date = v_today
    GROUP BY c.user_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'user_id',         a.user_id,
      'nickname',        a.nickname,
      'shift_status',    COALESCE(cs.s, CASE WHEN ost.user_id IS NOT NULL THEN 'OPEN' ELSE 'NOT_OPEN' END),
      'sell_money',      COALESCE(tps.sell_money, 0),
      'sell_count',      COALESCE(tps.sell_count, 0),
      'sell_gold_g',     COALESCE(ggs.sell_gold_g, 0),
      'buyback_money',   COALESCE(tps.buyback_money, 0),
      'buyback_count',   COALESCE(tps.buyback_count, 0),
      'buyback_gold_g',  COALESCE(ggs.bb_gold_g, 0),
      'withdraw_money',  COALESCE(tps.withdraw_money, 0),
      'withdraw_count',  COALESCE(tps.withdraw_count, 0),
      'withdraw_gold_g', COALESCE(ggs.wd_gold_g, 0),
      'old_gold',        COALESCE(ogs.gold_qty, '{}'::jsonb),
      'cash_breakdown',  COALESCE(cps.cash_breakdown, '{}'::jsonb)
    )
  )
  INTO v_result
  FROM active_sales a
  LEFT JOIN open_shift_today ost ON ost.user_id = a.user_id
  LEFT JOIN tx_per_sale tps ON tps.sale_user_id = a.user_id
  LEFT JOIN gold_g_per_sale ggs ON ggs.sale_user_id = a.user_id
  LEFT JOIN old_gold_per_sale ogs ON ogs.sale_user_id = a.user_id
  LEFT JOIN cash_per_sale cps ON cps.user_id = a.user_id
  LEFT JOIN close_status cs ON cs.user_id = a.user_id;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;
GRANT EXECUTE ON FUNCTION get_live_report_sales_breakdown(DATE, DATE) TO authenticated;
