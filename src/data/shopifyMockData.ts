import type { ShopifyOrder, ShopifyLineItem, ShopifyTransaction } from '@/types/shopify';

const FIRST_NAMES = [
  'Sarah', 'James', 'Priya', 'Marcus', 'Emily', 'David', 'Aisha', 'Lucas',
  'Mei', 'Oliver', 'Fatima', 'Ryan', 'Chloe', 'Tomás', 'Nina', 'Hassan',
  'Eva', 'Raj', 'Isabelle', 'Kenji', 'Sophia', 'Liam', 'Amara', 'Noah',
];

const LAST_NAMES = [
  'Mitchell', 'Rodriguez', 'Sharma', 'Chen', 'Watson', 'Okafor', 'Patel',
  'Fernandez', 'Lin', 'Hughes', 'Al-Rashid', 'Kowalski', 'Bernard', 'García',
  'Johansson', 'Malik', 'Müller', 'Krishnan', 'Dupont', 'Tanaka',
];

const PRODUCTS = [
  { title: 'Wireless Earbuds Pro', sku: 'WEP-001', variant: 'Black', vendor: 'TechStyle Co', price: 79.99 },
  { title: 'Organic Matcha Set', sku: 'OMS-042', variant: 'Premium', vendor: 'GreenLeaf Organics', price: 34.99 },
  { title: 'Denim Jacket Classic', sku: 'DJC-108', variant: 'Medium / Blue', vendor: 'UrbanWear Studio', price: 89.99 },
  { title: 'Ceramic Vase Duo', sku: 'CVD-220', variant: 'White', vendor: 'HomeBliss Décor', price: 45.00 },
  { title: 'Premium Dog Harness', sku: 'PDH-055', variant: 'Large / Red', vendor: 'PetPalace', price: 29.99 },
  { title: 'Yoga Mat Elite', sku: 'YME-301', variant: '6mm / Sage', vendor: 'FitGear Pro', price: 54.99 },
  { title: 'Sourdough Starter Kit', sku: 'SSK-015', variant: 'Standard', vendor: 'Artisan Bakes', price: 24.99 },
  { title: 'Scandi Table Lamp', sku: 'STL-190', variant: 'Oak', vendor: 'Nordic Living', price: 119.00 },
  { title: 'Smart Watch Band', sku: 'SWB-077', variant: '42mm / Navy', vendor: 'TechStyle Co', price: 19.99 },
  { title: 'Herbal Tea Collection', sku: 'HTC-063', variant: '12-Pack', vendor: 'GreenLeaf Organics', price: 28.50 },
  { title: 'Canvas Sneakers', sku: 'CSN-445', variant: 'US 10 / White', vendor: 'UrbanWear Studio', price: 64.99 },
  { title: 'Linen Throw Pillow', sku: 'LTP-332', variant: 'Oatmeal', vendor: 'HomeBliss Décor', price: 38.00 },
  { title: 'Cat Climbing Tower', sku: 'CCT-088', variant: 'Tall', vendor: 'PetPalace', price: 149.99 },
  { title: 'Resistance Band Set', sku: 'RBS-210', variant: '5-Pack', vendor: 'FitGear Pro', price: 22.99 },
  { title: 'Artisan Bread Knife', sku: 'ABK-007', variant: 'Walnut Handle', vendor: 'Artisan Bakes', price: 42.00 },
  { title: 'Wool Blanket', sku: 'WBL-156', variant: 'King / Grey', vendor: 'Nordic Living', price: 135.00 },
  { title: 'Phone Stand Walnut', sku: 'PSW-092', variant: 'Universal', vendor: 'TechStyle Co', price: 32.00 },
  { title: 'Face Serum Trio', sku: 'FST-501', variant: 'Sensitive', vendor: 'GreenLeaf Organics', price: 58.00 },
];

