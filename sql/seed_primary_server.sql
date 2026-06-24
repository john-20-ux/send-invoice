BEGIN TRANSACTION;

INSERT OR IGNORE INTO shops (
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
) VALUES (
  'seed-shop-1',
  'seed-shop.myshopify.com',
  'Seed Shop',
  'owner@seed-shop.example',
  'active',
  '2026-01-01T00:00:00Z',
  NULL,
  NULL,
  NULL,
  '2026-01-01T00:00:00Z',
  '2026-01-01T00:00:00Z'
);

INSERT OR IGNORE INTO shop_tokens (
  id,
  shop_id,
  access_token,
  scopes,
  token_type,
  is_active,
  created_at,
  updated_at
) VALUES (
  'seed-token-1',
  'seed-shop-1',
  'shpat_seed_example',
  'read_orders,read_shopify_payments_payouts',
  'offline',
  1,
  '2026-01-01T00:00:00Z',
  '2026-01-01T00:00:00Z'
);

INSERT OR IGNORE INTO invoice_templates (
  id,
  shop_id,
  template_name,
  template_type,
  config_json,
  is_default,
  created_at,
  updated_at
) VALUES (
  'seed-template-1',
  'seed-shop-1',
  'Default Invoice',
  'default',
  '{"company_name":"Seed Shop","currency_symbol":"$"}',
  1,
  '2026-01-01T00:00:00Z',
  '2026-01-01T00:00:00Z'
);

INSERT OR IGNORE INTO sync_logs (
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
) VALUES (
  'seed-sync-log-1',
  'seed-shop-1',
  'orders_sync',
  'completed',
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z',
  10,
  10,
  NULL,
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z'
);

INSERT OR IGNORE INTO sync_status (
  shop_id,
  last_sync_type,
  last_order_updated_at,
  last_cursor,
  last_synced_at,
  status,
  updated_at
) VALUES (
  'seed-shop-1',
  'incremental',
  '2026-01-02T00:05:00Z',
  NULL,
  '2026-01-02T00:05:00Z',
  'completed',
  '2026-01-02T00:05:00Z'
);

INSERT OR IGNORE INTO bulk_sync_jobs (
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
) VALUES (
  'seed-bulk-job-1',
  'seed-shop-1',
  'seed-sync-log-1',
  'gid://shopify/BulkOperation/seed-1',
  'full',
  'completed',
  10,
  2048,
  'https://example.test/bulk/orders.jsonl',
  NULL,
  10,
  0,
  NULL,
  NULL,
  NULL,
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z',
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z'
);

INSERT OR IGNORE INTO async_job_requests (
  id,
  shop_id,
  shop_domain,
  request_type,
  queue_name,
  dedupe_key,
  payload_json,
  status,
  attempts,
  claimed_by,
  claimed_at,
  available_at,
  dispatched_at,
  error_message,
  created_at,
  updated_at
) VALUES (
  'seed-async-job-1',
  'seed-shop-1',
  'seed-shop.myshopify.com',
  'sync.incremental',
  'incremental',
  'sync.incremental:seed-shop.myshopify.com',
  '{"shop_domain":"seed-shop.myshopify.com","type":"incremental","skip_rate_limit":true}',
  'completed',
  1,
  'seed-worker',
  '2026-01-02T00:06:00Z',
  '2026-01-02T00:05:30Z',
  '2026-01-02T00:06:00Z',
  NULL,
  '2026-01-02T00:05:00Z',
  '2026-01-02T00:06:00Z'
);

INSERT OR IGNORE INTO batch_logs (
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
) VALUES (
  'seed-batch-log-1',
  'seed-shop-1',
  'ORDER',
  'first_time_sync',
  'initial_3_days',
  '2025-12-29T00:00:00Z',
  '2026-01-01T00:00:00Z',
  10,
  1,
  'completed',
  'high',
  0,
  NULL,
  0,
  1000,
  NULL,
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z',
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z'
);

INSERT OR IGNORE INTO sessions (
  id,
  shop_id,
  shop_domain,
  data,
  created_at,
  updated_at
) VALUES (
  'seed-session-1',
  'seed-shop-1',
  'seed-shop.myshopify.com',
  '{"shop_domain":"seed-shop.myshopify.com"}',
  '2026-01-02T00:00:00Z',
  '2026-01-02T00:05:00Z'
);

COMMIT;
