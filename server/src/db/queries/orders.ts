import { query } from '../pool.js';

export interface OrderLineItemRow {
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

export interface OrderTransactionRow {
  amount: number;
  currency: string;
}

export interface OrderRow {
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
  line_items: OrderLineItemRow[];
  transactions: OrderTransactionRow[];
  raw_data: Record<string, unknown>;
  synced_at: string;
}

type QueryParam = string | number | boolean | null;

export async function upsertOrder(order: OrderRow): Promise<void> {
  await query(
    `INSERT INTO orders (
      id, shop_domain, name, created_at, fully_paid, financial_status, fulfillment_status,
      total_price_amount, total_price_currency, total_discounts_amount, total_refunded_amount,
      total_shipping_amount, total_tax_amount, total_tip_amount, total_weight,
      customer_id, customer_first_name, customer_last_name, customer_email, customer_phone,
      line_items, transactions, raw_data, synced_at
    ) VALUES (
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,now()
    ) ON CONFLICT (id, shop_domain) DO UPDATE SET
      name = EXCLUDED.name,
      created_at = EXCLUDED.created_at,
      fully_paid = EXCLUDED.fully_paid,
      financial_status = EXCLUDED.financial_status,
      fulfillment_status = EXCLUDED.fulfillment_status,
      total_price_amount = EXCLUDED.total_price_amount,
      total_price_currency = EXCLUDED.total_price_currency,
      total_discounts_amount = EXCLUDED.total_discounts_amount,
      total_refunded_amount = EXCLUDED.total_refunded_amount,
      total_shipping_amount = EXCLUDED.total_shipping_amount,
      total_tax_amount = EXCLUDED.total_tax_amount,
      total_tip_amount = EXCLUDED.total_tip_amount,
      total_weight = EXCLUDED.total_weight,
      customer_id = EXCLUDED.customer_id,
      customer_first_name = EXCLUDED.customer_first_name,
      customer_last_name = EXCLUDED.customer_last_name,
      customer_email = EXCLUDED.customer_email,
      customer_phone = EXCLUDED.customer_phone,
      line_items = EXCLUDED.line_items,
      transactions = EXCLUDED.transactions,
      raw_data = EXCLUDED.raw_data,
      synced_at = now()`,
    [
      order.id, order.shop_domain, order.name, order.created_at, order.fully_paid,
      order.financial_status, order.fulfillment_status, order.total_price_amount,
      order.total_price_currency, order.total_discounts_amount, order.total_refunded_amount,
      order.total_shipping_amount, order.total_tax_amount, order.total_tip_amount,
      order.total_weight, order.customer_id, order.customer_first_name,
      order.customer_last_name, order.customer_email, order.customer_phone,
      JSON.stringify(order.line_items), JSON.stringify(order.transactions),
      JSON.stringify(order.raw_data),
    ]
  );
}

export async function upsertOrders(orders: OrderRow[]): Promise<void> {
  for (const order of orders) {
    await upsertOrder(order);
  }
}

export async function getOrders(
  shopDomain: string,
  opts: { from?: string; to?: string; page?: number; limit?: number; search?: string }
): Promise<{ orders: OrderRow[]; total: number }> {
  const { from, to, page = 1, limit = 25, search } = opts;
  const conditions: string[] = ['shop_domain = $1'];
  const params: QueryParam[] = [shopDomain];
  let paramIdx = 2;

  if (from) {
    conditions.push(`created_at >= $${paramIdx}`);
    params.push(from);
    paramIdx++;
  }
  if (to) {
    conditions.push(`created_at <= ($${paramIdx}::date + interval '1 day')`);
    params.push(to);
    paramIdx++;
  }
  if (search) {
    conditions.push(
      `(name ILIKE $${paramIdx} OR customer_email ILIKE $${paramIdx} OR customer_first_name ILIKE $${paramIdx} OR customer_last_name ILIKE $${paramIdx})`
    );
    params.push(`%${search}%`);
    paramIdx++;
  }

  const where = conditions.join(' AND ');

  const countResult = await query<{ total: string }>(
    `SELECT COUNT(*) as total FROM orders WHERE ${where}`,
    params
  );
  const total = parseInt(countResult.rows[0].total, 10);

  const offset = (page - 1) * limit;
  const dataResult = await query<OrderRow>(
    `SELECT * FROM orders WHERE ${where} ORDER BY created_at DESC LIMIT $${paramIdx} OFFSET $${paramIdx + 1}`,
    [...params, limit, offset]
  );

  return { orders: dataResult.rows, total };
}

export async function getOrder(
  shopDomain: string,
  orderId: string
): Promise<OrderRow | null> {
  const { rows } = await query<OrderRow>(
    'SELECT * FROM orders WHERE shop_domain = $1 AND id = $2',
    [shopDomain, orderId]
  );
  return rows[0] || null;
}