const FINANCIAL_STATUSES = ['PAID', 'PAID', 'PAID', 'PARTIALLY_PAID', 'PENDING', 'REFUNDED', 'PARTIALLY_REFUNDED'];
const FULFILLMENT_STATUSES = ['FULFILLED', 'FULFILLED', 'FULFILLED', 'UNFULFILLED', 'PARTIALLY_FULFILLED', 'IN_PROGRESS', null];

function seededRandom(seed: number) {
  const x = Math.sin(seed) * 10000;
  return x - Math.floor(x);
}

function generateOrders(): ShopifyOrder[] {
  const orders: ShopifyOrder[] = [];
  const now = new Date();
  const shopDomain = 'demo-store.myshopify.com';

  for (let i = 0; i < 150; i++) {
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

    const lineItems: ShopifyLineItem[] = [];
    let subtotal = 0;

    for (let j = 0; j < itemCount; j++) {
      const product = PRODUCTS[Math.floor(seededRandom(seed + 10 + j) * PRODUCTS.length)];
      const qty = Math.floor(seededRandom(seed + 20 + j) * 3) + 1;
      const total = Math.round(qty * product.price * 100) / 100;
      subtotal += total;

      lineItems.push({
        id: `gid://shopify/LineItem/${1000 + i * 10 + j}`,
        sku: product.sku,
        title: product.title,
        variantTitle: product.variant,
        vendor: product.vendor,
        quantity: qty,
        currentQuantity: financialStatus === 'REFUNDED' ? 0 : qty,
        totalAmount: total,
        totalCurrency: 'USD',
      });
    }

    const discounts = Math.round(seededRandom(seed + 30) * subtotal * 0.15 * 100) / 100;
    const shipping = Math.round((seededRandom(seed + 31) * 15 + 5) * 100) / 100;
    const tax = Math.round((subtotal - discounts) * 0.08 * 100) / 100;
    const tip = seededRandom(seed + 32) > 0.8 ? Math.round(seededRandom(seed + 33) * 10 * 100) / 100 : 0;
    const totalPrice = Math.round((subtotal - discounts + shipping + tax + tip) * 100) / 100;
    const refunded = financialStatus === 'REFUNDED' ? totalPrice :
      financialStatus === 'PARTIALLY_REFUNDED' ? Math.round(totalPrice * 0.3 * 100) / 100 : 0;
    const fullyPaid = financialStatus === 'PAID';
    const weight = Math.round(seededRandom(seed + 34) * 5000 + 200);

    const transactions: ShopifyTransaction[] = [
      { amount: totalPrice, currency: 'USD' },
    ];
    if (refunded > 0) {
      transactions.push({ amount: -refunded, currency: 'USD' });
    }

    orders.push({
      id: `gid://shopify/Order/${4000 + i}`,
      shop_domain: shopDomain,
      name: `#${1001 + i}`,
      created_at: date.toISOString(),
      fully_paid: fullyPaid,
      financial_status: financialStatus,
      fulfillment_status: fulfillmentStatus,
      total_price_amount: totalPrice,
      total_price_currency: 'USD',
      total_discounts_amount: discounts,
      total_refunded_amount: refunded,
      total_shipping_amount: shipping,
      total_tax_amount: tax,
      total_tip_amount: tip,
      total_weight: weight,
      customer_id: `gid://shopify/Customer/${2000 + Math.floor(seededRandom(seed + 40) * 50)}`,
      customer_first_name: firstName,
      customer_last_name: lastName,
      customer_email: `${firstName.toLowerCase()}.${lastName.toLowerCase().replace(/[^a-z]/g, '')}@example.com`,
      customer_phone: seededRandom(seed + 41) > 0.5 ? `+1${Math.floor(seededRandom(seed + 42) * 9000000000 + 1000000000)}` : null,
      line_items: lineItems,
      transactions,
      raw_data: {},
      synced_at: new Date().toISOString(),
    });
  }

  return orders.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
}

export const mockShopifyOrders: ShopifyOrder[] = generateOrders();
