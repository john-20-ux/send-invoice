# Sync Engine: Single-Day Split

## Feature
High-volume single-day split handling.

## Scope
Verify that a single day with more than 1000 orders is split into multiple bounded batches.

## Test Cases

1. Splits high-volume day into page batches
- Given Shopify reports 3200 orders for one day
- When first-time sync batches are planned
- Then four `single_day_split` batches are created
- And their counts are `1000`, `1000`, `1000`, and `200`
- And no single batch exceeds 1000 orders

2. Uses page indexes for safe execution
- Given a split day has multiple batches
- When each batch runs
- Then each batch uses `page_index` and `page_limit`
- And each batch imports only its assigned order slice.

## Automated Coverage
- `test_first_time_sync_splits_single_day_over_one_thousand_orders`
