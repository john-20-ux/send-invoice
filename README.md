# Send Invoice Ruby Rebuild

This repository is now Ruby-first. It contains a full Ruby implementation of the Shopify orders sync app with:

- Shopify OAuth entrypoint at `/auth`
- 3-step onboarding
- dashboard analytics
- orders explorer with detail view
- vendor payout workspace
- invoice template editor
- notifications, settings, plans, and support pages
- JSON API endpoints for shop, orders, and sync status

The runtime is intentionally simple: `WEBrick` + `ERB` + `SQLite`, with no Rails dependency and no Node build.

## Run It

1. Install the Ruby dependency set:

   ```bash
   bundle install
   ```

2. Copy the environment file:

   ```bash
   cp .env.example .env
   ```

3. Start the Ruby app:

   ```bash
   bin/server
   ```

4. Open the mock install flow:

   ```text
   http://localhost:3000/auth
   ```

If `SHOPIFY_API_KEY` and `SHOPIFY_API_SECRET` are missing, the app automatically runs in mock mode and uses the demo store data set.

## Tests

Run the Ruby smoke suite with:

```bash
bin/test
```

## Real Shopify Mode

To use the real OAuth and sync flow, set these values in `.env`:

```text
SHOPIFY_API_KEY=...
SHOPIFY_API_SECRET=...
SHOPIFY_SCOPES=read_orders
SHOPIFY_API_VERSION=2026-04
HOST=https://your-public-app-host
MOCK_MODE=false
```

Then start from:

```text
/auth?shop=your-store.myshopify.com
```

The Ruby app stores shops, orders, sync logs, and UI settings in SQLite at `ruby_app/db/send_invoice.sqlite3` by default.

### Order Sync Flow

The app syncs real Shopify order data through the Admin GraphQL API:

- Initial sync pulls orders with the `orders` GraphQL query and stores normalized order fields plus the raw Shopify payload in SQLite.
- Incremental sync uses Shopify `updated_at` filtering, so refunds, fulfillment changes, payment status changes, and customer/order edits are picked up after the first import.
- Sync checkpoints are stored in SQLite in `sync_states`; progress and failures are stored in `sync_logs`.
- Manual sync is available from the Orders screen and `POST /api/sync`.
- Bulk full sync is available at `POST /api/sync/bulk` and is intended for first install, large historical backfills, and forced full re-syncs.
- If a bulk sync fails for a recoverable Shopify/API/import error, the app automatically falls back once to the existing paginated GraphQL full sync.

To enable in-process automated sync for every installed shop with an access token:

```text
AUTO_SYNC_ENABLED=true
AUTO_SYNC_INTERVAL_SECONDS=300
```

To trigger sync from an external cron or scheduler, set a secret:

```text
SYNC_API_SECRET=replace-with-a-long-random-secret
```

Then call:

```bash
curl -X POST https://your-public-app-host/api/sync/all \
  -H "Content-Type: application/json" \
  -H "X-Sync-Secret: replace-with-a-long-random-secret" \
  -d '{"type":"incremental"}'
```

To start a bulk sync for the currently authenticated shop:

```bash
curl -X POST https://your-public-app-host/api/sync/bulk \
  -H "Content-Type: application/json" \
  -d '{"type":"full"}'
```

Bulk job state is available at:

```text
GET /api/sync/bulk/status
```

## Repo Notes

- `app.rb` is the Ruby entrypoint.
- `Gemfile`, `Rakefile`, and `bin/` provide the primary project workflow.
- `ruby_app/lib/send_invoice` contains the Ruby app, data layer, sync engine, and Shopify helpers.
- `ruby_app/views` contains the ERB screens for the admin interface.
- `design/index.html` contains the standalone UX reference used for the current admin interface.
