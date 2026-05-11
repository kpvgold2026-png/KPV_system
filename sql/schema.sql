CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TYPE user_role AS ENUM ('Admin', 'Manager', 'Sales');
CREATE TYPE tx_type AS ENUM ('SELL', 'TRADEIN', 'EXCHANGE', 'SWITCH', 'FREE_EXCHANGE', 'BUYBACK', 'WITHDRAW');
CREATE TYPE tx_status AS ENUM ('PENDING', 'PARTIAL', 'COMPLETED', 'PAID', 'REJECTED', 'APPROVED');
CREATE TYPE item_role AS ENUM ('OLD', 'NEW', 'FOC', 'SWITCH', 'FREE_EX');
CREATE TYPE gold_type AS ENUM ('NEW', 'OLD');
CREATE TYPE move_direction AS ENUM ('IN', 'OUT');
CREATE TYPE move_type AS ENUM ('SELL', 'TRADEIN', 'EXCHANGE', 'SWITCH', 'BUYBACK', 'WITHDRAW', 'STOCK_IN', 'STOCK_OUT', 'TRANSFER', 'ADJUST');
CREATE TYPE cashbank_type AS ENUM (
  'CASH_IN', 'CASH_OUT', 'BANK_IN', 'BANK_OUT', 'BANK_DEPOSIT', 'BANK_WITHDRAW',
  'OTHER_INCOME', 'OTHER_EXPENSE',
  'SELL', 'BUYBACK', 'BUYBACK_FEE', 'TRADEIN', 'EXCHANGE', 'WITHDRAW',
  'OPEN_SHIFT', 'CLOSE_SHIFT', 'STOCK_IN', 'STOCK_IN_FEE'
);
CREATE TYPE currency_code AS ENUM ('LAK', 'THB', 'USD');
CREATE TYPE close_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED');
CREATE TYPE notification_type AS ENUM ('INFO', 'WARNING', 'APPROVAL', 'CLOSE', 'TRANSFER', 'STOCK', 'PAYMENT');

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role user_role NOT NULL,
  nickname TEXT NOT NULL,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  session_token TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_role ON users(role) WHERE is_active = TRUE;

CREATE TABLE app_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  description TEXT,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  updated_by UUID REFERENCES users(id)
);

CREATE TABLE banks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  account_no TEXT,
  account_name TEXT,
  currency currency_code DEFAULT 'LAK',
  balance NUMERIC(18,2) DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE products (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  unit TEXT DEFAULT 'แท่ง',
  weight_baht NUMERIC(10,6) NOT NULL,
  is_premium BOOLEAN DEFAULT FALSE,
  exchange_fee NUMERIC(18,2) DEFAULT 0,
  exchange_fee_switch NUMERIC(18,2) DEFAULT 0,
  sort_order INT DEFAULT 0
);

INSERT INTO products (id, name, weight_baht, is_premium, exchange_fee, exchange_fee_switch, sort_order) VALUES
  ('G01', '10 บาท',  10,        FALSE, 1690000, 2690000, 1),
  ('G02', '5 บาท',   5,         FALSE,  845000, 1345000, 2),
  ('G03', '2 บาท',   2,         FALSE,  338000,  538000, 3),
  ('G04', '1 บาท',   1,         FALSE,  169000,  269000, 4),
  ('G05', '2 สลึง',  0.5,       TRUE,    99000,  139000, 5),
  ('G06', '1 สลึง',  0.25,      TRUE,    99000,  139000, 6),
  ('G07', '1 กรัม',  0.0666667, FALSE,   99000,  139000, 7);

CREATE TABLE pricing (
  id BIGSERIAL PRIMARY KEY,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sell_1baht NUMERIC(18,2) NOT NULL,
  buyback_1baht NUMERIC(18,2) NOT NULL DEFAULT 0,
  updated_by UUID REFERENCES users(id),
  note TEXT
);
CREATE INDEX idx_pricing_date ON pricing(date DESC);

