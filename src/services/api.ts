import type { SyncStatus, ShopifyOrder, OrdersResponse } from '@/types/shopify';

const API_MODE = import.meta.env.VITE_API_MODE || 'auto';
const FORCE_MOCK = API_MODE === 'mock';
const FORCE_BACKEND = API_MODE === 'backend';

// --- HTTP helpers ---

function getShopDomain(): string {
  const params = new URLSearchParams(window.location.search);
  return params.get('shop') || localStorage.getItem('shopify_shop_domain') || '';
}

async function apiFetch(path: string, options: RequestInit = {}): Promise<Response> {
  const shopDomain = getShopDomain();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(shopDomain ? { 'x-shop-domain': shopDomain } : {}),
    ...(options.headers as Record<string, string> || {}),
  };

  const res = await fetch(path, { ...options, headers });
  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(body.error || `Request failed: ${res.status}`);
  }
  return res;
}

async function withMockFallback<T>(
  backendCall: () => Promise<T>,
  mockCall: () => Promise<T>
): Promise<T> {
  if (FORCE_MOCK) {
    return mockCall();
  }

  try {
    return await backendCall();
  } catch (error) {
    if (FORCE_BACKEND || !import.meta.env.DEV) {
      throw error;
    }

    console.warn('Backend unavailable, falling back to local mock data.', error);
    return mockCall();
  }
}

// --- Mock API state (used when no backend is available) ---

let mockSyncState: SyncStatus = {
  status: 'idle',
  ordersSynced: 0,
  totalEstimated: 0,
  startedAt: null,
  finishedAt: null,
  lastSyncedAt: null,
};

let lastManualSyncTime: number | null = null;
let mockOrdersCache: ShopifyOrder[] | null = null;

function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function getMockShopifyOrders(): Promise<ShopifyOrder[]> {
  if (mockOrdersCache) {
    return mockOrdersCache;
  }

  const module = await import('@/data/shopifyMockData');
  mockOrdersCache = module.mockShopifyOrders;
  if (mockSyncState.totalEstimated === 0) {
    mockSyncState = {
      ...mockSyncState,
      totalEstimated: mockOrdersCache.length,
    };
  }
  return mockOrdersCache;
}

// --- API interface (works with both mock and real backend) ---

export const api = {
  // Onboarding
  async saveEmail(email: string | null): Promise<{ success: boolean }> {
    return withMockFallback(async () => {
      const res = await apiFetch('/api/shop/email', {
        method: 'PUT',
        body: JSON.stringify({ email }),
      });
      return res.json();
    }, async () => {
      await delay(300);
      return { success: true };
    });
  },

  async connectStore(shopDomain: string): Promise<{ success: boolean; shopName: string }> {
    return withMockFallback(async () => {
      const res = await apiFetch('/api/shop');
      const data = await res.json();
      return { success: true, shopName: data.shopName || shopDomain };
    }, async () => {
      await delay(800);
      const pattern = /^[a-zA-Z0-9][a-zA-Z0-9-]*\.myshopify\.com$/;
      if (!pattern.test(shopDomain)) {
        throw new Error('Invalid shop domain. Must match *.myshopify.com');
      }
      localStorage.setItem('shopify_shop_domain', shopDomain);
      return { success: true, shopName: 'Demo Store' };
    });
  },

  // Sync
  async triggerSync(type: 'full' | 'incremental' = 'incremental'): Promise<{ started: boolean; message?: string }> {
    return withMockFallback(async () => {
      const res = await apiFetch('/api/sync', {
        method: 'POST',
        body: JSON.stringify({ type }),
      });
      return res.json();
    }, async () => {
      if (mockSyncState.status === 'running') {
        return { started: false, message: 'Sync already in progress' };
      }
      const mockShopifyOrders = await getMockShopifyOrders();
      if (type === 'incremental' && lastManualSyncTime && Date.now() - lastManualSyncTime < 5 * 60 * 1000) {
        const remaining = Math.ceil((5 * 60 * 1000 - (Date.now() - lastManualSyncTime)) / 1000);
        return { started: false, message: `Rate limited. Try again in ${remaining}s.` };
      }
      if (type === 'incremental') lastManualSyncTime = Date.now();

      mockSyncState = {
        status: 'running',
        ordersSynced: 0,
        totalEstimated: mockShopifyOrders.length,
        startedAt: new Date().toISOString(),
        finishedAt: null,
        lastSyncedAt: mockSyncState.lastSyncedAt,
      };

      (async () => {
        const batchSize = 50;
        const total = mockShopifyOrders.length;
        for (let i = 0; i < total; i += batchSize) {
          await delay(600 + Math.random() * 400);
          mockSyncState.ordersSynced = Math.min(i + batchSize, total);
        }
        mockSyncState.status = 'completed';
        mockSyncState.finishedAt = new Date().toISOString();
        mockSyncState.lastSyncedAt = new Date().toISOString();
      })();

      return { started: true };
    });
  },

  async getSyncStatus(): Promise<SyncStatus> {
    return withMockFallback(async () => {
      const res = await apiFetch('/api/sync/status');
      return res.json();
    }, async () => {
      await getMockShopifyOrders();
      return { ...mockSyncState };
    });
  },

  // Orders
  async getOrders(params: {
    from?: string;
    to?: string;
    page?: number;
    limit?: number;
    search?: string;
  }): Promise<OrdersResponse> {
    return withMockFallback(async () => {
      const qs = new URLSearchParams();
      if (params.from) qs.set('from', params.from);
      if (params.to) qs.set('to', params.to);
      if (params.page) qs.set('page', String(params.page));
      if (params.limit) qs.set('limit', String(params.limit));
      if (params.search) qs.set('search', params.search);

      const res = await apiFetch(`/api/orders?${qs}`);
      return res.json();
    }, async () => {
      await delay(200);
      const mockShopifyOrders = await getMockShopifyOrders();
      const { from, to, page = 1, limit = 25, search } = params;
      let filtered = [...mockShopifyOrders];

      if (from) {
        const fromDate = new Date(from);
        fromDate.setHours(0, 0, 0, 0);
        filtered = filtered.filter(o => new Date(o.created_at) >= fromDate);
      }
      if (to) {
        const toDate = new Date(to);
        toDate.setHours(23, 59, 59, 999);
        filtered = filtered.filter(o => new Date(o.created_at) <= toDate);
      }
      if (search) {
        const q = search.toLowerCase();
        filtered = filtered.filter(o =>
          o.name.toLowerCase().includes(q) ||
          (o.customer_first_name?.toLowerCase() || '').includes(q) ||
          (o.customer_last_name?.toLowerCase() || '').includes(q) ||
          (o.customer_email?.toLowerCase() || '').includes(q)
        );
      }

      const total = filtered.length;
      const totalPages = Math.ceil(total / limit);
      const offset = (page - 1) * limit;
      const orders = filtered.slice(offset, offset + limit);
      return { orders, total, page, limit, totalPages };
    });
  },

  async getOrder(id: string): Promise<ShopifyOrder | null> {
    return withMockFallback(async () => {
      const res = await apiFetch(`/api/orders/${encodeURIComponent(id)}`);
      return res.json();
    }, async () => {
      await delay(100);
      const mockShopifyOrders = await getMockShopifyOrders();
      return mockShopifyOrders.find(o => o.id === id) || null;
    });
  },

  getShopDomain(): string {
    return getShopDomain() || 'demo-store.myshopify.com';
  },

  getShopName(): string {
    return 'Demo Store';
  },

  isConnected(): boolean {
    return true;
  },

  resetSyncRateLimit(): void {
    lastManualSyncTime = null;
  },
};
