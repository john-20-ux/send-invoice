# Shopify: Orders Count Planning

## Feature
Order-count-based batch boundary detection.

## Scope
Verify Shopify `ordersCount` is used for batch planning rather than fixed weekly/monthly date windows.

## Test Cases

1. Counts each candidate day
- Given a target date range
- When planning batches
- Then the app calls Shopify order count with `created_at:>=... created_at:<...`
- And it moves backward from newest to oldest.

2. Closes a batch before exceeding 1000 orders
- Given accumulated candidate days total under 1000
- When the next older day would exceed 1000
- Then the batch closes before that day
- And the next batch starts from that older day.

3. Supports low-volume stores
- Given multiple days with low order counts
- When planning batches
- Then a single batch may cover many days
- And order count remains <=1000.

## Automated Coverage
- `test_first_time_sync_creates_initial_and_remaining_batches`
