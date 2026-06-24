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

- First install sync plans only the last 6 months of orders by default.
- The first high-priority install batch covers the latest 3 days so merchants can see recent data quickly.
- Remaining 6-month history is split into newest-to-oldest `batch_logs` using Shopify `ordersCount`; each batch is capped at 1000 orders.
- If one day has more than 1000 orders, that day is split into multiple `single_day_split` batches with page indexes and 1000-order limits.
- Initial install batches run before normal-priority remaining batches; remaining history continues in the background after recent data is ready.
- Batch status is available at `GET /api/sync/batches/status`.
- Bulk full sync is available at `POST /api/sync/bulk` and is intended for large historical backfills and forced full re-syncs.
- Real Shopify installs register `bulk_operations/finish` at `POST /webhooks/bulk-operations-finish`. Deliveries are HMAC-verified and processed idempotently; polling remains available as a recovery path.
- Real Shopify installs also register `app/uninstalled` at `POST /webhooks/app-uninstalled`. If a shop was installed for at least 3 months before uninstall, its local SQLite data is scheduled for automatic deletion 48 hours after uninstall. Reinstalling before that window clears the pending deletion.
- Real Shopify installs also register `orders/create`, `orders/updated`, and `orders/edited` at `POST /webhooks/orders-changed`. Each delivery triggers an incremental sync for that shop, and the sync itself uses Shopify `updated_at` filtering so changed orders are upserted in SQLite.
- Incremental sync also remains available on its own, so refunds, fulfillment changes, payment status changes, and customer/order edits are picked up after the first import even when the webhook path is not used.
- Sync checkpoints are stored in SQLite in `sync_states`; progress and failures are stored in `sync_logs`.
- Manual sync is available from the Orders screen and `POST /api/sync`.
- If a bulk sync fails for a recoverable Shopify/API/import error, the app automatically falls back once to the existing paginated GraphQL full sync.

To enable in-process automated sync for every installed shop with an access token:

