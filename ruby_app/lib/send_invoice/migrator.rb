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
            uninstalled_at TEXT,
            scheduled_for_deletion_at TEXT,
            data_deletion_started_at TEXT,
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

          CREATE TABLE IF NOT EXISTS sync_command_locks (
            shop_domain TEXT NOT NULL,
            command_key TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            locked_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (shop_domain, command_key),
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_sync_command_locks_owner ON sync_command_locks(owner_id);

          CREATE TABLE IF NOT EXISTS async_job_requests (
            id TEXT PRIMARY KEY,
            shop_domain TEXT,
            request_type TEXT NOT NULL,
            queue_name TEXT NOT NULL,
            dedupe_key TEXT NOT NULL,
            payload TEXT NOT NULL DEFAULT '{}',
            status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0,
            claimed_by TEXT,
            claimed_at TEXT,
            available_at TEXT NOT NULL,
            dispatched_at TEXT,
            error_message TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_async_job_requests_status_available
            ON async_job_requests(status, available_at, created_at);
          CREATE INDEX IF NOT EXISTS idx_async_job_requests_shop_created
            ON async_job_requests(shop_domain, created_at DESC);
          CREATE UNIQUE INDEX IF NOT EXISTS idx_async_job_requests_active_dedupe
            ON async_job_requests(dedupe_key)
            WHERE status IN ('queued', 'claimed', 'dispatched', 'running');

          CREATE TABLE IF NOT EXISTS invoice_deliveries (
            id TEXT PRIMARY KEY,
            shop_domain TEXT NOT NULL,
            order_id TEXT NOT NULL,
            recipient_email TEXT NOT NULL,
            subject TEXT NOT NULL,
            body_text TEXT NOT NULL,
            invoice_filename TEXT NOT NULL,
            delivery_status TEXT NOT NULL,
            delivery_channel TEXT NOT NULL,
            delivery_target TEXT,
            external_message_id TEXT,
            outbox_path TEXT,
            pdf_size_bytes INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            created_at TEXT NOT NULL,
            sent_at TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (shop_domain) REFERENCES shops(shop_domain) ON DELETE CASCADE,
            FOREIGN KEY (order_id, shop_domain) REFERENCES orders(id, shop_domain) ON DELETE CASCADE
          );

          CREATE INDEX IF NOT EXISTS idx_invoice_deliveries_order_created
            ON invoice_deliveries(shop_domain, order_id, created_at DESC);
        SQL

        ensure_column(db, "orders", "updated_at", "TEXT")
        ensure_column(db, "shops", "uninstalled_at", "TEXT")
        ensure_column(db, "shops", "scheduled_for_deletion_at", "TEXT")
        ensure_column(db, "shops", "data_deletion_started_at", "TEXT")
        ensure_column(db, "bulk_sync_jobs", "fallback_sync_log_id", "TEXT")
        db.execute("CREATE INDEX IF NOT EXISTS idx_orders_shop_updated ON orders(shop_domain, updated_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_shop_started ON bulk_sync_jobs(shop_domain, started_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_bulk_sync_jobs_operation ON bulk_sync_jobs(shopify_bulk_operation_id)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_shops_scheduled_deletion ON shops(scheduled_for_deletion_at, data_deletion_started_at)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_sync_command_locks_owner ON sync_command_locks(owner_id)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_async_job_requests_status_available ON async_job_requests(status, available_at, created_at)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_async_job_requests_shop_created ON async_job_requests(shop_domain, created_at DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_invoice_deliveries_order_created ON invoice_deliveries(shop_domain, order_id, created_at DESC)")
        db.execute(<<~SQL)
          CREATE UNIQUE INDEX IF NOT EXISTS idx_async_job_requests_active_dedupe
          ON async_job_requests(dedupe_key)
          WHERE status IN ('queued', 'claimed', 'dispatched', 'running')
        SQL

        run_invoice_automation_migrations(db)

        normalize_shop_domain_storage(db)
      end
    end

    private

    # Invoice automation, payment reminders, secure public links, and delivery-log
    # filtering. Kept SQLite-safe and additive so existing shop data is preserved.
    def run_invoice_automation_migrations(db)
      db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS invoice_automation_rules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          shop_domain TEXT NOT NULL,
          name TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          trigger_event TEXT NOT NULL,
          conditions_json TEXT NOT NULL DEFAULT '{}',
          action_json TEXT NOT NULL DEFAULT '{}',
          reminder_schedule_json TEXT NOT NULL DEFAULT '{}',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_invoice_automation_rules_shop
          ON invoice_automation_rules (shop_domain);
        CREATE INDEX IF NOT EXISTS idx_invoice_automation_rules_shop_enabled_trigger
          ON invoice_automation_rules (shop_domain, enabled, trigger_event);

        CREATE TABLE IF NOT EXISTS invoice_automation_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          shop_domain TEXT NOT NULL,
          order_id TEXT NOT NULL,
          rule_id INTEGER,
          event_type TEXT NOT NULL,
          event_key TEXT NOT NULL,
          stage TEXT,
          source TEXT NOT NULL DEFAULT 'system',
          payload_json TEXT NOT NULL DEFAULT '{}',
          status TEXT NOT NULL DEFAULT 'queued',
          run_after TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          max_attempts INTEGER NOT NULL DEFAULT 3,
          locked_at TEXT,
          last_error TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY(rule_id) REFERENCES invoice_automation_rules(id)
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_invoice_automation_events_event_key
          ON invoice_automation_events (event_key);
        CREATE INDEX IF NOT EXISTS idx_invoice_automation_events_due
          ON invoice_automation_events (status, run_after);
        CREATE INDEX IF NOT EXISTS idx_invoice_automation_events_shop_order
          ON invoice_automation_events (shop_domain, order_id);

        CREATE TABLE IF NOT EXISTS invoice_public_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          shop_domain TEXT NOT NULL,
          order_id TEXT NOT NULL,
          token_hash TEXT NOT NULL,
          purpose TEXT NOT NULL DEFAULT 'invoice_download',
          expires_at TEXT,
          revoked_at TEXT,
          access_count INTEGER NOT NULL DEFAULT 0,
          last_accessed_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_invoice_public_links_token_hash
          ON invoice_public_links (token_hash);
        CREATE INDEX IF NOT EXISTS idx_invoice_public_links_shop_order
          ON invoice_public_links (shop_domain, order_id);
      SQL

      # invoice_deliveries already ships with id/sent_at/error_message/delivery_status;
      # only add the automation + log-filtering columns it is missing.
      ensure_column(db, "invoice_deliveries", "automation_rule_id", "INTEGER")
      ensure_column(db, "invoice_deliveries", "automation_event_id", "INTEGER")
      ensure_column(db, "invoice_deliveries", "delivery_stage", "TEXT")
      ensure_column(db, "invoice_deliveries", "idempotency_key", "TEXT")
      ensure_column(db, "invoice_deliveries", "delivery_source", "TEXT")
      ensure_column(db, "invoice_deliveries", "retry_of_delivery_id", "TEXT")

      db.execute("CREATE INDEX IF NOT EXISTS idx_invoice_deliveries_shop_created ON invoice_deliveries (shop_domain, created_at)")
      db.execute("CREATE INDEX IF NOT EXISTS idx_invoice_deliveries_shop_status ON invoice_deliveries (shop_domain, delivery_status)")
      db.execute(<<~SQL)
        CREATE UNIQUE INDEX IF NOT EXISTS idx_invoice_deliveries_idempotency_key
        ON invoice_deliveries (idempotency_key)
        WHERE idempotency_key IS NOT NULL
      SQL
    end

    def ensure_column(db, table, column, definition)
      columns = db.execute("PRAGMA table_info(#{table})").map { |row| row["name"] || row[1] }
      return if columns.include?(column)

      db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    end

    def normalize_shop_domain_storage(db)
      child_tables = %w[
        orders
        sync_logs
        sessions
        sync_states
        bulk_sync_jobs
        batch_logs
        sync_command_locks
        async_job_requests
      ]

      db.execute("PRAGMA foreign_keys = OFF")
      child_tables.each do |table|
        db.execute("UPDATE #{table} SET shop_domain = CAST(shop_domain AS TEXT) WHERE typeof(shop_domain) = 'blob'")
      end
      deduplicate_shop_rows(db)
      db.execute("UPDATE shops SET shop_domain = CAST(shop_domain AS TEXT) WHERE typeof(shop_domain) = 'blob'")
    ensure
      db.execute("PRAGMA foreign_keys = ON")
    end

    def deduplicate_shop_rows(db)
      rows = db.execute(<<~SQL)
        SELECT rowid, shop_domain, CAST(shop_domain AS TEXT) AS normalized_shop_domain,
               access_token, updated_at, installed_at
        FROM shops
        ORDER BY
          CASE WHEN access_token IS NOT NULL AND access_token != '' THEN 0 ELSE 1 END,
          updated_at DESC,
          installed_at DESC,
          rowid DESC
      SQL

      grouped = rows.group_by { |row| row["normalized_shop_domain"] || row["shop_domain"].to_s }
      grouped.each_value do |group|
        next if group.length <= 1

        keeper = group.first
        duplicates = group.drop(1)
        duplicates.each do |row|
          db.execute("DELETE FROM shops WHERE rowid = ?", row["rowid"])
        end

        db.execute("UPDATE shops SET shop_domain = ? WHERE rowid = ?", [
          keeper["normalized_shop_domain"],
          keeper["rowid"]
        ])
      end
    end
  end
end
