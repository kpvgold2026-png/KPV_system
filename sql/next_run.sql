-- ============================================================
-- next_run.sql — Round 7.6 (2026-05-28)
-- ============================================================
-- 1) FIX add_cashbank_entry — cast p_type::cashbank_type + p_currency::currency_code
--    เดิม INSERT ส่ง TEXT ตรง ๆ ลงคอลัมน์ enum → error
--    "column \"type\" is of type cashbank_type but expression is of type text"
--    → cashbank ทุกประเภทพังหมด (CASH_IN/OUT, BANK_DEPOSIT/WITHDRAW,
--      OTHER_INCOME/EXPENSE) ไม่ใช่แค่ CASH_OUT
--
-- 2) FIX stock_in_new_tx — cashbank.ref_tx_id = 'SIN-...' ชน FK → transactions.id
--    (ไม่มี transactions row ของ SIN) → FK violation → rollback ทั้ง tx
--    → stock_moves ไม่ถูกบันทึก → ตาราง Stock New ว่าง
--    แก้: ref_tx_id = NULL + ฝัง [ref:SIN-...] ใน note (pattern เดียวกับ reset.sql)
--
-- 3) FIX get_stock_move_detail — payments match (ref_tx_id = ref OR note LIKE [ref:..])
--    ให้ payment breakdown ของ STOCK_IN (และ bootstrap) โผล่ใน View Detail
--
-- 4) User password plaintext — เพิ่ม users.password_plain + save_user เขียนค่า
--    + list_users คืน password เพื่อแสดงใน User Setting / prefill ตอนแก้ไข
--    (⚠️ เก็บรหัสผ่านแบบ plaintext ตามที่ร้องขอ — ดูหมายเหตุท้ายไฟล์)
-- ============================================================


