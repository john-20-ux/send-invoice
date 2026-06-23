# Ruby App Setup

The primary implementation lives under `ruby_app/`.

## Local Mock Mode

1. Install dependencies:

   ```bash
   bundle install
   ```

2. Copy the environment file:

   ```bash
   cp .env.example .env
   ```

3. Start the app:

   ```bash
   bin/server
   ```

4. Open the onboarding flow:

   ```text
   http://localhost:3000/auth
   ```

Mock mode activates automatically when Shopify credentials are missing, or you can force it with `MOCK_MODE=true`.

## Real Shopify Mode

For Shopify OAuth and real order sync:

1. Create an app in Shopify Partners.
2. Put the credentials in `.env`.
3. Expose your app with HTTPS.
4. Set `HOST` to that public URL.
5. Open:

   ```text
   /auth?shop=your-store.myshopify.com
   ```

The callback route is:

```text
/auth/callback
```

## Storage

- Default database: `ruby_app/db/send_invoice.sqlite3`
- Override with: `DATABASE_PATH=/absolute/path/to/send_invoice.sqlite3`

The Ruby app persists:

- shops
- orders
- sync logs
- sessions
- invoice settings
- notification settings
- vendor payout edits

## Tests

```bash
bin/test
```
