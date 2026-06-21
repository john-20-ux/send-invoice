import { query } from '../pool.js';

export interface SyncLogRow {
  id: string;
  shop_domain: string;
  started_at: string;
  finished_at: string | null;
  status: 'running' | 'completed' | 'failed';
  orders_synced: number;
  total_estimated: number;
  error_message: string | null;
}

export async function createSyncLog(shopDomain: string): Promise<SyncLogRow> {
  const { rows } = await query<SyncLogRow>(
    `INSERT INTO sync_logs (shop_domain, status) VALUES ($1, 'running') RETURNING *`,
    [shopDomain]
  );
  return rows[0];
}

export async function updateSyncLogProgress(
  id: string,
  ordersSynced: number,
  totalEstimated?: number
): Promise<void> {
  if (totalEstimated !== undefined) {
    await query(
      'UPDATE sync_logs SET orders_synced = $1, total_estimated = $2 WHERE id = $3',
      [ordersSynced, totalEstimated, id]
    );
  } else {
    await query(
      'UPDATE sync_logs SET orders_synced = $1 WHERE id = $2',
      [ordersSynced, id]
    );
  }
}

export async function completeSyncLog(id: string): Promise<void> {
  await query(
    `UPDATE sync_logs SET status = 'completed', finished_at = now() WHERE id = $1`,
    [id]
  );
}

export async function failSyncLog(id: string, errorMessage: string): Promise<void> {
  await query(
    `UPDATE sync_logs SET status = 'failed', finished_at = now(), error_message = $1 WHERE id = $2`,
    [errorMessage, id]
  );
}

export async function getLatestSyncLog(shopDomain: string): Promise<SyncLogRow | null> {
  const { rows } = await query<SyncLogRow>(
    'SELECT * FROM sync_logs WHERE shop_domain = $1 ORDER BY started_at DESC LIMIT 1',
    [shopDomain]
  );
  return rows[0] || null;
}

export async function getLastCompletedSync(shopDomain: string): Promise<SyncLogRow | null> {
  const { rows } = await query<SyncLogRow>(
    `SELECT * FROM sync_logs WHERE shop_domain = $1 AND status = 'completed' ORDER BY finished_at DESC LIMIT 1`,
    [shopDomain]
  );
  return rows[0] || null;
}