CREATE TABLE price_rates (
  id BIGSERIAL PRIMARY KEY,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  thb_sell NUMERIC(18,4) NOT NULL,
  usd_sell NUMERIC(18,4) NOT NULL,
  thb_buy  NUMERIC(18,4) NOT NULL,
  usd_buy  NUMERIC(18,4) NOT NULL,
  updated_by UUID REFERENCES users(id)
);
CREATE INDEX idx_price_rates_date ON price_rates(date DESC);

CREATE TABLE transactions (
  id TEXT PRIMARY KEY,
  type tx_type NOT NULL,
  status tx_status NOT NULL DEFAULT 'PENDING',
  bill_id TEXT,
  phone TEXT,
  sale_user_id UUID REFERENCES users(id),
  total NUMERIC(18,2) DEFAULT 0,
  paid NUMERIC(18,2) DEFAULT 0,
  change_amount NUMERIC(18,2) DEFAULT 0,
  currency currency_code DEFAULT 'LAK',
  ex_fee NUMERIC(18,2) DEFAULT 0,
  switch_fee NUMERIC(18,2) DEFAULT 0,
  premium NUMERIC(18,2) DEFAULT 0,
  diff_amount NUMERIC(18,2) DEFAULT 0,
  fee NUMERIC(18,2) DEFAULT 0,
  price NUMERIC(18,2) DEFAULT 0,
  balance NUMERIC(18,2) DEFAULT 0,
  withdraw_code TEXT,
  foc_bill_ref TEXT,
  foc_premium_deduct NUMERIC(18,2) DEFAULT 0,
  free_ex_bill_ref TEXT,
  note TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_tx_type_status ON transactions(type, status);
CREATE INDEX idx_tx_sale_date ON transactions(sale_user_id, date DESC);
CREATE INDEX idx_tx_date ON transactions(date DESC);
CREATE INDEX idx_tx_phone ON transactions(phone);
CREATE INDEX idx_tx_bill_id ON transactions(bill_id) WHERE bill_id IS NOT NULL;

CREATE TABLE transaction_items (
  id BIGSERIAL PRIMARY KEY,
  tx_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  item_role item_role NOT NULL,
  product_id TEXT NOT NULL REFERENCES products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0)
);
CREATE INDEX idx_tx_items_tx ON transaction_items(tx_id);
CREATE INDEX idx_tx_items_product ON transaction_items(product_id);

CREATE TABLE transaction_payments (
  id BIGSERIAL PRIMARY KEY,
  tx_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  amount NUMERIC(18,2) NOT NULL,
  currency currency_code NOT NULL DEFAULT 'LAK',
  method TEXT,
  bank_id UUID REFERENCES banks(id),
  paid_by_id UUID REFERENCES users(id),
  paid_at TIMESTAMPTZ DEFAULT NOW(),
  note TEXT
);
CREATE INDEX idx_tx_payments_tx ON transaction_payments(tx_id);
CREATE INDEX idx_tx_payments_paid_at ON transaction_payments(paid_at DESC);

CREATE TABLE stock_balances (
  product_id TEXT NOT NULL REFERENCES products(id),
  gold_type gold_type NOT NULL,
  qty NUMERIC(18,4) NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (product_id, gold_type)
);

