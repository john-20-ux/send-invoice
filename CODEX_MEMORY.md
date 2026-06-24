# Codex Memory: Send Invoice Project

## Project State

This repository is a Ruby-first Shopify order sync and invoice app.

Runtime stack:
- Ruby
- WEBrick
- ERB
- SQLite
- No Rails
- No Node/Vite runtime

Main entrypoints:
- `app.rb`
- `bin/server`
- `bin/test`

Current GitHub repo:
- `https://github.com/john-20-ux/send-invoice.git`
- Branch: `main`

Last pushed commit at handoff:
- `7a62fd1 Add first-time batch order sync`

## Key Implemented Features

### Shopify OAuth / App Flow
- OAuth start: `/auth?shop=your-store.myshopify.com`
- OAuth callback: `/auth/callback`
- Mock mode automatically runs when Shopify credentials are missing or `MOCK_MODE=true`.
- Real Shopify mode requires:
  - `SHOPIFY_API_KEY`
  - `SHOPIFY_API_SECRET`
  - `SHOPIFY_SCOPES=read_orders`
  - `SHOPIFY_API_VERSION=2026-04`
  - `HOST=https://your-public-app-host`
  - `MOCK_MODE=false`

### Normal GraphQL Sync
- Existing paginated GraphQL sync uses Shopify Admin GraphQL `orders`.
- Incremental sync uses `updated_at` watermark from `sync_states`.
- Orders are stored in SQLite `orders`.
- Sync logs are stored in `sync_logs`.

### Bulk Sync
- Bulk full sync implemented using Shopify Bulk Operations.
- Endpoints:
  - `POST /api/sync/bulk`
  - `GET /api/sync/bulk/status`
- Bulk jobs stored in `bulk_sync_jobs`.
- Bulk result JSONL is streamed and imported without loading the whole file into memory.
- If bulk sync fails for recoverable errors, the app falls back once to paginated GraphQL full sync.

### First-Time Batch Sync
First install sync now uses a batch-wise 6-month plan.

Rules implemented:
- Default first-time sync range is only the latest 6 months.
- Initial sync covers latest 3 days.
- Initial 3-day batches are high priority.
- Remaining 6-month history is normal priority.
- Batches are planned newest to oldest.
- Batch boundaries are based on Shopify `ordersCount`, not fixed weekly/monthly windows.
- Each batch is capped at 1000 orders.
- A single day with more than 1000 orders is split into `single_day_split` batches with `page_index` and `page_limit`.
- Failed batches are retryable.
- Duplicate batch creation is prevented by a unique constraint.

Tables involved:
- `batch_logs`
- `sync_logs`
- `sync_states`
- `orders`

Endpoint:
- `GET /api/sync/batches/status`

Onboarding step 3 posts:
- `POST /api/sync`
- Body: `{"type":"first_time"}`

Mock mode now exercises the same first-time batch planner and executor using `MockData`.

## Important Files

Core app:
- `ruby_app/lib/send_invoice/app.rb`
- `ruby_app/lib/send_invoice/boot.rb`
- `ruby_app/lib/send_invoice/configuration.rb`

Sync:
- `ruby_app/lib/send_invoice/sync_engine.rb`
- `ruby_app/lib/send_invoice/shopify_client.rb`
- `ruby_app/lib/send_invoice/store.rb`
- `ruby_app/lib/send_invoice/migrator.rb`

UI:
- `ruby_app/views/pages/onboarding.erb`
- `ruby_app/public/app.js`
- `ruby_app/public/app.css`

Tests:
- `ruby_app/test/app_test.rb`

Design:
- `design/index.html`
- Root `index.html` redirects to `design/index.html`.

Test case docs:
- `test_cases/sync_engine/first_time_batch_sync.md`
- `test_cases/sync_engine/single_day_split.md`
- `test_cases/store/batch_logs.md`
- `test_cases/shopify/orders_count_planning.md`
- `test_cases/mock_data/first_time_sync.md`
- `test_cases/api/onboarding_sync.md`

## Verification Commands

Run before commits:

