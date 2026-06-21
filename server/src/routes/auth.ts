import { Router } from 'express';
import { config } from '../config.js';
import {
  buildAuthUrl,
  exchangeToken,
  verifyHmac,
  isValidShopDomain,
  fetchShopInfo,
  generateNonce,
} from '../services/shopify.js';
import { upsertShop, updateShopName } from '../db/queries/shops.js';
import { getMockShopDomain } from '../mock/store.js';
import { getErrorMessage, getSingleString, toStringRecord } from '../utils/http.js';

const router = Router();

/**
 * GET /auth
 * Start the Shopify OAuth flow
 */
router.get('/auth', (req, res) => {
  const shop = getSingleString(req.query.shop);

  if (config.mockMode) {
    const mockShop = shop && isValidShopDomain(shop) ? shop : getMockShopDomain();
    req.session.shopDomain = mockShop;
    return res.redirect(`/onboarding?shop=${mockShop}`);
  }

  if (!shop || !isValidShopDomain(shop)) {
    return res.status(400).send('Missing or invalid shop parameter. Expected: yourstore.myshopify.com');
  }

  const state = generateNonce();
  req.session.state = state;
  req.session.shopDomain = shop;

  const redirectUri = `${config.host}/auth/callback`;
  const authUrl = buildAuthUrl(shop, redirectUri, state);

  res.redirect(authUrl);
});

/**
 * GET /auth/callback
 * Handle the OAuth callback from Shopify
 */
router.get('/auth/callback', async (req, res) => {
  try {
    if (config.mockMode) {
      const mockShop = getMockShopDomain();
      req.session.shopDomain = mockShop;
      return res.redirect(`/onboarding?shop=${mockShop}`);
    }

    const shop = getSingleString(req.query.shop);
    const code = getSingleString(req.query.code);
    const state = getSingleString(req.query.state);
    const hmac = getSingleString(req.query.hmac);

    // Validate shop domain
    if (!shop || !isValidShopDomain(shop)) {
      return res.status(400).send('Invalid shop domain');
    }

    if (!code || !state || !hmac) {
      return res.status(400).send('Missing required OAuth parameters');
    }

    // Verify state/nonce
    const savedState = req.session.state;
    if (!savedState || state !== savedState) {
      return res.status(403).send('Invalid state parameter. Possible CSRF attack.');
    }

    // Verify HMAC
    const queryParams = toStringRecord(req.query as Record<string, unknown>);
    if (!verifyHmac(queryParams)) {
      return res.status(403).send('HMAC verification failed');
    }

    // Exchange code for access token
    const { access_token, scope } = await exchangeToken(shop, code);

    // Save shop to database
    await upsertShop(shop, access_token, scope);

    // Try to fetch and save shop name
    try {
      const shopInfo = await fetchShopInfo(shop, access_token);
      if (shopInfo?.name) {
        await updateShopName(shop, shopInfo.name);
      }
    } catch (err) {
      console.warn('Could not fetch shop info:', err);
    }

    // Set session
    req.session.shopDomain = shop;
    req.session.state = null;

    // Redirect to app
    const host = getSingleString(req.query.host);
    if (host) {
      // Embedded app — redirect back into Shopify admin
      res.redirect(`/?shop=${shop}&host=${host}`);
    } else {
      res.redirect(`/onboarding?shop=${shop}`);
    }
  } catch (err) {
    console.error('OAuth callback error:', err);
    res.status(500).send(`Authentication failed: ${getErrorMessage(err)}`);
  }
});

export default router;
