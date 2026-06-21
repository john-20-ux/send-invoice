import { Router } from 'express';
import { config } from '../config.js';
import { verifySession } from '../middleware/verifySession.js';
import { getShop, updateShopEmail } from '../db/queries/shops.js';
import { getOrders, getOrder } from '../db/queries/orders.js';
import {
  getLatestSyncLog,
  getLastCompletedSync,
} from '../db/queries/syncLogs.js';
import { runSync } from '../services/sync.js';
import {
  getMockOrder,
  getMockOrders,
  getMockShopInfo,
  getMockSyncStatus,
  triggerMockSync,
  updateMockShopEmail,
} from '../mock/store.js';

const router = Router();

// All API routes require valid session
router.use(verifySession);

// Rate limit tracking for manual syncs (in-memory for simplicity)
const syncRateLimits = new Map<string, number>();

/**
 * GET /api/shop
 * Return shop info (without access_token)
 */
router.get('/shop', async (req, res) => {
  if (config.mockMode) {
    return res.json(getMockShopInfo(req.shopDomain));
  }

  const shop = await getShop(req.shopDomain!);
  if (!shop) return res.status(404).json({ error: 'Shop not found' });

  const lastSync = await getLastCompletedSync(req.shopDomain!);

  res.json({
    shopDomain: shop.shop_domain,
    shopName: shop.shop_name,
    ownerEmail: shop.owner_email,
    installedAt: shop.installed_at,
    hasCompletedInitialSync: !!lastSync,
  });
});

/**
 * PUT /api/shop/email
 * Update the shop owner's email
 */
router.put('/shop/email', async (req, res) => {
  const { email } = req.body;

  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Invalid email format' });
  }

  if (config.mockMode) {
    updateMockShopEmail(email || null);
    return res.json({ success: true });
  }

  await updateShopEmail(req.shopDomain!, email || null);
  res.json({ success: true });
});

/**
 * GET /api/orders
 * Fetch orders with pagination and date filtering
 */
router.get('/orders', async (req, res) => {
  const { from, to, page, limit, search } = req.query;

  const parsedPage = page ? parseInt(page as string, 10) : 1;
  const parsedLimit = limit ? parseInt(limit as string, 10) : 25;
  const options = {
    from: from as string,
    to: to as string,
    page: parsedPage,
    limit: parsedLimit,
    search: search as string,
  };

  const result = config.mockMode
    ? getMockOrders(options)
    : await getOrders(req.shopDomain!, options);

  const totalPages = Math.ceil(result.total / parsedLimit);

  res.json({
    orders: result.orders,
    total: result.total,
    page: parsedPage,
    limit: parsedLimit,
    totalPages,
  });
});

/**
 * GET /api/orders/:id
 * Fetch a single order by ID
 */
router.get('/orders/:id', async (req, res) => {
  const orderId = decodeURIComponent(req.params.id);
  const order = config.mockMode
    ? getMockOrder(orderId)
    : await getOrder(req.shopDomain!, orderId);

  if (!order) return res.status(404).json({ error: 'Order not found' });
  res.json(order);
});

/**
 * POST /api/sync
 * Trigger a sync job (full or incremental)
 */
router.post('/sync', async (req, res) => {
  if (config.mockMode) {
    return res.json(triggerMockSync(req.body.type));
  }

  const shopDomain = req.shopDomain!;
  const accessToken = req.accessToken!;
  const { type = 'incremental' } = req.body;

  // Check if already syncing
  const currentSync = await getLatestSyncLog(shopDomain);
  if (currentSync?.status === 'running') {
    return res.json({ started: false, message: 'Sync already in progress' });
  }

  // Rate limit: 1 manual sync per 5 minutes
  const lastTrigger = syncRateLimits.get(shopDomain);
  if (lastTrigger && Date.now() - lastTrigger < 5 * 60 * 1000) {
    const remaining = Math.ceil((5 * 60 * 1000 - (Date.now() - lastTrigger)) / 1000);
    return res.json({ started: false, message: `Rate limited. Try again in ${remaining}s.` });
  }

  syncRateLimits.set(shopDomain, Date.now());

  // Determine last sync timestamp for incremental
  let lastSyncedAt: string | null = null;
  if (type === 'incremental') {
    const lastCompleted = await getLastCompletedSync(shopDomain);
    lastSyncedAt = lastCompleted?.finished_at || null;
  }

  // Start async sync
  const syncLogId = await runSync({
    shopDomain,
    accessToken,
    lastSyncedAt,
  });

  res.json({ started: true, syncLogId });
});

/**
 * GET /api/sync/status
 * Return current sync status
 */
router.get('/sync/status', async (req, res) => {
  if (config.mockMode) {
    return res.json(getMockSyncStatus());
  }

  const latestLog = await getLatestSyncLog(req.shopDomain!);
  const lastCompleted = await getLastCompletedSync(req.shopDomain!);

  if (!latestLog) {
    return res.json({
      status: 'idle',
      ordersSynced: 0,
      totalEstimated: 0,
      startedAt: null,
      finishedAt: null,
      lastSyncedAt: null,
    });
  }

  res.json({
    status: latestLog.status,
    ordersSynced: latestLog.orders_synced,
    totalEstimated: latestLog.total_estimated,
    startedAt: latestLog.started_at,
    finishedAt: latestLog.finished_at,
    lastSyncedAt: lastCompleted?.finished_at || null,
  });
});

export default router;
