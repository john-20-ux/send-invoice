# frozen_string_literal: true

module SendInvoice
  class Migrator
    def initialize(database)
      @database = database
    end

    def run
      @database.with_connection do |db|
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS shops (
            id TEXT PRIMARY KEY,
            shop_domain TEXT NOT NULL UNIQUE,
            shop_name TEXT,
            access_token TEXT,
            scopes TEXT,
            owner_email TEXT,
            installed_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            onboarded INTEGER NOT NULL DEFAULT 0,
            current_plan TEXT NOT NULL DEFAULT 'trial',
            trial_started_at TEXT NOT NULL,
            tax_rate REAL NOT NULL DEFAULT 10,
            currency TEXT NOT NULL DEFAULT 'USD ($)',
            font_name TEXT NOT NULL DEFAULT 'Avenir Next',
            notification_config TEXT NOT NULL DEFAULT '{}',
            invoice_template_config TEXT NOT NULL DEFAULT '{}',
            vendor_edits TEXT NOT NULL DEFAULT '{}'
          );

          CREATE TABLE IF NOT EXISTS orders (
            id TEXT NOT NULL,
            shop_domain TEXT NOT NULL,
            name TEXT,
            created_at TEXT,
            updated_at TEXT,
            fully_paid INTEGER NOT NULL DEFAULT 0,
            financial_status TEXT,
            fulfillment_status TEXT,
            total_price_amount REAL NOT NULL DEFAULT 0,
            total_price_currency TEXT NOT NULL DEFAULT 'USD',
            total_discounts_amount REAL NOT NULL DEFAULT 0,
            total_refunded_amount REAL NOT NULL DEFAULT 0,
            total_shipping_amount REAL NOT NULL DEFAULT 0,
            total_tax_amount REAL NOT NULL DEFAULT 0,
            total_tip_amount REAL NOT NULL DEFAULT 0,
            total_weight REAL,
            customer_id TEXT,
            customer_first_name TEXT,
            customer_last_name TEXT,
            customer_email TEXT,
            customer_phone TEXT,
            line_items TEXT NOT NULL DEFAULT '[]',
            transactions TEXT NOT NULL DEFAULT '[]',
            raw_data TEXT NOT NULL DEFAULT '{}',
            synced_at TEXT NOT NULL,
            PRIMARY KEY (id, shop_domain),
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_orders_shop_created ON orders(shop_domain, created_at DESC);
          CREATE INDEX IF NOT EXISTS idx_orders_shop_updated ON orders(shop_domain, updated_at DESC);

          CREATE TABLE IF NOT EXISTS sync_logs (
            id TEXT PRIMARY KEY,
            shop_domain TEXT NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            status TEXT NOT NULL,
            orders_synced INTEGER NOT NULL DEFAULT 0,
            total_estimated INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_sync_logs_shop_started ON sync_logs(shop_domain, started_at DESC);

          CREATE TABLE IF NOT EXISTS sync_states (
            shop_domain TEXT PRIMARY KEY,
            last_order_updated_at TEXT,
            last_cursor TEXT,
            last_sync_type TEXT,
            last_synced_at TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE TABLE IF NOT EXISTS bulk_sync_jobs (
            id TEXT PRIMARY KEY,
            shop_domain TEXT NOT NULL,
            sync_log_id TEXT,
            shopify_bulk_operation_id TEXT,
            sync_type TEXT NOT NULL,
            status TEXT NOT NULL,
            object_count INTEGER NOT NULL DEFAULT 0,
            file_size INTEGER NOT NULL DEFAULT 0,
            result_url TEXT,
            partial_data_url TEXT,
            imported_count INTEGER NOT NULL DEFAULT 0,
            fallback_used INTEGER NOT NULL DEFAULT 0,
            fallback_sync_log_id TEXT,
            error_code TEXT,
            error_message TEXT,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE,
            FOREIGN KEY (sync_log_id) REFERENCES sync_logs(id) ON DELETE SET NULL,
            FOREIGN KEY (fallback_sync_log_id) REFERENCES sync_logs(id) ON DELETE SET NULL
          );

          CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_shop_started ON bulk_sync_jobs(shop_domain, started_at DESC);
          CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_operation ON bulk_sync_jobs(shopify_bulk_operation_id);

          CREATE TABLE IF NOT EXISTS batch_logs (
            id TEXT PRIMARY KEY,
            shop_domain TEXT NOT NULL,
            resource_name TEXT NOT NULL,
            sync_type TEXT NOT NULL,
            batch_type TEXT NOT NULL,
            start_date TEXT NOT NULL,
            end_date TEXT NOT NULL,
            order_count INTEGER NOT NULL DEFAULT 0,
            batch_sequence INTEGER NOT NULL,
            status TEXT NOT NULL,
            priority TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            cursor TEXT,
            page_index INTEGER NOT NULL DEFAULT 0,
            page_limit INTEGER NOT NULL DEFAULT 1000,
            error_message TEXT,
            started_at TEXT,
            completed_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(shop_domain, sync_type, batch_type, start_date, end_date, page_index),
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_batch_logs_shop_status ON batch_logs(shop_domain, status, priority, batch_sequence);
          CREATE INDEX IF NOT EXISTS idx_batch_logs_shop_created ON batch_logs(shop_domain, created_at DESC);

          CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            shop_domain TEXT,
            data TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
        SQL

        ensure_column(db, "orders", "updated_at", "TEXT")
        ensure_column(db, "bulk_sync_jobs", "fallback_sync_log_id", "TEXT")
        db.execute("CREATE INDEX IF NOT EXISTS idx_orders_shop_updated ON orders(shop_domain, updated_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_shop_started ON bulk_sync_jobs(shop_domain, started_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_operation ON bulk_sync_jobs(shopify_bulk_operation_id)")
      end
    end

    private

    def ensure_column(db, table, column, definition)
      columns = db.execute("PRAGMA table_info(#{table})").map { |row| row["name"] || row[1] }
      return if columns.include?(column)

      db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    end
  end
end
