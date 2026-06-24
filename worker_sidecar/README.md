# Send Invoice Worker Sidecar

This directory scaffolds the Phase 4 worker boundary for Solid Queue.

Purpose:

- keep the existing WEBrick app as the web/UI process
- run background sync jobs in a separate Rails + Active Job + Solid Queue sidecar
- reuse the existing Ruby sync code from `ruby_app/lib/send_invoice`
- drain durable app requests from `async_job_requests` when the web app is configured with `BACKGROUND_BACKEND=db_queue`

Important constraint:

- Solid Queue requires Rails 7.1+ and Ruby 3.1.6+
- the main repo runtime is currently Ruby 2.6, so this sidecar cannot be booted in the current local environment without a Ruby upgrade

Expected environment variables:

- `RAILS_ENV`
- `SEND_INVOICE_DATABASE_PATH`
- `SEND_INVOICE_QUEUE_DB_ADAPTER=sqlite3|postgresql`
- SQLite queue mode: `SEND_INVOICE_QUEUE_DATABASE_PATH`
- Postgres queue mode: `SEND_INVOICE_QUEUE_DATABASE_URL` or `SEND_INVOICE_QUEUE_DB_NAME` plus `SEND_INVOICE_QUEUE_DB_HOST`, `SEND_INVOICE_QUEUE_DB_PORT`, `SEND_INVOICE_QUEUE_DB_USER`, and `SEND_INVOICE_QUEUE_DB_PASSWORD` as needed
- `BACKGROUND_BACKEND=db_queue` on the WEBrick app process
- the same Shopify env vars already used by the main app

Suggested next steps once Ruby is upgraded:

1. from the repo root, run `bin/setup-worker-sidecar`
2. from the repo root, run `bin/start-worker-sidecar`

What the setup script does:

- checks for Ruby 3.1.6+
- installs sidecar gems into `worker_sidecar/vendor/bundle`
- runs `bundle exec rails solid_queue:install` if `worker_sidecar/bin/jobs` does not exist yet
- runs `bundle exec rails db:prepare`
- prints the active queue adapter so SQLite and Postgres rollouts are visible in startup output

Local development behavior:

- `bin/start-worker-sidecar` runs Solid Queue in `async` mode for SQLite stability
- development queue concurrency is intentionally much lower than production and uses a single worker across all queues
- SQLite timeout is raised in development, queue polling is slowed down, and SQLite WAL pragmas are enabled to reduce lock churn during recurring drains
- in SQLite queue mode, startup now refuses to boot if another fresh supervisor heartbeat already exists for the same queue DB; set `SEND_INVOICE_ALLOW_DUPLICATE_SIDECARS=1` only for intentional duplicate-sidecar testing
- in SQLite development, only `drain_app_job_requests` is scheduled by default; opt back into recurring incremental syncs with `SEND_INVOICE_ENABLE_INCREMENTAL_SYNC_RECURRING=1` and uninstall cleanup with `SEND_INVOICE_ENABLE_UNINSTALL_CLEANUP_RECURRING=1`
- Active Record SQL logging is off by default in development; set `SEND_INVOICE_WORKER_SQL_LOG=1` to re-enable it
- failed `async_job_requests` are retried automatically with exponential backoff before being marked permanently `failed`

Smoke commands:

- `bin/phase4-smoke` now health-gates on `GET /health` plus fresh `solid_queue_processes` heartbeats before enqueueing a real sync request; in SQLite mode it aborts before enqueue if multiple fresh supervisors are detected
- `bin/phase4-retry-smoke` inserts a synthetic unsupported request, waits for backoff to be scheduled, prints the request row and retry timing, then cleans it up by default; in SQLite mode it also aborts before inserting anything if multiple fresh supervisors are detected
- set `KEEP_FAILED_RETRY_SMOKE=1` to preserve the synthetic retry row on failure for debugging

Retry/backoff environment variables:

- `ASYNC_REQUEST_MAX_ATTEMPTS` default `5`
- `ASYNC_REQUEST_RETRY_BASE_SECONDS` default `5`
- `ASYNC_REQUEST_RETRY_JITTER_SECONDS` default `3`
- `ASYNC_REQUEST_RETRY_MAX_SECONDS` default `300`

Job mapping:

- `SendInvoiceWorker::DrainAppJobRequestsJob`
- `SendInvoiceWorker::RunSyncCommandJob`
- `SendInvoiceWorker::IncrementalSyncJob`
- `SendInvoiceWorker::FirstTimeSyncJob`
- `SendInvoiceWorker::StartBulkSyncJob`
- `SendInvoiceWorker::ProcessBulkFinishJob`
- `SendInvoiceWorker::EnqueueIncrementalSyncsJob`
- `SendInvoiceWorker::CleanupUninstalledShopsJob`
