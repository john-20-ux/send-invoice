export interface OrderLineItem {
  description: string;
  quantity: number;
  unit_price: number;
  amount: number;
}

export interface Order {
  id: string;
  order_number: number;
  created_at: string;
  customer_name: string;
  vendor_name: string;
  status: 'pending' | 'shipped' | 'delivered' | 'cancelled';
  total: number;
  currency: string;
  invoice_sent: boolean;
  line_items: OrderLineItem[];
}

export interface VendorSummary {
  name: string;
  total_orders: number;
  total_revenue: number;
  commission_rate: number;
  total_commission: number;
  custom_deductions: number;
  net_payable: number;
}

const VENDORS = [
  'TechStyle Co', 'GreenLeaf Organics', 'UrbanWear Studio',
  'HomeBliss Décor', 'PetPalace', 'FitGear Pro',
  'Artisan Bakes', 'Nordic Living',
];

const CUSTOMERS = [
  'Sarah Mitchell', 'James Rodriguez', 'Priya Sharma', 'Marcus Chen',
  'Emily Watson', 'David Okafor', 'Aisha Patel', 'Lucas Fernandez',
  'Mei Lin', 'Oliver Hughes', 'Fatima Al-Rashid', 'Ryan Kowalski',
  'Chloe Bernard', 'Tomás García', 'Nina Johansson', 'Hassan Malik',
  'Eva Müller', 'Raj Krishnan', 'Isabelle Dupont', 'Kenji Tanaka',
];

const PRODUCTS = [
  'Wireless Earbuds Pro', 'Organic Matcha Set', 'Denim Jacket Classic',
  'Ceramic Vase Duo', 'Premium Dog Harness', 'Yoga Mat Elite',
  'Sourdough Starter Kit', 'Scandi Table Lamp', 'Smart Watch Band',
  'Herbal Tea Collection', 'Canvas Sneakers', 'Linen Throw Pillow',
  'Cat Climbing Tower', 'Resistance Band Set', 'Artisan Bread Knife',
  'Wool Blanket', 'Phone Stand Walnut', 'Face Serum Trio',
];

const STATUSES: Order['status'][] = ['pending', 'shipped', 'delivered', 'delivered', 'delivered', 'shipped', 'pending', 'cancelled'];

function seededRandom(seed: number) {
  const x = Math.sin(seed) * 10000;
  return x - Math.floor(x);
}

function generateOrders(): Order[] {
  const orders: Order[] = [];
  const now = new Date();

  for (let i = 0; i < 64; i++) {
    const seed = i + 42;
    const daysAgo = Math.floor(seededRandom(seed) * 90);
    const date = new Date(now);
    date.setDate(date.getDate() - daysAgo);
    date.setHours(Math.floor(seededRandom(seed + 1) * 14) + 8);
    date.setMinutes(Math.floor(seededRandom(seed + 2) * 60));

    const vendor = VENDORS[Math.floor(seededRandom(seed + 3) * VENDORS.length)];
    const customer = CUSTOMERS[Math.floor(seededRandom(seed + 4) * CUSTOMERS.length)];
    const status = STATUSES[Math.floor(seededRandom(seed + 5) * STATUSES.length)];
    const itemCount = Math.floor(seededRandom(seed + 6) * 3) + 1;

    const lineItems: OrderLineItem[] = [];
    let total = 0;
    for (let j = 0; j < itemCount; j++) {
      const product = PRODUCTS[Math.floor(seededRandom(seed + 10 + j) * PRODUCTS.length)];
      const qty = Math.floor(seededRandom(seed + 20 + j) * 4) + 1;
      const price = Math.round((seededRandom(seed + 30 + j) * 120 + 15) * 100) / 100;
      const amount = Math.round(qty * price * 100) / 100;
      total += amount;
      lineItems.push({ description: product, quantity: qty, unit_price: price, amount });
    }

    orders.push({
      id: `gid://shopify/Order/${1000 + i}`,
      order_number: 1001 + i,
      created_at: date.toISOString(),
      customer_name: customer,
      vendor_name: vendor,
      status,
      total: Math.round(total * 100) / 100,
      currency: 'USD',
      invoice_sent: seededRandom(seed + 50) > 0.7,
      line_items: lineItems,
    });
  }

  return orders.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
}

export const mockOrders: Order[] = generateOrders();

export function getVendorSummaries(orders: Order[]): VendorSummary[] {
  const map = new Map<string, { orders: number; revenue: number }>();
  orders.forEach(o => {
    const v = map.get(o.vendor_name) || { orders: 0, revenue: 0 };
    v.orders++;
    v.revenue += o.total;
    map.set(o.vendor_name, v);
  });

  return Array.from(map.entries()).map(([name, data]) => {
    const rate = 12;
    const commission = Math.round(data.revenue * rate / 100 * 100) / 100;
    const deductions = Math.round(seededRandom(name.length) * 200 * 100) / 100;
    return {
      name,
      total_orders: data.orders,
      total_revenue: Math.round(data.revenue * 100) / 100,
      commission_rate: rate,
      total_commission: commission,
      custom_deductions: deductions,
      net_payable: Math.round((commission - deductions) * 100) / 100,
    };
  });
}

export function getDashboardStats(orders: Order[]) {
  return {
    totalOrders: orders.length,
    shipped: orders.filter(o => o.status === 'shipped').length,
    totalRevenue: Math.round(orders.reduce((s, o) => s + o.total, 0) * 100) / 100,
  };
}

export function getPdfsSentByDate(orders: Order[]) {
  const map = new Map<string, number>();
  orders.filter(o => o.invoice_sent).forEach(o => {
    const day = o.created_at.slice(0, 10);
    map.set(day, (map.get(day) || 0) + 1);
  });
  return Array.from(map.entries())
    .map(([date, count]) => ({ date, count }))
    .sort((a, b) => a.date.localeCompare(b.date));
}

export function getPdfsSentByVendor(orders: Order[]) {
  const map = new Map<string, number>();
  orders.filter(o => o.invoice_sent).forEach(o => {
    map.set(o.vendor_name, (map.get(o.vendor_name) || 0) + 1);
  });
  return Array.from(map.entries())
    .map(([vendor, count]) => ({ vendor, count }))
    .sort((a, b) => b.count - a.count);
}