CREATE TABLE stock_moves (
  id BIGSERIAL PRIMARY KEY,
  ref_id TEXT,
  gold_type gold_type NOT NULL,
  type move_type NOT NULL,
  direction move_direction NOT NULL,
  gold_g NUMERIC(18,4) DEFAULT 0,
  price NUMERIC(18,2) DEFAULT 0,
  wac_per_g NUMERIC(18,4) DEFAULT 0,
  wac_per_baht NUMERIC(18,2) DEFAULT 0,
  fulfilled BOOLEAN DEFAULT FALSE,
  user_id UUID REFERENCES users(id),
  note TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_stock_moves_date ON stock_moves(date DESC);
CREATE INDEX idx_stock_moves_ref ON stock_moves(ref_id);
CREATE INDEX idx_stock_moves_type ON stock_moves(gold_type, direction, fulfilled);

CREATE TABLE stock_move_items (
  id BIGSERIAL PRIMARY KEY,
  move_id BIGINT NOT NULL REFERENCES stock_moves(id) ON DELETE CASCADE,
  product_id TEXT NOT NULL REFERENCES products(id),
  qty NUMERIC(18,4) NOT NULL
);
CREATE INDEX idx_stock_move_items_move ON stock_move_items(move_id);
CREATE INDEX idx_stock_move_items_product ON stock_move_items(product_id);

CREATE TABLE stock_transfers (
  id TEXT PRIMARY KEY,
  status tx_status NOT NULL DEFAULT 'PENDING',
  created_by_id UUID REFERENCES users(id),
  approved_by_id UUID REFERENCES users(id),
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  approved_at TIMESTAMPTZ,
  note TEXT
);
CREATE TABLE stock_transfer_items (
  transfer_id TEXT NOT NULL REFERENCES stock_transfers(id) ON DELETE CASCADE,
  product_id TEXT NOT NULL REFERENCES products(id),
  qty NUMERIC(18,4) NOT NULL,
  PRIMARY KEY (transfer_id, product_id)
);

CREATE TABLE inventory_snapshots (
  id BIGSERIAL PRIMARY KEY,
  date DATE NOT NULL,
  gold_type gold_type NOT NULL,
  product_id TEXT NOT NULL REFERENCES products(id),
  carry NUMERIC(18,4) DEFAULT 0,
  qty_in NUMERIC(18,4) DEFAULT 0,
  qty_out NUMERIC(18,4) DEFAULT 0,
  qty_end NUMERIC(18,4) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (date, gold_type, product_id)
);
CREATE INDEX idx_inv_snap_date ON inventory_snapshots(date DESC);

CREATE TABLE wac_state (
  id INT PRIMARY KEY DEFAULT 1,
  new_gold_g NUMERIC(18,4) DEFAULT 0,
  new_value NUMERIC(18,2) DEFAULT 0,
  old_gold_g NUMERIC(18,4) DEFAULT 0,
  old_value NUMERIC(18,2) DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CHECK (id = 1)
);
INSERT INTO wac_state (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE cashbank (
  id TEXT PRIMARY KEY,
  type cashbank_type NOT NULL,
  amount NUMERIC(18,2) NOT NULL,
  currency currency_code NOT NULL DEFAULT 'LAK',
  method TEXT,
  bank_id UUID REFERENCES banks(id),
  ref_tx_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  note TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_cashbank_date ON cashbank(date DESC);
CREATE INDEX idx_cashbank_type ON cashbank(type);
CREATE INDEX idx_cashbank_user_date ON cashbank(created_by_id, date DESC);
CREATE INDEX idx_cashbank_ref ON cashbank(ref_tx_id) WHERE ref_tx_id IS NOT NULL;

CREATE TABLE user_cashbook (
  id TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id),
  type cashbank_type NOT NULL,
  amount NUMERIC(18,2) NOT NULL,
  currency currency_code NOT NULL DEFAULT 'LAK',
  method TEXT,
  bank_id UUID REFERENCES banks(id),
  ref_tx_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  note TEXT,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_user_cashbook_user_date ON user_cashbook(user_id, date DESC);
CREATE INDEX idx_user_cashbook_ref ON user_cashbook(ref_tx_id) WHERE ref_tx_id IS NOT NULL;

CREATE TABLE user_gold_received (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id),
  product_id TEXT NOT NULL REFERENCES products(id),
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  type tx_type NOT NULL,
  ref_tx_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_user_gold_user_date ON user_gold_received(user_id, date DESC);
CREATE INDEX idx_user_gold_ref ON user_gold_received(ref_tx_id) WHERE ref_tx_id IS NOT NULL;

CREATE TABLE diffs (
  tx_id TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
  type tx_type NOT NULL,
  sell_value NUMERIC(18,2) DEFAULT 0,
  ex_fee NUMERIC(18,2) DEFAULT 0,
  switch_fee NUMERIC(18,2) DEFAULT 0,
  premium NUMERIC(18,2) DEFAULT 0,
  cost_diff NUMERIC(18,2) DEFAULT 0,
  cost_old_gold NUMERIC(18,2) DEFAULT 0,
  diff NUMERIC(18,2) NOT NULL,
  date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_diffs_date ON diffs(date DESC);
CREATE INDEX idx_diffs_type ON diffs(type);

CREATE TABLE closes (
  id TEXT PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id),
  date TIMESTAMPTZ NOT NULL,
  cash_lak NUMERIC(18,2) DEFAULT 0,
  cash_thb NUMERIC(18,2) DEFAULT 0,
  cash_usd NUMERIC(18,2) DEFAULT 0,
  old_gold JSONB DEFAULT '{}'::jsonb,
  new_gold JSONB DEFAULT '{}'::jsonb,
  cash_summary JSONB DEFAULT '{}'::jsonb,
  bank_summary JSONB DEFAULT '{}'::jsonb,
  gold_summary JSONB DEFAULT '{}'::jsonb,
  total_tx INT DEFAULT 0,
  total_amount NUMERIC(18,2) DEFAULT 0,
  status close_status NOT NULL DEFAULT 'PENDING',
  approved_by_id UUID REFERENCES users(id),
  approved_at TIMESTAMPTZ,
  note TEXT,
  approval_note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_closes_user_date ON closes(user_id, date DESC);
CREATE INDEX idx_closes_status ON closes(status);

CREATE TABLE daily_reports (
  date DATE PRIMARY KEY,
  carry NUMERIC(18,2) DEFAULT 0,
  net NUMERIC(18,2) DEFAULT 0,
  payload JSONB DEFAULT '{}'::jsonb,
  generated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE notifications (
  id BIGSERIAL PRIMARY KEY,
  type notification_type NOT NULL,
  message TEXT NOT NULL,
  target_role user_role,
  target_user_id UUID REFERENCES users(id),
  tab TEXT,
  ref_tx_id TEXT,
  created_by_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_notif_target_role_created ON notifications(target_role, created_at DESC);
CREATE INDEX idx_notif_target_user_created ON notifications(target_user_id, created_at DESC);

CREATE TABLE notification_reads (
  notification_id BIGINT NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (notification_id, user_id)
);

CREATE TABLE approvals (
  id BIGSERIAL PRIMARY KEY,
  ref_id TEXT NOT NULL,
  ref_type TEXT NOT NULL,
  decision TEXT NOT NULL,
  approved_by_id UUID REFERENCES users(id),
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_approvals_ref ON approvals(ref_type, ref_id);

CREATE TABLE audit_logs (
  id BIGSERIAL PRIMARY KEY,
  table_name TEXT NOT NULL,
  ref_id TEXT,
  action TEXT NOT NULL,
  payload JSONB,
  user_id UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_audit_table_ref ON audit_logs(table_name, ref_id);
CREATE INDEX idx_audit_created ON audit_logs(created_at DESC);

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_tx_updated BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION current_user_id() RETURNS UUID AS $$
DECLARE
  uid UUID;
BEGIN
  uid := NULLIF(current_setting('request.jwt.claims', true)::json->>'user_id', '')::uuid;
  RETURN uid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION current_user_role() RETURNS user_role AS $$
DECLARE
  r TEXT;
BEGIN
  r := NULLIF(current_setting('request.jwt.claims', true)::json->>'role', '');
  RETURN r::user_role;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION is_admin() RETURNS BOOLEAN AS $$
  SELECT current_user_role() = 'Admin';
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION is_manager_or_admin() RETURNS BOOLEAN AS $$
  SELECT current_user_role() IN ('Admin', 'Manager');
$$ LANGUAGE sql STABLE;

ALTER TABLE users                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config             ENABLE ROW LEVEL SECURITY;
ALTER TABLE banks                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE products               ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing                ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_rates            ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions           ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE transaction_payments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_balances         ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_moves            ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_move_items       ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_transfer_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_snapshots    ENABLE ROW LEVEL SECURITY;
ALTER TABLE wac_state              ENABLE ROW LEVEL SECURITY;
ALTER TABLE cashbank               ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_cashbook          ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_gold_received     ENABLE ROW LEVEL SECURITY;
ALTER TABLE diffs                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE closes                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_reports          ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications          ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_reads     ENABLE ROW LEVEL SECURITY;
ALTER TABLE approvals              ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs             ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_self_or_admin ON users FOR SELECT
  USING (id = current_user_id() OR is_manager_or_admin());
CREATE POLICY users_admin_write ON users FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());

CREATE POLICY app_config_read_all ON app_config FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY app_config_admin_write ON app_config FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());

CREATE POLICY banks_read_all ON banks FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY banks_admin_write ON banks FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());

CREATE POLICY products_read_all ON products FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY products_admin_write ON products FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());

CREATE POLICY pricing_read_all ON pricing FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY pricing_mgr_write ON pricing FOR INSERT
  WITH CHECK (is_manager_or_admin());
CREATE POLICY pricing_admin_update ON pricing FOR UPDATE
  USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY pricing_admin_delete ON pricing FOR DELETE USING (is_admin());

CREATE POLICY price_rates_read_all ON price_rates FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY price_rates_mgr_write ON price_rates FOR INSERT
  WITH CHECK (is_manager_or_admin());
CREATE POLICY price_rates_admin_update ON price_rates FOR UPDATE
  USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY price_rates_admin_delete ON price_rates FOR DELETE USING (is_admin());

CREATE POLICY tx_select_scoped ON transactions FOR SELECT
  USING (
    is_manager_or_admin()
    OR sale_user_id = current_user_id()
  );
CREATE POLICY tx_insert_self ON transactions FOR INSERT
  WITH CHECK (
    current_user_id() IS NOT NULL
    AND (sale_user_id = current_user_id() OR is_manager_or_admin())
  );
CREATE POLICY tx_update_scoped ON transactions FOR UPDATE
  USING (
    is_manager_or_admin()
    OR (sale_user_id = current_user_id() AND status IN ('PENDING', 'PARTIAL'))
  );
CREATE POLICY tx_delete_admin ON transactions FOR DELETE USING (is_admin());

CREATE POLICY tx_items_scoped ON transaction_items FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.id = transaction_items.tx_id
        AND (is_manager_or_admin() OR t.sale_user_id = current_user_id())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.id = transaction_items.tx_id
        AND (is_manager_or_admin() OR t.sale_user_id = current_user_id())
    )
  );

CREATE POLICY tx_payments_scoped ON transaction_payments FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.id = transaction_payments.tx_id
        AND (is_manager_or_admin() OR t.sale_user_id = current_user_id())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.id = transaction_payments.tx_id
        AND (is_manager_or_admin() OR t.sale_user_id = current_user_id())
    )
  );