```bash
bin/test
rake test
ruby -c app.rb
ruby -c ruby_app/lib/send_invoice/app.rb
ruby -c ruby_app/lib/send_invoice/sync_engine.rb
ruby -c ruby_app/lib/send_invoice/store.rb
ruby -c ruby_app/lib/send_invoice/migrator.rb
ruby -c ruby_app/lib/send_invoice/shopify_client.rb
```

Most recent verification before `7a62fd1`:
- `bin/test`: `9 runs, 54 assertions, 0 failures`
- `rake test`: `9 runs, 54 assertions, 0 failures`
- Ruby syntax checks passed.

## Recently Pushed Commits

- `10eefee Add design folder entry point`
- `38f9459 Add Shopify GraphQL order sync`
- `0c4514b Add Shopify bulk order sync`
- `7a62fd1 Add first-time batch order sync`

## Suggested Next Work

1. Add webhook handling for Shopify `bulk_operations/finish`.
2. Add a real background job runner instead of in-process threads.
3. Add UI detail for batch progress:
   - initial sync pending/completed
   - remaining sync pending/in progress/completed
   - failed batch retry action
4. Add manual admin endpoint to retry failed `batch_logs`.
5. Add order count caching if Shopify `ordersCount` planning becomes expensive.
6. Add integration tests against a Shopify dev store once credentials are available.
7. Improve line item pagination for orders with more than 100 line items.
8. Add deployment notes for production hosting and persistent SQLite/backups.

## Important Cautions

- Do not delete or rewrite the Ruby app back to Node/React. The app was intentionally rebuilt as Ruby-first.
- Do not use `git reset --hard` or revert user changes unless explicitly requested.
- Keep mock mode working because it is the local demo and test path.
- The first-time batch sync currently uses in-process threads. This is acceptable for local/simple hosting but should become a durable job queue for production.
- Shopify Bulk Operations are still best for large backfills, but first-time install now intentionally limits to 6 months and prioritizes 3 recent days first.

## Phase 4 Memory

### Phase 4 Goal
- Phase 4 introduced a durable app-to-worker boundary using `async_job_requests` plus a Rails/Solid Queue sidecar in `worker_sidecar/`.
- The main app stays Ruby + WEBrick + SQLite.
- The sidecar handles background execution, retries, recurring drains, and health-gated smoke tests.

### Phase 4 Implemented

New / updated scripts:
- `bin/phase4-common.sh`
- `bin/phase4-smoke`
- `bin/phase4-retry-smoke`
- `bin/phase4-status`
- `bin/start-web-db-queue`
- `bin/setup-worker-sidecar`
- `bin/start-worker-sidecar`

Sidecar / queue files:
- `worker_sidecar/Gemfile`
- `worker_sidecar/Gemfile.lock`
- `worker_sidecar/config/database.yml`
- `worker_sidecar/config/environments/development.rb`
- `worker_sidecar/config/initializers/sqlite_pragmas.rb`
- `worker_sidecar/config/initializers/solid_queue_runtime.rb`
- `worker_sidecar/bin/setup`
- `worker_sidecar/bin/start`
- `worker_sidecar/db/queue_schema.rb`
- `worker_sidecar/db/queue_migrate/.keep`
- `worker_sidecar/app/jobs/application_job.rb`
- `worker_sidecar/app/jobs/send_invoice_worker/drain_app_job_requests_job.rb`

Docs updated:
- `README.md`
- `worker_sidecar/README.md`

### Phase 4 Behavior

`bin/phase4-smoke`:
- Uses shared health logic from `bin/phase4-common.sh`.
- Checks app health with `GET /health`.
- Checks sidecar health from queue DB `solid_queue_processes`, not via HTTP.
- Requires fresh `Supervisor`, `Worker`, and `Scheduler` heartbeats before enqueueing.
- Then enqueues a real sync request and waits for terminal completion as before.

`bin/phase4-retry-smoke`:
- Inserts a synthetic `async_job_requests` row with:
  - `request_type=sync.unsupported`
  - `queue_name=maintenance`
  - `status=queued`
  - `attempts=0`
