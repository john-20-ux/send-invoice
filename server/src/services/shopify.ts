import crypto from 'crypto';
import { config } from '../config.js';

const API_VERSION = config.shopify.apiVersion;

interface ShopifyAuthResult {
  access_token: string;
  scope: string;
}

interface ShopifyShopInfo {
  name?: string;
}

interface GraphQLError {
  message: string;
}

interface GraphQLResponse<TData> {
  data?: TData;
  errors?: GraphQLError[];
}

/**
 * Build the OAuth authorization URL for Shopify
 */
export function buildAuthUrl(shop: string, redirectUri: string, state: string): string {
  const scopes = config.shopify.scopes.join(',');
  return `https://${shop}/admin/oauth/authorize?client_id=${config.shopify.apiKey}&scope=${scopes}&redirect_uri=${encodeURIComponent(redirectUri)}&state=${state}`;
}

/**
 * Exchange authorization code for access token
 */
export async function exchangeToken(shop: string, code: string): Promise<ShopifyAuthResult> {
  const response = await fetch(`https://${shop}/admin/oauth/access_token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: config.shopify.apiKey,
      client_secret: config.shopify.apiSecret,
      code,
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Shopify token exchange failed: ${response.status} ${text}`);
  }

  return response.json() as Promise<ShopifyAuthResult>;
}

/**
 * Verify Shopify HMAC signature on OAuth callback
 */
export function verifyHmac(queryParams: Record<string, string>): boolean {
  const { hmac, ...rest } = queryParams;
  if (!hmac) return false;

  const message = Object.keys(rest)
    .sort()
    .map((key) => `${key}=${rest[key]}`)
    .join('&');

  const computed = crypto
    .createHmac('sha256', config.shopify.apiSecret)
    .update(message)
    .digest('hex');

  return crypto.timingSafeEqual(Buffer.from(hmac), Buffer.from(computed));
}

/**
 * Validate shop domain format
 */
export function isValidShopDomain(shop: string): boolean {
  return /^[a-zA-Z0-9][a-zA-Z0-9-]*\.myshopify\.com$/.test(shop);
}

/**
 * Fetch shop details from Shopify REST API
 */
export async function fetchShopInfo(shop: string, accessToken: string): Promise<ShopifyShopInfo> {
  const response = await fetch(
    `https://${shop}/admin/api/${API_VERSION}/shop.json`,
    {
      headers: {
        'X-Shopify-Access-Token': accessToken,
        'Content-Type': 'application/json',
      },
    }
  );

  if (!response.ok) {
    throw new Error(`Failed to fetch shop info: ${response.status}`);
  }

  const data = await response.json() as { shop: ShopifyShopInfo };
  return data.shop;
}

/**
 * Execute a GraphQL query against the Shopify Admin API
 */
export async function shopifyGraphQL<TData>(
  shop: string,
  accessToken: string,
  queryStr: string,
  variables: Record<string, unknown> = {}
): Promise<TData> {
  const response = await fetch(
    `https://${shop}/admin/api/${API_VERSION}/graphql.json`,
    {
      method: 'POST',
      headers: {
        'X-Shopify-Access-Token': accessToken,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query: queryStr, variables }),
    }
  );

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Shopify GraphQL error: ${response.status} ${text}`);
  }

  const result = await response.json() as GraphQLResponse<TData>;

  if (result.errors && result.errors.length > 0) {
    throw new Error(`GraphQL errors: ${JSON.stringify(result.errors)}`);
  }

  if (result.data === undefined) {
    throw new Error('GraphQL response missing data');
  }

  return result.data;
}

/**
 * Generate a cryptographically random nonce for OAuth state
 */
export function generateNonce(): string {
  return crypto.randomBytes(16).toString('hex');
}
