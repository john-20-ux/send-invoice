export interface ShopInfo {
  id: string;
  install_id: string;
  access_token: string;
  shop_domain: string;
  shop_name: string | null;
  owner_email: string | null;
  installed_at: string;
  updated_at: string;
}

export interface ShopifyLineItem {
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

export interface ShopifyTransaction {
  amount: number;
  currency: string;
}

export interface ShopifyOrder {
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
  line_items: ShopifyLineItem[];
  transactions: ShopifyTransaction[];
  raw_data: Record<string, unknown>;
  synced_at: string;
}

export interface SyncLog {
  id: string;
  shop_domain: string;
  started_at: string;
  finished_at: string | null;
  status: 'running' | 'completed' | 'failed' | 'idle';
  orders_synced: number;
  error_message: string | null;
}

export interface SyncStatus {
  status: 'running' | 'completed' | 'failed' | 'idle';
  ordersSynced: number;
  totalEstimated: number;
  startedAt: string | null;
  finishedAt: string | null;
  lastSyncedAt: string | null;
}

export interface OrdersResponse {
  orders: ShopifyOrder[];
  total: number;
  page: number;
  limit: number;
  totalPages: number;
}