- Waits until retry/backoff is observed:
  - `status=queued`
  - `attempts >= 1`
  - `error_message` contains `Unsupported async job request type: sync.unsupported`
  - `available_at` is in the future
- Cleans up the synthetic row automatically on success.
- Preserves the row on failure only when `KEEP_FAILED_RETRY_SMOKE=1`.
- Optional fallback:
  - `FORCE_DRAIN_WITH_RAILS=1 bin/phase4-retry-smoke`

### Queue DB Adapter Support

Primary DB:
- Still SQLite only.
- Still points at `ruby_app/db/send_invoice.sqlite3`.

Queue DB:
- Dual-support path added.
- Controlled by `SEND_INVOICE_QUEUE_DB_ADAPTER=sqlite3|postgresql`.

SQLite queue mode:
- Uses `SEND_INVOICE_QUEUE_DATABASE_PATH`.
- Local default:
  - `worker_sidecar/storage/development_queue.sqlite3`

Postgres queue mode:
- Uses either:
  - `SEND_INVOICE_QUEUE_DATABASE_URL`
  - or discrete env vars:
    - `SEND_INVOICE_QUEUE_DB_NAME`
    - `SEND_INVOICE_QUEUE_DB_HOST`
    - `SEND_INVOICE_QUEUE_DB_PORT`
    - `SEND_INVOICE_QUEUE_DB_USER`
    - `SEND_INVOICE_QUEUE_DB_PASSWORD`
    - optional `SEND_INVOICE_QUEUE_DB_SSLMODE`

Important Phase 4 choice:
- Only the Solid Queue sidecar DB is being prepared for Postgres migration.
- The main app DB is intentionally unchanged.
- Old SQLite `solid_queue_*` rows are not meant to be migrated.
- Queue state can be recreated fresh at cutover.

## Phase 5 Memory

### Phase 5 Direction
- Keep the app DB on SQLite.
- Fix the root Ruby dependency/runtime path first.
- Re-run `bin/test`, `bin/phase4-smoke`, and `bin/phase4-retry-smoke`.
- Continue with webhook/live-queue verification and queue-operability hardening.
- Do not split off into a separate Postgres-focused track yet.

### Root Runtime Fixes
- Root `Gemfile` now provides the Ruby runtime dependencies needed for the WEBrick app and tests:
  - `sqlite3`
  - `minitest`
  - `rake`
  - `webrick`
- Root `Gemfile.lock` was regenerated.
- Root entrypoints now execute inside Bundler:
  - `bin/test`
  - `bin/server`
  - `bin/start-web-db-queue`
  - `Rakefile`
- Ruby 3.2 keyword/hash compatibility fixes were applied in `ruby_app/lib/send_invoice/app.rb`.

### Phase 5 Verification Completed
- `bundle install` succeeded at repo root.
- `bin/test` passed:
  - `35 runs, 153 assertions, 0 failures, 0 errors, 0 skips`
- `rake test` passed:
  - `35 runs, 153 assertions, 0 failures, 0 errors, 0 skips`
- `bin/phase4-smoke` passed.
- `bin/phase4-retry-smoke` passed.
- Local webhook verification in queue mode passed:
  - `POST /webhooks/orders-changed`
  - app response: `{"received":true,"accepted":true,"topic":"orders/updated"}`
  - async request completed: `1f625f88-7698-4a2c-89c0-7eb71dee6dc6`
  - sync log completed: `61e3901d-9f24-48c1-8da6-4403979515e5`

### SQLite Dev Queue Hardening
- In SQLite development, recurring tasks now default to only:
  - `drain_app_job_requests`
- These remain opt-in:
  - `SEND_INVOICE_ENABLE_INCREMENTAL_SYNC_RECURRING=1`
  - `SEND_INVOICE_ENABLE_UNINSTALL_CLEANUP_RECURRING=1`
- Files updated:
  - `worker_sidecar/config/recurring.yml`
  - `worker_sidecar/bin/start`
  - `README.md`
  - `worker_sidecar/README.md`

