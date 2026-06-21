const DEMO_SHOP_DOMAIN = 'demo-store.myshopify.com';
const DEMO_SHOP_NAME = 'Demo Store';
const DEFAULT_CURRENCY = 'USD';
const SYNC_RATE_LIMIT_MS = 5 * 60 * 1000;

type SyncState = 'idle' | 'running' | 'completed' | 'failed';

interface MockLineItem {
  id: string;
  sku: string | null;
  title: string;
  variantTitle: string | null;
  vendor: string | null;
  quantity: number;
  currentQuantity: number;
  totalAmount: number;
  totalCurrency: string;
}

interface MockTransaction {
  amount: number;
  currency: string;
}

export interface MockOrder {
  id: string;
  shop_domain: string;
  name: string;
  created_at: string;
  fully_paid: boolean;
  financial_status: string;
  fulfillment_status: string | null;
  total_price_amount: number;
  total_price_currency: string;
  total_discounts_amount: number;
  total_refunded_amount: number;
  total_shipping_amount: number;
  total_tax_amount: number;
  total_tip_amount: number;
  total_weight: number | null;
  customer_id: string | null;
  customer_first_name: string | null;
  customer_last_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  line_items: MockLineItem[];
  transactions: MockTransaction[];
  raw_data: Record<string, unknown>;
  synced_at: string;
}

export interface MockShopInfo {
  shopDomain: string;
  shopName: string;
  ownerEmail: string | null;
  installedAt: string;
  hasCompletedInitialSync: boolean;
}

export interface MockSyncStatus {
  status: SyncState;
  ordersSynced: number;
  totalEstimated: number;
  startedAt: string | null;
  finishedAt: string | null;
  lastSyncedAt: string | null;
}

const FIRST_NAMES = [
  'Sarah', 'James', 'Priya', 'Marcus', 'Emily', 'David', 'Aisha', 'Lucas',
  'Mei', 'Oliver', 'Fatima', 'Ryan', 'Chloe', 'Tomas', 'Nina', 'Hassan',
  'Eva', 'Raj', 'Isabelle', 'Kenji', 'Sophia', 'Liam', 'Amara', 'Noah',
];

const LAST_NAMES = [
  'Mitchell', 'Rodriguez', 'Sharma', 'Chen', 'Watson', 'Okafor', 'Patel',
  'Fernandez', 'Lin', 'Hughes', 'Alrashid', 'Kowalski', 'Bernard', 'Garcia',
  'Johansson', 'Malik', 'Muller', 'Krishnan', 'Dupont', 'Tanaka',
];

const PRODUCTS = [
  { title: 'Wireless Earbuds Pro', sku: 'WEP-001', variant: 'Black', vendor: 'TechStyle Co', price: 79.99 },
  { title: 'Organic Matcha Set', sku: 'OMS-042', variant: 'Premium', vendor: 'GreenLeaf Organics', price: 34.99 },
  { title: 'Denim Jacket Classic', sku: 'DJC-108', variant: 'Medium / Blue', vendor: 'UrbanWear Studio', price: 89.99 },
  { title: 'Ceramic Vase Duo', sku: 'CVD-220', variant: 'White', vendor: 'HomeBliss Decor', price: 45.0 },
  { title: 'Premium Dog Harness', sku: 'PDH-055', variant: 'Large / Red', vendor: 'PetPalace', price: 29.99 },
  { title: 'Yoga Mat Elite', sku: 'YME-301', variant: '6mm / Sage', vendor: 'FitGear Pro', price: 54.99 },
  { title: 'Sourdough Starter Kit', sku: 'SSK-015', variant: 'Standard', vendor: 'Artisan Bakes', price: 24.99 },
  { title: 'Scandi Table Lamp', sku: 'STL-190', variant: 'Oak', vendor: 'Nordic Living', price: 119.0 },
  { title: 'Smart Watch Band', sku: 'SWB-077', variant: '42mm / Navy', vendor: 'TechStyle Co', price: 19.99 },
  { title: 'Herbal Tea Collection', sku: 'HTC-063', variant: '12-Pack', vendor: 'GreenLeaf Organics', price: 28.5 },
  { title: 'Canvas Sneakers', sku: 'CSN-445', variant: 'US 10 / White', vendor: 'UrbanWear Studio', price: 64.99 },
  { title: 'Linen Throw Pillow', sku: 'LTP-332', variant: 'Oatmeal', vendor: 'HomeBliss Decor', price: 38.0 },
  { title: 'Cat Climbing Tower', sku: 'CCT-088', variant: 'Tall', vendor: 'PetPalace', price: 149.99 },
  { title: 'Resistance Band Set', sku: 'RBS-210', variant: '5-Pack', vendor: 'FitGear Pro', price: 22.99 },
  { title: 'Artisan Bread Knife', sku: 'ABK-007', variant: 'Walnut Handle', vendor: 'Artisan Bakes', price: 42.0 },
  { title: 'Wool Blanket', sku: 'WBL-156', variant: 'King / Grey', vendor: 'Nordic Living', price: 135.0 },
  { title: 'Phone Stand Walnut', sku: 'PSW-092', variant: 'Universal', vendor: 'TechStyle Co', price: 32.0 },
  { title: 'Face Serum Trio', sku: 'FST-501', variant: 'Sensitive', vendor: 'GreenLeaf Organics', price: 58.0 },
];

