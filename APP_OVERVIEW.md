# Send Invoice — App Overview

A standalone **Shopify app** that syncs a merchant's store orders and lets them
generate, preview, and email **invoices** (HTML + PDF) for those orders. It also
provides dashboard analytics, a vendor/payout workspace, customizable invoice
templates, multi-channel notification settings, and an operator queue console.

> Runtime is intentionally minimal: **Ruby + WEBrick + ERB + SQLite**, with no
> Rails dependency and no Node build step. Entry point is `app.rb` →
> `SendInvoice::Boot.start`.

---

## 1. Purpose

Shopify gives merchants orders, but not a clean, branded, sendable **invoice**.
Send Invoice fills that gap:

- Pull a merchant's orders out of Shopify and keep them in sync.
- Turn any order into a professional invoice (on-screen, printable, or PDF).
- Email that invoice to the customer (real SMTP, or a local outbox in dev).
- Give the merchant analytics, branding controls, and delivery records.

The app is **standalone (non-embedded)** — Shopify opens it full-page in a new
tab rather than inside the admin iframe. It uses its own UI (no App Bridge /
Polaris); framing is forbidden via CSP `frame-ancestors 'none'` and
`X-Frame-Options: DENY` to prevent clickjacking.

---

## 2. Operating modes

| Mode | When | Behavior |
| --- | --- | --- |
| **Mock mode** | `SHOPIFY_API_KEY`/`SHOPIFY_API_SECRET` missing, or `MOCK_MODE=true` | Uses a demo store + canned `mock_data`. OAuth/HMAC bypassed. Great for local UI work. |
| **Shopify mode** | Real API key/secret + `MOCK_MODE=false` | Real OAuth, HMAC-verified webhooks, real Admin GraphQL order sync. |

Key env: `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET`, `SHOPIFY_SCOPES`
(`read_orders`), `SHOPIFY_API_VERSION` (`2026-04`), `HOST` (public HTTPS),
plus SMTP and sync-tuning vars (see §8).

---

## 3. End-to-end flow

### 3.1 Install & authentication (Shopify mode)

```
Merchant clicks Install
      │
      ▼
GET /auth?shop=store.myshopify.com
      │  validate shop domain, generate state nonce, store in session
      ▼
Redirect to Shopify OAuth consent (build_auth_url)
      │
      ▼
GET /auth/callback?shop&code&state&hmac
      │  verify state (CSRF), verify HMAC, exchange code → access_token
      │  fetch shop info, upsert into `shops`, register webhooks
      ▼
Redirect to /onboarding
```

In **mock mode** both `/auth` and `/auth/callback` skip verification and drop
straight into onboarding with the demo shop.

### 3.2 Onboarding (3 steps)

```
/onboarding (step 1)  → capture owner email          → POST /onboarding/email
/onboarding/step-2    → confirm/connect shop domain  → POST /onboarding/connect
/onboarding/step-3    → wait for first sync to be ready
/onboarding/complete  → mark shop onboarded=1        → redirect /dashboard
```

Onboarding watches live sync status so the merchant sees their data arriving
before finishing. `onboarded` gates access to the rest of the app
(`require_onboarded_shop`).

### 3.3 Order sync (Shopify → local SQLite)

The sync engine pulls orders via the **Admin GraphQL API** and stores them
locally. Strategy (from README):

- First install syncs only the **last 6 months** by default.
- First high-priority batch covers the **latest 3 days** so recent data appears
  fast; remaining history is split newest→oldest into `batch_logs`
  (≤1000 orders/batch; a >1000-order day splits into paged sub-batches).
- Initial batches run before normal-priority remaining batches; the rest
  continues in the background.
- **Incremental sync** uses Shopify `updated_at` filtering to upsert changed
  orders (refunds, fulfillment, payment status, edits).
- **Bulk sync** (`POST /api/sync/bulk`) is for big historical backfills /
  forced full re-syncs; on recoverable failure it falls back once to paginated
  GraphQL full sync.
- Checkpoints live in `sync_states`; progress/failures in `sync_logs`; bulk
  jobs in `bulk_sync_jobs`; first-time plan in `batch_logs`.

Triggers:
- Manual: Orders screen → `POST /orders/sync`, or `POST /api/sync`.
- Webhook-driven: `orders/create|updated|edited` → `POST /webhooks/orders-changed`
  → incremental sync (HMAC-verified, idempotent).
- Bulk completion: `bulk_operations/finish` → `POST /webhooks/bulk-operations-finish`.
- Scheduled: in-process scheduler when `AUTO_SYNC_ENABLED=true`, or external
  cron hitting `POST /api/sync/all` with `X-Sync-Secret`.

> Order webhooks (`ORDERS_*`) only register when `ENABLE_ORDER_WEBHOOKS` is set —
> they depend on Shopify **Protected Customer Data** approval.