### Phase 4 Status / Health Improvements
- `bin/phase4-common.sh` now includes queue-failure counts and lock-failure counts in sidecar health output.
- `bin/phase4-status` now shows:
  - sidecar process rows
  - condensed queue failures
  - queue failure class summary
  - lock-failure summary
- A SQLite health-query bug was fixed:
  - `solid_queue_processes` rows are now counted row-by-row instead of being collapsed by an accidental aggregate.

### Important Phase 5 Finding
- Starting a second sidecar against the same SQLite queue DB immediately reproduced the root contention symptom:
  - `SQLite3::BusyException: database is locked`
- `bin/phase4-status` correctly warned:
  - `multiple fresh supervisors detected for SQLite queue DB; duplicate sidecars are likely`
- The duplicate-sidecar lock error appeared in live sidecar logs, but did not create a new `solid_queue_failed_executions` row.
- Practical implication:
  - For SQLite dev, duplicate fresh supervisors are the reliable in-band warning signal.
  - Historical `solid_queue_failed_executions` data alone is not sufficient to detect this failure mode.

### Duplicate-Sidecar Guard
- `worker_sidecar/bin/start` now blocks a second SQLite sidecar before Solid Queue boots.
- The guard checks `solid_queue_processes` for fresh supervisor heartbeats using the same `QUEUE_HEALTH_FRESHNESS_SECONDS` window as the Phase 4 health scripts.
- If a fresh supervisor already exists, startup exits with code `1` and prints the conflicting supervisor `pid`, `hostname`, `name`, heartbeat age, and heartbeat timestamp.
- Intentional bypass remains available for debugging only:
  - `SEND_INVOICE_ALLOW_DUPLICATE_SIDECARS=1 bin/start-worker-sidecar`
- Verified behavior:
  - first sidecar start succeeds
  - second sidecar start is refused before worker boot
  - `bin/phase4-status` still reports `fresh supervisor=1/1 worker=1/1 scheduler=1/1`

### Smoke Guarding
- `bin/phase4-smoke` now aborts before enqueue when SQLite mode has multiple fresh supervisors.
- `bin/phase4-retry-smoke` now aborts before inserting the synthetic retry row when SQLite mode has multiple fresh supervisors.
- Verified behavior:
  - healthy single-sidecar `bin/phase4-smoke` still passes
  - forced duplicate-sidecar `bin/phase4-smoke` exits early with a dedicated duplicate-sidecar message
  - forced duplicate-sidecar `bin/phase4-retry-smoke` also exits early with the same diagnosis

### Phase 5 Exit Criteria
- Phase 5 is finishable from the current repo state.
- The root Ruby dependency/runtime path is repaired.
- Queue-mode app + sidecar smoke and retry smoke pass in the healthy single-sidecar case.
- Live webhook queue verification already passed earlier in Phase 5.
- The known SQLite duplicate-sidecar failure mode is now:
  - reproducible when intentionally bypassed
  - blocked at sidecar startup by default
  - surfaced by `bin/phase4-status`
  - blocked pre-enqueue by both smoke commands

### Suggested Next Work
1. Start the next phase from the queue boundary that now works reliably in SQLite single-sidecar mode.
2. Use the next phase for forward work rather than more duplicate-sidecar triage; this root cause is now contained.
3. If Postgres queue mode is revisited later, keep the duplicate-sidecar startup guard scoped to SQLite and re-evaluate multi-worker assumptions separately.

## Phase 6 Memory

### Phase 6 Direction
- Build operator recovery on top of the working queue boundary.
- Expose `async_job_requests` inspection and recovery through the app/API, not only through local shell scripts.
- Keep the scope backend-first for now; do not start with a new UI surface.

### Phase 6 Started
- Added app-level async request endpoints:
  - `GET /api/async-requests`
  - `POST /api/async-requests/:request_id/retry`
  - `DELETE /api/async-requests/:request_id`
- Endpoints are scoped to the current shop.
- `GET /api/async-requests` defaults to failed requests and supports `status=all` or a comma-separated status filter.
- Retry only succeeds for `failed` requests.
- Delete only succeeds for `failed` or `completed` requests.
- Response payloads include:
  - request metadata
  - `canRetry`
  - `canDelete`
  - `retryInSeconds` when a queued retry is scheduled in the future