const FINANCIAL_STATUSES = ['PAID', 'PAID', 'PAID', 'PARTIALLY_PAID', 'PENDING', 'REFUNDED', 'PARTIALLY_REFUNDED'];
const FULFILLMENT_STATUSES = ['FULFILLED', 'FULFILLED', 'FULFILLED', 'UNFULFILLED', 'PARTIALLY_FULFILLED', 'IN_PROGRESS', null] as const;

function seededRandom(seed: number) {
  const x = Math.sin(seed) * 10000;
  return x - Math.floor(x);
}

function generateOrders(): MockOrder[] {
  const orders: MockOrder[] = [];
  const now = new Date();

  for (let i = 0; i < 150; i += 1) {
    const seed = i + 42;
    const daysAgo = Math.floor(seededRandom(seed) * 120);
    const date = new Date(now);
    date.setDate(date.getDate() - daysAgo);
    date.setHours(Math.floor(seededRandom(seed + 1) * 14) + 8);
    date.setMinutes(Math.floor(seededRandom(seed + 2) * 60));

    const firstName = FIRST_NAMES[Math.floor(seededRandom(seed + 3) * FIRST_NAMES.length)];
    const lastName = LAST_NAMES[Math.floor(seededRandom(seed + 4) * LAST_NAMES.length)];
    const financialStatus = FINANCIAL_STATUSES[Math.floor(seededRandom(seed + 5) * FINANCIAL_STATUSES.length)];
    const fulfillmentStatus = FULFILLMENT_STATUSES[Math.floor(seededRandom(seed + 6) * FULFILLMENT_STATUSES.length)];
    const itemCount = Math.floor(seededRandom(seed + 7) * 4) + 1;

    const lineItems: MockLineItem[] = [];
    let subtotal = 0;

    for (let j = 0; j < itemCount; j += 1) {
      const product = PRODUCTS[Math.floor(seededRandom(seed + 10 + j) * PRODUCTS.length)];
      const quantity = Math.floor(seededRandom(seed + 20 + j) * 3) + 1;
      const total = Math.round(quantity * product.price * 100) / 100;
      subtotal += total;

      lineItems.push({
        id: `gid://shopify/LineItem/${1000 + i * 10 + j}`,
        sku: product.sku,
        title: product.title,
        variantTitle: product.variant,
        vendor: product.vendor,
        quantity,
        currentQuantity: financialStatus === 'REFUNDED' ? 0 : quantity,
        totalAmount: total,
        totalCurrency: DEFAULT_CURRENCY,
      });
    }

    const discounts = Math.round(seededRandom(seed + 30) * subtotal * 0.15 * 100) / 100;
    const shipping = Math.round((seededRandom(seed + 31) * 15 + 5) * 100) / 100;
    const tax = Math.round((subtotal - discounts) * 0.08 * 100) / 100;
    const tip = seededRandom(seed + 32) > 0.8 ? Math.round(seededRandom(seed + 33) * 10 * 100) / 100 : 0;
    const totalPrice = Math.round((subtotal - discounts + shipping + tax + tip) * 100) / 100;
    const refunded = financialStatus === 'REFUNDED'
      ? totalPrice
      : financialStatus === 'PARTIALLY_REFUNDED'
        ? Math.round(totalPrice * 0.3 * 100) / 100
        : 0;
    const weight = Math.round(seededRandom(seed + 34) * 5000 + 200);

    const transactions: MockTransaction[] = [{ amount: totalPrice, currency: DEFAULT_CURRENCY }];
    if (refunded > 0) {
      transactions.push({ amount: -refunded, currency: DEFAULT_CURRENCY });
    }

    orders.push({
      id: `gid://shopify/Order/${4000 + i}`,
      shop_domain: DEMO_SHOP_DOMAIN,
      name: `#${1001 + i}`,
      created_at: date.toISOString(),
      fully_paid: financialStatus === 'PAID',
      financial_status: financialStatus,
      fulfillment_status: fulfillmentStatus,
      total_price_amount: totalPrice,
      total_price_currency: DEFAULT_CURRENCY,
      total_discounts_amount: discounts,
      total_refunded_amount: refunded,
      total_shipping_amount: shipping,
      total_tax_amount: tax,
      total_tip_amount: tip,
      total_weight: weight,
      customer_id: `gid://shopify/Customer/${2000 + Math.floor(seededRandom(seed + 40) * 50)}`,
      customer_first_name: firstName,
      customer_last_name: lastName,
      customer_email: `${firstName.toLowerCase()}.${lastName.toLowerCase()}@example.com`,
      customer_phone: seededRandom(seed + 41) > 0.5
        ? `+1${Math.floor(seededRandom(seed + 42) * 9000000000 + 1000000000)}`
        : null,
      line_items: lineItems,
      transactions,
      raw_data: {},
      synced_at: new Date().toISOString(),
    });
  }

  return orders.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
}

