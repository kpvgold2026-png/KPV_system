CREATE OR REPLACE FUNCTION get_dashboard_data(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_wac JSONB;
  v_pl_diff NUMERIC := 0;
  v_other_expense NUMERIC := 0;
  v_new_pieces NUMERIC := 0;
  v_new_g NUMERIC := 0;
  v_old_pieces NUMERIC := 0;
  v_old_g NUMERIC := 0;
  v_cash JSONB;
  v_banks JSONB;
  v_sales JSONB;
  v_buybacks JSONB;
  v_withdraws JSONB;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT row_to_json(w)::jsonb INTO v_wac FROM wac_state w WHERE id = 1;

  SELECT COALESCE(SUM(diff), 0) INTO v_pl_diff
  FROM diffs WHERE date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ABS(amount)), 0) INTO v_other_expense
  FROM cashbank WHERE type = 'OTHER_EXPENSE' AND date BETWEEN v_from AND v_to;

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * p.weight_baht * 15), 0)
  INTO v_new_pieces, v_new_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'NEW';

  SELECT
    COALESCE(SUM(sb.qty), 0),
    COALESCE(SUM(sb.qty * p.weight_baht * 15), 0)
  INTO v_old_pieces, v_old_g
  FROM stock_balances sb JOIN products p ON p.id = sb.product_id
  WHERE sb.gold_type = 'OLD';

  SELECT jsonb_object_agg(currency, total) INTO v_cash FROM (
    SELECT currency::text, COALESCE(SUM(amount), 0) AS total
    FROM cashbank WHERE method = 'CASH' GROUP BY currency
  ) t;

  SELECT jsonb_object_agg(bank_name, balances) INTO v_banks FROM (
    SELECT b.name AS bank_name,
           jsonb_object_agg(cb.currency, COALESCE(cb.total, 0)) AS balances
    FROM banks b
    LEFT JOIN (
      SELECT bank_id, currency::text, SUM(amount) AS total
      FROM cashbank
      WHERE method <> 'CASH' AND bank_id IS NOT NULL
      GROUP BY bank_id, currency
    ) cb ON cb.bank_id = b.id
    WHERE b.is_active = TRUE
    GROUP BY b.name
  ) t;

  SELECT jsonb_build_object(
    'sell', COALESCE(SUM(CASE WHEN type = 'SELL' THEN total ELSE 0 END), 0),
    'sell_count', COALESCE(SUM(CASE WHEN type = 'SELL' THEN 1 ELSE 0 END), 0),
    'tradein', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN total ELSE 0 END), 0),
    'tradein_count', COALESCE(SUM(CASE WHEN type = 'TRADEIN' THEN 1 ELSE 0 END), 0),
    'exchange', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN total ELSE 0 END), 0),
    'exchange_count', COALESCE(SUM(CASE WHEN type = 'EXCHANGE' THEN 1 ELSE 0 END), 0)
  ) INTO v_sales
  FROM transactions
  WHERE type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND status IN ('COMPLETED', 'PAID')
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_buybacks
  FROM transactions
  WHERE type = 'BUYBACK' AND status IN ('COMPLETED', 'PAID')
    AND date BETWEEN v_from AND v_to;

  SELECT jsonb_build_object(
    'amount', COALESCE(SUM(total), 0),
    'count', COUNT(*)
  ) INTO v_withdraws
  FROM transactions
  WHERE type = 'WITHDRAW' AND status IN ('COMPLETED', 'PAID')
    AND date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'wac', COALESCE(v_wac, '{}'::jsonb),
    'pl_diff', v_pl_diff,
    'other_expense', v_other_expense,
    'new_pieces', v_new_pieces,
    'new_g', v_new_g,
    'old_pieces', v_old_pieces,
    'old_g', v_old_g,
    'cash', COALESCE(v_cash, '{}'::jsonb),
    'banks', COALESCE(v_banks, '{}'::jsonb),
    'sales', v_sales,
    'buybacks', v_buybacks,
    'withdraws', v_withdraws
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_dashboard_data(DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_sales_gold_grams(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_sales_old_g NUMERIC := 0;
  v_sales_new_g NUMERIC := 0;
  v_bb_old_g NUMERIC := 0;
  v_wd_new_g NUMERIC := 0;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT
    COALESCE(SUM(CASE WHEN ti.item_role IN ('OLD', 'FOC') THEN ti.qty * p.weight_baht * 15 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN ti.item_role = 'NEW' THEN ti.qty * p.weight_baht * 15 ELSE 0 END), 0)
  INTO v_sales_old_g, v_sales_new_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type IN ('SELL', 'TRADEIN', 'EXCHANGE')
    AND t.status IN ('COMPLETED', 'PAID')
    AND t.date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0) INTO v_bb_old_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type = 'BUYBACK' AND t.status IN ('COMPLETED', 'PAID')
    AND t.date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ti.qty * p.weight_baht * 15), 0) INTO v_wd_new_g
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type = 'WITHDRAW' AND t.status IN ('COMPLETED', 'PAID')
    AND t.date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'sales_old_g', v_sales_old_g,
    'sales_new_g', v_sales_new_g,
    'buyback_old_g', v_bb_old_g,
    'withdraw_new_g', v_wd_new_g
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_sales_gold_grams(DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_history_txs(
  p_date_from DATE DEFAULT NULL,
  p_date_to DATE DEFAULT NULL,
  p_limit INT DEFAULT 500
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_role user_role;
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  IF p_date_from IS NOT NULL THEN
    v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;
  IF p_date_to IS NOT NULL THEN
    v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'type', t.type,
    'status', t.status,
    'bill_id', t.bill_id,
    'phone', t.phone,
    'total', t.total,
    'paid', t.paid,
    'currency', t.currency,
    'sale_user_id', t.sale_user_id,
    'sale_nickname', u.nickname,
    'date', t.date,
    'items', (
      SELECT jsonb_agg(jsonb_build_object('productId', ti.product_id, 'qty', ti.qty, 'role', ti.item_role))
      FROM transaction_items ti WHERE ti.tx_id = t.id
    )
  ) ORDER BY t.date DESC), '[]'::jsonb)
  INTO v_result
  FROM transactions t
  LEFT JOIN users u ON u.id = t.sale_user_id
  WHERE (v_from IS NULL OR t.date >= v_from)
    AND (v_to IS NULL OR t.date <= v_to)
    AND (v_role <> 'Sales' OR t.sale_user_id = v_user_id)
  LIMIT p_limit;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_history_txs(DATE, DATE, INT) TO authenticated;