-- ============================================================
-- 1) add_cashbank_entry — FIX enum cast
-- ============================================================
DROP FUNCTION IF EXISTS public.add_cashbank_entry(text, numeric, text, text, text, text);
DROP FUNCTION IF EXISTS public.add_cashbank_entry(text, numeric, text, text, text, text, numeric);

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
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Auth required');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Amount must be > 0');
  END IF;

  -- LAK บังคับ rate = 1; foreign currency ต้อง rate > 0
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

  v_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS')
                || '-' || substring(md5(random()::text), 1, 4);

  -- ⚠️ type / currency เป็น ENUM (cashbank_type / currency_code)
  --    ต้อง cast จาก TEXT param ไม่งั้น error type mismatch
  INSERT INTO cashbank (id, type, amount, currency, rate, method,
                        bank_id, ref_tx_id, note, date)
  VALUES (v_id, p_type::cashbank_type, p_amount, UPPER(p_currency)::currency_code,
          v_rate, p_method, v_bank_id, NULL, p_note, NOW());

  RETURN jsonb_build_object(
    'success', true,
    'id', v_id,
    'lak', p_amount * v_rate
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.add_cashbank_entry(text, numeric, text, text, text, text, numeric) TO authenticated;


-- ============================================================
-- 2) stock_in_new_tx — FIX FK violation (ref_tx_id → NULL + [ref:] ใน note)
-- ============================================================
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
  v_pid TEXT;
  v_qty NUMERIC;
  v_weight NUMERIC;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF NOT is_admin() AND NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager or Admin only');
  END IF;

  v_ref_id := 'SIN-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

  FOR v_item IN SELECT (value->>'productId') AS pid, (value->>'qty')::numeric AS qty
                FROM jsonb_array_elements(p_items) LOOP
    SELECT weight_baht * 15 INTO v_weight FROM products WHERE id = v_item.pid;
    IF v_weight IS NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Unknown product: ' || v_item.pid);
    END IF;
    v_total_g := v_total_g + (v_weight * v_item.qty);
  END LOOP;

  INSERT INTO stock_moves (ref_id, gold_type, type, direction, gold_g, price, wac_per_g, wac_per_baht, fulfilled, user_id, note, date)
  VALUES (v_ref_id, 'NEW', 'STOCK_IN', 'IN', v_total_g, p_cost,
          CASE WHEN v_total_g > 0 THEN p_cost / v_total_g ELSE 0 END,
          CASE WHEN v_total_g > 0 THEN (p_cost / v_total_g) * 15 ELSE 0 END,
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

  FOR v_pay IN SELECT * FROM jsonb_array_elements(p_payments) LOOP
    DECLARE
      v_method TEXT := v_pay->>'method';
      v_bank_name TEXT := v_pay->>'bank';
      v_cur TEXT := COALESCE(v_pay->>'currency', 'LAK');
      v_amount NUMERIC := (v_pay->>'amount')::numeric;
      v_rate NUMERIC := COALESCE((v_pay->>'rate')::numeric, 1);
      v_fee NUMERIC := COALESCE((v_pay->>'fee')::numeric, 0);
      v_bank_id UUID := NULL;
    BEGIN
      IF v_method = 'Bank' AND v_bank_name IS NOT NULL AND v_bank_name <> '' THEN
        SELECT id INTO v_bank_id FROM banks WHERE name = v_bank_name LIMIT 1;
      END IF;

      -- ⚠️ ref_tx_id มี FK → transactions.id ; SIN-... ไม่มี row ใน transactions
      --    → set NULL แล้วผูกผ่าน [ref:...] ใน note (get_stock_move_detail ค้นเจอผ่าน LIKE)
      v_cb_id := 'CB-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text || v_method), 1, 6);
      INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
      VALUES (v_cb_id, 'STOCK_IN', -v_amount, v_cur::currency_code, v_rate,
              CASE WHEN v_method = 'Cash' THEN 'CASH' ELSE 'TRANSFER' END,
              v_bank_id, NULL,
              COALESCE(NULLIF(p_note, ''), 'Stock In NEW') || ' [ref:' || v_ref_id || ']',
              NOW(), v_user_id);

      IF v_fee > 0 THEN
        v_cb_id := 'CB-FEE-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISSMS') || '-' || substring(md5(random()::text), 1, 4);
        INSERT INTO cashbank (id, type, amount, currency, rate, method, bank_id, ref_tx_id, note, date, created_by_id)
        VALUES (v_cb_id, 'STOCK_IN_FEE', -v_fee, v_cur::currency_code, v_rate, 'TRANSFER', v_bank_id, NULL,
                'Stock In Fee [ref:' || v_ref_id || ']', NOW(), v_user_id);
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Stock In สำเร็จ', 'ref_id', v_ref_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION stock_in_new_tx(JSONB, TEXT, NUMERIC, JSONB, NUMERIC) TO authenticated;


-- ============================================================
-- 3) get_stock_move_detail — FIX payments match (ref_tx_id OR note [ref:..])
-- ============================================================
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text);
DROP FUNCTION IF EXISTS public.get_stock_move_detail(text, text);