```text
AUTO_SYNC_ENABLED=true
AUTO_SYNC_INTERVAL_SECONDS=300
UNINSTALL_CLEANUP_INTERVAL_SECONDS=300
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

### Split Database Migration

The live Ruby app still uses one SQLite database by default. The files in `sql/` are for a planned split between:

- primary server database
- data storage database

Files:

- `sql/primary_server.sql`
- `sql/data_storage.sql`
- `sql/migrate_primary_from_single_db.sql`
- `sql/migrate_data_storage_from_single_db.sql`
- `sql/seed_primary_server.sql`
- `sql/seed_data_storage.sql`
- `bin/split-db-migrate`

One-command workflow:

```bash
bin/split-db-migrate --overwrite
```

Seed fresh split databases instead of backfilling:

```bash
bin/split-db-migrate --seed --overwrite
```

Create fresh split databases:

```bash
sqlite3 primary.sqlite < sql/primary_server.sql
sqlite3 data_storage.sqlite < sql/data_storage.sql
```

Backfill from the current single app database:

```bash
sqlite3 primary.sqlite <<'SQL'
ATTACH DATABASE 'ruby_app/db/send_invoice.sqlite3' AS source_db;
.read sql/migrate_primary_from_single_db.sql
DETACH DATABASE source_db;
SQL
```

```bash
sqlite3 data_storage.sqlite <<'SQL'
ATTACH DATABASE 'ruby_app/db/send_invoice.sqlite3' AS source_db;
.read sql/migrate_data_storage_from_single_db.sql
DETACH DATABASE source_db;
SQL
```

Seed a fresh split environment with sample data:

```bash
sqlite3 primary.sqlite <<'SQL'
.read sql/primary_server.sql
.read sql/seed_primary_server.sql
SQL
```

```bash
sqlite3 data_storage.sqlite <<'SQL'
.read sql/data_storage.sql
.read sql/seed_data_storage.sql
SQL
```

Export tables from the current single database for inspection:

```bash
sqlite3 ruby_app/db/send_invoice.sqlite3 ".tables"
sqlite3 ruby_app/db/send_invoice.sqlite3 ".schema shops"
sqlite3 ruby_app/db/send_invoice.sqlite3 "SELECT COUNT(*) FROM orders;"
```

Notes:

- `migrate_data_storage_from_single_db.sql` uses `json_each` and `json_extract`, so your `sqlite3` build must include JSON1 support.
- Payout tables are created in the split schema, but the current single database has no payout source tables yet, so payout backfill is intentionally a no-op for now.
- The storage database uses `shop_domain` as the shared cross-server key. The primary database uses `shop_id` for local foreign keys.

### Solid Queue Sidecar

Phase 3 scaffolding for multi-shop background sync is in:

- `worker_sidecar/`

This keeps the current WEBrick app as the web/UI process and moves background execution into a separate Rails + Active Job + Solid Queue worker boundary.

Phase 4 adds a durable app-to-worker handoff:

- set `BACKGROUND_BACKEND=db_queue` on the WEBrick app
- sync requests are written into `async_job_requests` instead of being executed in in-process threads
- the Solid Queue sidecar drains `async_job_requests` and hands them off to queue workers
- in `db_queue` mode, the in-process auto-sync scheduler and uninstall cleanup thread stay disabled so the sidecar is the only background executor

Important constraint:

- Solid Queue requires Rails 7.1+ and Ruby 3.1.6+
- the current repo runtime is Ruby 2.6, so the sidecar is scaffolded but cannot be booted in this environment yet

Main files:

- `worker_sidecar/Gemfile`
- `worker_sidecar/config/database.yml`
- `worker_sidecar/config/queue.yml`
- `worker_sidecar/config/recurring.yml`
- `worker_sidecar/app/jobs/send_invoice_worker/*.rb`
- `worker_sidecar/lib/send_invoice_worker/runtime.rb`
- `async_job_requests` table in the primary app database

See:

- `worker_sidecar/README.md`

Quick start for Phase 4:

1. Start the web app in queue mode:

   ```bash
   bin/start-web-db-queue
   ```

2. In a separate terminal, switch to Ruby 3.1.6+ and prepare the sidecar once:

   ```bash
   bin/setup-worker-sidecar
   ```

3. Start the Solid Queue sidecar:

   ```bash
   bin/start-worker-sidecar
   ```

SQLite note:

- `bin/start-worker-sidecar` now refuses to start if the same SQLite queue DB already has a fresh Solid Queue supervisor heartbeat.
- Use `SEND_INVOICE_ALLOW_DUPLICATE_SIDECARS=1 bin/start-worker-sidecar` only when you intentionally want to bypass that guard for debugging.

4. Inspect queued and completed work:

   ```bash
   bin/phase4-status
   ```

5. Run the health-gated smoke test:

   ```bash
   bin/phase4-smoke
   ```

6. Run the retry/backoff smoke test:

   ```bash
   bin/phase4-retry-smoke
   ```

7. Retry a failed async request:

   ```bash
   bin/retry-async-request --latest-failed
   ```

   or:

   ```bash
   bin/retry-async-request REQUEST_ID
   ```

8. Delete a stale failed/completed async request:

   ```bash
   bin/delete-async-request REQUEST_ID
   ```

9. Inspect or recover async requests over the app API:

   ```text
   GET /api/async-requests?status=failed
   POST /api/async-requests/retry-latest-failed
   POST /api/async-requests/retry-all-failed
   POST /api/async-requests/:request_id/retry
   DELETE /api/async-requests/:request_id
   ```

10. Use the operator queue workspace in the app:

   ```text
   GET /queue-ops
   ```

Notes:

- `bin/start-web-db-queue` uses `BACKGROUND_BACKEND=db_queue`.
- `bin/setup-worker-sidecar` installs gems, runs `rails solid_queue:install` when `bin/jobs` is missing, and runs `rails db:prepare`.
- `bin/start-worker-sidecar` starts the generated Solid Queue `bin/jobs` process and prints the active queue adapter.
- `bin/phase4-smoke` now checks app health plus fresh sidecar DB heartbeats before enqueueing work.
- `bin/phase4-retry-smoke` verifies retry/backoff behavior with a synthetic unsupported request and cleans it up automatically on success.
- the sync banner now surfaces failed background requests for the current shop and offers inline retry/delete actions plus bulk `retry latest failed` and `retry all failed` controls backed by the async-request API
- `/queue-ops` provides a dedicated operator page with queue history, status counts, sync diagnostics, and server-rendered recovery actions
- `/queue-ops` also shows first-time sync batch visibility so operators can see batch plan status, recent batch failures, and retry counts beside async request history
- failed first-time sync batches can now be retried directly from `/queue-ops`, which marks the batch retryable again and resumes first-time sync through the existing engine
- local development runs the sidecar in `async` mode with reduced worker concurrency and a higher SQLite timeout to reduce `database is locked` noise
- local development further reduces SQLite lock churn by collapsing queue work to one worker, using a smaller connection pool, and enabling SQLite WAL pragmas in the sidecar
- in SQLite development, only `drain_app_job_requests` is scheduled by default; opt back into recurring incremental syncs with `SEND_INVOICE_ENABLE_INCREMENTAL_SYNC_RECURRING=1` and uninstall cleanup with `SEND_INVOICE_ENABLE_UNINSTALL_CLEANUP_RECURRING=1`
- Active Record SQL logging is off by default in sidecar development output; set `SEND_INVOICE_WORKER_SQL_LOG=1` to restore it.
- failed `async_job_requests` are retried automatically with exponential backoff before they are marked `failed`
- retry tuning is controlled with `ASYNC_REQUEST_MAX_ATTEMPTS` (default `5`), `ASYNC_REQUEST_RETRY_BASE_SECONDS` (default `5`), `ASYNC_REQUEST_RETRY_JITTER_SECONDS` (default `3`), and `ASYNC_REQUEST_RETRY_MAX_SECONDS` (default `300`)
- the queue DB can stay on SQLite locally or switch to Postgres with `SEND_INVOICE_QUEUE_DB_ADAPTER=postgresql` plus `SEND_INVOICE_QUEUE_DATABASE_URL` or the discrete `SEND_INVOICE_QUEUE_DB_*` settings
- The sidecar still needs a Ruby 3.1.6+ shell. The current main app runtime remains Ruby 2.6.

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
