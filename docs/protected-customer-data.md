# Protected Customer Data (PCD) program

Send Invoice reads Shopify order data to generate and send invoices. Order data
includes **protected customer data** (name, email, phone, billing/shipping
address). This document records how the app meets Shopify's Protected Customer
Data requirements; it backs the PCD access request in the Partner Dashboard.

## Data we access and why

| Data | Shopify scope | Purpose |
|------|---------------|---------|
| Orders, line items, totals | `read_orders` | Build the invoice contents |
| Customer name / email | `read_orders` (order payload) | Address and deliver the invoice |
| Billing / shipping address | `read_orders` (order payload) | Render the invoice "bill to" block |

We request the **minimum** scopes needed (currently `read_orders`). Additional
scopes are only added when a feature requires them, and adding one triggers a
re-authorization prompt (see "Scope changes").

## Data minimization

- We store only the order fields needed to render invoices. We do not sync
  products, full customer lists, or unrelated resources.
- Compliance responses (`customers/data_request`) and logs **redact** addresses,
  emails, and tokens. See `ErrorReporter` redaction and `Store#redact_address`.

## Retention

- Synced orders carry PII, so they are retained only as long as needed.
  `ORDER_RETENTION_DAYS` (env) deletes orders older than N days on a schedule
  (`SyncEngine#purge_expired_order_data`). `0` keeps data indefinitely — set a
  concrete limit (e.g. 90) in production.
- On app uninstall, all shop data is scheduled for deletion and purged by the
  cleanup worker (`Store#delete_shop_data`).

## Encryption

- **In transit:** all Shopify and merchant traffic is HTTPS.
- **At rest:** access and refresh tokens are encrypted with AES-256-GCM
  (`TokenCipher`, keyed by `ENCRYPTION_KEY`). Order PII lives in the app
  database; protect it with disk/volume encryption at the hosting layer (and
  migrate to managed Postgres with encryption-at-rest — see roadmap Phase 7).

## Access controls

- Shopify Admin API tokens are never exposed to the browser; all API calls are
  server-side.
- OAuth state + HMAC are verified on the callback; every webhook verifies the
  Shopify HMAC.

## Mandatory compliance webhooks

`customers/data_request`, `customers/redact`, and `shop/redact` are handled at
`/webhooks/compliance` (HMAC-verified, idempotent). They surface the customer's
order data for a data request and delete shop data on redaction.

## Scope changes (re-authorization)

When the app's required scopes change, merchants whose granted scopes are now
insufficient see a **Reauthorize** banner that restarts OAuth, so consent is
always explicit and current.

## Customer consent / opt-out

Invoicing is initiated by the merchant on their own orders; customers receive
invoices as part of the merchant relationship. Data-subject requests are served
via the mandatory compliance webhooks above.

## Operational checklist before requesting PCD access

- [ ] `ENCRYPTION_KEY` set in production
- [ ] `ORDER_RETENTION_DAYS` set to a concrete limit
- [ ] Hosting volume / database encryption-at-rest enabled
- [ ] Error alerts wired (`ERROR_WEBHOOK_URL`)
- [ ] Privacy policy + terms pages published (`/legal/privacy`, `/legal/terms`)
