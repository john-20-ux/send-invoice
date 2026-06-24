BEGIN TRANSACTION;

INSERT OR IGNORE INTO orders (
  id,
  shop_domain,
  shopify_order_id,
  order_name,
  created_at,
  updated_at,
  financial_status,
  fulfillment_status,
  currency,
  total_price,
  total_tax,
  total_discount,
  total_shipping,
  total_refunded,
  total_tip,
  total_weight,
  customer_id,
  customer_first_name,
  customer_last_name,
  customer_email,
  customer_phone,
  raw_data,
  synced_at
) VALUES (
  'seed-shop.myshopify.com::gid://shopify/Order/1001',
  'seed-shop.myshopify.com',
  'gid://shopify/Order/1001',
  '#1001',
  '2026-01-02T10:00:00Z',
  '2026-01-02T10:10:00Z',
  'PAID',
  'FULFILLED',
  'USD',
  125.00,
  5.00,
  0.00,
  10.00,
  0.00,
  0.00,
  250.00,
  'gid://shopify/Customer/1001',
  'Ada',
  'Lovelace',
  'ada@example.com',
  NULL,
  '{"id":"gid://shopify/Order/1001","name":"#1001"}',
  '2026-01-02T10:10:00Z'
);

INSERT OR IGNORE INTO order_line_items (
  id,
  order_id,
  shop_domain,
  shopify_line_item_id,
  vendor_name,
  sku,
  title,
  variant_title,
  quantity,
  current_quantity,
  unit_price,
  line_total,
  currency,
  raw_data,
  synced_at
) VALUES
(
  'seed-shop.myshopify.com::gid://shopify/Order/1001::gid://shopify/LineItem/1',
  'seed-shop.myshopify.com::gid://shopify/Order/1001',
  'seed-shop.myshopify.com',
  'gid://shopify/LineItem/1',
  'Paper Co',
  'SKU-1',
  'Notebook',
  'Black',
  1,
  1,
  75.00,
  75.00,
  'USD',
  '{"id":"gid://shopify/LineItem/1","vendor":"Paper Co"}',
  '2026-01-02T10:10:00Z'
),
(
  'seed-shop.myshopify.com::gid://shopify/Order/1001::gid://shopify/LineItem/2',
  'seed-shop.myshopify.com::gid://shopify/Order/1001',
  'seed-shop.myshopify.com',
  'gid://shopify/LineItem/2',
  'Paper Co',
  'SKU-2',
  'Pen Set',
  'Blue',
  1,
  1,
  50.00,
  50.00,
  'USD',
  '{"id":"gid://shopify/LineItem/2","vendor":"Paper Co"}',
  '2026-01-02T10:10:00Z'
);

INSERT OR IGNORE INTO vendors (
  id,
  shop_domain,
  vendor_name,
  commission_rate,
  deduction_rules_json,
  contact_email,
  status,
  created_at,
  updated_at
) VALUES (
  'seed-shop.myshopify.com::vendor::Paper Co',
  'seed-shop.myshopify.com',
  'Paper Co',
  12.00,
  '{"rate":12,"deductions":5}',
  'vendors@paperco.example',
  'active',
  '2026-01-01T00:00:00Z',
  '2026-01-02T10:10:00Z'
);

INSERT OR IGNORE INTO payouts (
  id,
  shop_domain,
  shopify_payout_id,
  status,
  issued_at,
  amount,
  currency,
  summary_json,
  raw_data,
  synced_at
) VALUES (
  'seed-payout-1',
  'seed-shop.myshopify.com',
  'gid://shopify/ShopifyPaymentsPayout/1001',
  'paid',
  '2026-01-03T00:00:00Z',
  120.00,
  'USD',
  '{"orders":1,"refunds":0}',
  '{"id":"gid://shopify/ShopifyPaymentsPayout/1001"}',
  '2026-01-03T00:05:00Z'
);

INSERT OR IGNORE INTO payout_transactions (
  id,
  payout_id,
  shop_domain,
  transaction_type,
  source_type,
  source_id,
  amount,
  fee,
  net_amount,
  currency,
  processed_at,
  raw_data
) VALUES (
  'seed-payout-tx-1',
  'seed-payout-1',
  'seed-shop.myshopify.com',
  'charge',
  'order',
  'gid://shopify/Order/1001',
  125.00,
  5.00,
  120.00,
  'USD',
  '2026-01-03T00:00:00Z',
  '{"source_id":"gid://shopify/Order/1001"}'
);

COMMIT;
