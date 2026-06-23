# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "send_invoice/app"
require "send_invoice/configuration"
require "send_invoice/database"
require "send_invoice/migrator"
require "send_invoice/shopify_client"
require "send_invoice/store"
require "send_invoice/sync_engine"

class SendInvoiceAppTest < Minitest::Test
  Request = Struct.new(:request_method, :path, :query, :header, :cookies, :body) do
    def [](key)
      header[key]
    end
  end

  Response = Struct.new(:status, :body, :cookies, :headers) do
    def []=(key, value)
      headers[key] = value
    end

    def [](key)
      headers[key]
    end
  end

  def test_dashboard_renders_for_onboarded_mock_shop
    app, = build_app(onboarded: true, order_count: 12)
    response = perform(app, "GET", "/dashboard", { "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN })

    assert_equal 200, response.status
    assert_includes response.body, "Daily revenue"
    assert_includes response.body, "Order mix"
  end

  def test_orders_api_returns_paginated_json
    app, = build_app(onboarded: true, order_count: 12)
    response = perform(app, "GET", "/api/orders", {
      "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN,
      "limit" => "5",
      "page" => "1"
    })

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal 5, payload["orders"].length
    assert_equal 12, payload["total"]
    assert_equal 3, payload["totalPages"]
  end

  def test_onboarding_complete_redirects_after_sync
    app, store = build_app(onboarded: false, order_count: 4)
    shop = store.shop(SendInvoice::MockData::DEMO_SHOP_DOMAIN)
    sync_log = store.create_sync_log(shop["shop_domain"], total_estimated: 4)
    store.complete_sync_log(sync_log["id"], total_estimated: 4)

    response = perform(app, "GET", "/onboarding/complete", { "shop" => shop["shop_domain"] })

    assert_equal 302, response.status
    assert_equal "/dashboard", response["Location"]
    assert_equal true, store.shop(shop["shop_domain"])["onboarded"]
  end

  def test_shopify_graphql_sync_paginates_and_persists_watermark
    store, sync_engine, shopify_client, database_path = build_real_sync_engine
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger(shop: shop, type: "full")
    assert_equal true, result["started"]

    wait_for_sync(store, shop["shop_domain"])
    orders = store.orders(shop["shop_domain"], limit: 10)["orders"]
    updated_order = orders.find { |order| order["name"] == "#1002" }
    state = store.sync_state(shop["shop_domain"])

    assert_equal 2, orders.length
    refute_nil updated_order
    assert_equal "2026-06-11T10:30:00Z", updated_order["updated_at"]
    assert_equal "2026-06-11T10:30:00Z", state["last_order_updated_at"]

    incremental = sync_engine.trigger(shop: shop, type: "incremental")
    assert_equal true, incremental["started"]
    wait_for_sync(store, shop["shop_domain"])
    assert_includes shopify_client.calls.map { |call| call["query"] }, "updated_at:>=2026-06-11T10:30:00Z"
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  def test_bulk_sync_imports_jsonl_and_updates_checkpoint
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBulkShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger_bulk(shop: shop, type: "full")
    assert_equal true, result["started"]

    wait_for_sync(store, shop["shop_domain"])
    job = wait_for_bulk_job(store, shop["shop_domain"])
    orders = store.orders(shop["shop_domain"], limit: 10)["orders"]
    state = store.sync_state(shop["shop_domain"])

    assert_equal "completed", job["status"]
    assert_equal false, job["fallback_used"]
    assert_equal 1, job["imported_count"]
    assert_equal 1, orders.length
    assert_equal "#2001", orders.first["name"]
    assert_equal "Bulk Vendor", orders.first["line_items"].first["vendor"]
    assert_equal "2026-06-12T12:00:00Z", state["last_order_updated_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  def test_bulk_sync_falls_back_to_paginated_graphql_when_bulk_fails
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeFailingBulkShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger_bulk(shop: shop, type: "full")
    assert_equal true, result["started"]

    job = wait_for_bulk_job(store, shop["shop_domain"])
    orders = store.orders(shop["shop_domain"], limit: 10)["orders"]

    assert_equal "fallback_completed", job["status"]
    assert_equal true, job["fallback_used"]
    assert_equal 2, orders.length
    assert_equal "completed", store.latest_sync_log(shop["shop_domain"])["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  private

  class FakeShopifyClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def graph_ql(_shop_domain, _access_token, _query, variables = {})
      @calls << variables
      cursor = variables["cursor"]
      if cursor
        page("#1002", "gid://shopify/Order/1002", "2026-06-11T10:30:00Z", false)
      else
        page("#1001", "gid://shopify/Order/1001", "2026-06-10T09:00:00Z", true)
      end
    end

    private

    def page(name, id, updated_at, has_next_page)
      {
        "orders" => {
          "pageInfo" => {
            "hasNextPage" => has_next_page,
            "endCursor" => has_next_page ? "next-cursor" : nil
          },
          "edges" => [
            {
              "node" => {
                "id" => id,
                "name" => name,
                "createdAt" => "2026-06-09T08:00:00Z",
                "updatedAt" => updated_at,
                "fullyPaid" => true,
                "displayFinancialStatus" => "PAID",
                "displayFulfillmentStatus" => "FULFILLED",
                "totalDiscountsSet" => money("0.00"),
                "totalPriceSet" => money("125.00"),
                "totalRefundedSet" => money("0.00"),
                "totalShippingPriceSet" => money("10.00"),
                "totalTaxSet" => money("5.00"),
                "totalTipReceivedSet" => money("0.00"),
                "totalWeight" => 200,
                "transactions" => [{ "amountSet" => money("125.00") }],
                "customer" => {
                  "id" => "gid://shopify/Customer/1",
                  "firstName" => "Ada",
                  "lastName" => "Lovelace",
                  "email" => "ada@example.com",
                  "phone" => nil
                },
                "lineItems" => {
                  "edges" => [
                    {
                      "node" => {
                        "id" => "#{id}/LineItem/1",
                        "sku" => "SKU-1",
                        "title" => "Notebook",
                        "variantTitle" => "Black",
                        "vendor" => "Paper Co",
                        "quantity" => 1,
                        "currentQuantity" => 1,
                        "originalTotalSet" => money("110.00")
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
      }
    end

    def money(amount)
      { "shopMoney" => { "amount" => amount, "currencyCode" => "USD" } }
    end
  end

  class FakeBulkShopifyClient < FakeShopifyClient
    def start_bulk_query(_shop_domain, _access_token, _query)
      { "id" => "gid://shopify/BulkOperation/1", "status" => "CREATED" }
    end

    def bulk_operation(_shop_domain, _access_token, operation_id)
      {
        "id" => operation_id,
        "status" => "COMPLETED",
        "errorCode" => nil,
        "objectCount" => "2",
        "fileSize" => "512",
        "url" => "https://bulk.example.test/orders.jsonl",
        "partialDataUrl" => nil
      }
    end

    def stream_bulk_result(_url)
      bulk_lines.each { |line| yield line }
    end

    private

    def bulk_lines
      order_id = "gid://shopify/Order/2001"
      [
        JSON.generate({
          "id" => order_id,
          "name" => "#2001",
          "createdAt" => "2026-06-12T10:00:00Z",
          "updatedAt" => "2026-06-12T12:00:00Z",
          "fullyPaid" => true,
          "displayFinancialStatus" => "PAID",
          "displayFulfillmentStatus" => "FULFILLED",
          "totalDiscountsSet" => money("0.00"),
          "totalPriceSet" => money("250.00"),
          "totalRefundedSet" => money("0.00"),
          "totalShippingPriceSet" => money("20.00"),
          "totalTaxSet" => money("10.00"),
          "totalTipReceivedSet" => money("0.00"),
          "totalWeight" => 320,
          "transactions" => [{ "amountSet" => money("250.00") }],
          "customer" => {
            "id" => "gid://shopify/Customer/2",
            "firstName" => "Grace",
            "lastName" => "Hopper",
            "email" => "grace@example.com",
            "phone" => nil
          }
        }),
        JSON.generate({
          "__parentId" => order_id,
          "id" => "#{order_id}/LineItem/1",
          "sku" => "BULK-1",
          "title" => "Bulk Notebook",
          "variantTitle" => "Blue",
          "vendor" => "Bulk Vendor",
          "quantity" => 2,
          "currentQuantity" => 2,
          "originalTotalSet" => money("220.00")
        })
      ]
    end
  end

  class FakeFailingBulkShopifyClient < FakeShopifyClient
    def start_bulk_query(_shop_domain, _access_token, _query)
      raise "Shopify bulk query error: temporary Shopify failure"
    end
  end

  def build_app(onboarded:, order_count:)
    database_path = File.join(Dir.tmpdir, "send_invoice_test_#{Process.pid}_#{rand(1_000_000)}.sqlite3")
    root = File.expand_path("../..", __dir__)
    ENV["DATABASE_PATH"] = database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")

    config = SendInvoice::Configuration.load(root: root)
    database = SendInvoice::Database.new(config)
    SendInvoice::Migrator.new(database).run
    store = SendInvoice::Store.new(database)
    store.ensure_shop(SendInvoice::MockData::DEMO_SHOP_DOMAIN, {
      "shop_name" => SendInvoice::MockData::DEMO_SHOP_NAME,
      "onboarded" => onboarded
    })
    store.upsert_orders(SendInvoice::MockData.orders.first(order_count))

    shopify_client = SendInvoice::ShopifyClient.new(config)
    sync_engine = SendInvoice::SyncEngine.new(config: config, store: store, shopify_client: shopify_client)
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)

    [app, store, database_path]
  end

  def build_real_sync_engine(shopify_client = FakeShopifyClient.new)
    database_path = File.join(Dir.tmpdir, "send_invoice_real_sync_test_#{Process.pid}_#{rand(1_000_000)}.sqlite3")
    root = File.expand_path("../..", __dir__)
    ENV["DATABASE_PATH"] = database_path
    ENV["SHOPIFY_API_KEY"] = "test-key"
    ENV["SHOPIFY_API_SECRET"] = "test-secret"
    ENV["MOCK_MODE"] = "false"
    ENV.delete("AUTO_SYNC_ENABLED")

    config = SendInvoice::Configuration.load(root: root)
    database = SendInvoice::Database.new(config)
    SendInvoice::Migrator.new(database).run
    store = SendInvoice::Store.new(database)
    store.ensure_shop("sync-test.myshopify.com", {
      "shop_name" => "Sync Test",
      "access_token" => "shpat_test",
      "onboarded" => true
    })
    sync_engine = SendInvoice::SyncEngine.new(config: config, store: store, shopify_client: shopify_client)

    [store, sync_engine, shopify_client, database_path]
  end

  def wait_for_sync(store, shop_domain)
    40.times do
      latest = store.latest_sync_log(shop_domain)
      return latest if latest && latest["status"] != "running"

      sleep 0.05
    end

    flunk "Timed out waiting for sync to finish"
  end

  def wait_for_bulk_job(store, shop_domain)
    terminal = %w[completed failed fallback_completed fallback_failed]
    60.times do
      job = store.latest_bulk_sync_job(shop_domain)
      return job if job && terminal.include?(job["status"])

      sleep 0.05
    end

    flunk "Timed out waiting for bulk sync to finish"
  end

  def perform(app, method, path, query = {}, cookies = [])
    request = Request.new(method, path, query, {}, cookies, "")
    response = Response.new(nil, nil, [], {})
    app.handle(request, response)
    response
  end
end