CREATE OR REPLACE FUNCTION get_diff_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_rows JSONB;
  v_total NUMERIC := 0;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(diff), 0) INTO v_total
  FROM diffs WHERE date BETWEEN v_from AND v_to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tx_id', d.tx_id,
    'type', d.type,
    'sell_value', d.sell_value,
    'ex_fee', d.ex_fee,
    'switch_fee', d.switch_fee,
    'premium', d.premium,
    'cost_diff', d.cost_diff,
    'fee', d.fee,
    'diff', d.diff,
    'date', d.date
  ) ORDER BY d.date DESC), '[]'::jsonb)
  INTO v_rows
  FROM diffs d
  WHERE d.date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_diff_summary(DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_accounting_summary(p_date_from DATE, p_date_to DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_income NUMERIC := 0;
  v_expense NUMERIC := 0;
  v_buyback_paid NUMERIC := 0;
  v_stock_in NUMERIC := 0;
  v_fees NUMERIC := 0;
  v_breakdown JSONB;
BEGIN
  v_from := (p_date_from::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date_to::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(SUM(amount), 0)
  INTO v_income
  FROM cashbank
  WHERE date BETWEEN v_from AND v_to AND amount > 0;

  SELECT COALESCE(SUM(ABS(amount)), 0)
  INTO v_expense
  FROM cashbank
  WHERE date BETWEEN v_from AND v_to AND amount < 0;

  SELECT COALESCE(SUM(ABS(amount)), 0) INTO v_buyback_paid
  FROM cashbank WHERE type = 'BUYBACK' AND date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ABS(amount)), 0) INTO v_stock_in
  FROM cashbank WHERE type = 'STOCK_IN' AND date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(ABS(amount)), 0) INTO v_fees
  FROM cashbank WHERE type IN ('BUYBACK_FEE', 'STOCK_IN_FEE') AND date BETWEEN v_from AND v_to;

  SELECT jsonb_object_agg(type, total) INTO v_breakdown FROM (
    SELECT type::text, SUM(amount) AS total
    FROM cashbank WHERE date BETWEEN v_from AND v_to GROUP BY type
  ) t;

  RETURN jsonb_build_object(
    'income', v_income,
    'expense', v_expense,
    'net', v_income - v_expense,
    'buyback_paid', v_buyback_paid,
    'stock_in', v_stock_in,
    'fees', v_fees,
    'breakdown', COALESCE(v_breakdown, '{}'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_accounting_summary(DATE, DATE) TO authenticated;

CREATE OR REPLACE FUNCTION get_live_report()
RETURNS JSONB AS $$
DECLARE
  v_today DATE;
  v_yest DATE;
  v_carry NUMERIC := 0;
  v_today_diff NUMERIC := 0;
  v_today_from TIMESTAMPTZ;
  v_today_to TIMESTAMPTZ;
BEGIN
  v_today := (NOW() AT TIME ZONE 'Asia/Bangkok')::date;
  v_yest := v_today - INTERVAL '1 day';

  v_today_from := (v_today || ' 00:00:00')::timestamptz AT TIME ZONE 'Asia/Bangkok';
  v_today_to := (v_today || ' 23:59:59')::timestamptz AT TIME ZONE 'Asia/Bangkok';

  SELECT
    COALESCE(SUM(
      CASE
        WHEN ti.item_role = 'NEW' THEN ti.qty * p.weight_baht
        WHEN ti.item_role IN ('OLD', 'FOC') THEN -ti.qty * p.weight_baht
        ELSE 0
      END
    ), 0)
  INTO v_today_diff
  FROM transaction_items ti
  JOIN transactions t ON t.id = ti.tx_id
  JOIN products p ON p.id = ti.product_id
  WHERE t.type IN ('SELL', 'TRADEIN', 'EXCHANGE', 'BUYBACK', 'WITHDRAW')
    AND t.status IN ('COMPLETED', 'PAID')
    AND t.date BETWEEN v_today_from AND v_today_to;

  RETURN jsonb_build_object(
    'netTotal', v_today_diff,
    'carryForward', v_carry,
    'diff', v_today_diff - v_carry
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_live_report() TO authenticated;

CREATE OR REPLACE FUNCTION get_close_report(p_date DATE)
RETURNS JSONB AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_user_id UUID;
  v_role user_role;
  v_my_txs JSONB;
  v_my_cashbook JSONB;
  v_my_gold JSONB;
BEGIN
  v_user_id := current_user_id();
  v_role := current_user_role();
  v_from := (p_date::text || ' 00:00:00')::timestamp AT TIME ZONE 'Asia/Bangkok';
  v_to := (p_date::text || ' 23:59:59')::timestamp AT TIME ZONE 'Asia/Bangkok';

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id, 'type', t.type, 'status', t.status,
    'total', t.total, 'paid', t.paid, 'date', t.date,
    'items', (SELECT jsonb_agg(jsonb_build_object('productId', ti.product_id, 'qty', ti.qty, 'role', ti.item_role))
              FROM transaction_items ti WHERE ti.tx_id = t.id)
  )), '[]'::jsonb)
  INTO v_my_txs
  FROM transactions t
  WHERE t.sale_user_id = v_user_id
    AND t.date BETWEEN v_from AND v_to
    AND t.status IN ('COMPLETED', 'PAID');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', uc.id, 'type', uc.type, 'amount', uc.amount,
    'currency', uc.currency, 'method', uc.method,
    'bank_id', uc.bank_id, 'note', uc.note, 'date', uc.date,
    'ref_tx_id', uc.ref_tx_id
  )), '[]'::jsonb)
  INTO v_my_cashbook
  FROM user_cashbook uc
  WHERE uc.user_id = v_user_id AND uc.date BETWEEN v_from AND v_to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'product_id', ug.product_id, 'qty', ug.qty,
    'type', ug.type, 'ref_tx_id', ug.ref_tx_id, 'date', ug.date
  )), '[]'::jsonb)
  INTO v_my_gold
  FROM user_gold_received ug
  WHERE ug.user_id = v_user_id AND ug.date BETWEEN v_from AND v_to;

  RETURN jsonb_build_object(
    'txs', v_my_txs,
    'cashbook', v_my_cashbook,
    'gold_received', v_my_gold
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_close_report(DATE) TO authenticated;

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

  v_close_id := 'CL-' || to_char(NOW() AT TIME ZONE 'Asia/Bangkok', 'YYYYMMDDHH24MISS') || '-' || substring(md5(random()::text), 1, 4);

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

GRANT EXECUTE ON FUNCTION submit_close_report(DATE, JSONB, JSONB, JSONB, INT, NUMERIC, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION approve_close_report(p_close_id TEXT, p_decision TEXT, p_note TEXT)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_new_status close_status;
BEGIN
  v_user_id := current_user_id();
  IF NOT is_manager_or_admin() THEN
    RETURN jsonb_build_object('success', false, 'message', 'Manager only');
  END IF;

  v_new_status := CASE WHEN p_decision = 'APPROVE' THEN 'APPROVED'::close_status ELSE 'REJECTED'::close_status END;

  UPDATE closes SET status = v_new_status, approved_by_id = v_user_id,
                    approved_at = NOW(), approval_note = p_note
  WHERE id = p_close_id;

  RETURN jsonb_build_object('success', true);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION approve_close_report(TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION get_pending_closes_for_manager()
RETURNS JSONB AS $$
BEGIN
  IF NOT is_manager_or_admin() THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', c.id, 'user_id', c.user_id, 'nickname', u.nickname,
      'date', c.date, 'status', c.status,
      'total_tx', c.total_tx, 'total_amount', c.total_amount,
      'cash_summary', c.cash_summary, 'bank_summary', c.bank_summary,
      'gold_summary', c.gold_summary, 'note', c.note,
      'created_at', c.created_at
    ) ORDER BY c.created_at DESC), '[]'::jsonb)
    FROM closes c JOIN users u ON u.id = c.user_id
    WHERE c.status = 'PENDING'
  );
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_pending_closes_for_manager() TO authenticated;

CREATE OR REPLACE FUNCTION transfer_user_cash_to_shop(p_transfers JSONB)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID;
  v_t RECORD;
  v_uc_id TEXT;
  v_cb_id TEXT;
BEGIN
  v_user_id := current_user_id();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Not authenticated');
  END IF;

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
