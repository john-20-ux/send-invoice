CREATE TABLE IF NOT EXISTS shops (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  install_id      UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  shop_domain     TEXT NOT NULL UNIQUE,
  shop_name       TEXT,
  access_token    TEXT NOT NULL,
  scopes          TEXT,
  owner_email     TEXT,
  installed_at    TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);
