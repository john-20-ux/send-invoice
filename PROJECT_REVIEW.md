# Project Review

Date: 2026-06-21

## Verdict

This project is only partially moving in the right direction.

The good news is that the repo already has a real foundation for a Shopify embedded app: React frontend, Express backend, PostgreSQL migrations, OAuth install flow, order sync, and order listing. That is a valid base.

The problem is that the product direction is split. The `Orders` flow is real, but most of the rest of the app is still prototype/demo UI backed by local state, mock data, or toast messages. Right now the repo looks like two different products merged together:

- a real Shopify orders sync app
- a demo invoicing / vendors / notifications SaaS concept

If the goal is a production Shopify app, the repo needs to narrow its scope fast and make the non-real surfaces either real or hidden.

## What Is Strong

- Clear frontend/backend split with a simple local dev workflow in `package.json`.
- Real database migrations and normalized persistence for shops, orders, and sync logs.
- Real Shopify OAuth entry points in `server/src/routes/auth.ts`.
- Real order fetch, persistence, pagination, and detail views.
- Mock mode in `src/services/api.ts` is useful for UI iteration without Shopify credentials.

## Highest-Priority Findings

### 1. API auth/session model is not production-safe

Severity: High

`server/src/middleware/verifySession.ts:25-28` accepts shop identity from session, query string, or the `x-shop-domain` header, then loads the access token from the database and authorizes the request.

The comment says App Bridge JWT is supported, but no JWT verification exists. In practice this means the backend trusts a client-controlled shop identifier. If someone knows a stored shop domain, they can attempt to act as that shop.

Related issues:

- `server/src/index.ts:20-31` uses the default in-memory `express-session` store.
- `server/src/index.ts:21` falls back to `dev-secret-change-me` if the secret is missing.
- `server/src/db/migrations/004_create_sessions.sql` creates a `sessions` table, but the app never uses it.

Directionally, this is the biggest gap between “working prototype” and “real Shopify app”.

### 2. Incremental sync logic will miss important order updates

Severity: High

`server/src/routes/api.ts:115-120` defines incremental sync from the last completed sync timestamp.

But `server/src/services/sync.ts:139-142` filters Shopify orders with:

`created_at:>='lastSyncedAt'`

That only catches newly created orders. It does not catch later changes to existing orders such as:

- payment status changes
- fulfillment changes
- refunds
- edited line items

For an operations app, that will make synced data stale even when sync “succeeds”.

### 3. Sync progress reporting is incomplete

Severity: Medium

The UI expects progress information:

- `src/contexts/AppContext.tsx:56-67`
- `src/components/layout/SyncProgressBar.tsx:8-20`
- `src/pages/Onboarding.tsx:172-224`

But `server/src/services/sync.ts:163-165` only updates `orders_synced`. `server/src/db/queries/syncLogs.ts:22-37` supports `total_estimated`, but it is never set by the sync engine.

Result: the real backend can report a running sync with `totalEstimated = 0`, so the progress bar percentage is not meaningful.

### 4. Bulk order upsert is implemented sequentially

Severity: Medium

`server/src/services/sync.ts:159-165` syncs 50 orders at a time, but `server/src/db/queries/orders.ts:76-79` writes them one by one with `await upsertOrder(order)`.

This will become slow for larger stores and makes initial sync duration scale poorly. It is fine for a small demo, but not for a real multi-store app.

### 5. Large parts of the product are still mock/demo only

Severity: High from a product-direction standpoint

The real backend supports shops, sync, and orders. The following surfaces are still isolated demos:

- `src/pages/Vendors.tsx:9,32-50,64-66` uses `mockOrders` and only shows a toast for PDF generation.
- `src/pages/InvoiceTemplates.tsx:70-84,125-147` persists template edits only in `localStorage`.
- `src/pages/Notifications.tsx:15-39,60-80` has no backend/API/integration; it only edits in-memory component state.
- `src/pages/Settings.tsx:15-22,66` saves nothing.
- `src/pages/Plans.tsx:31-37` changes billing plan only in React state.
- `src/pages/Support.tsx:24-27,73-80` submits nowhere and only shows a toast.

This is the main reason I would say the project is not yet tightly aligned. The nav implies a full product, but only one core slice is actually implemented end-to-end.

### 6. Frontend quality gates are not green

Severity: Medium

Verification results:

- `npm run build`: passed
- `npx tsc -p server/tsconfig.json --noEmit`: passed
- `npx tsc -p tsconfig.app.json --noEmit`: failed
- `npm run lint`: failed
- `npm test`: passed, but only with a placeholder test

The immediate frontend type error is:

- `src/components/layout/SyncOverlay.tsx:6-9` reads `syncProgress` from context, but `src/contexts/AppContext.tsx:5-23` does not define it.

Tests are not meaningful yet:

- `src/test/example.test.ts:1-6` is only a trivial placeholder.

Lint also reports 27 errors and 10 warnings, so the repo does not currently meet a clean engineering baseline.

## Secondary Observations

- `README.md` is empty while `SETUP.md` contains the real onboarding docs. That increases project ambiguity.
- `package.json` still uses the generic name `vite_react_shadcn_ts` instead of the product name.
- Production build output contains a very large main chunk: about `1.55 MB` minified. This will likely need route-level or feature-level code splitting.
- `npm ci` reported `30 vulnerabilities` in dependencies. I would treat that as a cleanup task after the product/auth direction is fixed.

## Direction Recommendation

If you want this project to succeed, choose one of these paths and commit to it:

### Path A: Shopify Orders Sync App

Keep and deepen what is already real:

- secure embedded auth properly
- make sync reliable and update-aware
- improve dashboard, order analytics, and sync observability
- remove or hide vendors/invoices/notifications/plans/support until backed by real APIs

This is the shortest path to a coherent product.

### Path B: Full Invoicing / Vendor Payout Product

If this is the intended destination, then the current repo is still very early. You need real backend/domain work for:

- vendors data model
- invoice templates persistence
- PDF generation pipeline tied to real orders/vendors
- notification providers and delivery logs
- billing/subscription integration
- support/contact handling

Without that, the current UI is mostly signaling future ideas rather than implemented capability.

## My Recommendation

I would choose Path A first.

The repo already has the hardest early infrastructure started for that path:

- Shopify install flow
- shop persistence
- order sync
- order browsing

Turn it into a strong, narrow product before expanding again.

## Suggested Next 5 Steps

1. Replace `verifySession` with real embedded auth validation using Shopify session tokens or a proper persistent session strategy.
2. Fix incremental sync to track order updates, not just new order creation timestamps.
3. Remove, hide, or clearly mark demo-only pages until they have backend models and APIs.
4. Fix the current frontend type/lint failures and add real tests around auth, sync, and orders.
5. Define the product boundary in docs: either “orders sync app” or “invoicing/vendor operations app”.

## Final Assessment

There is a real product core here, but the repo is not yet disciplined enough to say it is strongly headed in the right direction.

The foundation is promising.
The scope is not.
The security/auth model must be fixed before calling it production-ready.
