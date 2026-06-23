# Mock Data: First-Time Sync

## Feature
Mock-mode first-time sync simulation.

## Scope
Verify local/demo mode exercises the same first-time batch planning and execution flow without Shopify credentials.

## Test Cases

1. Plans mock batches
- Given the app is running in mock mode
- When `trigger_first_time` is called
- Then `batch_logs` are created for `initial_3_days` and `remaining_6_months`
- And initial batches are high priority
- And remaining batches are normal priority.

2. Imports mock orders by batch date range
- Given planned mock batches
- When batches are processed
- Then mock orders are filtered by the batch `created_at` range
- And imported orders match planned batch order counts.

3. Completes sync log
- Given all mock batches complete
- When sync status is checked
- Then the latest sync log is `completed`
- And batch summary is `full_6_months_sync_completed`.

## Automated Coverage
- `test_mock_first_time_sync_uses_batch_logs_and_imports_recent_mock_orders`