CREATE POLICY stock_balances_read_all ON stock_balances FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY stock_balances_mgr_write ON stock_balances FOR ALL
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY stock_moves_read_all ON stock_moves FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY stock_moves_insert_any ON stock_moves FOR INSERT
  WITH CHECK (current_user_id() IS NOT NULL);
CREATE POLICY stock_moves_mgr_modify ON stock_moves FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());
CREATE POLICY stock_moves_admin_delete ON stock_moves FOR DELETE USING (is_admin());

CREATE POLICY stock_move_items_scoped ON stock_move_items FOR ALL
  USING (current_user_id() IS NOT NULL)
  WITH CHECK (current_user_id() IS NOT NULL);

CREATE POLICY stock_transfers_scoped ON stock_transfers FOR SELECT
  USING (is_manager_or_admin() OR created_by_id = current_user_id());
CREATE POLICY stock_transfers_insert_self ON stock_transfers FOR INSERT
  WITH CHECK (created_by_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY stock_transfers_update_mgr ON stock_transfers FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY stock_transfer_items_scoped ON stock_transfer_items FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM stock_transfers st
      WHERE st.id = stock_transfer_items.transfer_id
        AND (is_manager_or_admin() OR st.created_by_id = current_user_id())
    )
  ) WITH CHECK (
    EXISTS (
      SELECT 1 FROM stock_transfers st
      WHERE st.id = stock_transfer_items.transfer_id
        AND (is_manager_or_admin() OR st.created_by_id = current_user_id())
    )
  );

