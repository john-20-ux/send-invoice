# App Uninstalled Webhook

1. Install a real Shopify shop and let it remain installed for at least 3 months.
2. Confirm the app has registered `APP_UNINSTALLED` to `POST /webhooks/app-uninstalled`.
3. Send a signed Shopify webhook request:
   - `X-Shopify-Topic: app/uninstalled`
   - `X-Shopify-Shop-Domain: your-store.myshopify.com`
   - Valid `X-Shopify-Hmac-Sha256`
4. Expect a `200` response with:
   - `received: true`
   - `scheduledForDeletionAt` set to roughly 48 hours after the uninstall time
5. Confirm the shop record has:
   - `access_token = NULL`
   - `uninstalled_at` populated
   - `scheduled_for_deletion_at` populated
6. After the cleanup worker reaches the scheduled time, confirm the shop row and its related order/sync data are deleted from SQLite.
7. Reinstalling before the scheduled deletion should clear the pending deletion timestamps and restore normal access.
