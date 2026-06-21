import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '../../.env') });
dotenv.config({ path: path.resolve(__dirname, '../../.env.local'), override: true });

const isProd = process.env.NODE_ENV === 'production';
const hasShopifyCredentials = Boolean(process.env.SHOPIFY_API_KEY && process.env.SHOPIFY_API_SECRET);
const hasDatabaseUrl = Boolean(process.env.DATABASE_URL);
const mockMode = process.env.MOCK_MODE === 'true'
  || (!isProd && (!hasShopifyCredentials || !hasDatabaseUrl));

export const config = {
  port: parseInt(process.env.PORT || '3001', 10),
  shopify: {
    apiKey: process.env.SHOPIFY_API_KEY || '',
    apiSecret: process.env.SHOPIFY_API_SECRET || '',
    scopes: (process.env.SHOPIFY_SCOPES || 'read_orders').split(','),
    hostName: process.env.HOST || 'localhost:3000',
    apiVersion: '2026-01',
  },
  databaseUrl: process.env.DATABASE_URL || 'postgresql://localhost:5432/send_invoice_pro',
  host: process.env.HOST || 'http://localhost:8080',
  isProd,
  mockMode,
};
