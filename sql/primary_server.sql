PRAGMA foreign_keys = ON;

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS shops (
  id TEXT PRIMARY KEY,
  shop_domain TEXT NOT NULL UNIQUE,
  shop_name TEXT,
  owner_email TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  installed_at TEXT NOT NULL,
  uninstalled_at TEXT,
  scheduled_for_deletion_at TEXT,
  data_deletion_started_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_shops_cleanup
  ON shops(scheduled_for_deletion_at, data_deletion_started_at);

CREATE TABLE IF NOT EXISTS shop_tokens (
  id TEXT PRIMARY KEY,
  shop_id TEXT NOT NULL,
  access_token TEXT NOT NULL,
  scopes TEXT,
  token_type TEXT NOT NULL DEFAULT 'offline',
  is_active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_shop_tokens_shop_id
  ON shop_tokens(shop_id);

CREATE INDEX IF NOT EXISTS idx_shop_tokens_active
  ON shop_tokens(shop_id, is_active);

CREATE TABLE IF NOT EXISTS invoice_templates (
  id TEXT PRIMARY KEY,
  shop_id TEXT NOT NULL,
  template_name TEXT NOT NULL,
  template_type TEXT NOT NULL DEFAULT 'default',
  config_json TEXT NOT NULL DEFAULT '{}',
  is_default INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_invoice_templates_shop_id
  ON invoice_templates(shop_id);

CREATE INDEX IF NOT EXISTS idx_invoice_templates_default
  ON invoice_templates(shop_id, is_default);

CREATE TABLE IF NOT EXISTS sync_logs (
  id TEXT PRIMARY KEY,
  shop_id TEXT NOT NULL,
  sync_type TEXT NOT NULL,
  status TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  records_synced INTEGER NOT NULL DEFAULT 0,
  total_estimated INTEGER NOT NULL DEFAULT 0,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_sync_logs_shop_started
  ON sync_logs(shop_id, started_at DESC);

CREATE TABLE IF NOT EXISTS sync_status (
  shop_id TEXT PRIMARY KEY,
  last_sync_type TEXT,
  last_order_updated_at TEXT,
  last_cursor TEXT,
  last_synced_at TEXT,
  status TEXT NOT NULL DEFAULT 'idle',
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS bulk_sync_jobs (
  id TEXT PRIMARY KEY,
  shop_id TEXT NOT NULL,
  sync_log_id TEXT,
  shopify_bulk_operation_id TEXT,
  sync_type TEXT NOT NULL,
  status TEXT NOT NULL,
  object_count INTEGER NOT NULL DEFAULT 0,
  file_size INTEGER NOT NULL DEFAULT 0,
  result_url TEXT,
  partial_data_url TEXT,
  imported_count INTEGER NOT NULL DEFAULT 0,
  fallback_used INTEGER NOT NULL DEFAULT 0,
  fallback_sync_log_id TEXT,
  error_code TEXT,
  error_message TEXT,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE,
  FOREIGN KEY (sync_log_id) REFERENCES sync_logs(id) ON DELETE SET NULL,
  FOREIGN KEY (fallback_sync_log_id) REFERENCES sync_logs(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_shop_started
  ON bulk_sync_jobs(shop_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_operation
  ON bulk_sync_jobs(shopify_bulk_operation_id);

CREATE TABLE IF NOT EXISTS async_job_requests (
  id TEXT PRIMARY KEY,
  shop_id TEXT,
  shop_domain TEXT,
  request_type TEXT NOT NULL,
  queue_name TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  payload_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  claimed_by TEXT,
  claimed_at TEXT,
  available_at TEXT NOT NULL,
  dispatched_at TEXT,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_async_job_requests_status_available
  ON async_job_requests(status, available_at, created_at);

CREATE INDEX IF NOT EXISTS idx_async_job_requests_shop_created
  ON async_job_requests(shop_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_async_job_requests_active_dedupe
  ON async_job_requests(dedupe_key)
  WHERE status IN ('queued', 'claimed', 'dispatched', 'running');

CREATE TABLE IF NOT EXISTS batch_logs (
  id TEXT PRIMARY KEY,
  shop_id TEXT NOT NULL,
  resource_name TEXT NOT NULL,
  sync_type TEXT NOT NULL,
  batch_type TEXT NOT NULL,
  start_date TEXT NOT NULL,
  end_date TEXT NOT NULL,
  order_count INTEGER NOT NULL DEFAULT 0,
  batch_sequence INTEGER NOT NULL,
  status TEXT NOT NULL,
  priority TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  cursor TEXT,
  page_index INTEGER NOT NULL DEFAULT 0,
  page_limit INTEGER NOT NULL DEFAULT 1000,
  error_message TEXT,
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE CASCADE,
  UNIQUE (shop_id, sync_type, batch_type, start_date, end_date, page_index)
);

CREATE INDEX IF NOT EXISTS idx_batch_logs_shop_status
  ON batch_logs(shop_id, status, priority, batch_sequence);

CREATE INDEX IF NOT EXISTS idx_batch_logs_shop_created
  ON batch_logs(shop_id, created_at DESC);

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  shop_id TEXT,
  shop_domain TEXT,
  data TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (shop_id) REFERENCES shops(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_shop_id
  ON sessions(shop_id);

COMMIT;
