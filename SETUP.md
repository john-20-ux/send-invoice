# Shopify Orders Sync App — Local Setup Guide

## Prerequisites

- Node.js 18+
- PostgreSQL 14+
- A [Shopify Partner account](https://partners.shopify.com/)
- A [Shopify development store](https://shopify.dev/docs/apps/tools/development-stores)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-local-tunnel/) or [ngrok](https://ngrok.com/) for HTTPS tunneling

## 1. Create the Shopify App in Partners Dashboard

1. Go to [Shopify Partners](https://partners.shopify.com/) → Apps → Create app
2. Choose "Create app manually"
3. Name: `Orders Sync Pro` (or anything you like)
4. Note your **API key** and **API secret key**

## 2. Set Up PostgreSQL

```bash
# Create the database
createdb shopify_orders_sync

# Or with Docker:
docker run -d --name shopify-pg \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=shopify_orders_sync \
  -p 5432:5432 \
  postgres:16
```

## 3. Configure Environment Variables

```bash
cp .env.example .env
```

Edit `.env` with your values:

```
SHOPIFY_API_KEY=<your API key from step 1>
SHOPIFY_API_SECRET=<your API secret from step 1>
SHOPIFY_SCOPES=read_orders
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/shopify_orders_sync
PORT=3001
VITE_SHOPIFY_API_KEY=<same API key>
```

## 4. Start a Tunnel

You need HTTPS for Shopify OAuth. Pick one:

**Option A — Cloudflare Tunnel (free, no account needed):**
```bash
npx cloudflared tunnel --url http://localhost:8080
```

**Option B — ngrok:**
```bash
ngrok http 8080
```

Copy the tunnel URL (e.g., `https://abc123.trycloudflare.com`) and update:

1. `.env` → `HOST=https://abc123.trycloudflare.com`
2. Shopify Partners → App Setup:
   - **App URL**: `https://abc123.trycloudflare.com`
   - **Allowed redirection URL(s)**: `https://abc123.trycloudflare.com/auth/callback`

## 5. Install Dependencies & Run Migrations

```bash
npm install
npm run db:migrate
```

## 6. Start the Dev Servers

```bash
# Start both Vite frontend (port 8080) and Express backend (port 3001)
npm run dev:full
```

This runs:
- **Vite** on `http://localhost:8080` (frontend, with proxy to backend)
- **Express** on `http://localhost:3001` (API + OAuth)

## 7. Install the App on Your Dev Store

1. Open your tunnel URL in a browser:
   ```
   https://abc123.trycloudflare.com/auth?shop=your-store.myshopify.com
   ```
2. You'll be redirected to Shopify to authorize the app
3. After authorizing, you'll land on the onboarding flow
4. Complete the 3 steps → your real orders will sync!

## 8. Access the App

After installation, access the app from:
- **Shopify Admin** → Apps → Orders Sync Pro
- **Direct URL**: `https://abc123.trycloudflare.com?shop=your-store.myshopify.com`

## Development Modes

### Mock Mode (no Shopify, no PostgreSQL)

If `VITE_SHOPIFY_API_KEY` is not set, the app runs with mock data:

```bash
npm run dev    # Just the Vite frontend with mock data
```

### Full Mode (real Shopify + PostgreSQL)

```bash
npm run dev:full    # Frontend + backend together
```

### Production

```bash
npm run build       # Build the Vite frontend
npm run start       # Serve everything from Express
```

## Architecture

```
┌─────────────────────────────────────────┐
│           Shopify Admin (iframe)         │
│  ┌─────────────────────────────────┐    │
│  │   Vite React SPA (:8080)       │    │
│  │   - Onboarding (3 steps)       │    │
│  │   - Dashboard                   │    │
│  │   - Orders page + detail modal │    │
│  │   - Sync progress bar          │    │
│  └──────────┬──────────────────────┘    │
│             │ /api/* proxied             │
│  ┌──────────▼──────────────────────┐    │
│  │   Express Server (:3000)       │    │
│  │   - OAuth (/auth, /auth/cb)    │    │
│  │   - API routes (/api/*)        │    │
│  │   - Sync engine (GraphQL)      │    │
│  └──────────┬──────────────────────┘    │
│             │                            │
│  ┌──────────▼──────────────────────┐    │
│  │   PostgreSQL                    │    │
│  │   - shops, orders, sync_logs   │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Troubleshooting

- **"Invalid shop domain"**: Ensure the shop param is `your-store.myshopify.com`
- **OAuth redirect fails**: Check that your tunnel URL matches exactly in `.env` and Partners dashboard
- **Database connection error**: Ensure PostgreSQL is running and `DATABASE_URL` is correct
- **Tunnel changes**: Cloudflare Tunnel URLs change on restart — update `.env` and Partners dashboard each time. Consider ngrok with a fixed subdomain for stability.
