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

  private

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

  def perform(app, method, path, query = {}, cookies = [])
    request = Request.new(method, path, query, {}, cookies, "")
    response = Response.new(nil, nil, [], {})
    app.handle(request, response)
    response
  end
end
