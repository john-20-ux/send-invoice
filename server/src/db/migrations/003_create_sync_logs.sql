CREATE TABLE IF NOT EXISTS sync_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_domain     TEXT NOT NULL REFERENCES shops(shop_domain) ON DELETE CASCADE,
  started_at      TIMESTAMPTZ DEFAULT now(),
  finished_at     TIMESTAMPTZ,
  status          TEXT DEFAULT 'running' CHECK (status IN ('running','completed','failed')),
  orders_synced   INTEGER DEFAULT 0,
  total_estimated INTEGER DEFAULT 0,
  error_message   TEXT
);

CREATE INDEX IF NOT EXISTS idx_sync_logs_shop ON sync_logs(shop_domain, started_at DESC);
