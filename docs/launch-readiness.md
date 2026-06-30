# Launch readiness

Config reference and go-live checklist for the Send Invoice Shopify app.
Companion to [protected-customer-data.md](./protected-customer-data.md).

## What's in place

| Area | Summary |
|------|---------|
| Auth & tokens | OAuth + HMAC; **expiring offline tokens** with auto-refresh; access/refresh tokens **encrypted at rest** (AES-256-GCM) |
| Webhooks | HMAC-verified, **idempotent** (deduped by `X-Shopify-Webhook-Id`); GDPR compliance topics handled |
| API resilience | Retry + backoff on 429/5xx/timeouts; GraphQL `THROTTLED` honors `throttleStatus` |
| Billing | Shopify recurring billing: 14-day trial (unlimited) → Basic $5 (50/mo) or Pro $13 (unlimited), with entitlement gating |
| Data | Dual-engine: **PostgreSQL** in prod (`DATABASE_URL`), SQLite in dev; PII retention purge |
| Observability | Structured JSON request logs + `X-Request-Id`; error alerts to a webhook (PII-redacted) |
| Delivery | CI (tests + RuboCop + bundler-audit); Dockerfile + compose; Render blueprint with managed Postgres |

## Environment variables

### Core
| Var | Required | Notes |
|-----|----------|-------|
| `HOST` | yes | Public base URL (used for OAuth redirect + billing return URLs) |
| `DATABASE_URL` | prod | Postgres connection string. If unset, falls back to SQLite at `DATABASE_PATH` |
| `DB_POOL` | no | Postgres pool size per process (default 5) |
| `PORT` / `BIND_ADDRESS` | no | Defaults `3000` / `0.0.0.0` |
| `MOCK_MODE` | no | `true` runs with demo data and no real Shopify/billing calls |
| `APP_ENV` | prod | Set to `production`; controls billing test mode default |

### Shopify
| Var | Required | Notes |
|-----|----------|-------|
| `SHOPIFY_API_KEY` / `SHOPIFY_API_SECRET` | yes | From the Partner Dashboard app |
| `SHOPIFY_SCOPES` | yes | Minimum needed (default `read_orders`). Adding scopes triggers a reauthorize prompt |
| `SHOPIFY_API_VERSION` | no | Default `2026-04` |
| `EXPIRING_OFFLINE_TOKENS` | no | `true` (recommended) opts into token rotation |
| `ENABLE_ORDER_WEBHOOKS` | no | Keep `false` until Protected Customer Data access is approved |

### Security & data
| Var | Required | Notes |
|-----|----------|-------|
| `ENCRYPTION_KEY` | **prod** | 32-byte hex; encrypts tokens at rest. `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'` |
| `ORDER_RETENTION_DAYS` | recommended | Delete synced orders (PII) older than N days. `0` = keep forever |

### Billing
| Var | Required | Notes |
|-----|----------|-------|
| `BILLING_TEST` | no | `true` = Shopify test charges (no money). Auto-`false` when `APP_ENV=production` |

### Observability
| Var | Required | Notes |
|-----|----------|-------|
| `ERROR_WEBHOOK_URL` | recommended | Slack-compatible webhook for error alerts (secrets/PII redacted). Log-only if blank |

### Sync (optional)
`AUTO_SYNC_ENABLED`, `AUTO_SYNC_INTERVAL_SECONDS`, `SYNC_API_SECRET` — background order sync.

### API tuning (optional)
`SHOPIFY_MAX_RETRIES`, `SHOPIFY_RETRY_BASE_SECONDS`, `SHOPIFY_RETRY_MAX_SECONDS`, `SHOPIFY_HTTP_OPEN_TIMEOUT`, `SHOPIFY_HTTP_READ_TIMEOUT`.

## Go-live checklist

**Infrastructure**
- [ ] Provision managed Postgres (Render blueprint creates `send-invoice-db`) and confirm `DATABASE_URL` is injected
- [ ] Set production secrets: `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET`, `ENCRYPTION_KEY`, `ERROR_WEBHOOK_URL`, `SYNC_API_SECRET`
- [ ] Set `APP_ENV=production`, `MOCK_MODE=false`, a concrete `ORDER_RETENTION_DAYS`, and the real `HOST`
- [ ] Enable encryption-at-rest on the database/host

**Shopify**
- [ ] App created in Partner Dashboard; redirect URL = `${HOST}/auth/callback`
- [ ] Webhook compliance URL = `${HOST}/webhooks/compliance`; subscriptions registered
- [ ] Apply for **Protected Customer Data** access (see PCD doc); flip `ENABLE_ORDER_WEBHOOKS=true` only after approval
- [ ] Verify a live **OAuth install + token refresh** on a dev store
- [ ] Verify **billing**: choose a plan → Shopify approval → callback activates the subscription

**Quality**
- [ ] CI green (tests, RuboCop, bundler-audit)
- [ ] Docker image builds and `/health` passes
- [ ] Privacy policy + terms published (`/legal/privacy`, `/legal/terms`)
- [ ] Uptime monitor pointed at `/health`

## Local development

```bash
cp .env.example .env       # MOCK_MODE=true by default
bundle install
bin/server                 # http://localhost:3000  (SQLite, demo data)
bin/test                   # run the suite
```

To run against Postgres locally, set `DATABASE_URL` in `.env` and re-run.
