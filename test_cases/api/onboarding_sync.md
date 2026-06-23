# API/UI: Onboarding Sync

## Feature
First-time sync through onboarding.

## Scope
Verify the onboarding flow triggers first-time sync and exposes clear batch status.

## Test Cases

1. Starts first-time sync
- Given onboarding step 3 loads
- When the browser posts to `/api/sync`
- Then request body uses `{"type":"first_time"}`
- And the backend calls `trigger_first_time`.

2. Exposes batch status
- Given first-time batches exist
- When `GET /api/sync/batches/status` is called
- Then response includes total, pending, processing, failed, completed, initial completion, remaining completion, and full 6-month completion fields.

3. Redirects when recent data is ready
- Given initial 3-day batches complete and remaining batches are still pending/running
- When onboarding polls `/api/sync/status`
- Then status can be treated as ready for dashboard access
- And remaining batches continue in the background.

## Automated Coverage
- `test_onboarding_complete_redirects_after_sync`
- `test_mock_first_time_sync_uses_batch_logs_and_imports_recent_mock_orders`