CREATE POLICY inv_snap_read_all ON inventory_snapshots FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY inv_snap_mgr_write ON inventory_snapshots FOR ALL
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY wac_read_all ON wac_state FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY wac_mgr_write ON wac_state FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY cashbank_read_mgr ON cashbank FOR SELECT
  USING (is_manager_or_admin() OR created_by_id = current_user_id());
CREATE POLICY cashbank_insert_self ON cashbank FOR INSERT
  WITH CHECK (created_by_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY cashbank_update_mgr ON cashbank FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());
CREATE POLICY cashbank_delete_admin ON cashbank FOR DELETE USING (is_admin());

CREATE POLICY user_cashbook_read_self ON user_cashbook FOR SELECT
  USING (user_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY user_cashbook_insert_self ON user_cashbook FOR INSERT
  WITH CHECK (user_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY user_cashbook_update_mgr ON user_cashbook FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());
CREATE POLICY user_cashbook_delete_admin ON user_cashbook FOR DELETE USING (is_admin());

CREATE POLICY user_gold_read_self ON user_gold_received FOR SELECT
  USING (user_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY user_gold_insert_self ON user_gold_received FOR INSERT
  WITH CHECK (user_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY user_gold_update_mgr ON user_gold_received FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());
CREATE POLICY user_gold_delete_admin ON user_gold_received FOR DELETE USING (is_admin());

CREATE POLICY diffs_read_mgr ON diffs FOR SELECT USING (is_manager_or_admin());
CREATE POLICY diffs_mgr_write ON diffs FOR ALL
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY closes_read_scoped ON closes FOR SELECT
  USING (user_id = current_user_id() OR is_manager_or_admin());
CREATE POLICY closes_insert_self ON closes FOR INSERT
  WITH CHECK (user_id = current_user_id());
CREATE POLICY closes_update_mgr ON closes FOR UPDATE
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());
CREATE POLICY closes_delete_own_pending ON closes FOR DELETE
  USING ((user_id = current_user_id() AND status = 'PENDING') OR is_admin());

CREATE POLICY daily_reports_read_all ON daily_reports FOR SELECT USING (current_user_id() IS NOT NULL);
CREATE POLICY daily_reports_mgr_write ON daily_reports FOR ALL
  USING (is_manager_or_admin()) WITH CHECK (is_manager_or_admin());

CREATE POLICY notifications_read_targeted ON notifications FOR SELECT
  USING (
    is_admin()
    OR target_user_id = current_user_id()
    OR (target_role IS NOT NULL AND target_role = current_user_role())
    OR (target_user_id IS NULL AND target_role IS NULL)
  );
CREATE POLICY notifications_insert_any ON notifications FOR INSERT
  WITH CHECK (current_user_id() IS NOT NULL);
CREATE POLICY notifications_admin_modify ON notifications FOR UPDATE
  USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY notifications_admin_delete ON notifications FOR DELETE USING (is_admin());

CREATE POLICY notif_reads_self ON notification_reads FOR ALL
  USING (user_id = current_user_id() OR is_admin())
  WITH CHECK (user_id = current_user_id() OR is_admin());

CREATE POLICY approvals_read_mgr ON approvals FOR SELECT USING (is_manager_or_admin());
CREATE POLICY approvals_insert_mgr ON approvals FOR INSERT
  WITH CHECK (is_manager_or_admin());

CREATE POLICY audit_read_admin ON audit_logs FOR SELECT USING (is_admin());
CREATE POLICY audit_insert_any ON audit_logs FOR INSERT
  WITH CHECK (current_user_id() IS NOT NULL);
