PRAGMA foreign_keys = ON;

BEGIN TRANSACTION;

-- Prerequisite:
-- 1. Run sql/primary_server.sql against the target primary database first.
-- 2. Attach the current single-db app database as:
--      ATTACH DATABASE '/absolute/path/to/send_invoice.sqlite3' AS source_db;
--
-- This script backfills primary-server tables from the current Ruby app schema.

INSERT OR REPLACE INTO shops (
  id,
  shop_domain,
  shop_name,
  owner_email,
  status,
  installed_at,
  uninstalled_at,
  scheduled_for_deletion_at,
  data_deletion_started_at,
  created_at,
  updated_at
)
SELECT
  s.id,
  s.shop_domain,
  s.shop_name,
  s.owner_email,
  CASE WHEN s.uninstalled_at IS NULL THEN 'active' ELSE 'uninstalled' END AS status,
  s.installed_at,
  s.uninstalled_at,
  s.scheduled_for_deletion_at,
  s.data_deletion_started_at,
  COALESCE(s.installed_at, s.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(s.updated_at, s.installed_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.shops s;

INSERT OR REPLACE INTO shop_tokens (
  id,
  shop_id,
  access_token,
  scopes,
  token_type,
  is_active,
  created_at,
  updated_at
)
SELECT
  'token:' || s.id AS id,
  s.id AS shop_id,
  s.access_token,
  s.scopes,
  'offline' AS token_type,
  CASE WHEN s.uninstalled_at IS NULL THEN 1 ELSE 0 END AS is_active,
  COALESCE(s.installed_at, s.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(s.updated_at, s.installed_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.shops s
WHERE s.access_token IS NOT NULL AND TRIM(s.access_token) != '';

INSERT OR REPLACE INTO invoice_templates (
  id,
  shop_id,
  template_name,
  template_type,
  config_json,
  is_default,
  created_at,
  updated_at
)
SELECT
  'invoice-template:' || s.id AS id,
  s.id AS shop_id,
  'Default Template' AS template_name,
  'default' AS template_type,
  COALESCE(s.invoice_template_config, '{}') AS config_json,
  1 AS is_default,
  COALESCE(s.installed_at, s.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(s.updated_at, s.installed_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.shops s;

INSERT OR REPLACE INTO sync_logs (
  id,
  shop_id,
  sync_type,
  status,
  started_at,
  finished_at,
  records_synced,
  total_estimated,
  error_message,
  created_at,
  updated_at
)
SELECT
  l.id,
  s.id AS shop_id,
  'orders_sync' AS sync_type,
  l.status,
  l.started_at,
  l.finished_at,
  l.orders_synced,
  l.total_estimated,
  l.error_message,
  COALESCE(l.started_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(l.finished_at, l.started_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.sync_logs l
JOIN source_db.shops s ON s.shop_domain = l.shop_domain;

INSERT OR REPLACE INTO sync_status (
  shop_id,
  last_sync_type,
  last_order_updated_at,
  last_cursor,
  last_synced_at,
  status,
  updated_at
)
SELECT
  s.id AS shop_id,
  st.last_sync_type,
  st.last_order_updated_at,
  st.last_cursor,
  st.last_synced_at,
  CASE
    WHEN st.last_synced_at IS NULL THEN 'idle'
    ELSE 'completed'
  END AS status,
  COALESCE(st.updated_at, st.last_synced_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.sync_states st
JOIN source_db.shops s ON s.shop_domain = st.shop_domain;

INSERT OR REPLACE INTO bulk_sync_jobs (
  id,
  shop_id,
  sync_log_id,
  shopify_bulk_operation_id,
  sync_type,
  status,
  object_count,
  file_size,
  result_url,
  partial_data_url,
  imported_count,
  fallback_used,
  fallback_sync_log_id,
  error_code,
  error_message,
  started_at,
  completed_at,
  created_at,
  updated_at
)
SELECT
  b.id,
  s.id AS shop_id,
  b.sync_log_id,
  b.shopify_bulk_operation_id,
  b.sync_type,
  b.status,
  b.object_count,
  b.file_size,
  b.result_url,
  b.partial_data_url,
  b.imported_count,
  b.fallback_used,
  b.fallback_sync_log_id,
  b.error_code,
  b.error_message,
  b.started_at,
  b.completed_at,
  COALESCE(b.started_at, b.updated_at, CURRENT_TIMESTAMP) AS created_at,
  COALESCE(b.updated_at, b.completed_at, b.started_at, CURRENT_TIMESTAMP) AS updated_at
FROM source_db.bulk_sync_jobs b
JOIN source_db.shops s ON s.shop_domain = b.shop_domain;

INSERT OR REPLACE INTO batch_logs (
  id,
  shop_id,
  resource_name,
  sync_type,
  batch_type,
  start_date,
  end_date,
  order_count,
  batch_sequence,
  status,
  priority,
  retry_count,
  cursor,
  page_index,
  page_limit,
  error_message,
  started_at,
  completed_at,
  created_at,
  updated_at
)
SELECT
  b.id,
  s.id AS shop_id,
  b.resource_name,
  b.sync_type,
  b.batch_type,
  b.start_date,
  b.end_date,
  b.order_count,
  b.batch_sequence,
  b.status,
  b.priority,
  b.retry_count,
  b.cursor,
  b.page_index,
  b.page_limit,
  b.error_message,
  b.started_at,
  b.completed_at,
  b.created_at,
  b.updated_at
FROM source_db.batch_logs b
JOIN source_db.shops s ON s.shop_domain = b.shop_domain;

INSERT OR REPLACE INTO sessions (
  id,
  shop_id,
  shop_domain,
  data,
  created_at,
  updated_at
)
SELECT
  sess.id,
  s.id AS shop_id,
  sess.shop_domain,
  sess.data,
  sess.created_at,
  sess.updated_at
FROM source_db.sessions sess
LEFT JOIN source_db.shops s ON s.shop_domain = sess.shop_domain;

COMMIT;
