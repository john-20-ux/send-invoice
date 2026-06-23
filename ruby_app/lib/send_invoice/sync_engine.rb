# frozen_string_literal: true

require "json"
require "thread"
require "time"

module SendInvoice
  class SyncEngine
    RATE_LIMIT_SECONDS = 300
    BULK_POLL_SECONDS = 5

    ORDERS_QUERY = <<~GRAPHQL
      query SyncOrders($cursor: String, $query: String) {
        orders(first: 100, after: $cursor, query: $query, sortKey: UPDATED_AT) {
          pageInfo {
            hasNextPage
            endCursor
          }
          edges {
            node {
              id
              name
              createdAt
              updatedAt
              fullyPaid
              displayFinancialStatus
              displayFulfillmentStatus
              lineItems(first: 100) {
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
                      shopMoney {
                        amount
                        currencyCode
                      }
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
    GRAPHQL

    BULK_ORDERS_QUERY = <<~GRAPHQL
      {
        orders {
          edges {
            node {
              id
              name
              createdAt
              updatedAt
              fullyPaid
              displayFinancialStatus
              displayFulfillmentStatus
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
              lineItems {
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
                      shopMoney {
                        amount
                        currencyCode
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    def initialize(config:, store:, shopify_client:)
      @config = config
      @store = store
      @shopify_client = shopify_client
      @rate_limits = {}
      @mutex = Mutex.new
      @scheduler_thread = nil
    end

    def trigger(shop:, type: "incremental", skip_rate_limit: false)
      shop_domain = shop.fetch("shop_domain")
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?

      if type == "incremental" && !skip_rate_limit
        limited_for = rate_limited_for(shop_domain)
        return { "started" => false, "message" => "Rate limited. Try again in #{limited_for}s." } if limited_for
      end

      sync_state = type == "incremental" ? @store.sync_state(shop_domain) : nil
      last_order_updated_at = sync_state && sync_state["last_order_updated_at"]
      total_estimated = @config.mock_mode? ? filtered_mock_orders(last_order_updated_at).length : 0
      sync_log = @store.create_sync_log(shop_domain, total_estimated: total_estimated)
      touch_rate_limit(shop_domain) if type == "incremental" && !skip_rate_limit

      Thread.new do
        Thread.current.abort_on_exception = false
        begin
          if @config.mock_mode?
            run_mock_sync(sync_log["id"], shop_domain, last_order_updated_at, type)
          else
            run_shopify_sync(sync_log["id"], shop, last_order_updated_at, type)
          end
        rescue StandardError => e
          @store.fail_sync_log(sync_log["id"], e.message)
        end
      end

      { "started" => true, "syncLogId" => sync_log["id"] }
    end

    def trigger_bulk(shop:, type: "full")
      shop_domain = shop.fetch("shop_domain")
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?

      if @config.mock_mode?
        return trigger(shop: shop, type: type, skip_rate_limit: true).merge("mode" => "mock")
      end

      sync_log = @store.create_sync_log(shop_domain, total_estimated: 0)
      job = @store.create_bulk_sync_job(shop_domain, {
        "sync_log_id" => sync_log["id"],
        "sync_type" => type,
        "status" => "queued"
      })

      Thread.new do
        Thread.current.abort_on_exception = false
        begin
          run_bulk_sync(job["id"], sync_log["id"], shop, type)
        rescue StandardError => e
          handle_bulk_failure(job["id"], sync_log["id"], shop, type, e)
        end
      end

      { "started" => true, "syncLogId" => sync_log["id"], "bulkJobId" => job["id"], "mode" => "bulk" }
    end

    def trigger_all(type: "incremental", skip_rate_limit: false)
      shops = if @config.mock_mode?
                [@store.ensure_shop(MockData::DEMO_SHOP_DOMAIN, "shop_name" => MockData::DEMO_SHOP_NAME)]
              else
                @store.syncable_shops
              end

      shops.map do |shop|
        {
          "shopDomain" => shop["shop_domain"],
          "result" => trigger(shop: shop, type: type, skip_rate_limit: skip_rate_limit)
        }
      end
    end

    def start_scheduler
      return false unless @config.auto_sync_enabled
      return false if @scheduler_thread&.alive?

      @scheduler_thread = Thread.new do
        Thread.current.abort_on_exception = false
        loop do
          begin
            trigger_all(type: "incremental", skip_rate_limit: true)
          rescue StandardError => e
            warn "[send-invoice] auto sync failed: #{e.class}: #{e.message}"
          ensure
            sleep @config.auto_sync_interval_seconds
          end
        end
      end

      true
    end

    def status(shop_domain)
      latest = @store.latest_sync_log(shop_domain)
      last_completed = @store.last_completed_sync(shop_domain)

      return idle_status unless latest

      {
        "status" => latest["status"],
        "ordersSynced" => latest["orders_synced"],
        "totalEstimated" => latest["total_estimated"],
        "startedAt" => latest["started_at"],
        "finishedAt" => latest["finished_at"],
        "lastSyncedAt" => last_completed && last_completed["finished_at"]
      }
    end

    def bulk_status(shop_domain)
      job = @store.latest_bulk_sync_job(shop_domain)
      return { "status" => "idle" } unless job

      job.merge("syncStatus" => status(shop_domain))
    end

    private

    def idle_status
      {
        "status" => "idle",
        "ordersSynced" => 0,
        "totalEstimated" => 0,
        "startedAt" => nil,
        "finishedAt" => nil,
        "lastSyncedAt" => nil
      }
    end

    def rate_limited_for(shop_domain)
      @mutex.synchronize do
        last_trigger = @rate_limits[shop_domain]
        return nil unless last_trigger

        elapsed = Time.now.to_i - last_trigger
        return nil if elapsed >= RATE_LIMIT_SECONDS

        RATE_LIMIT_SECONDS - elapsed
      end
    end

    def touch_rate_limit(shop_domain)
      @mutex.synchronize do
        @rate_limits[shop_domain] = Time.now.to_i
      end
    end

    def filtered_mock_orders(last_order_updated_at = nil)
      return MockData.orders unless last_order_updated_at

      cutoff = Time.parse(last_order_updated_at)
      MockData.orders.select { |order| Time.parse(order["updated_at"] || order["created_at"]) >= cutoff }
    end

    def run_mock_sync(sync_log_id, shop_domain, last_order_updated_at = nil, sync_type = "incremental")
      orders = filtered_mock_orders(last_order_updated_at).map do |order|
        order.merge(
          "shop_domain" => shop_domain,
          "updated_at" => order["updated_at"] || order["created_at"],
          "synced_at" => Time.now.utc.iso8601
        )
      end

      batch_size = 40
      total = orders.length
      synced = 0

      if total.zero?
        @store.complete_sync_log(sync_log_id, total_estimated: 0)
        @store.upsert_sync_state(shop_domain, {
          "last_order_updated_at" => last_order_updated_at,
          "last_cursor" => nil,
          "last_sync_type" => sync_type
        })
        return
      end

      orders.each_slice(batch_size) do |batch|
        sleep 0.25
        @store.upsert_orders(batch)
        synced += batch.length
        @store.update_sync_log_progress(sync_log_id, synced, total)
      end

      @store.complete_sync_log(sync_log_id, total_estimated: total)
      @store.upsert_sync_state(shop_domain, {
        "last_order_updated_at" => max_order_updated_at(orders),
        "last_cursor" => nil,
        "last_sync_type" => sync_type
      })
    end

    def run_shopify_sync(sync_log_id, shop, last_order_updated_at = nil, sync_type = "incremental")
      cursor = nil
      synced = 0
      total_estimated = 0
      highest_order_updated_at = last_order_updated_at
      query_filter = sync_type == "incremental" && last_order_updated_at ? "updated_at:>=#{last_order_updated_at}" : nil

      loop do
        data = @shopify_client.graph_ql(shop.fetch("shop_domain"), shop.fetch("access_token"), ORDERS_QUERY, {
          "cursor" => cursor,
          "query" => query_filter
        })

        edges = data.fetch("orders", {}).fetch("edges", [])
        page_info = data.fetch("orders", {}).fetch("pageInfo", {})

        unless edges.empty?
          orders = edges.map do |edge|
            map_order_node(edge.fetch("node"), shop.fetch("shop_domain"))
          end
          @store.upsert_orders(orders)
          highest_order_updated_at = [highest_order_updated_at, max_order_updated_at(orders)].compact.max
          synced += orders.length
          total_estimated = [synced, total_estimated].max
          @store.update_sync_log_progress(sync_log_id, synced, total_estimated)
        end

        break unless page_info["hasNextPage"]

        cursor = page_info["endCursor"]
      end

      @store.complete_sync_log(sync_log_id, total_estimated: total_estimated)
      @store.upsert_sync_state(shop.fetch("shop_domain"), {
        "last_order_updated_at" => highest_order_updated_at,
        "last_cursor" => nil,
        "last_sync_type" => sync_type
      })
    rescue StandardError => e
      @store.fail_sync_log(sync_log_id, e.message)
      raise
    end

    def run_bulk_sync(job_id, sync_log_id, shop, sync_type)
      query = bulk_orders_query(shop.fetch("shop_domain"), sync_type)
      operation = @shopify_client.start_bulk_query(shop.fetch("shop_domain"), shop.fetch("access_token"), query)
      operation_id = operation.fetch("id")

      @store.update_bulk_sync_job(job_id, {
        "shopify_bulk_operation_id" => operation_id,
        "status" => normalize_bulk_status(operation["status"])
      })

      loop do
        operation = @shopify_client.bulk_operation(shop.fetch("shop_domain"), shop.fetch("access_token"), operation_id)
        status = normalize_bulk_status(operation["status"])
        @store.update_bulk_sync_job(job_id, bulk_operation_attributes(operation).merge("status" => status))

        case status
        when "completed"
          url = operation["url"] || operation["partialDataUrl"]
          raise "Shopify bulk operation completed without a result URL" if url.to_s.empty?

          @store.update_bulk_sync_job(job_id, "status" => "downloading")
          result = import_bulk_result(url, shop.fetch("shop_domain"), sync_log_id, job_id)
          @store.complete_sync_log(sync_log_id, total_estimated: result["imported_count"])
          @store.upsert_sync_state(shop.fetch("shop_domain"), {
            "last_order_updated_at" => result["last_order_updated_at"],
            "last_cursor" => nil,
            "last_sync_type" => "bulk_#{sync_type}"
          })
          @store.update_bulk_sync_job(job_id, {
            "status" => "completed",
            "imported_count" => result["imported_count"],
            "completed_at" => Time.now.utc.iso8601
          })
          break
        when "failed", "canceled", "expired"
          raise "Shopify bulk operation #{status}: #{operation['errorCode']}"
        else
          sleep BULK_POLL_SECONDS
        end
      end
    end

    def import_bulk_result(url, shop_domain, sync_log_id, job_id)
      imported = 0
      highest_order_updated_at = nil
      current_order = nil
      current_line_items = []
      pending_line_items = Hash.new { |hash, key| hash[key] = [] }
      batch = []

      flush_order = lambda do
        next unless current_order

        order = map_bulk_order_record(current_order, shop_domain, current_line_items)
        batch << order
        highest_order_updated_at = [highest_order_updated_at, order["updated_at"]].compact.max
        imported += 1

        if batch.length >= 250
          @store.upsert_orders(batch)
          @store.update_sync_log_progress(sync_log_id, imported, imported)
          @store.update_bulk_sync_job(job_id, "imported_count" => imported)
          batch = []
        end
      end

      @store.update_bulk_sync_job(job_id, "status" => "importing")

      @shopify_client.stream_bulk_result(url) do |line|
        record = JSON.parse(line)
        parent_id = record["__parentId"]

        if parent_id
          line_item = map_bulk_line_item_record(record)
          if current_order && current_order["id"] == parent_id
            current_line_items << line_item
          else
            pending_line_items[parent_id] << line_item
          end
          next
        end

        flush_order.call
        current_order = record
        current_line_items = pending_line_items.delete(record["id"]) || []
      end

      flush_order.call
      unless batch.empty?
        @store.upsert_orders(batch)
        @store.update_sync_log_progress(sync_log_id, imported, imported)
        @store.update_bulk_sync_job(job_id, "imported_count" => imported)
      end

      { "imported_count" => imported, "last_order_updated_at" => highest_order_updated_at }
    end

    def handle_bulk_failure(job_id, sync_log_id, shop, sync_type, error)
      @store.update_bulk_sync_job(job_id, {
        "status" => "failed",
        "error_message" => error.message,
        "completed_at" => Time.now.utc.iso8601
      })
      @store.fail_sync_log(sync_log_id, error.message)

      return unless fallback_allowed?(error)

      fallback_log = @store.create_sync_log(shop.fetch("shop_domain"), total_estimated: 0)
      @store.update_bulk_sync_job(job_id, {
        "fallback_used" => true,
        "fallback_sync_log_id" => fallback_log["id"],
        "status" => "fallback_running"
      })

      run_shopify_sync(fallback_log["id"], shop, nil, sync_type)
      @store.update_bulk_sync_job(job_id, {
        "status" => "fallback_completed",
        "completed_at" => Time.now.utc.iso8601
      })
    rescue StandardError => fallback_error
      @store.update_bulk_sync_job(job_id, {
        "status" => "fallback_failed",
        "error_message" => fallback_error.message,
        "completed_at" => Time.now.utc.iso8601
      })
      @store.fail_sync_log(fallback_log["id"], fallback_error.message) if fallback_log
    end

    def fallback_allowed?(error)
      !error.message.match?(/401|403|unauthorized|access token|invalid token/i)
    end

    def bulk_orders_query(shop_domain, sync_type)
      return BULK_ORDERS_QUERY unless sync_type == "incremental"

      state = @store.sync_state(shop_domain)
      last_order_updated_at = state && state["last_order_updated_at"]
      return BULK_ORDERS_QUERY if last_order_updated_at.to_s.empty?

      BULK_ORDERS_QUERY.sub("orders {", "orders(query: #{JSON.generate("updated_at:>=#{last_order_updated_at}")}) {")
    end

    def bulk_operation_attributes(operation)
      {
        "object_count" => operation["objectCount"].to_i,
        "file_size" => operation["fileSize"].to_i,
        "result_url" => operation["url"],
        "partial_data_url" => operation["partialDataUrl"],
        "error_code" => operation["errorCode"]
      }
    end

    def normalize_bulk_status(status)
      status.to_s.downcase
    end

    def map_order_node(node, shop_domain)
      total_price = money(node["totalPriceSet"])
      {
        "id" => node["id"],
        "shop_domain" => shop_domain,
        "name" => node["name"],
        "created_at" => node["createdAt"],
        "updated_at" => node["updatedAt"] || node["createdAt"],
        "fully_paid" => node["fullyPaid"] || false,
        "financial_status" => node["displayFinancialStatus"] || "PENDING",
        "fulfillment_status" => node["displayFulfillmentStatus"],
        "total_price_amount" => total_price["amount"],
        "total_price_currency" => total_price["currency"],
        "total_discounts_amount" => money(node["totalDiscountsSet"])["amount"],
        "total_refunded_amount" => money(node["totalRefundedSet"])["amount"],
        "total_shipping_amount" => money(node["totalShippingPriceSet"])["amount"],
        "total_tax_amount" => money(node["totalTaxSet"])["amount"],
        "total_tip_amount" => money(node["totalTipReceivedSet"])["amount"],
        "total_weight" => node["totalWeight"],
        "customer_id" => node.dig("customer", "id"),
        "customer_first_name" => node.dig("customer", "firstName"),
        "customer_last_name" => node.dig("customer", "lastName"),
        "customer_email" => node.dig("customer", "email"),
        "customer_phone" => node.dig("customer", "phone"),
        "line_items" => Array(node.dig("lineItems", "edges")).map do |edge|
          line_item = edge.fetch("node")
          line_total = money(line_item["originalTotalSet"])
          {
            "id" => line_item["id"],
            "sku" => line_item["sku"],
            "title" => line_item["title"],
            "variantTitle" => line_item["variantTitle"],
            "vendor" => line_item["vendor"],
            "quantity" => line_item["quantity"],
            "currentQuantity" => line_item["currentQuantity"],
            "totalAmount" => line_total["amount"],
            "totalCurrency" => line_total["currency"]
          }
        end,
        "transactions" => Array(node["transactions"]).map do |transaction|
          value = money(transaction["amountSet"])
          { "amount" => value["amount"], "currency" => value["currency"] }
        end,
        "raw_data" => node,
        "synced_at" => Time.now.utc.iso8601
      }
    end

    def map_bulk_order_record(record, shop_domain, line_items)
      total_price = money(record["totalPriceSet"])
      {
        "id" => record["id"],
        "shop_domain" => shop_domain,
        "name" => record["name"],
        "created_at" => record["createdAt"],
        "updated_at" => record["updatedAt"] || record["createdAt"],
        "fully_paid" => record["fullyPaid"] || false,
        "financial_status" => record["displayFinancialStatus"] || "PENDING",
        "fulfillment_status" => record["displayFulfillmentStatus"],
        "total_price_amount" => total_price["amount"],
        "total_price_currency" => total_price["currency"],
        "total_discounts_amount" => money(record["totalDiscountsSet"])["amount"],
        "total_refunded_amount" => money(record["totalRefundedSet"])["amount"],
        "total_shipping_amount" => money(record["totalShippingPriceSet"])["amount"],
        "total_tax_amount" => money(record["totalTaxSet"])["amount"],
        "total_tip_amount" => money(record["totalTipReceivedSet"])["amount"],
        "total_weight" => record["totalWeight"],
        "customer_id" => record.dig("customer", "id"),
        "customer_first_name" => record.dig("customer", "firstName"),
        "customer_last_name" => record.dig("customer", "lastName"),
        "customer_email" => record.dig("customer", "email"),
        "customer_phone" => record.dig("customer", "phone"),
        "line_items" => line_items,
        "transactions" => Array(record["transactions"]).map do |transaction|
          value = money(transaction["amountSet"])
          { "amount" => value["amount"], "currency" => value["currency"] }
        end,
        "raw_data" => record.merge("lineItems" => line_items),
        "synced_at" => Time.now.utc.iso8601
      }
    end

    def map_bulk_line_item_record(record)
      line_total = money(record["originalTotalSet"])
      {
        "id" => record["id"],
        "sku" => record["sku"],
        "title" => record["title"],
        "variantTitle" => record["variantTitle"],
        "vendor" => record["vendor"],
        "quantity" => record["quantity"],
        "currentQuantity" => record["currentQuantity"],
        "totalAmount" => line_total["amount"],
        "totalCurrency" => line_total["currency"]
      }
    end

    def max_order_updated_at(orders)
      orders.map { |order| order["updated_at"] || order["created_at"] }.compact.max
    end

    def money(node)
      money = node && node["shopMoney"]
      {
        "amount" => money ? money["amount"].to_f : 0.0,
        "currency" => money ? money["currencyCode"] : "USD"
      }
    end
  end
end
