import { query } from '../pool.js';

export interface ShopRow {
  id: string;
  install_id: string;
  shop_domain: string;
  shop_name: string | null;
  access_token: string;
  scopes: string | null;
  owner_email: string | null;
  installed_at: string;
  updated_at: string;
}

export async function upsertShop(
  shopDomain: string,
  accessToken: string,
  scopes: string
): Promise<ShopRow> {
  const { rows } = await query<ShopRow>(
    `INSERT INTO shops (shop_domain, access_token, scopes)
     VALUES ($1, $2, $3)
     ON CONFLICT (shop_domain) DO UPDATE SET
       access_token = EXCLUDED.access_token,
       scopes = EXCLUDED.scopes,
       updated_at = now()
     RETURNING *`,
    [shopDomain, accessToken, scopes]
  );
  return rows[0];
}

export async function getShop(shopDomain: string): Promise<ShopRow | null> {
  const { rows } = await query<ShopRow>(
    'SELECT * FROM shops WHERE shop_domain = $1',
    [shopDomain]
  );
  return rows[0] || null;
}

export async function updateShopEmail(shopDomain: string, email: string | null): Promise<void> {
  await query(
    'UPDATE shops SET owner_email = $1, updated_at = now() WHERE shop_domain = $2',
    [email, shopDomain]
  );
}

export async function updateShopName(shopDomain: string, shopName: string): Promise<void> {
  await query(
    'UPDATE shops SET shop_name = $1, updated_at = now() WHERE shop_domain = $2',
    [shopName, shopDomain]
  );
}

export async function deleteShop(shopDomain: string): Promise<void> {
  await query('DELETE FROM shops WHERE shop_domain = $1', [shopDomain]);
}
