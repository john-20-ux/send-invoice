# Bulk Operations Finish Webhook

## Valid delivery

1. Create a running `bulk_sync_jobs` row with a Shopify bulk operation ID.
2. POST a JSON payload to `/webhooks/bulk-operations-finish`.
3. Include:
   - `X-Shopify-Hmac-Sha256`
   - `X-Shopify-Topic: bulk_operations/finish`
   - `X-Shopify-Shop-Domain`
   - `X-Shopify-Webhook-Id`
4. Verify the endpoint returns HTTP 200 immediately.
5. Verify the matching job imports its JSONL result and reaches `completed`.
6. Deliver the same webhook again.
7. Verify the order is not imported twice.

## Invalid signature

1. POST the same payload with an invalid HMAC header.
2. Verify the endpoint returns HTTP 401.
3. Verify no bulk job processing starts.

## Poll and webhook race

1. Allow the polling loop and webhook handler to observe the same completed operation.
2. Verify only one path can atomically claim the job for downloading.
3. Verify the other path exits without importing the result again.