const mockOrders = generateOrders();
const installedAt = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();

let ownerEmail: string | null = null;
let lastManualSyncAt: number | null = null;
let syncTimer: ReturnType<typeof setTimeout> | null = null;
let syncStatus: MockSyncStatus = {
  status: 'idle',
  ordersSynced: 0,
  totalEstimated: mockOrders.length,
  startedAt: null,
  finishedAt: null,
  lastSyncedAt: null,
};

function normalizeSearchValue(value: string | null | undefined) {
  return (value || '').toLowerCase();
}

function clearExistingTimer() {
  if (syncTimer) {
    clearTimeout(syncTimer);
    syncTimer = null;
  }
}

function completeSync(totalOrders: number) {
  clearExistingTimer();
  const finishedAt = new Date().toISOString();
  syncStatus = {
    status: 'completed',
    ordersSynced: totalOrders,
    totalEstimated: totalOrders,
    startedAt: syncStatus.startedAt,
    finishedAt,
    lastSyncedAt: finishedAt,
  };
}

function simulateSync(totalOrders: number) {
  clearExistingTimer();

  const batchSize = 40;
  const step = () => {
    const nextValue = Math.min(syncStatus.ordersSynced + batchSize, totalOrders);
    syncStatus = {
      ...syncStatus,
      ordersSynced: nextValue,
      totalEstimated: totalOrders,
    };

    if (nextValue >= totalOrders) {
      completeSync(totalOrders);
      return;
    }

    syncTimer = setTimeout(step, 250);
  };

  syncTimer = setTimeout(step, 250);
}

export function getMockShopInfo(shopDomain = DEMO_SHOP_DOMAIN): MockShopInfo {
  return {
    shopDomain,
    shopName: DEMO_SHOP_NAME,
    ownerEmail,
    installedAt,
    hasCompletedInitialSync: Boolean(syncStatus.lastSyncedAt),
  };
}

export function updateMockShopEmail(nextEmail: string | null) {
  ownerEmail = nextEmail;
}

export function getMockOrders(opts: {
  from?: string;
  to?: string;
  page?: number;
  limit?: number;
  search?: string;
}): { orders: MockOrder[]; total: number } {
  const { from, to, page = 1, limit = 25, search } = opts;
  let filtered = [...mockOrders];

  if (from) {
    const fromDate = new Date(from);
    fromDate.setHours(0, 0, 0, 0);
    filtered = filtered.filter((order) => new Date(order.created_at) >= fromDate);
  }

  if (to) {
    const toDate = new Date(to);
    toDate.setHours(23, 59, 59, 999);
    filtered = filtered.filter((order) => new Date(order.created_at) <= toDate);
  }

  if (search) {
    const needle = search.toLowerCase();
    filtered = filtered.filter((order) => {
      const fullName = `${normalizeSearchValue(order.customer_first_name)} ${normalizeSearchValue(order.customer_last_name)}`.trim();
      return normalizeSearchValue(order.name).includes(needle)
        || normalizeSearchValue(order.customer_email).includes(needle)
        || fullName.includes(needle);
    });
  }

  const offset = (page - 1) * limit;
  return {
    orders: filtered.slice(offset, offset + limit),
    total: filtered.length,
  };
}

export function getMockOrder(orderId: string): MockOrder | null {
  return mockOrders.find((order) => order.id === orderId) || null;
}

export function triggerMockSync(type: 'full' | 'incremental' = 'incremental'): {
  started: boolean;
  message?: string;
  syncLogId?: string;
} {
  if (syncStatus.status === 'running') {
    return { started: false, message: 'Sync already in progress' };
  }

  if (type === 'incremental' && lastManualSyncAt && Date.now() - lastManualSyncAt < SYNC_RATE_LIMIT_MS) {
    const remaining = Math.ceil((SYNC_RATE_LIMIT_MS - (Date.now() - lastManualSyncAt)) / 1000);
    return { started: false, message: `Rate limited. Try again in ${remaining}s.` };
  }

  if (type === 'incremental') {
    lastManualSyncAt = Date.now();
  }

  syncStatus = {
    status: 'running',
    ordersSynced: 0,
    totalEstimated: mockOrders.length,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    lastSyncedAt: syncStatus.lastSyncedAt,
  };

  simulateSync(mockOrders.length);

  return {
    started: true,
    syncLogId: `mock-sync-${Date.now()}`,
  };
}

export function getMockSyncStatus(): MockSyncStatus {
  return { ...syncStatus };
}

export function getMockShopDomain() {
  return DEMO_SHOP_DOMAIN;
}
