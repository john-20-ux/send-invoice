CREATE TABLE IF NOT EXISTS orders (
  id                          TEXT NOT NULL,
  shop_domain                 TEXT NOT NULL REFERENCES shops(shop_domain) ON DELETE CASCADE,
  name                        TEXT,
  created_at                  TIMESTAMPTZ,
  fully_paid                  BOOLEAN DEFAULT FALSE,
  financial_status            TEXT,
  fulfillment_status          TEXT,
  total_price_amount          NUMERIC(12,2),
  total_price_currency        TEXT,
  total_discounts_amount      NUMERIC(12,2) DEFAULT 0,
  total_refunded_amount       NUMERIC(12,2) DEFAULT 0,
  total_shipping_amount       NUMERIC(12,2) DEFAULT 0,
  total_tax_amount            NUMERIC(12,2) DEFAULT 0,
  total_tip_amount            NUMERIC(12,2) DEFAULT 0,
  total_weight                NUMERIC,
  customer_id                 TEXT,
  customer_first_name         TEXT,
  customer_last_name          TEXT,
  customer_email              TEXT,
  customer_phone              TEXT,
  line_items                  JSONB DEFAULT '[]',
  transactions                JSONB DEFAULT '[]',
  raw_data                    JSONB DEFAULT '{}',
  synced_at                   TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (id, shop_domain)
);

CREATE INDEX IF NOT EXISTS idx_orders_shop_domain ON orders(shop_domain);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_shop_created ON orders(shop_domain, created_at DESC);