CREATE OR REPLACE FUNCTION public.get_stock_move_detail(
  p_ref_id TEXT,
  p_gold_type TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_move RECORD;
  v_items JSONB;
  v_payments JSONB;
  v_price_per_g NUMERIC := 0;
  v_price_per_baht NUMERIC := 0;
  v_wac_per_g NUMERIC := 0;
  v_wac_per_baht NUMERIC := 0;
BEGIN
  SELECT sm.id, sm.ref_id, sm.gold_type, sm.type, sm.direction,
         sm.gold_g, sm.price, sm.wac_per_g, sm.wac_per_baht,
         sm.date, sm.note
    INTO v_move
    FROM stock_moves sm
    WHERE sm.ref_id = p_ref_id
      AND (p_gold_type IS NULL OR sm.gold_type::text = p_gold_type)
    ORDER BY CASE WHEN sm.direction = 'IN' THEN 0 ELSE 1 END,
             sm.date ASC
    LIMIT 1;

  IF v_move.id IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object('productId', smi.product_id, 'qty', smi.qty)
           ORDER BY smi.product_id
         ), '[]'::jsonb)
    INTO v_items
    FROM stock_move_items smi
    WHERE smi.move_id = v_move.id;

  IF v_move.gold_g > 0 THEN
    v_price_per_g := COALESCE(v_move.price, 0) / v_move.gold_g;
    v_price_per_baht := v_price_per_g * 15;
  END IF;
  v_wac_per_g := COALESCE(v_move.wac_per_g, 0);
  v_wac_per_baht := COALESCE(v_move.wac_per_baht, v_wac_per_g * 15);

  -- payments: ผูกผ่าน ref_tx_id ตรง ๆ หรือ [ref:..] ใน note (STOCK_IN/TRANSFER/bootstrap)
  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'type', cb.type,
             'method', cb.method,
             'bank', COALESCE(b.name, ''),
             'currency', cb.currency,
             'amount', cb.amount,
             'rate', COALESCE(cb.rate, 1),
             'lak', cb.amount * COALESCE(cb.rate, 1)
           )
           ORDER BY cb.date ASC, cb.id ASC
         ), '[]'::jsonb)
    INTO v_payments
    FROM cashbank cb
    LEFT JOIN banks b ON b.id = cb.bank_id
    WHERE cb.ref_tx_id = p_ref_id
       OR cb.note LIKE '%[ref:' || p_ref_id || ']%';

  RETURN jsonb_build_object(
    'found', true,
    'ref_id', v_move.ref_id,
    'gold_type', v_move.gold_type,
    'type', v_move.type,
    'direction', v_move.direction,
    'gold_g', v_move.gold_g,
    'price', v_move.price,
    'price_per_g', v_price_per_g,
    'price_per_baht', v_price_per_baht,
    'wac_per_g', v_wac_per_g,
    'wac_per_baht', v_wac_per_baht,
    'date', v_move.date,
    'note', v_move.note,
    'items', v_items,
    'payments', v_payments
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_stock_move_detail(text, text) TO authenticated;


-- ============================================================
-- 4) User password plaintext
-- ============================================================
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS password_plain TEXT;

