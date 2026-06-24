# Orders Changed Webhook

1. Install a real Shopify shop and confirm the app has registered:
   - `ORDERS_CREATE`
   - `ORDERS_UPDATED`
   - `ORDERS_EDITED`
2. Confirm each topic points to `POST /webhooks/orders-changed`.
3. Send a signed Shopify webhook request with one of these headers:
   - `X-Shopify-Topic: orders/create`
   - `X-Shopify-Topic: orders/updated`
   - `X-Shopify-Topic: orders/edited`
4. Expect a `200` response with:
   - `received: true`
   - `accepted: true` unless another sync is already running
5. Confirm the app starts an incremental sync for that shop.
6. Confirm the updated order row is upserted in SQLite using the latest Shopify `updatedAt` values.
7. Confirm repeated webhook deliveries do not duplicate orders because writes use upsert on `(id, shop_domain)`.