### 3.4 Invoice generation & delivery (the core feature)

```
Orders list → pick an order → Order detail
      │
      ├── GET /orders/invoice        → on-screen / printable invoice (print layout)
      ├── GET /orders/invoice.pdf     → downloadable PDF (InvoicePdf)
      └── POST /orders/send-invoice   → email the invoice
                │
                │  build draft (recipient, subject, body, PDF attachment)
                ▼
          InvoiceMailer.deliver
                │
        ┌───────┴───────────┐
        ▼                   ▼
   SMTP configured?     not configured
   send by email        save .eml to local outbox (ruby_app/tmp/outbox)
        │                   │
        └───────┬───────────┘
                ▼
      record row in `invoice_deliveries`
      (status, channel, target, message id, outbox path, pdf size, errors)
```

Invoice content is assembled by `invoice_document` (numbering, line items,
totals, tax, currency, branding/font) and respects the merchant's saved
**invoice template** and **notification** templates with placeholder tokens.

Invoices can be sent **manually** (order detail page) or **automatically** via
merchant-configured automation rules and payment reminders, with every attempt
recorded and surfaced in the Delivery Log (see the Automations and Delivery Log
screens in §4, and the data model in §6).

### 3.5 Uninstall & data lifecycle

- `app/uninstalled` → `POST /webhooks/app-uninstalled`. If the shop was installed
  ≥ 3 months, its local data is scheduled for deletion **48h** after uninstall;
  reinstalling within the window cancels the pending deletion.
- Compliance webhooks `customers/data_request`, `customers/redact`,
  `shop/redact` → `POST /webhooks/compliance` (required for App Store review).

---

## 4. Screens (admin UI)

Primary nav (`NAV_ITEMS`):

| Screen | Route | Purpose |
| --- | --- | --- |
| **Home / Dashboard** | `/dashboard` | KPIs (total orders, revenue, paid, fulfilled), 30-day revenue trend, status breakdown. |
| **Orders** | `/orders` | Searchable/paginated order explorer; filters; row → detail. |
| **Order detail** | `/orders/detail` | Full order; invoice preview / PDF / send actions. |
| **Automations** | `/automations` | Create/edit/toggle/delete automatic invoice + reminder rules. |
| **Delivery Log** | `/delivery-log` | All invoice deliveries; filter, search, retry, resend. |
| **Vendors** | `/vendors` | Vendor/payout workspace; per-vendor invoice at `/vendors/:id`. |
| **Invoice Templates** | `/invoice-templates` | Live-preview branded invoice template editor. |
| **Notifications** | `/notifications` | Email / WhatsApp / Slack / Basecamp delivery config + templates/placeholders. |
| **Settings** | `/settings` | Tax rate, currency, font, automation links, plan, legal pages. |
| **Plans** | `/settings/plans` | Trial/plan selection and billing. |
| **Support** | `/support` | Support request form. |
| **Legal** | `/legal/privacy`, `/legal/terms` | Public trust pages for review. |

Admin-only (`ADMIN_NAV_ITEMS`):

| Screen | Route | Purpose |
| --- | --- | --- |
| **Queue Ops** | `/queue-ops` | Operator console: queue history, status counts, sync diagnostics, first-time batch visibility, server-rendered retry/delete actions. Requires explicit admin grant. |

---

## 5. JSON API

| Method & path | Purpose |
| --- | --- |
| `GET /health` | Liveness check. |
| `GET /api/shop` / `PUT /api/shop/email` | Read shop / update owner email. |
| `GET /api/orders` / `GET /api/orders/:id` | List / fetch orders. |
| `POST /api/sync` | Incremental sync for current shop. |
| `POST /api/sync/bulk` / `GET /api/sync/bulk/status` | Start / poll bulk sync. |
| `POST /api/sync/all` | Sync all shops (cron, `X-Sync-Secret`). |
| `GET /api/sync/status` / `GET /api/sync/batches/status` | Sync + first-time batch progress. |
| `GET /api/async-requests` (+ retry/delete variants) | Inspect/recover queued background work. |

---

## 6. Data model (SQLite)

Core tables (see `migrator.rb`):

- **shops** — install record, `access_token`, `onboarded`, plan/trial,
  branding (`tax_rate`, `currency`, `font_name`), and JSON blobs
  (`notification_config`, `invoice_template_config`, `vendor_edits`), plus
  uninstall/deletion timestamps.
- **orders** — synced orders keyed by `(id, shop_domain)`: totals, financial &
  fulfillment status, customer fields, `line_items`/`transactions`/`raw_data`
  JSON.
- **invoice_deliveries** — one row per send attempt: recipient, subject, body,
  filename, status, channel, target, external message id, outbox path, pdf
  size, errors, timestamps.
- **invoice_automation_rules** — merchant automation/reminder rules (trigger,
  conditions, action, reminder schedule as JSON).
