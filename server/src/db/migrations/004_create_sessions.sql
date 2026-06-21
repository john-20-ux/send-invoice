CREATE TABLE IF NOT EXISTS sessions (
  id              TEXT PRIMARY KEY,
  shop_domain     TEXT NOT NULL,
  state           TEXT,
  access_token    TEXT,
  scopes          TEXT,
  is_online       BOOLEAN DEFAULT FALSE,
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ DEFAULT now()
);
