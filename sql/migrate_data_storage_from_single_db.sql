PRAGMA foreign_keys = ON;

BEGIN TRANSACTION;

-- Prerequisite:
-- 1. Run sql/data_storage.sql against the target storage database first.
-- 2. Attach the current single-db app database as:
--      ATTACH DATABASE '/absolute/path/to/send_invoice.sqlite3' AS source_db;
--
-- This script backfills storage-server tables from the current Ruby app schema.
-- It requires a sqlite3 build with JSON1 support because it uses json_each/json_extract.

INSERT OR REPLACE INTO orders (
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
)
SELECT
  o.shop_domain || '::' || o.id AS id,
  o.shop_domain,
  o.id AS shopify_order_id,
  o.name AS order_name,
  o.created_at,
  o.updated_at,
  o.financial_status,
  o.fulfillment_status,
  o.total_price_currency AS currency,
  o.total_price_amount AS total_price,
  o.total_tax_amount AS total_tax,
  o.total_discounts_amount AS total_discount,
  o.total_shipping_amount AS total_shipping,
  o.total_refunded_amount AS total_refunded,
  o.total_tip_amount AS total_tip,
  o.total_weight,
  o.customer_id,
  o.customer_first_name,
  o.customer_last_name,
  o.customer_email,
  o.customer_phone,
  COALESCE(o.raw_data, '{}') AS raw_data,
  o.synced_at
FROM source_db.orders o;

INSERT OR REPLACE INTO order_line_items (
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
)
SELECT
  o.shop_domain || '::' || o.id || '::' ||
    COALESCE(json_extract(li.value, '$.id'), CAST(li.key AS TEXT)) AS id,
  o.shop_domain || '::' || o.id AS order_id,
  o.shop_domain,
  COALESCE(
    json_extract(li.value, '$.id'),
    o.id || '::line-item::' || CAST(li.key AS TEXT)
  ) AS shopify_line_item_id,
  json_extract(li.value, '$.vendor') AS vendor_name,
  json_extract(li.value, '$.sku') AS sku,
  json_extract(li.value, '$.title') AS title,
  json_extract(li.value, '$.variantTitle') AS variant_title,
  CAST(COALESCE(json_extract(li.value, '$.quantity'), 0) AS INTEGER) AS quantity,
  CAST(COALESCE(json_extract(li.value, '$.currentQuantity'), 0) AS INTEGER) AS current_quantity,
  CASE
    WHEN CAST(COALESCE(json_extract(li.value, '$.quantity'), 0) AS REAL) = 0 THEN
      CAST(COALESCE(json_extract(li.value, '$.totalAmount'), 0) AS REAL)
    ELSE
      CAST(COALESCE(json_extract(li.value, '$.totalAmount'), 0) AS REAL) /
      CAST(COALESCE(json_extract(li.value, '$.quantity'), 0) AS REAL)
  END AS unit_price,
  CAST(COALESCE(json_extract(li.value, '$.totalAmount'), 0) AS REAL) AS line_total,
  json_extract(li.value, '$.totalCurrency') AS currency,
  li.value AS raw_data,
  o.synced_at
FROM source_db.orders o,
     json_each(COALESCE(o.line_items, '[]')) li;

INSERT OR REPLACE INTO vendors (
  id,
  shop_domain,
  vendor_name,
  commission_rate,
  deduction_rules_json,
  contact_email,
  status,
  created_at,
  updated_at
)
SELECT
  sh.shop_domain || '::vendor::' || ve.key AS id,
  sh.shop_domain,
  ve.key AS vendor_name,
  CAST(COALESCE(json_extract(ve.value, '$.rate'), 0) AS REAL) AS commission_rate,
  CASE WHEN json_valid(ve.value) THEN ve.value ELSE '{}' END AS deduction_rules_json,
  NULL AS contact_email,
  'active' AS status,
  COALESCE(sh.installed_at, sh.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(sh.updated_at, sh.installed_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.shops sh,
     json_each(COALESCE(sh.vendor_edits, '{}')) ve;

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
)
SELECT
  sh.shop_domain || '::vendor::' || vendor_list.vendor_name AS id,
  sh.shop_domain,
  vendor_list.vendor_name,
  0 AS commission_rate,
  '{}' AS deduction_rules_json,
  NULL AS contact_email,
  'active' AS status,
  COALESCE(sh.installed_at, sh.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(sh.updated_at, sh.installed_at, CURRENT_TIMESTAMP) AS updated_at
FROM (
  SELECT DISTINCT
    o.shop_domain,
    json_extract(li.value, '$.vendor') AS vendor_name
  FROM source_db.orders o,
       json_each(COALESCE(o.line_items, '[]')) li
  WHERE TRIM(COALESCE(json_extract(li.value, '$.vendor'), '')) != ''
) vendor_list
JOIN source_db.shops sh ON sh.shop_domain = vendor_list.shop_domain;

-- No payouts or payout_transactions are backfilled here because the current
-- single-db app schema doesn't contain Shopify Payments payout tables yet.

COMMIT;
