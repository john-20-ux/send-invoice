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
      existing = shop(shop_domain)
      if existing
        update_shop(shop_domain, attributes) unless attributes.empty?
        return shop(shop_domain)
      end

      now = Time.now.utc.iso8601
      payload = {
        "id" => SecureRandom.uuid,
        "shop_domain" => shop_domain,
        "shop_name" => attributes["shop_name"] || attributes[:shop_name] || default_shop_name(shop_domain),
        "access_token" => attributes["access_token"] || attributes[:access_token],
        "scopes" => attributes["scopes"] || attributes[:scopes],
        "owner_email" => attributes["owner_email"] || attributes[:owner_email],
        "installed_at" => now,
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
        db.execute(<<~SQL, payload.values_at("id", "shop_domain", "shop_name", "access_token", "scopes", "owner_email", "installed_at", "updated_at", "onboarded", "current_plan", "trial_started_at", "tax_rate", "currency", "font_name", "notification_config", "invoice_template_config", "vendor_edits"))
          INSERT INTO shops (
            id, shop_domain, shop_name, access_token, scopes, owner_email, installed_at,
            updated_at, onboarded, current_plan, trial_started_at, tax_rate, currency,
            font_name, notification_config, invoice_template_config, vendor_edits
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end

      shop(shop_domain)
    end

    def shop(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM shops WHERE shop_domain = ?", shop_domain)
        hydrate_shop(row)
      end
    end

    def update_shop(shop_domain, attributes)
      return if attributes.nil? || attributes.empty?

      updates = []
      values = []
      normalized = normalize_keys(attributes)

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
        db.execute("UPDATE shops SET #{updates.join(', ')} WHERE shop_domain = ?", values)
      end
    end

    def upsert_orders(orders)
      @database.with_connection do |db|
        orders.each do |order|
          normalized = order_to_row(order)
          db.execute(<<~SQL, normalized)
            INSERT INTO orders (
              id, shop_domain, name, created_at, fully_paid, financial_status, fulfillment_status,
              total_price_amount, total_price_currency, total_discounts_amount, total_refunded_amount,
              total_shipping_amount, total_tax_amount, total_tip_amount, total_weight,
              customer_id, customer_first_name, customer_last_name, customer_email, customer_phone,
              line_items, transactions, raw_data, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, shop_domain) DO UPDATE SET
              name = excluded.name,
              created_at = excluded.created_at,
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
        row = db.get_first_row("SELECT * FROM orders WHERE shop_domain = ? AND id = ?", shop_domain, order_id)
        hydrate_order(row)
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
        row = db.get_first_row("SELECT * FROM sync_logs WHERE shop_domain = ? ORDER BY started_at DESC LIMIT 1", shop_domain)
        hydrate_sync_log(row)
      end
    end

    def last_completed_sync(shop_domain)
      @database.with_connection do |db|
        row = db.get_first_row("SELECT * FROM sync_logs WHERE shop_domain = ? AND status = 'completed' ORDER BY finished_at DESC LIMIT 1", shop_domain)
        hydrate_sync_log(row)
      end
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

    def normalize_keys(attributes)
      attributes.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
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
        "shop_domain" => row["shop_domain"],
        "shop_name" => row["shop_name"],
        "access_token" => row["access_token"],
        "scopes" => row["scopes"],
        "owner_email" => row["owner_email"],
        "installed_at" => row["installed_at"],
        "updated_at" => row["updated_at"],
        "onboarded" => row["onboarded"].to_i == 1,
        "current_plan" => row["current_plan"],
        "trial_started_at" => row["trial_started_at"],
        "tax_rate" => row["tax_rate"].to_f,
        "currency" => row["currency"],
        "font_name" => row["font_name"],
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

    def order_to_row(order)
      [
        order["id"],
        order["shop_domain"],
        order["name"],
        order["created_at"],
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
  end
end