### Phase 6 UI Slice
- The existing sync banner now supports queue-backed sync states more accurately:
  - `queued`
  - `running`
  - `failed`
  - last successful sync
- The sync banner now polls failed `async_job_requests` for the current shop and shows a lightweight recovery panel when any exist.
- Operators can retry or delete failed async requests inline from the product UI.
- Retrying a failed async request now feeds back into `sync_status` correctly because queued request freshness uses the request `updated_at` timestamp for re-queued work.

### Phase 6 Files Updated
- `ruby_app/lib/send_invoice/app.rb`
- `ruby_app/lib/send_invoice/store.rb`
- `ruby_app/lib/send_invoice/sync_engine.rb`
- `ruby_app/public/app.js`
- `ruby_app/public/app.css`
- `ruby_app/views/partials/sync_banner.erb`
- `ruby_app/test/app_test.rb`
- `README.md`

### Phase 6 Verification
- `ruby -c ruby_app/lib/send_invoice/app.rb`
- `ruby -c ruby_app/lib/send_invoice/store.rb`
- `bin/test`
  - `40 runs, 174 assertions, 0 failures, 0 errors, 0 skips`
- `rake test`
  - `40 runs, 174 assertions, 0 failures, 0 errors, 0 skips`

### Phase 6 Current Boundary
- Phase 6 is now functionally complete for the intended queue-recovery scope.
- The backend recovery API now covers:
  - single-request retry
  - retry latest failed
  - retry all failed
  - single-request delete for failed/completed rows
- The sync banner recovery panel now exposes both single-request actions and bulk retry actions for the current shop.
- The remaining optional work is broader than Phase 6:
  - dedicated queue-ops workspace
  - deeper history
  - richer diagnostics

### Suggested Next Work
1. Move to Phase 7 from this queue-ops baseline instead of extending Phase 6 further.
2. Consider a dedicated queue-ops page only if the sync-banner workflow proves too narrow for operators.
3. Keep all future queue-ops behavior shop-scoped and consistent with the shell tooling semantics.

## Phase 7 Memory

### Phase 7 Direction
- Add a dedicated operator workspace for queue operations instead of relying only on the sync banner.
- Expand from failed-request recovery into broader queue history and diagnostics.
- Keep the workflow shop-scoped and aligned with the existing async request semantics.

### Phase 7 Started
- Added a dedicated `GET /queue-ops` app page.
- Added server-rendered queue action routes for the operator workspace:
  - `POST /queue-ops/retry-latest-failed`
  - `POST /queue-ops/retry-all-failed`
  - `POST /queue-ops/requests/:request_id/retry`
  - `POST /queue-ops/requests/:request_id/delete`
- Added queue request pagination support and grouped per-status counts in the store layer.

### Phase 7 UI Slice
- Added a new sidebar destination: `Queue Ops`.
- The new queue page shows:
  - request history table
  - filter presets for all / failed / active / completed
  - per-status counts
  - sync diagnostics
  - bulk diagnostics
  - bulk and per-request recovery actions
- The sync banner remains the lightweight recovery surface; `/queue-ops` is the broader operator page.

### Phase 7 Files Updated
- `ruby_app/lib/send_invoice/app.rb`
- `ruby_app/lib/send_invoice/store.rb`
- `ruby_app/views/pages/queue_ops.erb`
- `ruby_app/public/app.css`
- `ruby_app/test/app_test.rb`
- `README.md`
- `CODEX_MEMORY.md`

### Phase 7 Verification
- `ruby -c ruby_app/lib/send_invoice/app.rb`
- `ruby -c ruby_app/lib/send_invoice/store.rb`
- `ruby -I ruby_app/lib:ruby_app/test ruby_app/test/app_test.rb`
  - `49 runs, 216 assertions, 0 failures, 0 errors, 0 skips`
- `rake test`
  - `49 runs, 216 assertions, 0 failures, 0 errors, 0 skips`