- **invoice_automation_events** — scheduled/queued automation work, idempotent by
  `event_key`, with status, `run_after`, attempts, and retry metadata.
- **invoice_public_links** — secure public invoice tokens (SHA-256 hash only,
  expiry, revocation, access count).
- **sync_logs / sync_states / bulk_sync_jobs / batch_logs** — sync progress,
  checkpoints, bulk job state, and first-time batch plan.
- **sessions** — server-side session store.
- **async_job_requests / sync_command_locks** — durable app→worker handoff and
  per-shop command locking for the background/queue system.

---

## 7. Background processing

- **In-process** (default): WEBrick app runs an auto-sync scheduler thread and
  an uninstall-cleanup worker thread (toggled by env).
- **DB-queue handoff** (`BACKGROUND_BACKEND=db_queue`): sync requests are
  written to `async_job_requests` instead of running inline; the in-process
  scheduler/cleanup are disabled.
- **Solid Queue sidecar** (`worker_sidecar/`): a separate Rails + Active Job +
  Solid Queue worker drains `async_job_requests`. Scaffolded but requires
  **Ruby 3.1.6+ / Rails 7.1+**; the main app currently runs on **Ruby 2.6**, so
  the sidecar can't boot in this environment yet.

---

## 8. Configuration highlights

- **Shopify**: `SHOPIFY_API_KEY`, `SHOPIFY_API_SECRET`, `SHOPIFY_SCOPES`,
  `SHOPIFY_API_VERSION`, `HOST`, `MOCK_MODE`, `ENABLE_ORDER_WEBHOOKS`.
- **Email/SMTP**: when configured, real send; otherwise `.eml` files land in
  `ruby_app/tmp/outbox`. Header-injection protections are in the mailer.
- **Sync**: `AUTO_SYNC_ENABLED`, `AUTO_SYNC_INTERVAL_SECONDS`,
  `UNINSTALL_CLEANUP_INTERVAL_SECONDS`, `SYNC_API_SECRET`.
- **Queue/retry**: `BACKGROUND_BACKEND`, `ASYNC_REQUEST_MAX_ATTEMPTS`,
  `ASYNC_REQUEST_RETRY_BASE_SECONDS`, `*_JITTER_SECONDS`, `*_MAX_SECONDS`,
  and queue DB adapter overrides.

---

## 9. Deployment

- **Render** blueprint (`render.yaml`) with a persistent disk for the SQLite DB.
- Separate Shopify app configs: `shopify.app.staging.toml`,
  `shopify.app.production.toml` (both declare the required compliance topics).
- SQLite default path: `ruby_app/db/send_invoice.sqlite3`. A planned
  primary/data-storage **DB split** lives in `sql/` (migration scripts +
  `bin/split-db-migrate`).

---

## 10. Request lifecycle (every request)

1. Set security headers (CSP, X-Frame-Options) and content type.
2. Load session (skipped for webhooks).
3. Route via `route!` (method + path match, with a few prefix-based fallbacks).
4. Render ERB page/partial or JSON, handling `UnauthorizedError` (→ onboarding /
   401), `NotFoundError` (→ 404), and any other error (→ 500 + logged).
5. Persist session.

---

## 11. Code map

| Path | Role |
| --- | --- |
| `app.rb` | Entry point → `SendInvoice::Boot.start`. |
| `ruby_app/lib/send_invoice/boot.rb` | Boot: config, DB, migrate, webhooks, scheduler, WEBrick server. |
| `ruby_app/lib/send_invoice/app.rb` | HTTP router + all request handlers. |
| `ruby_app/lib/send_invoice/store.rb` | Data access layer over SQLite. |
| `ruby_app/lib/send_invoice/migrator.rb` | Schema + migrations. |
| `ruby_app/lib/send_invoice/sync_engine.rb` | Order sync orchestration + scheduler; notifies automation on order transitions. |
| `ruby_app/lib/send_invoice/invoice_automation_engine.rb` | Evaluates rules, schedules/sends automation invoices + reminders, retry/resend. |
| `ruby_app/lib/send_invoice/invoice_composition.rb` | Shared invoice/notification config composition (App + engine). |
| `ruby_app/lib/send_invoice/shopify_client.rb` | OAuth, HMAC, Admin GraphQL, webhooks. |
| `ruby_app/lib/send_invoice/invoice_document.rb` | Builds invoice payload (numbering, totals, branding). |
| `ruby_app/lib/send_invoice/invoice_pdf.rb` | Renders invoice PDF. |
| `ruby_app/lib/send_invoice/invoice_mailer.rb` | SMTP send / outbox fallback. |
| `ruby_app/views/` | ERB pages, layouts (`application`, `print`), partials. |
| `worker_sidecar/` | Solid Queue background worker (future runtime). |
| `design/index.html` | Standalone UX reference for the admin UI. |
</content>
</invoke>
