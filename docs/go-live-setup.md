# Go-live setup (step by step)

Hands-on runbook for the three real-environment validations. Companion to
[launch-readiness.md](./launch-readiness.md) (config reference) and
[protected-customer-data.md](./protected-customer-data.md).

**Dependency order:** Docker can be validated anytime. Render must come before
Shopify (it gives you the public `HOST` URL). Shopify config + live OAuth/billing
come last.

Generate the secrets you'll reuse below up front:

```bash
ruby -rsecurerandom -e 'puts "ENCRYPTION_KEY=" + SecureRandom.hex(32)'
ruby -rsecurerandom -e 'puts "SYNC_API_SECRET=" + SecureRandom.hex(24)'
```

---

## Part 1 — Docker build & run (local, independent)

1. Build the image:
   ```bash
   docker build -t send-invoice:local .
   ```
2. Run it (mock mode, no Shopify needed):
   ```bash
   docker compose up --build      # or: docker run -p 3000:3000 send-invoice:local
   ```
3. Validate:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/health   # expect 200
   ```
   The container `HEALTHCHECK` should also show `healthy` in `docker ps`.
4. (Optional) Run against Postgres locally: set `DATABASE_URL` + `ENCRYPTION_KEY`
   in the compose `environment:` and flip `MOCK_MODE=false`.

✅ **Done when:** the image builds and `/health` returns 200.

---

## Part 2 — Provision on Render (Postgres + web + worker + secrets)

The repo ships a `render.yaml` blueprint that creates the **Postgres database**,
the **web service**, and the **worker service** in one go.

1. **Create the Blueprint**: Render Dashboard → **New → Blueprint** → connect this
   GitHub repo → it reads `render.yaml`. Confirm it lists:
   - `send-invoice-staging` (web), `send-invoice-worker` (worker), `send-invoice-db` (Postgres).
2. **Apply** — Render provisions Postgres and injects `DATABASE_URL` into both the
   web and worker services automatically (via `fromDatabase`). No SQLite disk is used.
3. **Set the secret env vars** (marked `sync: false`) on **both** the web and
   worker services (Service → Environment):
   - `ENCRYPTION_KEY` — the 32-byte hex from above (**must match** on web + worker)
   - `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET` — from the Shopify app (Part 3, step 1)
   - `HOST` — your web service URL, e.g. `https://send-invoice-staging.onrender.com`
   - `ERROR_WEBHOOK_URL` — a Slack incoming webhook (optional)
   - Web only: `SYNC_API_SECRET`
4. **Set `MOCK_MODE=false`** on the web service (it's `false` in the blueprint).
   For real production billing later, also set `APP_ENV=production` (turns off
   `BILLING_TEST`) and a concrete `ORDER_RETENTION_DAYS`.
5. **Deploy.** The worker's build runs `bin/rails queue:ensure_schema` (idempotent —
   creates the `solid_queue_*` tables in Postgres only if missing).

Validate:
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-host>/health    # expect 200
```
- Web logs show structured JSON request lines; worker logs show `Starting Solid Queue sidecar` and `SEND_INVOICE_QUEUE_DB_ADAPTER=postgresql`.
- In Render's Postgres shell: `\dt solid_queue_*` lists the queue tables, and the app tables (`shops`, `orders`, …) exist.

✅ **Done when:** `/health` is 200, the worker boots on `postgresql`, and the queue/app tables exist in Postgres.

---

## Part 3 — Shopify app + live OAuth & billing

### 3a. Create / configure the app (Partner Dashboard)

1. **Partners → Apps → Create app** (or use the existing one). Copy the **API key**
   and **API secret** into the Render secrets (Part 2, step 3).
2. Set **App URL** = `${HOST}` and **Allowed redirection URL** = `${HOST}/auth/callback`.
3. Update `shopify.app.production.toml` with your real `client_id`, `application_url`,
   and redirect URL, then deploy the config so the **compliance webhooks** register:
   ```bash
   shopify app deploy            # registers customers/data_request, customers/redact, shop/redact -> /webhooks/compliance
   ```
4. **Scopes:** `read_orders` is enough for invoicing from synced orders. If you
   enable the draft-order/send features, add `write_draft_orders`, `write_orders`,
   `read_customers` — the app shows a **Reauthorize** banner when scopes change.
5. **Protected Customer Data:** request access in the app's API access settings
   (orders carry customer PII). Keep `ENABLE_ORDER_WEBHOOKS=false` until approved;
   bulk sync covers orders meanwhile.

### 3b. Validate live OAuth install

1. Install on a **development store**: visit
   `https://<your-host>/auth?shop=<your-dev-store>.myshopify.com`.
2. Approve the consent screen → you should land back on the app (onboarding) after
   `/auth/callback`.
3. Verify in Render Postgres: the `shops` row exists, and its `access_token` is
   **encrypted** (starts with `enc:v1:`), with `token_expires_at`/`refresh_token`
   populated (expiring-token rotation).
4. Other webhooks (app uninstall, bulk finish, orders) are registered by the app on
   install — confirm in the store's webhook list or app logs.

### 3c. Validate billing

1. In the app: **Settings → Plans** → choose **Basic** or **Pro**.
2. You're redirected to Shopify's subscription approval page (a **test charge** while
   `BILLING_TEST=true` / `APP_ENV != production`). Approve it.
3. You return to `/settings/plans/callback`; the app confirms the **active**
   subscription and sets `plan_status=active`. The plan card shows **Active**.
4. Check entitlement: on Basic, after 50 invoice sends in a month, sends are blocked
   with an upgrade prompt; trial/Pro are unlimited.
5. For real money in production: set `APP_ENV=production` (or `BILLING_TEST=false`).

### 3d. Validate compliance (GDPR) webhooks

Trigger the mandatory webhooks (Partner Dashboard → app → API access → "Send test
notification", or `shopify app webhook trigger`) for `customers/data_request`,
`customers/redact`, `shop/redact`. Each should return **200** and be HMAC-verified
and idempotent.

✅ **Done when:** OAuth install works (token encrypted + rotating), a test
subscription activates, entitlement gating works, and compliance webhooks 200.

---

## Quick reference

| Thing | Value |
|------|-------|
| OAuth start | `GET ${HOST}/auth?shop=<store>.myshopify.com` |
| OAuth callback | `${HOST}/auth/callback` |
| Compliance webhook | `${HOST}/webhooks/compliance` |
| Health check | `${HOST}/health` |
| Billing return | `${HOST}/settings/plans/callback` |

## Rollback / notes

- Roll back a Render deploy from the service's **Events** tab (previous deploy).
- Re-running the worker deploy is safe — `queue:ensure_schema` won't drop existing
  queue tables.
- If OAuth loops on a "Reauthorize" banner, the granted scopes don't include a
  required scope — confirm `SHOPIFY_SCOPES` matches the Partner Dashboard config.
