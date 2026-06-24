PRAGMA foreign_keys = ON;

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY,
  shop_domain TEXT NOT NULL,
  shopify_order_id TEXT NOT NULL,
  order_name TEXT,
  created_at TEXT,
  updated_at TEXT,
  financial_status TEXT,
  fulfillment_status TEXT,
  currency TEXT,
  total_price REAL NOT NULL DEFAULT 0,
  total_tax REAL NOT NULL DEFAULT 0,
  total_discount REAL NOT NULL DEFAULT 0,
  total_shipping REAL NOT NULL DEFAULT 0,
  total_refunded REAL NOT NULL DEFAULT 0,
  total_tip REAL NOT NULL DEFAULT 0,
  total_weight REAL,
  customer_id TEXT,
  customer_first_name TEXT,
  customer_last_name TEXT,
  customer_email TEXT,
  customer_phone TEXT,
  raw_data TEXT NOT NULL DEFAULT '{}',
  synced_at TEXT NOT NULL,
  UNIQUE (shop_domain, shopify_order_id)
);

CREATE INDEX IF NOT EXISTS idx_orders_shop_updated
  ON orders(shop_domain, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_shop_created
  ON orders(shop_domain, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_shop_customer_email
  ON orders(shop_domain, customer_email);

CREATE TABLE IF NOT EXISTS order_line_items (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  shop_domain TEXT NOT NULL,
  shopify_line_item_id TEXT NOT NULL,
  vendor_name TEXT,
  sku TEXT,
  title TEXT,
  variant_title TEXT,
  quantity INTEGER NOT NULL DEFAULT 0,
  current_quantity INTEGER NOT NULL DEFAULT 0,
  unit_price REAL NOT NULL DEFAULT 0,
  line_total REAL NOT NULL DEFAULT 0,
  currency TEXT,
  raw_data TEXT NOT NULL DEFAULT '{}',
  synced_at TEXT NOT NULL,
  FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
  UNIQUE (order_id, shopify_line_item_id)
);

CREATE INDEX IF NOT EXISTS idx_line_items_order_id
  ON order_line_items(order_id);

CREATE INDEX IF NOT EXISTS idx_line_items_shop_vendor
  ON order_line_items(shop_domain, vendor_name);

CREATE INDEX IF NOT EXISTS idx_line_items_shop_sku
  ON order_line_items(shop_domain, sku);

CREATE TABLE IF NOT EXISTS payouts (
  id TEXT PRIMARY KEY,
  shop_domain TEXT NOT NULL,
  shopify_payout_id TEXT NOT NULL,
  status TEXT NOT NULL,
  issued_at TEXT,
  amount REAL NOT NULL DEFAULT 0,
  currency TEXT,
  summary_json TEXT NOT NULL DEFAULT '{}',
  raw_data TEXT NOT NULL DEFAULT '{}',
  synced_at TEXT NOT NULL,
  UNIQUE (shop_domain, shopify_payout_id)
);

CREATE INDEX IF NOT EXISTS idx_payouts_shop_issued
  ON payouts(shop_domain, issued_at DESC);

CREATE INDEX IF NOT EXISTS idx_payouts_shop_status
  ON payouts(shop_domain, status);

CREATE TABLE IF NOT EXISTS payout_transactions (
  id TEXT PRIMARY KEY,
  payout_id TEXT NOT NULL,
  shop_domain TEXT NOT NULL,
  transaction_type TEXT,
  source_type TEXT,
  source_id TEXT,
  amount REAL NOT NULL DEFAULT 0,
  fee REAL NOT NULL DEFAULT 0,
  net_amount REAL NOT NULL DEFAULT 0,
  currency TEXT,
  processed_at TEXT,
  raw_data TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (payout_id) REFERENCES payouts(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_payout_tx_payout_id
  ON payout_transactions(payout_id);

CREATE TABLE IF NOT EXISTS vendors (
  id TEXT PRIMARY KEY,
  shop_domain TEXT NOT NULL,
  vendor_name TEXT NOT NULL,
  commission_rate REAL NOT NULL DEFAULT 0,
  deduction_rules_json TEXT NOT NULL DEFAULT '{}',
  contact_email TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (shop_domain, vendor_name)
);

CREATE INDEX IF NOT EXISTS idx_vendors_shop_name
  ON vendors(shop_domain, vendor_name);

COMMIT;
