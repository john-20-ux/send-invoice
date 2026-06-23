# frozen_string_literal: true

require "thread"

module SendInvoice
  class SyncEngine
    RATE_LIMIT_SECONDS = 300

    ORDERS_QUERY = <<~GRAPHQL
      query SyncOrders($cursor: String, $query: String) {
        orders(first: 50, after: $cursor, query: $query, sortKey: CREATED_AT) {
          pageInfo {
            hasNextPage
            endCursor
          }
          edges {
            node {
              id
              name
              createdAt
              fullyPaid
              displayFinancialStatus
              displayFulfillmentStatus
              lineItems(first: 50) {
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

    def initialize(config:, store:, shopify_client:)
      @config = config
      @store = store
      @shopify_client = shopify_client
      @rate_limits = {}
      @mutex = Mutex.new
    end

    def trigger(shop:, type: "incremental")
      shop_domain = shop.fetch("shop_domain")
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"

      if type == "incremental"
        limited_for = rate_limited_for(shop_domain)
        return { "started" => false, "message" => "Rate limited. Try again in #{limited_for}s." } if limited_for
      end

      last_completed = type == "incremental" ? @store.last_completed_sync(shop_domain) : nil
      total_estimated = @config.mock_mode? ? filtered_mock_orders(last_completed&.fetch("finished_at", nil)).length : 0
      sync_log = @store.create_sync_log(shop_domain, total_estimated: total_estimated)
      touch_rate_limit(shop_domain) if type == "incremental"

      Thread.new do
        Thread.current.abort_on_exception = false
        begin
          if @config.mock_mode?
            run_mock_sync(sync_log["id"], shop_domain, last_completed&.fetch("finished_at", nil))
          else
            run_shopify_sync(sync_log["id"], shop, last_completed&.fetch("finished_at", nil))
          end
        rescue StandardError => e
          @store.fail_sync_log(sync_log["id"], e.message)
        end
      end

      { "started" => true, "syncLogId" => sync_log["id"] }
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

    def filtered_mock_orders(last_synced_at = nil)
      return MockData.orders unless last_synced_at

      cutoff = Time.parse(last_synced_at)
      MockData.orders.select { |order| Time.parse(order["created_at"]) >= cutoff }
    end

    def run_mock_sync(sync_log_id, shop_domain, last_synced_at = nil)
      orders = filtered_mock_orders(last_synced_at).map do |order|
        order.merge("shop_domain" => shop_domain, "synced_at" => Time.now.utc.iso8601)
      end

      batch_size = 40
      total = orders.length
      synced = 0

      if total.zero?
        @store.complete_sync_log(sync_log_id, total_estimated: 0)
        return
      end

      orders.each_slice(batch_size) do |batch|
        sleep 0.25
        @store.upsert_orders(batch)
        synced += batch.length
        @store.update_sync_log_progress(sync_log_id, synced, total)
      end

      @store.complete_sync_log(sync_log_id, total_estimated: total)
    end

    def run_shopify_sync(sync_log_id, shop, last_synced_at = nil)
      cursor = nil
      synced = 0
      total_estimated = 0
      query_filter = last_synced_at ? "created_at:>='#{last_synced_at}'" : nil

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
          synced += orders.length
          total_estimated = [synced, total_estimated].max
          @store.update_sync_log_progress(sync_log_id, synced, total_estimated)
        end

        break unless page_info["hasNextPage"]

        cursor = page_info["endCursor"]
      end

      @store.complete_sync_log(sync_log_id, total_estimated: total_estimated)
    rescue StandardError => e
      @store.fail_sync_log(sync_log_id, e.message)
      raise
    end

    def map_order_node(node, shop_domain)
      total_price = money(node["totalPriceSet"])
      {
        "id" => node["id"],
        "shop_domain" => shop_domain,
        "name" => node["name"],
        "created_at" => node["createdAt"],
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

    def money(node)
      money = node && node["shopMoney"]
      {
        "amount" => money ? money["amount"].to_f : 0.0,
        "currency" => money ? money["currencyCode"] : "USD"
      }
    end
  end
end