-- ----- save_user: เขียน password_plain เพิ่ม (นอกจาก hash) -----
CREATE OR REPLACE FUNCTION save_user(
  p_user_id UUID,
  p_role user_role,
  p_nickname TEXT,
  p_username TEXT,
  p_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_existing UUID;
  v_new_id UUID;
  v_email TEXT;
  v_hash TEXT;
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;

  IF p_username IS NULL OR length(trim(p_username)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Username required');
  END IF;

  v_email := lower(trim(p_username)) || '@kpv.local';

  IF p_user_id IS NULL THEN
    -- ===== สร้างใหม่ =====
    SELECT id INTO v_existing FROM public.users WHERE username = p_username;
    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'message', 'Username already exists');
    END IF;
    IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_email) THEN
      RETURN jsonb_build_object('success', false, 'message', 'Email already exists in auth.users');
    END IF;
    IF p_password IS NULL OR length(p_password) = 0 THEN
      RETURN jsonb_build_object('success', false, 'message', 'Password required for new user');
    END IF;

    v_new_id := gen_random_uuid();
    v_hash := hash_password(p_password);

    INSERT INTO auth.users (
      id, instance_id, aud, role,
      email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token,
      reauthentication_token,
      created_at, updated_at
    )
    VALUES (
      v_new_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      'authenticated', 'authenticated',
      v_email, v_hash, NOW(),
      jsonb_build_object(
        'provider', 'email',
        'providers', jsonb_build_array('email'),
        'user_role', p_role::text
      ),
      jsonb_build_object('username', p_username, 'nickname', p_nickname),
      '', '',
      '', '', '',
      '', '',
      '',
      NOW(), NOW()
    );

    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    VALUES (
      gen_random_uuid(),
      v_new_id,
      v_new_id::text,
      jsonb_build_object(
        'sub', v_new_id::text,
        'email', v_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      NOW(), NOW(), NOW()
    );

    INSERT INTO public.users (id, role, nickname, username, password_hash, password_plain, is_active)
    VALUES (v_new_id, p_role, p_nickname, p_username, v_hash, p_password, TRUE);

    RETURN jsonb_build_object('success', true, 'message', 'User created', 'user_id', v_new_id);

  ELSE
    -- ===== แก้ไข =====
    v_hash := CASE
      WHEN p_password IS NULL OR length(p_password) = 0 THEN NULL
      ELSE hash_password(p_password)
    END;

    UPDATE public.users SET
      role = p_role,
      nickname = p_nickname,
      username = p_username,
      password_hash = COALESCE(v_hash, password_hash),
      password_plain = COALESCE(NULLIF(p_password, ''), password_plain),
      updated_at = NOW()
    WHERE id = p_user_id;

    UPDATE auth.users SET
      email = v_email,
      encrypted_password = COALESCE(v_hash, encrypted_password),
      raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object(
             'provider', 'email',
             'providers', jsonb_build_array('email'),
             'user_role', p_role::text
           ),
      raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object('username', p_username, 'nickname', p_nickname),
      updated_at = NOW()
    WHERE id = p_user_id;

    IF EXISTS (SELECT 1 FROM auth.identities WHERE user_id = p_user_id AND provider = 'email') THEN
      UPDATE auth.identities SET
        identity_data = COALESCE(identity_data, '{}'::jsonb)
          || jsonb_build_object(
               'sub', p_user_id::text,
               'email', v_email,
               'email_verified', true
             ),
        updated_at = NOW()
      WHERE user_id = p_user_id AND provider = 'email';
    ELSE
      INSERT INTO auth.identities (
        id, user_id, provider_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
      )
      VALUES (
        gen_random_uuid(),
        p_user_id,
        p_user_id::text,
        jsonb_build_object(
          'sub', p_user_id::text,
          'email', v_email,
          'email_verified', true,
          'phone_verified', false
        ),
        'email',
        NOW(), NOW(), NOW()
      );
    END IF;

    RETURN jsonb_build_object('success', true, 'message', 'User updated');
  END IF;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION save_user(UUID, user_role, TEXT, TEXT, TEXT) TO authenticated;


-- ----- list_users: คืน password (plaintext) เพิ่ม -----
CREATE OR REPLACE FUNCTION list_users()
RETURNS JSONB AS $$
BEGIN
  IF NOT is_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Admin only');
  END IF;
  RETURN jsonb_build_object('success', true, 'data', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id,
      'role', role,
      'nickname', nickname,
      'username', username,
      'password', password_plain,
      'is_active', is_active
    ) ORDER BY role, nickname), '[]'::jsonb)
    FROM users WHERE is_active = TRUE
  ));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION list_users() TO authenticated;


-- ============================================================
-- ทดสอบหลังรัน
-- ============================================================
--   -- 1) cashbank ทุกประเภทต้องผ่าน (ไม่ error type mismatch)
--   SELECT add_cashbank_entry('CASH_OUT', 50000, 'LAK', 'CASH', NULL, 'test out');
--   SELECT add_cashbank_entry('BANK_WITHDRAW', 100, 'USD', 'BANK', 'BCEL', 'test', 22000);
--
--   -- 2) Stock In NEW ต้องสำเร็จ + โผล่ใน get_stock_moves('NEW')
--   --    (ทดสอบผ่าน UI; ตรวจ stock_moves ว่ามี row STOCK_IN/NEW วันนี้)
--   SELECT get_stock_moves('NEW');
--
--   -- 3) payments ของ STOCK_IN ต้องโผล่ใน detail
--   --    SELECT get_stock_move_detail('SIN-...', 'NEW');
--
--   -- 4) password แสดงใน list_users (ของ user ที่ตั้ง/แก้รหัสหลังรันไฟล์นี้)
--   SELECT list_users();
--
-- ⚠️ หมายเหตุ password_plain:
--   - user ที่สร้าง "ก่อน" รันไฟล์นี้ยังไม่มี plaintext (กู้จาก hash ไม่ได้)
--     → จะแสดงว่าง จนกว่าจะแก้ไข/ตั้งรหัสใหม่ผ่าน User Setting
--   - การเก็บรหัสผ่าน plaintext เป็น security trade-off ตามที่ร้องขอ
--     (เครื่องมือภายในร้าน) — RLS ของ users + list_users จำกัดเฉพาะ Admin
