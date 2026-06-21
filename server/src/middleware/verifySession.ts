import type { Request, Response, NextFunction } from 'express';
import { config } from '../config.js';
import { getShop } from '../db/queries/shops.js';
import { isValidShopDomain } from '../services/shopify.js';
import { getMockShopDomain } from '../mock/store.js';
import { getSingleString } from '../utils/http.js';

/**
 * Middleware to verify the Shopify session.
 * In embedded apps, the shop domain comes from:
 * 1. Session cookie (set during OAuth)
 * 2. Query param `shop` (initial load from Shopify admin)
 * 3. App Bridge session token (JWT in Authorization header)
 */
export async function verifySession(req: Request, res: Response, next: NextFunction) {
  try {
    if (config.mockMode) {
      const requestedShop =
        req.session.shopDomain ||
        getSingleString(req.query.shop) ||
        getSingleString(req.headers['x-shop-domain']) ||
        getMockShopDomain();

      const shopDomain = isValidShopDomain(requestedShop) ? requestedShop : getMockShopDomain();
      req.shopDomain = shopDomain;
      req.accessToken = 'mock-access-token';
      req.session.shopDomain = shopDomain;
      return next();
    }

    // Get shop domain from session cookie, query param, or header
    const shopDomain =
      req.session.shopDomain ||
      getSingleString(req.query.shop) ||
      getSingleString(req.headers['x-shop-domain']);

    if (!shopDomain || !isValidShopDomain(shopDomain)) {
      return res.status(401).json({ error: 'Unauthorized: missing or invalid shop domain' });
    }

    const shop = await getShop(shopDomain);
    if (!shop) {
      return res.status(401).json({ error: 'Unauthorized: shop not found. Please reinstall the app.' });
    }

    req.shopDomain = shopDomain;
    req.accessToken = shop.access_token;
    next();
  } catch (err) {
    console.error('Session verification error:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
}
