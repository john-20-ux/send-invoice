# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module SendInvoice
  class Store
    def initialize(database)
      @database = database
    end

    def ensure_shop(shop_domain, attributes = {})
      shop_domain = normalize_text(shop_domain)
      existing = shop(shop_domain)
      if existing
        update_shop(shop_domain, attributes) unless attributes.empty?
        return shop(shop_domain)
      end

      now = Time.now.utc.iso8601
      normalized_attributes = normalize_keys(attributes)
      reinstalling = present?(normalized_attributes["access_token"])
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => shop_domain,
        "shop_name" => attributes["shop_name"] || attributes[:shop_name] || default_shop_name(shop_domain),
        "access_token" => attributes["access_token"] || attributes[:access_token],
        "scopes" => attributes["scopes"] || attributes[:scopes],
        "owner_email" => attributes["owner_email"] || attributes[:owner_email],
        "installed_at" => now,
        "uninstalled_at" => reinstalling ? nil : normalized_attributes["uninstalled_at"],
        "scheduled_for_deletion_at" => reinstalling ? nil : normalized_attributes["scheduled_for_deletion_at"],
        "data_deletion_started_at" => reinstalling ? nil : normalized_attributes["data_deletion_started_at"],
        "updated_at" => now,
        "onboarded" => truthy_db(attributes["onboarded"] || attributes[:onboarded] || false),
        "current_plan" => attributes["current_plan"] || attributes[:current_plan] || "trial",
        "trial_started_at" => attributes["trial_started_at"] || attributes[:trial_started_at] || (Time.now.utc - 7 * 86_400).iso8601,
        "tax_rate" => (attributes["tax_rate"] || attributes[:tax_rate] || 10).to_f,
        "currency" => attributes["currency"] || attributes[:currency] || "USD ($)",
        "font_name" => attributes["font_name"] || attributes[:font_name] || "Avenir Next",
        "notification_config" => JSON.generate(MockData::DEFAULT_NOTIFICATION_CONFIG),
        "invoice_template_config" => JSON.generate(MockData::DEFAULT_INVOICE_TEMPLATE_CONFIG),
        "vendor_edits" => JSON.generate({})
      }

      @database.with_connection do |db|
        db.execute(<<~SQL, payload.values_at("id", "shop_domain", "shop_name", "access_token", "scopes", "owner_email", "installed_at", "uninstalled_at", "scheduled_for_deletion_at", "data_deletion_started_at", "updated_at", "onboarded", "current_plan", "trial_started_at", "tax_rate", "currency", "font_name", "notification_config", "invoice_template_config", "vendor_edits"))
          INSERT INTO shops (
            id, shop_domain, shop_name, access_token, scopes, owner_email, installed_at,
            uninstalled_at, scheduled_for_deletion_at, data_deletion_started_at, updated_at, onboarded, current_plan, trial_started_at, tax_rate, currency,
            font_name, notification_config, invoice_template_config, vendor_edits
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      shop(shop_domain)
    end

    def shop(shop_domain)
      shop_domain = normalize_text(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM shops WHERE CAST(shop_domain AS TEXT) = ?", shop_domain)
        hydrate_shop(row)
      end
    end

    def syncable_shops
      @database.with_connection do |db|
        db.execute("SELECT * FROM shops WHERE access_token IS NOT NULL AND access_token != '' AND uninstalled_at IS NULL ORDER BY installed_at ASC").map do |row|
          hydrate_shop(row)
        end
      end
    end

    def mark_shop_uninstalled(shop_domain, uninstalled_at:, scheduled_for_deletion_at:)
      shop_domain = normalize_text(shop_domain)
      now = Time.now.utc.iso8601

      @database.with_connection do |db|
        db.execute(<<~SQL, [nil, uninstalled_at, scheduled_for_deletion_at, nil, now, shop_domain])
          UPDATE shops
          SET access_token = ?,
              uninstalled_at = ?,
              scheduled_for_deletion_at = ?,
              data_deletion_started_at = ?,
              updated_at = ?
          WHERE CAST(shop_domain AS TEXT) = ?
        SQL
      end

      shop(shop_domain)
    end

    def due_data_deletion_shops(reference_time: Time.now.utc.iso8601)
      @database.with_connection do |db|
        db.execute(<<~SQL, [reference_time]).map { |row| hydrate_shop(row) }
          SELECT * FROM shops
          WHERE uninstalled_at IS NOT NULL
            AND scheduled_for_deletion_at IS NOT NULL
            AND scheduled_for_deletion_at <= ?
            AND data_deletion_started_at IS NULL
          ORDER BY scheduled_for_deletion_at ASC
        SQL
      end
    end

    def claim_shop_data_deletion(shop_domain, claimed_at: Time.now.utc.iso8601)
      shop_domain = normalize_text(shop_domain)
      changed = @database.with_connection do |db|
        db.execute(<<~SQL, [claimed_at, claimed_at, shop_domain, claimed_at])
          UPDATE shops
          SET data_deletion_started_at = ?, updated_at = ?
          WHERE CAST(shop_domain AS TEXT) = ?
            AND uninstalled_at IS NOT NULL
            AND scheduled_for_deletion_at IS NOT NULL
            AND scheduled_for_deletion_at <= ?
            AND data_deletion_started_at IS NULL
        SQL
        db.changes
      end

      changed == 1
    end

    def delete_shop_data(shop_domain)
      shop_domain = normalize_text(shop_domain)
      @database.with_connection do |db|
        db.execute("DELETE FROM sessions WHERE CAST(shop_domain AS TEXT) = ?", shop_domain)
        db.execute("DELETE FROM shops WHERE CAST(shop_domain AS TEXT) = ?", shop_domain)
      end

      true
    end

    def customer_data_request_orders(shop_domain:, customer_id: nil, customer_email: nil)
      with_matching_customer_orders(shop_domain: shop_domain, customer_id: customer_id, customer_email: customer_email) do |db, sql, values|
        db.execute("SELECT id, name, created_at, updated_at FROM orders WHERE #{sql} ORDER BY created_at DESC, rowid DESC", values).map do |row|
          {
            "id" => row["id"],
            "name" => row["name"],
            "created_at" => row["created_at"],
            "updated_at" => row["updated_at"]
          }
        end
      end
    end

    def redact_customer_data(shop_domain:, customer_id: nil, customer_email: nil)
      with_matching_customer_orders(shop_domain: shop_domain, customer_id: customer_id, customer_email: customer_email) do |db, sql, values|
        rows = db.execute("SELECT id, raw_data FROM orders WHERE #{sql}", values)
        rows.each do |row|
          db.execute(<<~SQL, [nil, nil, nil, nil, nil, redact_order_raw_data(row["raw_data"]), Time.now.utc.iso8601, row["id"], shop_domain])
            UPDATE orders
            SET customer_id = ?,
                customer_first_name = ?,
                customer_last_name = ?,
                customer_email = ?,
                customer_phone = ?,
                raw_data = ?,
                synced_at = ?
            WHERE id = ? AND shop_domain = ?
          SQL
        end
        rows.length
      end
    end

    def claim_sync_command_lock(shop_domain, command_key, owner_id:, locked_at: Time.now.utc.iso8601)
      changed = @database.with_connection do |db|
        db.execute(<<~SQL, [shop_domain, command_key, owner_id, locked_at, locked_at])
          INSERT OR IGNORE INTO sync_command_locks (
            shop_domain, command_key, owner_id, locked_at, updated_at
          ) VALUES (?, ?, ?, ?, ?)
        SQL
        db.changes
      end

      changed == 1
    end

    def release_sync_command_lock(shop_domain, command_key, owner_id: nil)
      @database.with_connection do |db|
        if owner_id
          db.execute(
            "DELETE FROM sync_command_locks WHERE shop_domain = ? AND command_key = ? AND owner_id = ?",
            [shop_domain, command_key, owner_id]
          )
        else
          db.execute(
            "DELETE FROM sync_command_locks WHERE shop_domain = ? AND command_key = ?",
            [shop_domain, command_key]
          )
        end
      end

      true
    end

    def sync_command_lock(shop_domain, command_key)
      @database.with_connection do |db|
        db.get_first_row(
          "SELECT * FROM sync_command_locks WHERE shop_domain = ? AND command_key = ?",
          [shop_domain, command_key]
        )
      end
    end

    def enqueue_async_job_request(shop_domain:, request_type:, queue_name:, dedupe_key:, payload:, available_at: Time.now.utc.iso8601)
      now = Time.now.utc.iso8601
      request_id = SecureRandom.uuid
      inserted = @database.with_connection do |db|
        db.execute(<<~SQL, [request_id, shop_domain, request_type, queue_name, dedupe_key, JSON.generate(payload), "queued", 0, available_at, now, now])
          INSERT OR IGNORE INTO async_job_requests (
            id, shop_domain, request_type, queue_name, dedupe_key, payload, status,
            attempts, available_at, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        db.changes
      end

      if inserted == 1
        async_job_request(request_id).merge("created" => true)
      else
        active_async_job_request_by_dedupe(dedupe_key).merge("created" => false)
      end
    end

    def async_job_request(request_id)
      @database.with_connection do |db|
        hydrate_async_job_request(db.get_first_row("SELECT * FROM async_job_requests WHERE id = ?", request_id))
      end
    end

    def active_async_job_request_by_dedupe(dedupe_key)
      @database.with_connection do |db|
        row = db.get_first_row(<<~SQL, [dedupe_key])
          SELECT * FROM async_job_requests
          WHERE dedupe_key = ?
            AND status IN ('queued', 'claimed', 'dispatched', 'running')
          ORDER BY created_at DESC, rowid DESC
          LIMIT 1
        SQL
        hydrate_async_job_request(row)
      end
    end

    def latest_active_async_job_request(shop_domain, request_types: nil)
      values = [shop_domain]
      where = ["shop_domain = ?", "status IN ('queued', 'claimed', 'dispatched', 'running')"]

      if request_types && !Array(request_types).empty?
        types = Array(request_types).map(&:to_s)
        where << "request_type IN (#{(['?'] * types.length).join(', ')})"
        values.concat(types)
      end

      @database.with_connection do |db|
        row = db.get_first_row(
          "SELECT * FROM async_job_requests WHERE #{where.join(' AND ')} ORDER BY created_at DESC, rowid DESC LIMIT 1",
          values
        )
        hydrate_async_job_request(row)
      end
    end

    def due_async_job_requests(reference_time: Time.now.utc.iso8601, limit: 50)
      @database.with_connection do |db|
        db.execute(<<~SQL, [reference_time, limit]).map { |row| hydrate_async_job_request(row) }
          SELECT * FROM async_job_requests
          WHERE status = 'queued' AND available_at <= ?
          ORDER BY created_at ASC, rowid ASC
          LIMIT ?
        SQL
      end
    end

    def failed_async_job_requests(shop_domain: nil, limit: 50)
      values = []
      where = ["status = 'failed'"]

      if shop_domain
        where << "shop_domain = ?"
        values << shop_domain
      end

      values << limit
      @database.with_connection do |db|
        db.execute(
          "SELECT * FROM async_job_requests WHERE #{where.join(' AND ')} ORDER BY created_at DESC, rowid DESC LIMIT ?",
          values
        ).map { |row| hydrate_async_job_request(row) }
      end
    end

    def latest_failed_async_job_request(shop_domain:)
      @database.with_connection do |db|
        row = db.get_first_row(<<~SQL, [shop_domain])
          SELECT * FROM async_job_requests
          WHERE shop_domain = ?
            AND status = 'failed'
          ORDER BY created_at DESC, rowid DESC
          LIMIT 1
        SQL
        hydrate_async_job_request(row)
      end
    end

    def async_job_request_status_counts(shop_domain:)
      counts = Hash.new(0)

      @database.with_connection do |db|
        db.execute(
          "SELECT status, COUNT(*) AS count FROM async_job_requests WHERE shop_domain = ? GROUP BY status",
          [shop_domain]
        ).each do |row|
          counts[row["status"]] = row["count"].to_i
        end
      end

      counts
    end

    def async_job_request_count(shop_domain:, statuses: nil)
      values = [shop_domain]
      where = ["shop_domain = ?"]

      if statuses && !Array(statuses).empty?
        normalized_statuses = Array(statuses).map(&:to_s)
        where << "status IN (#{(['?'] * normalized_statuses.length).join(', ')})"
        values.concat(normalized_statuses)
      end

      @database.with_connection do |db|
        db.get_first_value("SELECT COUNT(*) FROM async_job_requests WHERE #{where.join(' AND ')}", values).to_i
      end
    end

    def async_job_requests(shop_domain:, statuses: nil, limit: 20, offset: 0)
      values = [shop_domain]
      where = ["shop_domain = ?"]

      if statuses && !Array(statuses).empty?
        normalized_statuses = Array(statuses).map(&:to_s)
        where << "status IN (#{(['?'] * normalized_statuses.length).join(', ')})"
        values.concat(normalized_statuses)
      end

      values << limit.to_i
      values << offset.to_i
      @database.with_connection do |db|
        db.execute(
          "SELECT * FROM async_job_requests WHERE #{where.join(' AND ')} ORDER BY created_at DESC, rowid DESC LIMIT ? OFFSET ?",
          values
        ).map { |row| hydrate_async_job_request(row) }
      end
    end

    def claim_async_job_request(request_id, worker_id:, claimed_at: Time.now.utc.iso8601)
      changed = @database.with_connection do |db|
        db.execute(<<~SQL, [worker_id, claimed_at, claimed_at, request_id, claimed_at])
          UPDATE async_job_requests
          SET status = 'claimed',
              attempts = attempts + 1,
              claimed_by = ?,
              claimed_at = ?,
              updated_at = ?
          WHERE id = ?
            AND status = 'queued'
            AND available_at <= ?
        SQL
        db.changes
      end

      changed == 1
    end

    def mark_async_job_request_dispatched(request_id, dispatched_at: Time.now.utc.iso8601)
      update_async_job_request_status(
        request_id,
        status: "dispatched",
        attributes: {
          "dispatched_at" => dispatched_at,
          "error_message" => nil
        }
      )
    end

    def mark_async_job_request_running(request_id)
      return nil unless request_id

      update_async_job_request_status(request_id, status: "running")
    end

    def complete_async_job_request(request_id)
      return nil unless request_id

      update_async_job_request_status(request_id, status: "completed", attributes: { "error_message" => nil })
    end

    def fail_async_job_request(request_id, error_message)
      return nil unless request_id

      update_async_job_request_status(request_id, status: "failed", attributes: { "error_message" => error_message })
    end

    def requeue_async_job_request(request_id, error_message:, available_at: Time.now.utc.iso8601)
      now = Time.now.utc.iso8601
      @database.with_connection do |db|
        db.execute(<<~SQL, [available_at, error_message, now, request_id])
          UPDATE async_job_requests
          SET status = 'queued',
              claimed_by = NULL,
              claimed_at = NULL,
              dispatched_at = NULL,
              available_at = ?,
              error_message = ?,
              updated_at = ?
          WHERE id = ?
        SQL
      end

      async_job_request(request_id)
    end

    def retry_failed_async_job_request(request_id, available_at: Time.now.utc.iso8601)
      now = Time.now.utc.iso8601
      changed = @database.with_connection do |db|
        db.execute(<<~SQL, [available_at, now, request_id])
          UPDATE async_job_requests
          SET status = 'queued',
              claimed_by = NULL,
              claimed_at = NULL,
              dispatched_at = NULL,
              error_message = NULL,
              available_at = ?,
              updated_at = ?
          WHERE id = ?
            AND status = 'failed'
        SQL
        db.changes
      end

      changed == 1 ? async_job_request(request_id) : nil
    end

    def retry_latest_failed_async_job_request(shop_domain:, available_at: Time.now.utc.iso8601)
      request = latest_failed_async_job_request(shop_domain: shop_domain)
      return nil unless request

      retry_failed_async_job_request(request["id"], available_at: available_at)
    end

    def retry_all_failed_async_job_requests(shop_domain:, available_at: Time.now.utc.iso8601)
      now = Time.now.utc.iso8601
      @database.with_connection do |db|
        db.execute(<<~SQL, [available_at, now, shop_domain])
          UPDATE async_job_requests
          SET status = 'queued',
              claimed_by = NULL,
              claimed_at = NULL,
              dispatched_at = NULL,
              error_message = NULL,
              available_at = ?,
              updated_at = ?
          WHERE shop_domain = ?
            AND status = 'failed'
        SQL
        db.changes
      end
    end

    def delete_async_job_request(request_id, allowed_statuses: nil)
      values = [request_id]
      where = ["id = ?"]

      if allowed_statuses && !Array(allowed_statuses).empty?
        statuses = Array(allowed_statuses).map(&:to_s)
        where << "status IN (#{(['?'] * statuses.length).join(', ')})"
        values.concat(statuses)
      end

      changed = @database.with_connection do |db|
        db.execute("DELETE FROM async_job_requests WHERE #{where.join(' AND ')}", values)
        db.changes
      end

      changed == 1
    end

    def update_shop(shop_domain, attributes)
      return if attributes.nil? || attributes.empty?

      shop_domain = normalize_text(shop_domain)
      updates = []
      values = []
      normalized = normalize_keys(attributes)
      if present?(normalized["access_token"])
        normalized["uninstalled_at"] = nil unless normalized.key?("uninstalled_at")
        normalized["scheduled_for_deletion_at"] = nil unless normalized.key?("scheduled_for_deletion_at")
        normalized["data_deletion_started_at"] = nil unless normalized.key?("data_deletion_started_at")
      end

      normalized.each do |key, value|
        case key
        when "notification_config", "invoice_template_config", "vendor_edits"
          updates << "#{key} = ?"
          values << JSON.generate(value)
        when "onboarded"
          updates << "onboarded = ?"
          values << truthy_db(value)
        else
          updates << "#{key} = ?"
          values << value
        end
      end

      updates << "updated_at = ?"
      values << Time.now.utc.iso8601
      values << shop_domain

      @database.with_connection do |db|
        db.execute("UPDATE shops SET #{updates.join(', ')} WHERE CAST(shop_domain AS TEXT) = ?", values)
      end
    end

    def upsert_orders(orders)
      @database.with_connection do |db|
        orders.each do |order|
          normalized = order_to_row(order)
          db.execute(<<~SQL, normalized)
            INSERT INTO orders (
              id, shop_domain, name, created_at, updated_at, fully_paid, financial_status, fulfillment_status,
              total_price_amount, total_price_currency, total_discounts_amount, total_refunded_amount,
              total_shipping_amount, total_tax_amount, total_tip_amount, total_weight,
              customer_id, customer_first_name, customer_last_name, customer_email, customer_phone,
              line_items, transactions, raw_data, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, shop_domain) DO UPDATE SET
              name = excluded.name,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              fully_paid = excluded.fully_paid,
              financial_status = excluded.financial_status,
              fulfillment_status = excluded.fulfillment_status,
              total_price_amount = excluded.total_price_amount,
              total_price_currency = excluded.total_price_currency,
              total_discounts_amount = excluded.total_discounts_amount,
              total_refunded_amount = excluded.total_refunded_amount,
              total_shipping_amount = excluded.total_shipping_amount,
              total_tax_amount = excluded.total_tax_amount,
              total_tip_amount = excluded.total_tip_amount,
              total_weight = excluded.total_weight,
              customer_id = excluded.customer_id,
              customer_first_name = excluded.customer_first_name,
              customer_last_name = excluded.customer_last_name,
              customer_email = excluded.customer_email,
              customer_phone = excluded.customer_phone,
              line_items = excluded.line_items,
              transactions = excluded.transactions,
              raw_data = excluded.raw_data,
              synced_at = excluded.synced_at
          SQL
        end
      end
    end

    def orders(shop_domain, filters = {})
      page = [filters.fetch(:page, 1).to_i, 1].max
      limit = [filters.fetch(:limit, 25).to_i, 1].max
      clauses = ["shop_domain = ?"]
      values = [shop_domain]

      if present?(filters[:from])
        clauses << "created_at >= ?"
        values << Time.parse(filters[:from].to_s).utc.iso8601
      end

      if present?(filters[:to])
        clauses << "created_at <= ?"
        values << (Time.parse(filters[:to].to_s) + 86_399).utc.iso8601
      end

      if present?(filters[:search])
        clauses << "(LOWER(name) LIKE ? OR LOWER(customer_email) LIKE ? OR LOWER(customer_first_name) LIKE ? OR LOWER(customer_last_name) LIKE ?)"
        needle = "%#{filters[:search].to_s.downcase}%"
        4.times { values << needle }
      end

      where = clauses.join(" AND ")
      offset = (page - 1) * limit

      @database.with_connection do |db|
        total = db.get_first_value("SELECT COUNT(*) FROM orders WHERE #{where}", values).to_i
        rows = db.execute("SELECT * FROM orders WHERE #{where} ORDER BY created_at DESC LIMIT ? OFFSET ?", values + [limit, offset])
        {
          "orders" => rows.map { |row| hydrate_order(row) },
          "total" => total,
          "page" => page,
          "limit" => limit,
          "total_pages" => (total.to_f / limit).ceil
        }
      end
    end

    def all_orders(shop_domain)
      @database.with_connection do |db|
        db.execute("SELECT * FROM orders WHERE shop_domain = ? ORDER BY created_at DESC", shop_domain).map do |row|
          hydrate_order(row)
        end
      end
    end

    def order(shop_domain, order_id)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM orders WHERE shop_domain = ? AND id = ?", [shop_domain, order_id])
        hydrate_order(row)
      end
    end

    def create_invoice_delivery(shop_domain, order_id, attributes = {})
      now = Time.now.utc.iso8601
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => normalize_text(shop_domain),
        "order_id" => normalize_text(order_id),
        "recipient_email" => normalize_text(attributes["recipient_email"] || attributes[:recipient_email]),
        "subject" => normalize_text(attributes["subject"] || attributes[:subject]),
        "body_text" => normalize_text(attributes["body_text"] || attributes[:body_text]),
        "invoice_filename" => normalize_text(attributes["invoice_filename"] || attributes[:invoice_filename]),
        "delivery_status" => normalize_text(attributes["delivery_status"] || attributes[:delivery_status] || "pending"),
        "delivery_channel" => normalize_text(attributes["delivery_channel"] || attributes[:delivery_channel] || "email"),
        "delivery_target" => normalize_text(attributes["delivery_target"] || attributes[:delivery_target]),
        "external_message_id" => normalize_text(attributes["external_message_id"] || attributes[:external_message_id]),
        "outbox_path" => normalize_text(attributes["outbox_path"] || attributes[:outbox_path]),
        "pdf_size_bytes" => (attributes["pdf_size_bytes"] || attributes[:pdf_size_bytes] || 0).to_i,
        "error_message" => normalize_text(attributes["error_message"] || attributes[:error_message]),
        "created_at" => now,
        "sent_at" => attributes["sent_at"] || attributes[:sent_at],
        "updated_at" => now
      }
      values = payload.values_at(
        "id", "shop_domain", "order_id", "recipient_email", "subject", "body_text",
        "invoice_filename", "delivery_status", "delivery_channel", "delivery_target",
        "external_message_id", "outbox_path", "pdf_size_bytes", "error_message",
        "created_at", "sent_at", "updated_at"
      )

      @database.with_connection do |db|
        db.execute(<<~SQL, values)
          INSERT INTO invoice_deliveries (
            id, shop_domain, order_id, recipient_email, subject, body_text,
            invoice_filename, delivery_status, delivery_channel, delivery_target,
            external_message_id, outbox_path, pdf_size_bytes, error_message,
            created_at, sent_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      invoice_delivery(payload["id"])
    end

    def invoice_deliveries(shop_domain, order_id, limit: 20)
      @database.with_connection do |db|
        db.execute(
          "SELECT * FROM invoice_deliveries WHERE shop_domain = ? AND order_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
          [normalize_text(shop_domain), normalize_text(order_id), limit.to_i]
        ).map { |row| hydrate_invoice_delivery(row) }
      end
    end

    def latest_invoice_delivery(shop_domain, order_id)
      @database.with_connection do |db|
        row = db.get_first_row(
          "SELECT * FROM invoice_deliveries WHERE shop_domain = ? AND order_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
          [normalize_text(shop_domain), normalize_text(order_id)]
        )
        hydrate_invoice_delivery(row)
      end
    end

    def invoice_delivery(delivery_id)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM invoice_deliveries WHERE id = ?", delivery_id)
        hydrate_invoice_delivery(row)
      end
    end

    def create_sync_log(shop_domain, total_estimated: 0)
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => shop_domain,
        "started_at" => Time.now.utc.iso8601,
        "status" => "running",
        "orders_synced" => 0,
        "total_estimated" => total_estimated
      }

      @database.with_connection do |db|
        db.execute(
          "INSERT INTO sync_logs (id, shop_domain, started_at, status, orders_synced, total_estimated) VALUES (?, ?, ?, ?, ?, ?)",
          [payload["id"], payload["shop_domain"], payload["started_at"], payload["status"], payload["orders_synced"], payload["total_estimated"]]
        )
      end

      payload
    end

    def update_sync_log_progress(sync_log_id, orders_synced, total_estimated = nil)
      @database.with_connection do |db|
        if total_estimated.nil?
          db.execute("UPDATE sync_logs SET orders_synced = ? WHERE id = ?", [orders_synced, sync_log_id])
        else
          db.execute("UPDATE sync_logs SET orders_synced = ?, total_estimated = ? WHERE id = ?", [orders_synced, total_estimated, sync_log_id])
        end
      end
    end

    def complete_sync_log(sync_log_id, total_estimated: nil)
      @database.with_connection do |db|
        if total_estimated
          db.execute("UPDATE sync_logs SET status = 'completed', finished_at = ?, total_estimated = ? WHERE id = ?", [Time.now.utc.iso8601, total_estimated, sync_log_id])
        else
          db.execute("UPDATE sync_logs SET status = 'completed', finished_at = ? WHERE id = ?", [Time.now.utc.iso8601, sync_log_id])
        end
      end
    end

    def fail_sync_log(sync_log_id, error_message)
      @database.with_connection do |db|
        db.execute("UPDATE sync_logs SET status = 'failed', finished_at = ?, error_message = ? WHERE id = ?", [Time.now.utc.iso8601, error_message, sync_log_id])
      end
    end

    def latest_sync_log(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM sync_logs WHERE shop_domain = ? ORDER BY started_at DESC, rowid DESC LIMIT 1", shop_domain)
        hydrate_sync_log(row)
      end
    end

    def last_completed_sync(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM sync_logs WHERE shop_domain = ? AND status = 'completed' ORDER BY finished_at DESC, rowid DESC LIMIT 1", shop_domain)
        hydrate_sync_log(row)
      end
    end

    def sync_state(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM sync_states WHERE shop_domain = ?", shop_domain)
        hydrate_sync_state(row)
      end
    end

    def upsert_sync_state(shop_domain, attributes)
      now = Time.now.utc.iso8601
      payload = {
        "shop_domain" => shop_domain,
        "last_order_updated_at" => attributes["last_order_updated_at"] || attributes[:last_order_updated_at],
        "last_cursor" => attributes["last_cursor"] || attributes[:last_cursor],
        "last_sync_type" => attributes["last_sync_type"] || attributes[:last_sync_type],
        "last_synced_at" => attributes["last_synced_at"] || attributes[:last_synced_at] || now,
        "updated_at" => now
      }

      @database.with_connection do |db|
        db.execute(<<~SQL, payload.values_at("shop_domain", "last_order_updated_at", "last_cursor", "last_sync_type", "last_synced_at", "updated_at"))
          INSERT INTO sync_states (
            shop_domain, last_order_updated_at, last_cursor, last_sync_type, last_synced_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(shop_domain) DO UPDATE SET
            last_order_updated_at = excluded.last_order_updated_at,
            last_cursor = excluded.last_cursor,
            last_sync_type = excluded.last_sync_type,
            last_synced_at = excluded.last_synced_at,
            updated_at = excluded.updated_at
        SQL
      end

      sync_state(shop_domain)
    end

    def create_bulk_sync_job(shop_domain, attributes = {})
      now = Time.now.utc.iso8601
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => shop_domain,
        "sync_log_id" => attributes["sync_log_id"] || attributes[:sync_log_id],
        "shopify_bulk_operation_id" => attributes["shopify_bulk_operation_id"] || attributes[:shopify_bulk_operation_id],
        "sync_type" => attributes["sync_type"] || attributes[:sync_type] || "full",
        "status" => attributes["status"] || attributes[:status] || "queued",
        "object_count" => (attributes["object_count"] || attributes[:object_count] || 0).to_i,
        "file_size" => (attributes["file_size"] || attributes[:file_size] || 0).to_i,
        "result_url" => attributes["result_url"] || attributes[:result_url],
        "partial_data_url" => attributes["partial_data_url"] || attributes[:partial_data_url],
        "imported_count" => (attributes["imported_count"] || attributes[:imported_count] || 0).to_i,
        "fallback_used" => truthy_db(attributes["fallback_used"] || attributes[:fallback_used] || false),
        "fallback_sync_log_id" => attributes["fallback_sync_log_id"] || attributes[:fallback_sync_log_id],
        "error_code" => attributes["error_code"] || attributes[:error_code],
        "error_message" => attributes["error_message"] || attributes[:error_message],
        "started_at" => now,
        "completed_at" => attributes["completed_at"] || attributes[:completed_at],
        "updated_at" => now
      }

      values = payload.values_at(
        "id", "shop_domain", "sync_log_id", "shopify_bulk_operation_id", "sync_type", "status",
        "object_count", "file_size", "result_url", "partial_data_url", "imported_count",
        "fallback_used", "fallback_sync_log_id", "error_code", "error_message",
        "started_at", "completed_at", "updated_at"
      )

      @database.with_connection do |db|
        db.execute(<<~SQL, values)
          INSERT INTO bulk_sync_jobs (
            id, shop_domain, sync_log_id, shopify_bulk_operation_id, sync_type, status,
            object_count, file_size, result_url, partial_data_url, imported_count,
            fallback_used, fallback_sync_log_id, error_code, error_message,
            started_at, completed_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      bulk_sync_job(payload["id"])
    end

    def update_bulk_sync_job(job_id, attributes)
      normalized = normalize_keys(attributes)
      allowed = %w[
        sync_log_id shopify_bulk_operation_id status object_count file_size result_url
        partial_data_url imported_count fallback_used fallback_sync_log_id error_code
        error_message completed_at
      ]
      updates = []
      values = []

      normalized.each do |key, value|
        next unless allowed.include?(key)

        updates << "#{key} = ?"
        values << (key == "fallback_used" ? truthy_db(value) : value)
      end

      updates << "updated_at = ?"
      values << Time.now.utc.iso8601
      values << job_id

      @database.with_connection do |db|
        db.execute("UPDATE bulk_sync_jobs SET #{updates.join(', ')} WHERE id = ?", values)
      end

      bulk_sync_job(job_id)
    end

    def bulk_sync_job(job_id)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM bulk_sync_jobs WHERE id = ?", job_id)
        hydrate_bulk_sync_job(row)
      end
    end

    def bulk_sync_job_by_operation(shop_domain, operation_id)
      @database.with_connection do |db|
        row = db.get_first_row(
          "SELECT * FROM bulk_sync_jobs WHERE shop_domain = ? AND shopify_bulk_operation_id = ? ORDER BY started_at DESC, rowid DESC LIMIT 1",
          [shop_domain, operation_id]
        )
        hydrate_bulk_sync_job(row)
      end
    end

    def claim_bulk_sync_job(job_id, from_statuses:, status:)
      statuses = Array(from_statuses).map(&:to_s)
      return false if statuses.empty?

      placeholders = (["?"] * statuses.length).join(", ")
      changed = @database.with_connection do |db|
        db.execute(
          "UPDATE bulk_sync_jobs SET status = ?, updated_at = ? WHERE id = ? AND status IN (#{placeholders})",
          [status, Time.now.utc.iso8601, job_id] + statuses
        )
        db.changes
      end

      changed == 1
    end

    def latest_bulk_sync_job(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM bulk_sync_jobs WHERE shop_domain = ? ORDER BY started_at DESC, rowid DESC LIMIT 1", shop_domain)
        hydrate_bulk_sync_job(row)
      end
    end

    def create_batch_log(shop_domain, attributes)
      now = Time.now.utc.iso8601
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => shop_domain,
        "resource_name" => attributes["resource_name"] || attributes[:resource_name] || "ORDER",
        "sync_type" => attributes["sync_type"] || attributes[:sync_type] || "first_time_sync",
        "batch_type" => attributes["batch_type"] || attributes[:batch_type],
        "start_date" => attributes["start_date"] || attributes[:start_date],
        "end_date" => attributes["end_date"] || attributes[:end_date],
        "order_count" => (attributes["order_count"] || attributes[:order_count] || 0).to_i,
        "batch_sequence" => (attributes["batch_sequence"] || attributes[:batch_sequence] || 0).to_i,
        "status" => attributes["status"] || attributes[:status] || "pending",
        "priority" => attributes["priority"] || attributes[:priority] || "normal",
        "retry_count" => (attributes["retry_count"] || attributes[:retry_count] || 0).to_i,
        "cursor" => attributes["cursor"] || attributes[:cursor],
        "page_index" => (attributes["page_index"] || attributes[:page_index] || 0).to_i,
        "page_limit" => (attributes["page_limit"] || attributes[:page_limit] || 1000).to_i,
        "error_message" => attributes["error_message"] || attributes[:error_message],
        "started_at" => attributes["started_at"] || attributes[:started_at],
        "completed_at" => attributes["completed_at"] || attributes[:completed_at],
        "created_at" => now,
        "updated_at" => now
      }

      values = payload.values_at(
        "id", "shop_domain", "resource_name", "sync_type", "batch_type", "start_date", "end_date",
        "order_count", "batch_sequence", "status", "priority", "retry_count", "cursor",
        "page_index", "page_limit", "error_message", "started_at", "completed_at", "created_at", "updated_at"
      )

      @database.with_connection do |db|
        db.execute(<<~SQL, values)
          INSERT OR IGNORE INTO batch_logs (
            id, shop_domain, resource_name, sync_type, batch_type, start_date, end_date,
            order_count, batch_sequence, status, priority, retry_count, cursor,
            page_index, page_limit, error_message, started_at, completed_at, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      batch_log_by_unique(
        shop_domain,
        payload["sync_type"],
        payload["batch_type"],
        payload["start_date"],
        payload["end_date"],
        payload["page_index"]
      )
    end

    def update_batch_log(batch_id, attributes)
      normalized = normalize_keys(attributes)
      allowed = %w[
        status order_count retry_count cursor page_limit error_message started_at completed_at
      ]
      updates = []
      values = []

      normalized.each do |key, value|
        next unless allowed.include?(key)

        updates << "#{key} = ?"
        values << value
      end

      updates << "updated_at = ?"
      values << Time.now.utc.iso8601
      values << batch_id

      @database.with_connection do |db|
        db.execute("UPDATE batch_logs SET #{updates.join(', ')} WHERE id = ?", values)
      end

      batch_log(batch_id)
    end

    def batch_log(batch_id)
      @database.with_connection do |db|
        hydrate_batch_log(db.get_first_row("SELECT * FROM batch_logs WHERE id = ?", batch_id))
      end
    end

    def batch_log_by_unique(shop_domain, sync_type, batch_type, start_date, end_date, page_index)
      @database.with_connection do |db|
        row = db.get_first_row(<<~SQL, [shop_domain, sync_type, batch_type, start_date, end_date, page_index])
          SELECT * FROM batch_logs
          WHERE shop_domain = ? AND sync_type = ? AND batch_type = ? AND start_date = ? AND end_date = ? AND page_index = ?
        SQL
        hydrate_batch_log(row)
      end
    end

    def pending_batch_logs(shop_domain, sync_type: "first_time_sync")
      @database.with_connection do |db|
        db.execute(<<~SQL, [shop_domain, sync_type]).map { |row| hydrate_batch_log(row) }
          SELECT * FROM batch_logs
          WHERE shop_domain = ? AND sync_type = ? AND status IN ('pending', 'failed')
          ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END, batch_sequence ASC, page_index ASC
        SQL
      end
    end

    def batch_logs(shop_domain, sync_type: "first_time_sync")
      @database.with_connection do |db|
        db.execute(<<~SQL, [shop_domain, sync_type]).map { |row| hydrate_batch_log(row) }
          SELECT * FROM batch_logs
          WHERE shop_domain = ? AND sync_type = ?
          ORDER BY batch_sequence ASC, page_index ASC
        SQL
      end
    end

    def retry_failed_batch_log(batch_id)
      now = Time.now.utc.iso8601
      changed = @database.with_connection do |db|
        db.execute(<<~SQL, [now, batch_id])
          UPDATE batch_logs
          SET status = 'pending',
              error_message = NULL,
              started_at = NULL,
              completed_at = NULL,
              updated_at = ?
          WHERE id = ?
            AND status = 'failed'
        SQL
        db.changes
      end

      changed == 1 ? batch_log(batch_id) : nil
    end

    def batch_summary(shop_domain, sync_type: "first_time_sync")
      rows = batch_logs(shop_domain, sync_type: sync_type)
      grouped = rows.group_by { |batch| batch["batch_type"] }
      {
        "status" => first_time_sync_status(rows),
        "totalBatches" => rows.length,
        "completedBatches" => rows.count { |batch| batch["status"] == "completed" },
        "failedBatches" => rows.count { |batch| batch["status"] == "failed" },
        "pendingBatches" => rows.count { |batch| batch["status"] == "pending" },
        "processingBatches" => rows.count { |batch| batch["status"] == "processing" },
        "initialSyncCompleted" => Array(grouped["initial_3_days"]).all? { |batch| batch["status"] == "completed" },
        "remainingSyncCompleted" => Array(grouped["remaining_6_months"]).all? { |batch| batch["status"] == "completed" },
        "fullSixMonthsSyncCompleted" => rows.any? && rows.all? { |batch| batch["status"] == "completed" },
        "batches" => rows
      }
    end

    def load_session(session_id)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM sessions WHERE id = ?", session_id)
        row ? JSON.parse(row["data"]) : {}
      end
    end

    def save_session(session_id, shop_domain, data)
      now = Time.now.utc.iso8601
      @database.with_connection do |db|
        db.execute(<<~SQL, [session_id, shop_domain, JSON.generate(data), now, now])
          INSERT INTO sessions (id, shop_domain, data, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            shop_domain = excluded.shop_domain,
            data = excluded.data,
            updated_at = excluded.updated_at
        SQL
      end
    end

    private

    def update_async_job_request_status(request_id, status:, attributes: {})
      normalized = normalize_keys(attributes)
      updates = ["status = ?"]
      values = [status]

      normalized.each do |key, value|
        updates << "#{key} = ?"
        values << value
      end

      updates << "updated_at = ?"
      values << Time.now.utc.iso8601
      values << request_id

      @database.with_connection do |db|
        db.execute("UPDATE async_job_requests SET #{updates.join(', ')} WHERE id = ?", values)
      end

      async_job_request(request_id)
    end

    def normalize_keys(attributes)
      attributes.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
    end

    def normalize_text(value)
      return nil if value.nil?

      text = value.to_s.dup
      text.force_encoding("UTF-8") if text.respond_to?(:force_encoding)
      text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      value.to_s
    end

    def truthy_db(value)
      value ? 1 : 0
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    def default_shop_name(shop_domain)
      shop_domain.to_s.split(".").first.to_s.split("-").map(&:capitalize).join(" ")
    end

    def hydrate_shop(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => normalize_text(row["shop_domain"]),
        "shop_name" => normalize_text(row["shop_name"]),
        "access_token" => normalize_text(row["access_token"]),
        "scopes" => normalize_text(row["scopes"]),
        "owner_email" => normalize_text(row["owner_email"]),
        "installed_at" => normalize_text(row["installed_at"]),
        "uninstalled_at" => normalize_text(row["uninstalled_at"]),
        "scheduled_for_deletion_at" => normalize_text(row["scheduled_for_deletion_at"]),
        "data_deletion_started_at" => normalize_text(row["data_deletion_started_at"]),
        "updated_at" => normalize_text(row["updated_at"]),
        "onboarded" => row["onboarded"].to_i == 1,
        "current_plan" => normalize_text(row["current_plan"]),
        "trial_started_at" => normalize_text(row["trial_started_at"]),
        "tax_rate" => row["tax_rate"].to_f,
        "currency" => normalize_text(row["currency"]),
        "font_name" => normalize_text(row["font_name"]),
        "notification_config" => JSON.parse(row["notification_config"].to_s),
        "invoice_template_config" => JSON.parse(row["invoice_template_config"].to_s),
        "vendor_edits" => JSON.parse(row["vendor_edits"].to_s)
      }
    end

    def hydrate_order(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "name" => row["name"],
        "created_at" => row["created_at"],
        "updated_at" => row["updated_at"],
        "fully_paid" => row["fully_paid"].to_i == 1,
        "financial_status" => row["financial_status"],
        "fulfillment_status" => row["fulfillment_status"],
        "total_price_amount" => row["total_price_amount"].to_f,
        "total_price_currency" => row["total_price_currency"],
        "total_discounts_amount" => row["total_discounts_amount"].to_f,
        "total_refunded_amount" => row["total_refunded_amount"].to_f,
        "total_shipping_amount" => row["total_shipping_amount"].to_f,
        "total_tax_amount" => row["total_tax_amount"].to_f,
        "total_tip_amount" => row["total_tip_amount"].to_f,
        "total_weight" => row["total_weight"]&.to_f,
        "customer_id" => row["customer_id"],
        "customer_first_name" => row["customer_first_name"],
        "customer_last_name" => row["customer_last_name"],
        "customer_email" => row["customer_email"],
        "customer_phone" => row["customer_phone"],
        "line_items" => JSON.parse(row["line_items"].to_s),
        "transactions" => JSON.parse(row["transactions"].to_s),
        "raw_data" => JSON.parse(row["raw_data"].to_s),
        "synced_at" => row["synced_at"]
      }
    end

    def hydrate_sync_log(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "started_at" => row["started_at"],
        "finished_at" => row["finished_at"],
        "status" => row["status"],
        "orders_synced" => row["orders_synced"].to_i,
        "total_estimated" => row["total_estimated"].to_i,
        "error_message" => row["error_message"]
      }
    end

    def hydrate_sync_state(row)
      return nil unless row

      {
        "shop_domain" => row["shop_domain"],
        "last_order_updated_at" => row["last_order_updated_at"],
        "last_cursor" => row["last_cursor"],
        "last_sync_type" => row["last_sync_type"],
        "last_synced_at" => row["last_synced_at"],
        "updated_at" => row["updated_at"]
      }
    end

    def hydrate_bulk_sync_job(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "sync_log_id" => row["sync_log_id"],
        "shopify_bulk_operation_id" => row["shopify_bulk_operation_id"],
        "sync_type" => row["sync_type"],
        "status" => row["status"],
        "object_count" => row["object_count"].to_i,
        "file_size" => row["file_size"].to_i,
        "result_url" => row["result_url"],
        "partial_data_url" => row["partial_data_url"],
        "imported_count" => row["imported_count"].to_i,
        "fallback_used" => row["fallback_used"].to_i == 1,
        "fallback_sync_log_id" => row["fallback_sync_log_id"],
        "error_code" => row["error_code"],
        "error_message" => row["error_message"],
        "started_at" => row["started_at"],
        "completed_at" => row["completed_at"],
        "updated_at" => row["updated_at"]
      }
    end

    def hydrate_invoice_delivery(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "order_id" => row["order_id"],
        "recipient_email" => row["recipient_email"],
        "subject" => row["subject"],
        "body_text" => row["body_text"],
        "invoice_filename" => row["invoice_filename"],
        "delivery_status" => row["delivery_status"],
        "delivery_channel" => row["delivery_channel"],
        "delivery_target" => row["delivery_target"],
        "external_message_id" => row["external_message_id"],
        "outbox_path" => row["outbox_path"],
        "pdf_size_bytes" => row["pdf_size_bytes"].to_i,
        "error_message" => row["error_message"],
        "created_at" => row["created_at"],
        "sent_at" => row["sent_at"],
        "updated_at" => row["updated_at"]
      }
    end

    def hydrate_batch_log(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "resource_name" => row["resource_name"],
        "sync_type" => row["sync_type"],
        "batch_type" => row["batch_type"],
        "start_date" => row["start_date"],
        "end_date" => row["end_date"],
        "order_count" => row["order_count"].to_i,
        "batch_sequence" => row["batch_sequence"].to_i,
        "status" => row["status"],
        "priority" => row["priority"],
        "retry_count" => row["retry_count"].to_i,
        "cursor" => row["cursor"],
        "page_index" => row["page_index"].to_i,
        "page_limit" => row["page_limit"].to_i,
        "error_message" => row["error_message"],
        "started_at" => row["started_at"],
        "completed_at" => row["completed_at"],
        "created_at" => row["created_at"],
        "updated_at" => row["updated_at"]
      }
    end

    def hydrate_async_job_request(row)
      return nil unless row

      {
        "id" => row["id"],
        "shop_domain" => row["shop_domain"],
        "request_type" => row["request_type"],
        "queue_name" => row["queue_name"],
        "dedupe_key" => row["dedupe_key"],
        "payload" => JSON.parse(row["payload"].to_s),
        "status" => row["status"],
        "attempts" => row["attempts"].to_i,
        "claimed_by" => row["claimed_by"],
        "claimed_at" => row["claimed_at"],
        "available_at" => row["available_at"],
        "dispatched_at" => row["dispatched_at"],
        "error_message" => row["error_message"],
        "created_at" => row["created_at"],
        "updated_at" => row["updated_at"]
      }
    end

    def first_time_sync_status(rows)
      return "not_planned" if rows.empty?
      return "failed" if rows.any? { |batch| batch["status"] == "failed" }
      return "full_6_months_sync_completed" if rows.all? { |batch| batch["status"] == "completed" }

      initial = rows.select { |batch| batch["batch_type"] == "initial_3_days" }
      remaining = rows.reject { |batch| batch["batch_type"] == "initial_3_days" }
      return "initial_sync_pending" if initial.any? { |batch| batch["status"] == "pending" }
      return "initial_sync_completed" if initial.all? { |batch| batch["status"] == "completed" } && remaining.any? { |batch| batch["status"] == "pending" }
      return "remaining_sync_in_progress" if remaining.any? { |batch| batch["status"] == "processing" }
      return "remaining_sync_pending" if remaining.any? { |batch| batch["status"] == "pending" }

      "processing"
    end

    def order_to_row(order)
      [
        order["id"],
        order["shop_domain"],
        order["name"],
        order["created_at"],
        order["updated_at"],
        truthy_db(order["fully_paid"]),
        order["financial_status"],
        order["fulfillment_status"],
        order["total_price_amount"],
        order["total_price_currency"],
        order["total_discounts_amount"],
        order["total_refunded_amount"],
        order["total_shipping_amount"],
        order["total_tax_amount"],
        order["total_tip_amount"],
        order["total_weight"],
        order["customer_id"],
        order["customer_first_name"],
        order["customer_last_name"],
        order["customer_email"],
        order["customer_phone"],
        JSON.generate(order["line_items"]),
        JSON.generate(order["transactions"]),
        JSON.generate(order["raw_data"]),
        order["synced_at"] || Time.now.utc.iso8601
      ]
    end

    def with_matching_customer_orders(shop_domain:, customer_id:, customer_email:)
      values = [shop_domain]
      filters = []

      unless customer_id.to_s.strip.empty?
        filters << "customer_id = ?"
        values << customer_id.to_s
      end

      unless customer_email.to_s.strip.empty?
        filters << "LOWER(customer_email) = ?"
        values << customer_email.to_s.downcase
      end

      return [] if filters.empty?

      sql = "shop_domain = ? AND (#{filters.join(' OR ')})"
      @database.with_connection do |db|
        yield db, sql, values
      end
    end

    def redact_order_raw_data(raw_data)
      payload = JSON.parse(raw_data.to_s)
      payload.delete("customer")
      payload["shippingAddress"] = redact_address(payload["shippingAddress"]) if payload["shippingAddress"].is_a?(Hash)
      payload["billingAddress"] = redact_address(payload["billingAddress"]) if payload["billingAddress"].is_a?(Hash)
      payload["note"] = nil if payload.key?("note")
      JSON.generate(payload)
    rescue JSON::ParserError
      JSON.generate({})
    end

    def redact_address(address)
      address.each_with_object({}) do |(key, value), memo|
        memo[key] = redact_address_field?(key) ? nil : value
      end
    end

    def redact_address_field?(key)
      %w[name firstName lastName company address1 address2 city province zip country phone].include?(key.to_s)
    end
  end
end