### Phase 7 Current Boundary
- Phase 7 is now functionally complete for the queue-ops workspace goal.
- Operators now have both:
  - lightweight in-banner recovery
  - a dedicated page for history and diagnostics
- The page currently focuses on async request operations and the latest sync/bulk signals.
- Remaining Phase 7 extensions, if needed, are deeper rather than foundational:
  - richer payload inspection
  - batch log drill-down
  - queue search beyond status presets

### Suggested Next Work
1. Consider adding batch-log visibility to `/queue-ops` so first-time sync progress and retries are visible beside async requests.
2. Consider expanding filters from status presets to request type or queue name if operators need narrower slicing.
3. If diagnostics need to be shared externally, consider a read-only JSON summary endpoint for the queue-ops page later.

## Phase 8 Memory

### Phase 8 Direction
- Extend `/queue-ops` from async-request operations into broader batch-operations visibility.
- Make first-time sync planning and failures visible in the same operator workspace.
- Keep Phase 8 focused on observability first; batch recovery actions can follow after the page exposes the right signals.

### Phase 8 Started
- Added first-time sync batch visibility to `/queue-ops`.
- The queue-ops page now shows:
  - batch plan status
  - total/completed/failed batch counts
  - initial and remaining sync completion flags
  - recent batch history with range, priority, retry count, and error message
- Added manual retry actions for failed `batch_logs` from `/queue-ops`.
- Retrying a failed batch now:
  - marks the batch `pending` again
  - clears its terminal error fields
  - resumes first-time sync through the existing sync engine flow
- Reused existing `batch_summary` and `batch_logs` data instead of introducing a separate batch status model.

### Phase 8 Files Updated
- `ruby_app/lib/send_invoice/app.rb`
- `ruby_app/lib/send_invoice/store.rb`
- `ruby_app/views/pages/queue_ops.erb`
- `ruby_app/test/app_test.rb`
- `README.md`
- `CODEX_MEMORY.md`

### Phase 8 Verification
- `ruby -c ruby_app/lib/send_invoice/app.rb`
- `ruby -c ruby_app/lib/send_invoice/store.rb`
- `ruby -I ruby_app/lib:ruby_app/test ruby_app/test/app_test.rb`
  - `50 runs, 228 assertions, 0 failures, 0 errors, 0 skips`
- `rake test`
  - `50 runs, 228 assertions, 0 failures, 0 errors, 0 skips`

### Phase 8 Current Boundary
- Phase 8 has started cleanly.
- `/queue-ops` now covers:
  - async request recovery
  - sync diagnostics
  - bulk diagnostics
  - first-time sync batch visibility
- failed batch rows are now actionable from the operator page.
- The remaining Phase 8 gaps are deeper operator tooling rather than basic workflow support.

### Suggested Next Work
1. Add request-type and queue-name filtering for async requests if operators need narrower slices.
2. Consider adding payload/detail drill-down for individual async requests and batches.
3. Consider a compact JSON diagnostics endpoint if `/queue-ops` needs machine-readable status later.

### Logging / Runtime Defaults

Development sidecar defaults:
- `SEND_INVOICE_WORKER_LOG_LEVEL=info`
- `SEND_INVOICE_WORKER_SQL_LOG=0`
- `config.active_record.verbose_query_logs = false`

Meaning:
- Worker lifecycle logs stay visible.
- Retry scheduling warnings stay visible.
- Permanent failure warnings stay visible.
- Active Record SQL logs are off by default.

### Heartbeat / Health Notes

Important live fix during Phase 4:
- Solid Queue default heartbeat interval is `60s`.
- That conflicted with the smoke health gate freshness window of `30s`.
- Added:
  - `worker_sidecar/config/initializers/solid_queue_runtime.rb`
- Development sidecar now defaults:
  - `SEND_INVOICE_QUEUE_HEARTBEAT_INTERVAL_SECONDS=10`

Health gate details:
- `QUEUE_HEALTH_FRESHNESS_SECONDS` default is `30`.
- Supervisor rows are normalized from values like `Supervisor(async)` to logical `Supervisor`.
- Stale old rows are warning-only if at least one fresh live set exists.

