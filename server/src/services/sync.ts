import { shopifyGraphQL } from './shopify.js';
import { upsertOrders, type OrderRow } from '../db/queries/orders.js';
import {
  createSyncLog,
  updateSyncLogProgress,
  completeSyncLog,
  failSyncLog,
} from '../db/queries/syncLogs.js';
import { getErrorMessage } from '../utils/http.js';

const ORDERS_QUERY = `
query SyncOrders($cursor: String, $query: String) {
  orders(first: 50, after: $cursor, query: $query, sortKey: CREATED_AT) {
    pageInfo {
      hasNextPage
      endCursor
    }
    edges {
      node {
        id
        name
        createdAt
        fullyPaid
        displayFinancialStatus
        displayFulfillmentStatus
        lineItems(first: 50) {
          edges {
            node {
              id
              sku
              title
              variantTitle
              vendor
              quantity
              currentQuantity
              originalTotalSet {
                shopMoney { amount currencyCode }
              }
            }
          }
        }
        totalDiscountsSet { shopMoney { amount currencyCode } }
        totalPriceSet { shopMoney { amount currencyCode } }
        totalRefundedSet { shopMoney { amount currencyCode } }
        totalShippingPriceSet { shopMoney { amount currencyCode } }
        totalTaxSet { shopMoney { amount currencyCode } }
        totalTipReceivedSet { shopMoney { amount currencyCode } }
        totalWeight
        transactions {
          amountSet { shopMoney { amount currencyCode } }
        }
        customer {
          id
          firstName
          lastName
          email
          phone
        }
      }
    }
  }
}
`;

interface SyncOptions {
  shopDomain: string;
  accessToken: string;
  lastSyncedAt?: string | null; // ISO string for incremental sync
}

interface ShopifyMoneySet {
  shopMoney?: {
    amount: string;
    currencyCode: string;
  } | null;
}

interface ShopifyLineItemNode {
  id: string;
  sku: string | null;
  title: string;
  variantTitle: string | null;
  vendor: string | null;
  quantity: number;
  currentQuantity: number;
  originalTotalSet?: ShopifyMoneySet | null;
}

interface ShopifyTransactionNode {
  amountSet?: ShopifyMoneySet | null;
}

interface ShopifyCustomerNode {
  id: string | null;
  firstName: string | null;
  lastName: string | null;
  email: string | null;
  phone: string | null;
}

interface ShopifyOrderNode {
  id: string;
  name: string;
  createdAt: string;
  fullyPaid?: boolean | null;
  displayFinancialStatus?: string | null;
  displayFulfillmentStatus?: string | null;
  lineItems?: {
    edges: Array<{ node: ShopifyLineItemNode }>;
  } | null;
  totalDiscountsSet?: ShopifyMoneySet | null;
  totalPriceSet?: ShopifyMoneySet | null;
  totalRefundedSet?: ShopifyMoneySet | null;
  totalShippingPriceSet?: ShopifyMoneySet | null;
  totalTaxSet?: ShopifyMoneySet | null;
  totalTipReceivedSet?: ShopifyMoneySet | null;
  totalWeight?: number | null;
  transactions: ShopifyTransactionNode[];
  customer?: ShopifyCustomerNode | null;
}

interface OrdersQueryData {
  orders: {
    pageInfo: {
      hasNextPage: boolean;
      endCursor: string | null;
    };
    edges: Array<{ node: ShopifyOrderNode }>;
  };
}

function getMoney(set: ShopifyMoneySet | null | undefined): { amount: number; currency: string } {
  if (!set?.shopMoney) return { amount: 0, currency: 'USD' };
  return {
    amount: parseFloat(set.shopMoney.amount) || 0,
    currency: set.shopMoney.currencyCode || 'USD',
  };
}

function mapOrderNode(node: ShopifyOrderNode, shopDomain: string): OrderRow {
  const totalPrice = getMoney(node.totalPriceSet);
  const lineItems = (node.lineItems?.edges || []).map((e) => {
    const li = e.node;
    const total = getMoney(li.originalTotalSet);
    return {
      id: li.id,
      sku: li.sku || null,
      title: li.title,
      variantTitle: li.variantTitle || null,
      vendor: li.vendor || null,
      quantity: li.quantity,
      currentQuantity: li.currentQuantity,
      totalAmount: total.amount,
      totalCurrency: total.currency,
    };
  });

  const transactions = (node.transactions || []).map((t) => {
    const amt = getMoney(t.amountSet);
    return { amount: amt.amount, currency: amt.currency };
  });

  return {
    id: node.id,
    shop_domain: shopDomain,
    name: node.name,
    created_at: node.createdAt,
    fully_paid: node.fullyPaid || false,
    financial_status: node.displayFinancialStatus || 'PENDING',
    fulfillment_status: node.displayFulfillmentStatus || null,
    total_price_amount: totalPrice.amount,
    total_price_currency: totalPrice.currency,
    total_discounts_amount: getMoney(node.totalDiscountsSet).amount,
    total_refunded_amount: getMoney(node.totalRefundedSet).amount,
    total_shipping_amount: getMoney(node.totalShippingPriceSet).amount,
    total_tax_amount: getMoney(node.totalTaxSet).amount,
    total_tip_amount: getMoney(node.totalTipReceivedSet).amount,
    total_weight: node.totalWeight || null,
    customer_id: node.customer?.id || null,
    customer_first_name: node.customer?.firstName || null,
    customer_last_name: node.customer?.lastName || null,
    customer_email: node.customer?.email || null,
    customer_phone: node.customer?.phone || null,
    line_items: lineItems,
    transactions,
    raw_data: node as unknown as Record<string, unknown>,
    synced_at: new Date().toISOString(),
  };
}

/**
 * Run a sync job — either full or incremental.
 * This runs asynchronously; callers should not await it.
 */
export async function runSync(opts: SyncOptions): Promise<string> {
  const { shopDomain, accessToken, lastSyncedAt } = opts;

  const syncLog = await createSyncLog(shopDomain);
  const syncLogId = syncLog.id;

  // Build query filter for incremental sync
  const queryFilter = lastSyncedAt
    ? `created_at:>='${lastSyncedAt}'`
    : undefined;

  // Run async - don't block the response
  (async () => {
    let cursor: string | null = null;
    let totalSynced = 0;

    try {
      while (true) {
        const data: OrdersQueryData = await shopifyGraphQL(shopDomain, accessToken, ORDERS_QUERY, {
          cursor,
          query: queryFilter || null,
        });

        const edges: OrdersQueryData['orders']['edges'] = data.orders.edges || [];
        const pageInfo: OrdersQueryData['orders']['pageInfo'] = data.orders.pageInfo;

        if (edges.length > 0) {
          const orders: OrderRow[] = edges.map((e) =>
            mapOrderNode(e.node, shopDomain)
          );
          await upsertOrders(orders);
          totalSynced += orders.length;
          await updateSyncLogProgress(syncLogId, totalSynced);
        }

        if (!pageInfo.hasNextPage) break;
        cursor = pageInfo.endCursor;
      }

      await completeSyncLog(syncLogId);
      console.log(`Sync completed for ${shopDomain}: ${totalSynced} orders synced`);
    } catch (err) {
      const errorMessage = getErrorMessage(err);
      console.error(`Sync failed for ${shopDomain}:`, errorMessage);
      await failSyncLog(syncLogId, errorMessage);
    }
  })();

  return syncLogId;
}
