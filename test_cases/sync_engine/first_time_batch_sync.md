# Sync Engine: First-Time Batch Sync

## Feature
Batch-wise first install order sync.

## Scope
Verify that first-time sync plans only the latest 6 months, prioritizes the latest 3 days, and processes remaining history newest-to-oldest in <=1000-order batches.

## Test Cases

1. Creates initial and remaining batches
- Given a newly installed shop with no existing `batch_logs`
- When `trigger_first_time` is called
- Then `initial_3_days` batches are created with `high` priority
- And `remaining_6_months` batches are created with `normal` priority
- And every batch has `order_count <= 1000`
- And all batches eventually complete

2. Initial data is available first
- Given initial batches are pending
- When processing starts
- Then high-priority `initial_3_days` batches run before normal-priority remaining batches
- And sync status can report recent data readiness before full 6-month completion

3. Existing plan is reusable
- Given a shop already has first-time sync batches
- When `trigger_first_time` is called again
- Then duplicate batches are not created for the same shop/range/page
- And failed/pending batches remain retryable.

## Automated Coverage
- `test_first_time_sync_creates_initial_and_remaining_batches`
- `test_mock_first_time_sync_uses_batch_logs_and_imports_recent_mock_orders`