### Live Verification Completed

Live checks performed during Phase 4:
- App `/health` verified.
- Sidecar `solid_queue_processes` verified.
- `bin/phase4-smoke` passed live.
- `bin/phase4-retry-smoke` passed live.

Observed successful retry smoke result:
- Synthetic request stayed `queued`
- `attempts=1`
- `error_message=Unsupported async job request type: sync.unsupported`
- `available_at` moved into the future
- Cleanup succeeded

Observed successful normal smoke result:
- Real `sync.full` request completed
- `sync_logs` latest row showed `completed`

### Live Problems Seen During Phase 4

1. Sidecar health initially failed because:
- the health check treated only exact `Supervisor`, but Solid Queue stored `Supervisor(async)`.
- This was fixed in `bin/phase4-common.sh`.

2. SQLite queue DB lock churn happened when multiple sidecar processes were alive at once:
- `SQLite3::BusyException: database is locked`
- This caused stale heartbeats and confusing health-gate failures.
- Phase 4 conclusion:
  - only run one sidecar against the SQLite queue DB in local dev
  - duplicate sidecars make smoke results unreliable

3. The app on port `3000` was not stable across all earlier verification attempts:
- it had to be restarted during live testing
- final retry smoke passed only after restarting the app and using one fresh sidecar

4. `bin/phase4-retry-smoke` had to be run outside the sandbox during this session because local socket reachability from sandboxed bash was inconsistent.
- This is session/tooling-specific, not app logic.

### Commands That Worked

Web app:
```bash
bin/start-web-db-queue
```

Sidecar setup:
```bash
bin/setup-worker-sidecar
```

Sidecar start:
```bash
bin/start-worker-sidecar
```

Smoke tests:
```bash
bin/phase4-smoke
bin/phase4-retry-smoke
```

Queue inspection:
```bash
bin/phase4-status
```

### Phase 4 Handoff Guidance For Phase 5

If continuing from another account/session:
- Read this memory file first.
- Re-check whether an app is already running on `127.0.0.1:3000`.
- Re-check whether more than one sidecar is touching `worker_sidecar/storage/development_queue.sqlite3`.
- If smoke tests fail with stale heartbeats, suspect duplicate sidecars or SQLite lock churn first.
- If moving to Postgres queue DB, keep the main app DB unchanged.
- Validate Postgres queue mode with:
  - `SEND_INVOICE_QUEUE_DB_ADAPTER=postgresql`
  - sidecar setup/start
  - `bin/phase4-smoke`
  - `bin/phase4-retry-smoke`

Likely Phase 5 direction:
- continue Postgres queue DB rollout / stabilization
- reduce or eliminate SQLite lock churn in local development
- tighten sidecar startup / shutdown discipline
- possibly add more explicit tooling for detecting duplicate sidecars and stale queue rows

### Phase 5 Starter Checklist

1. Read `CODEX_MEMORY.md` fully before making changes.
2. Confirm whether the web app is already running on `127.0.0.1:3000`.
3. Confirm whether a sidecar is already running and whether more than one process is touching:
   - `worker_sidecar/storage/development_queue.sqlite3`
4. If using SQLite queue mode:
   - keep only one sidecar process active
   - expect lock issues if duplicate sidecars exist
5. If using Postgres queue mode:
   - set `SEND_INVOICE_QUEUE_DB_ADAPTER=postgresql`
   - set `SEND_INVOICE_QUEUE_DATABASE_URL` or the discrete `SEND_INVOICE_QUEUE_DB_*` env vars
   - keep primary app DB unchanged
6. Run:
   - `bin/setup-worker-sidecar`
   - `bin/start-worker-sidecar`
   - `bin/phase4-smoke`
   - `bin/phase4-retry-smoke`
7. If health gate fails:
   - inspect `solid_queue_processes`
   - check for stale or duplicate sidecars
   - check for SQLite lock churn
   - verify heartbeats are within the freshness window
8. Only start Phase 5 feature work after smoke and retry smoke are green again.
