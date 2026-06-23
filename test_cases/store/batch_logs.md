# Store: Batch Logs

## Feature
Durable batch tracking.

## Scope
Verify batch creation, uniqueness, status transitions, retry metadata, and summary reporting.

## Test Cases

1. Creates durable batch rows
- Given a first-time sync plan
- When batches are created
- Then each batch stores shop, resource, sync type, batch type, date range, order count, sequence, status, priority, and retry metadata.

2. Prevents duplicate batches
- Given an existing batch with the same shop, sync type, batch type, date range, and page index
- When the same batch is planned again
- Then the existing batch is reused
- And no duplicate row is inserted.

3. Tracks status transitions
- Given a pending batch
- When processing starts
- Then status becomes `processing`
- When processing completes
- Then status becomes `completed`
- When processing fails
- Then status becomes `failed`, `retry_count` increments, and `error_message` is stored.

4. Summarizes first-time sync status
- Given mixed batch statuses
- When `batch_summary` is read
- Then it reports pending, processing, failed, completed, initial completion, remaining completion, and full 6-month completion.

## Automated Coverage
- `test_first_time_sync_creates_initial_and_remaining_batches`
- `test_first_time_sync_splits_single_day_over_one_thousand_orders`
- `test_mock_first_time_sync_uses_batch_logs_and_imports_recent_mock_orders`
