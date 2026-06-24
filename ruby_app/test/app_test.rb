# frozen_string_literal: true

require "fileutils"
require "base64"
require "json"
require "minitest/autorun"
require "openssl"
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

  def test_orders_page_renders_selected_order_workspace
    app, store = build_app(onboarded: true, order_count: 12)
    order = store.orders(SendInvoice::MockData::DEMO_SHOP_DOMAIN, limit: 1)["orders"].first

    response = perform(app, "GET", "/orders", {
      "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN,
      "order_id" => order["id"]
    })

    assert_equal 200, response.status
    assert_includes response.body, "Order overview"
    assert_includes response.body, order["name"]
    assert_includes response.body, "Back to orders"
    assert_includes response.body, "View order"
  end

  def test_orders_page_shows_not_found_state_for_missing_order
    app, = build_app(onboarded: true, order_count: 12)

    response = perform(app, "GET", "/orders", {
      "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN,
      "order_id" => "gid://shopify/Order/missing"
    })

    assert_equal 200, response.status
    assert_includes response.body, "Order not found"
    assert_includes response.body, "We could not find that order in the synced data for this shop."
  end

  def test_invoice_templates_page_exposes_selected_template_preview_state
    app, = build_app(onboarded: true, order_count: 12)

    response = perform(app, "GET", "/invoice-templates", {
      "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN
    })

    assert_equal 200, response.status
    assert_includes response.body, 'data-preview-template'
    assert_includes response.body, 'data-template="classic"'
    assert_includes response.body, 'data-role="template-style-label"'
    assert_includes response.body, 'data-preview-style="accent_color"'
    assert_includes response.body, 'data-role="preview-line-items-body"'
    assert_includes response.body, 'data-template-choice="editorial"'
  end

  def test_queue_ops_page_renders_history_and_diagnostics
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    failed_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(failed_request_id, "permanent failure")
    completed_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")
    store.complete_async_job_request(completed_request_id)
    sync_log = store.create_sync_log(shop["shop_domain"], total_estimated: 10)
    store.complete_sync_log(sync_log["id"], total_estimated: 10)
    store.upsert_sync_state(shop["shop_domain"], {
      "last_order_updated_at" => "2026-06-16T12:00:00Z",
      "last_sync_type" => "incremental",
      "last_synced_at" => "2026-06-16T12:15:00Z"
    })
    store.create_bulk_sync_job(shop["shop_domain"], {
      "sync_log_id" => sync_log["id"],
      "shopify_bulk_operation_id" => "gid://shopify/BulkOperation/phase7",
      "sync_type" => "full",
      "status" => "completed",
      "imported_count" => 42
    })
    store.create_batch_log(shop["shop_domain"], {
      "batch_type" => "initial_3_days",
      "start_date" => "2026-06-14",
      "end_date" => "2026-06-16",
      "order_count" => 25,
      "batch_sequence" => 1,
      "priority" => "high",
      "status" => "completed"
    })
    store.create_batch_log(shop["shop_domain"], {
      "batch_type" => "remaining_6_months",
      "start_date" => "2026-05-01",
      "end_date" => "2026-06-13",
      "order_count" => 180,
      "batch_sequence" => 2,
      "priority" => "normal",
      "status" => "failed",
      "retry_count" => 1,
      "error_message" => "Shopify timeout"
    })

    response = perform(app, "GET", "/queue-ops", { "shop" => shop["shop_domain"], "status" => "all" }, cookies)

    assert_equal 200, response.status
    assert_includes response.body, "Queue Ops"
    assert_includes response.body, "Queue recovery and history"
    assert_includes response.body, "First-time sync batch visibility"
    assert_includes response.body, "remaining 6 months"
    assert_includes response.body, "Shopify timeout"
    assert_includes response.body, failed_request_id
    assert_includes response.body, completed_request_id
    assert_includes response.body, "Latest bulk job"
    assert_includes response.body, "Last order watermark"
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
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

  def test_bulk_finish_webhook_verifies_hmac_and_imports_once
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    shop = store.shop("sync-test.myshopify.com")
    sync_log = store.create_sync_log(shop["shop_domain"], total_estimated: 0)
    job = store.create_bulk_sync_job(shop["shop_domain"], {
      "sync_log_id" => sync_log["id"],
      "shopify_bulk_operation_id" => "gid://shopify/BulkOperation/1",
      "sync_type" => "full",
      "status" => "running"
    })
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({
      "admin_graphql_api_id" => job["shopify_bulk_operation_id"],
      "status" => "completed",
      "type" => "query"
    })
    headers = webhook_headers(body)

    first_response = perform(app, "POST", "/webhooks/bulk-operations-finish", {}, [], body, headers)
    assert_equal 200, first_response.status
    assert_equal true, JSON.parse(first_response.body)["accepted"]

    imported_job = wait_for_bulk_job(store, shop["shop_domain"])
    assert_equal "completed", imported_job["status"]
    assert_equal 1, imported_job["imported_count"]

    duplicate_response = perform(app, "POST", "/webhooks/bulk-operations-finish", {}, [], body, headers)
    assert_equal 200, duplicate_response.status
    sleep 0.05
    assert_equal 1, store.orders(shop["shop_domain"], limit: 10)["total"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_bulk_finish_webhook_rejects_invalid_hmac
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({ "admin_graphql_api_id" => "gid://shopify/BulkOperation/1" })
    headers = webhook_headers(body).merge("x-shopify-hmac-sha256" => "invalid")

    response = perform(app, "POST", "/webhooks/bulk-operations-finish", {}, [], body, headers)

    assert_equal 401, response.status
    assert_equal "Invalid webhook signature", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_app_uninstalled_webhook_schedules_deletion_for_mature_shop
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    shop_domain = "sync-test.myshopify.com"
    store.update_shop(shop_domain, "installed_at" => (Time.now.utc - (100 * 86_400)).iso8601)
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({ "id" => 1 })

    response = perform(app, "POST", "/webhooks/app-uninstalled", {}, [], body, webhook_headers(body, topic: "app/uninstalled"))

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    refute_nil payload["scheduledForDeletionAt"]

    shop = store.shop(shop_domain)
    assert_nil shop["access_token"]
    refute_nil shop["uninstalled_at"]
    refute_nil shop["scheduled_for_deletion_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_cleanup_uninstalled_shop_data_deletes_due_shop_records
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBulkShopifyClient.new)
    shop_domain = "sync-test.myshopify.com"
    store.update_shop(shop_domain, "installed_at" => (Time.now.utc - (100 * 86_400)).iso8601)
    store.upsert_orders([
      SendInvoice::MockData.orders.first.merge(
        "shop_domain" => shop_domain,
        "updated_at" => SendInvoice::MockData.orders.first["updated_at"] || SendInvoice::MockData.orders.first["created_at"],
        "synced_at" => Time.now.utc.iso8601
      )
    ])

    uninstalled_shop = sync_engine.mark_shop_uninstalled(shop_domain)
    due_time = Time.parse(uninstalled_shop["scheduled_for_deletion_at"]) + 1

    sync_engine.cleanup_uninstalled_shop_data(reference_time: due_time)

    assert_nil store.shop(shop_domain)
    assert_equal 0, store.orders(shop_domain, limit: 10)["total"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_app_uninstalled_webhook_does_not_schedule_recent_install_for_deletion
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    shop_domain = "sync-test.myshopify.com"
    store.update_shop(shop_domain, "installed_at" => (Time.now.utc - (20 * 86_400)).iso8601)
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({ "id" => 2 })

    response = perform(app, "POST", "/webhooks/app-uninstalled", {}, [], body, webhook_headers(body, topic: "app/uninstalled"))

    assert_equal 200, response.status
    assert_nil JSON.parse(response.body)["scheduledForDeletionAt"]

    shop = store.shop(shop_domain)
    refute_nil shop["uninstalled_at"]
    assert_nil shop["scheduled_for_deletion_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_orders_changed_webhook_triggers_incremental_sync_for_updated_orders
    client = FakeShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    shop_domain = "sync-test.myshopify.com"
    store.upsert_sync_state(shop_domain, {
      "last_order_updated_at" => "2026-06-11T10:30:00Z",
      "last_sync_type" => "incremental"
    })
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({ "id" => 123 })

    response = perform(app, "POST", "/webhooks/orders-changed", {}, [], body, webhook_headers(body, topic: "orders/updated"))

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal true, payload["accepted"]

    wait_for_sync(store, shop_domain)
    assert_includes client.calls.map { |call| call["query"] }, "updated_at:>=2026-06-11T10:30:00Z"
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_orders_changed_webhook_rejects_unexpected_topic
    client = FakeShopifyClient.new
    store, sync_engine, _shopify_client, database_path, config = build_real_sync_engine(client)
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: client)
    body = JSON.generate({ "id" => 456 })

    response = perform(app, "POST", "/webhooks/orders-changed", {}, [], body, webhook_headers(body, topic: "orders/cancelled"))

    assert_equal 401, response.status
    assert_equal "Unexpected webhook topic", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_trigger_queues_incremental_request_when_db_queue_backend_enabled
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger(shop: shop, type: "incremental")

    assert_equal true, result["started"]
    assert_equal "queued", result["mode"]
    refute_nil result["requestId"]

    request = store.async_job_request(result["requestId"])
    assert_equal "sync.incremental", request["request_type"]
    assert_equal "queued", request["status"]
    assert_equal shop["shop_domain"], request["payload"]["shop_domain"]
    assert_equal "incremental", request["payload"]["type"]
    assert_nil store.latest_sync_log(shop["shop_domain"])
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_trigger_rejects_duplicate_queued_incremental_request_when_db_queue_backend_enabled
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    first = sync_engine.trigger(shop: shop, type: "incremental")
    second = sync_engine.trigger(shop: shop, type: "incremental")

    assert_equal true, first["started"]
    assert_equal false, second["started"]
    assert_equal "Sync already queued or in progress", second["message"]

    request = store.latest_active_async_job_request(shop["shop_domain"], request_types: ["sync.incremental"])
    assert_equal "queued", request["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_status_reports_queued_when_db_queue_request_pending
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    sync_engine.trigger_first_time(shop: shop)
    status = sync_engine.status(shop["shop_domain"])

    assert_equal "queued", status["status"]
    assert_equal "sync.first_time", status["queuedType"]
    refute_nil status["queuedAt"]
    refute_nil status["requestId"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_status_returns_to_queued_after_failed_async_request_is_retried
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    first = sync_engine.trigger(shop: shop, type: "full")
    first_request_id = first.fetch("requestId")
    store.fail_async_job_request(first_request_id, "temporary failure")

    second = sync_engine.trigger(shop: shop, type: "incremental")
    second_request_id = second.fetch("requestId")
    store.claim_async_job_request(second_request_id, worker_id: "worker-1")
    store.mark_async_job_request_dispatched(second_request_id)
    store.mark_async_job_request_running(second_request_id)
    failed_log = store.create_sync_log(shop["shop_domain"], total_estimated: 0)
    store.fail_sync_log(failed_log["id"], "sync failed")
    store.fail_async_job_request(second_request_id, "sync failed")

    retried = store.retry_failed_async_job_request(second_request_id)
    status = sync_engine.status(shop["shop_domain"])

    assert_equal "queued", retried["status"]
    assert_equal "queued", status["status"]
    assert_equal second_request_id, status["requestId"]
    refute_nil status["queuedAt"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_handle_bulk_finish_queues_request_when_db_queue_backend_enabled
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, = build_real_sync_engine(client, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")
    sync_log = store.create_sync_log(shop["shop_domain"], total_estimated: 0)
    store.create_bulk_sync_job(shop["shop_domain"], {
      "sync_log_id" => sync_log["id"],
      "shopify_bulk_operation_id" => "gid://shopify/BulkOperation/1",
      "sync_type" => "full",
      "status" => "running"
    })

    accepted = sync_engine.handle_bulk_finish(shop: shop, operation_id: "gid://shopify/BulkOperation/1")

    assert_equal true, accepted
    request = store.latest_active_async_job_request(shop["shop_domain"], request_types: ["sync.bulk_finish"])
    assert_equal "queued", request["status"]
    assert_equal "gid://shopify/BulkOperation/1", request["payload"]["operation_id"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_failed_async_job_request_requeues_request
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger(shop: shop, type: "full")
    request_id = result.fetch("requestId")
    store.fail_async_job_request(request_id, "temporary failure")

    retried = store.retry_failed_async_job_request(request_id)

    refute_nil retried
    assert_equal "queued", retried["status"]
    assert_nil retried["error_message"]
    assert_nil retried["claimed_by"]
    assert_nil retried["claimed_at"]
    assert_nil retried["dispatched_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_requeue_async_job_request_clears_dispatched_timestamp
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger(shop: shop, type: "full")
    request_id = result.fetch("requestId")
    store.mark_async_job_request_dispatched(request_id)

    requeued = store.requeue_async_job_request(request_id, error_message: "temporary failure")

    assert_equal "queued", requeued["status"]
    assert_equal "temporary failure", requeued["error_message"]
    assert_nil requeued["claimed_by"]
    assert_nil requeued["claimed_at"]
    assert_nil requeued["dispatched_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_delete_async_job_request_removes_failed_request
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger(shop: shop, type: "full")
    request_id = result.fetch("requestId")
    store.fail_async_job_request(request_id, "permanent failure")

    deleted = store.delete_async_job_request(request_id, allowed_statuses: %w[failed])

    assert_equal true, deleted
    assert_nil store.async_job_request(request_id)
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_latest_failed_async_job_request_requeues_most_recent_failed_request
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    first_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(first_request_id, "older failure")
    second_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")
    store.fail_async_job_request(second_request_id, "newer failure")

    retried = store.retry_latest_failed_async_job_request(shop_domain: shop["shop_domain"])

    assert_equal second_request_id, retried["id"]
    assert_equal "queued", retried["status"]
    assert_nil retried["error_message"]
    assert_equal "failed", store.async_job_request(first_request_id)["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_all_failed_async_job_requests_requeues_only_failed_requests_for_shop
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    shop = store.shop("sync-test.myshopify.com")

    failed_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(failed_request_id, "temporary failure")
    queued_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")

    retried_count = store.retry_all_failed_async_job_requests(shop_domain: shop["shop_domain"])

    assert_equal 1, retried_count
    assert_equal "queued", store.async_job_request(failed_request_id)["status"]
    assert_nil store.async_job_request(failed_request_id)["error_message"]
    assert_equal "queued", store.async_job_request(queued_request_id)["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_async_requests_api_lists_failed_requests_for_current_shop
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    failed_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(failed_request_id, "permanent failure")
    sync_engine.trigger(shop: shop, type: "incremental")

    response = perform(app, "GET", "/api/async-requests", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal ["failed"], payload["statuses"]
    assert_equal 1, payload["requests"].length
    assert_equal failed_request_id, payload["requests"].first["id"]
    assert_equal "failed", payload["requests"].first["status"]
    assert_equal true, payload["requests"].first["canRetry"]
    assert_equal true, payload["requests"].first["canDelete"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_async_request_api_requeues_failed_request
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(request_id, "temporary failure")

    response = perform(app, "POST", "/api/async-requests/#{request_id}/retry", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal true, payload["retried"]
    assert_equal "queued", payload.dig("request", "status")
    assert_nil payload.dig("request", "errorMessage")
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_latest_failed_async_request_api_requeues_most_recent_failed_request
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    first_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(first_request_id, "older failure")
    second_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")
    store.fail_async_job_request(second_request_id, "newer failure")

    response = perform(app, "POST", "/api/async-requests/retry-latest-failed", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal true, payload["retried"]
    assert_equal second_request_id, payload.dig("request", "id")
    assert_equal "queued", payload.dig("request", "status")
    assert_equal "failed", store.async_job_request(first_request_id)["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_all_failed_async_requests_api_requeues_failed_requests_for_current_shop
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    first_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.fail_async_job_request(first_request_id, "temporary failure")
    second_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")
    store.fail_async_job_request(second_request_id, "permanent failure")

    response = perform(app, "POST", "/api/async-requests/retry-all-failed", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal true, payload["retried"]
    assert_equal 2, payload["retriedCount"]
    assert_equal "queued", store.async_job_request(first_request_id)["status"]
    assert_equal "queued", store.async_job_request(second_request_id)["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_delete_async_request_api_removes_completed_request
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.complete_async_job_request(request_id)

    response = perform(app, "DELETE", "/api/async-requests/#{request_id}", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal true, payload["deleted"]
    assert_equal request_id, payload["requestId"]
    assert_nil store.async_job_request(request_id)
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_async_request_api_rejects_non_failed_request
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")

    response = perform(app, "POST", "/api/async-requests/#{request_id}/retry", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 409, response.status
    assert_equal "Only failed async job requests can be retried", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_latest_failed_async_request_api_returns_not_found_when_shop_has_no_failed_requests
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    response = perform(app, "POST", "/api/async-requests/retry-latest-failed", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 404, response.status
    assert_equal "No failed async job requests found", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_retry_all_failed_async_requests_api_returns_not_found_when_shop_has_no_failed_requests
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    response = perform(app, "POST", "/api/async-requests/retry-all-failed", { "shop" => shop["shop_domain"] }, cookies)

    assert_equal 404, response.status
    assert_equal "No failed async job requests found", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_queue_ops_retry_all_failed_action_requeues_failed_requests
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    first_request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    second_request_id = sync_engine.trigger(shop: shop, type: "incremental").fetch("requestId")
    store.fail_async_job_request(first_request_id, "temporary failure")
    store.fail_async_job_request(second_request_id, "permanent failure")

    response = perform(
      app,
      "POST",
      "/queue-ops/retry-all-failed",
      { "shop" => shop["shop_domain"] },
      cookies,
      "",
      { "referer" => "http://example.test/queue-ops?shop=#{shop['shop_domain']}&status=all" }
    )

    assert_equal 302, response.status
    assert_equal "/queue-ops?shop=#{shop['shop_domain']}&status=all", response["Location"]
    assert_equal "queued", store.async_job_request(first_request_id)["status"]
    assert_equal "queued", store.async_job_request(second_request_id)["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_queue_ops_delete_request_action_removes_completed_request
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])

    request_id = sync_engine.trigger(shop: shop, type: "full").fetch("requestId")
    store.complete_async_job_request(request_id)

    response = perform(
      app,
      "POST",
      "/queue-ops/requests/#{request_id}/delete",
      { "shop" => shop["shop_domain"] },
      cookies,
      "",
      { "referer" => "http://example.test/queue-ops?shop=#{shop['shop_domain']}&status=all" }
    )

    assert_equal 302, response.status
    assert_equal "/queue-ops?shop=#{shop['shop_domain']}&status=all", response["Location"]
    assert_nil store.async_job_request(request_id)
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_queue_ops_retry_batch_action_marks_failed_batch_pending_and_queues_first_time_sync
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")
    cookies = admin_session_cookies(store, config, shop["shop_domain"])
    batch = store.create_batch_log(shop["shop_domain"], {
      "batch_type" => "remaining_6_months",
      "start_date" => "2026-05-01",
      "end_date" => "2026-06-13",
      "order_count" => 180,
      "batch_sequence" => 2,
      "priority" => "normal",
      "status" => "failed",
      "retry_count" => 1,
      "error_message" => "Shopify timeout"
    })

    response = perform(
      app,
      "POST",
      "/queue-ops/batches/#{batch['id']}/retry",
      { "shop" => shop["shop_domain"] },
      cookies,
      "",
      { "referer" => "http://example.test/queue-ops?shop=#{shop['shop_domain']}&status=all" }
    )

    retried_batch = store.batch_log(batch["id"])
    queued_request = store.latest_active_async_job_request(shop["shop_domain"], request_types: ["sync.first_time"])

    assert_equal 302, response.status
    assert_equal "/queue-ops?shop=#{shop['shop_domain']}&status=all", response["Location"]
    assert_equal "pending", retried_batch["status"]
    assert_nil retried_batch["error_message"]
    assert_equal "queued", queued_request["status"]
    assert_equal "sync.first_time", queued_request["request_type"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_dashboard_hides_admin_queue_nav_without_admin_session
    app, = build_app(onboarded: true, order_count: 12)

    response = perform(app, "GET", "/dashboard", { "shop" => SendInvoice::MockData::DEMO_SHOP_DOMAIN })

    assert_equal 200, response.status
    refute_includes response.body, ">Queue Ops<"
    refute_includes response.body, ">Admin<"
  end

  def test_async_requests_api_rejects_non_admin_session
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")

    response = perform(app, "GET", "/api/async-requests", { "shop" => shop["shop_domain"] })

    assert_equal 401, response.status
    assert_equal "Unauthorized: missing admin app session", JSON.parse(response.body)["error"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_queue_ops_page_redirects_without_admin_session
    store, sync_engine, shopify_client, database_path, config = build_real_sync_engine(FakeShopifyClient.new, "BACKGROUND_BACKEND" => "db_queue")
    app = SendInvoice::App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)
    shop = store.shop("sync-test.myshopify.com")

    response = perform(app, "GET", "/queue-ops", { "shop" => shop["shop_domain"] })

    assert_equal 302, response.status
    assert_equal "/onboarding", response["Location"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_run_sync_command_executes_synchronously
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine
    shop = store.shop("sync-test.myshopify.com")

    prepared = sync_engine.prepare_sync_command(shop: shop, type: "full", skip_rate_limit: true)
    assert_equal true, prepared["started"]

    sync_engine.run_sync_command(
      shop: shop,
      type: "full",
      sync_log_id: prepared["syncLogId"],
      last_order_updated_at: prepared["lastOrderUpdatedAt"]
    )

    orders = store.orders(shop["shop_domain"], limit: 10)["orders"]
    assert_equal 2, orders.length
    assert_equal "completed", store.latest_sync_log(shop["shop_domain"])["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_prepare_sync_command_rejects_duplicate_inflight_incremental_sync
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine
    shop = store.shop("sync-test.myshopify.com")

    first = sync_engine.prepare_sync_command(shop: shop, type: "incremental", skip_rate_limit: true)
    second = sync_engine.prepare_sync_command(shop: shop, type: "incremental", skip_rate_limit: true)

    assert_equal true, first["started"]
    assert_equal false, second["started"]
    assert_equal "Sync already in progress", second["message"]

    sync_engine.run_sync_command(
      shop: shop,
      type: "incremental",
      sync_log_id: first["syncLogId"],
      last_order_updated_at: first["lastOrderUpdatedAt"],
      command_key: first["commandKey"],
      lock_owner_id: first["lockOwnerId"]
    )

    third = sync_engine.prepare_sync_command(shop: shop, type: "incremental", skip_rate_limit: true)
    assert_equal true, third["started"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_run_first_time_sync_command_executes_synchronously
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBatchShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    prepared = sync_engine.prepare_first_time_sync_command(shop: shop)
    assert_equal true, prepared["started"]
    assert_equal false, prepared["batchesPlanned"]

    sync_engine.run_first_time_sync_command(
      shop: shop,
      sync_log_id: prepared["syncLogId"],
      batches_planned: prepared["batchesPlanned"]
    )

    summary = store.batch_summary(shop["shop_domain"])
    assert_equal "full_6_months_sync_completed", summary["status"]
    assert_equal "completed", store.latest_sync_log(shop["shop_domain"])["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_prepare_first_time_sync_command_rejects_duplicate_inflight_first_time_sync
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBatchShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    first = sync_engine.prepare_first_time_sync_command(shop: shop)
    second = sync_engine.prepare_first_time_sync_command(shop: shop)

    assert_equal true, first["started"]
    assert_equal false, second["started"]
    assert_equal "Sync already in progress", second["message"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_prepare_first_time_sync_command_rejects_when_another_sync_is_running
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBatchShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")
    store.create_sync_log(shop["shop_domain"], total_estimated: 0)

    prepared = sync_engine.prepare_first_time_sync_command(shop: shop)

    assert_equal false, prepared["started"]
    assert_equal "Sync already in progress", prepared["message"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_run_bulk_finish_command_executes_synchronously
    client = FakeBulkShopifyClient.new
    store, sync_engine, _shopify_client, database_path, = build_real_sync_engine(client)
    shop = store.shop("sync-test.myshopify.com")
    sync_log = store.create_sync_log(shop["shop_domain"], total_estimated: 0)
    store.create_bulk_sync_job(shop["shop_domain"], {
      "sync_log_id" => sync_log["id"],
      "shopify_bulk_operation_id" => "gid://shopify/BulkOperation/1",
      "sync_type" => "full",
      "status" => "running"
    })

    result = sync_engine.run_bulk_finish_command(shop: shop, operation_id: "gid://shopify/BulkOperation/1")

    assert_equal true, result
    job = store.latest_bulk_sync_job(shop["shop_domain"])
    assert_equal "completed", job["status"]
    assert_equal 1, job["imported_count"]
    assert_equal "completed", store.latest_sync_log(shop["shop_domain"])["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_prepare_bulk_sync_command_rejects_duplicate_inflight_bulk_sync
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBulkShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    first = sync_engine.prepare_bulk_sync_command(shop: shop, type: "full")
    second = sync_engine.prepare_bulk_sync_command(shop: shop, type: "full")

    assert_equal true, first["started"]
    assert_equal false, second["started"]
    assert_equal "Sync already in progress", second["message"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_run_bulk_sync_command_releases_lock_after_failure
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeFailingBulkShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    prepared = sync_engine.prepare_bulk_sync_command(shop: shop, type: "full")
    assert_equal true, prepared["started"]

    assert_raises RuntimeError do
      sync_engine.run_bulk_sync_command(
        shop: shop,
        type: "full",
        sync_log_id: prepared["syncLogId"],
        bulk_job_id: prepared["bulkJobId"],
        command_key: prepared["commandKey"],
        lock_owner_id: prepared["lockOwnerId"]
      )
    end

    next_attempt = sync_engine.prepare_bulk_sync_command(shop: shop, type: "full")
    assert_equal true, next_attempt["started"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_reinstall_clears_pending_data_deletion_state
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBulkShopifyClient.new)
    shop_domain = "sync-test.myshopify.com"
    store.update_shop(shop_domain, "installed_at" => (Time.now.utc - (100 * 86_400)).iso8601)
    sync_engine.mark_shop_uninstalled(shop_domain)

    store.ensure_shop(shop_domain, {
      "shop_name" => "Sync Test",
      "access_token" => "shpat_reinstalled",
      "scopes" => "read_orders"
    })

    shop = store.shop(shop_domain)
    assert_equal "shpat_reinstalled", shop["access_token"]
    assert_nil shop["uninstalled_at"]
    assert_nil shop["scheduled_for_deletion_at"]
    assert_nil shop["data_deletion_started_at"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_webhook_subscription_is_updated_when_host_changes
    client = FakeWebhookSubscriptionClient.new([
      {
        "id" => "gid://shopify/WebhookSubscription/1",
        "topic" => "BULK_OPERATIONS_FINISH",
        "uri" => "https://old.example/webhooks/bulk-operations-finish"
      }
    ])

    subscription = client.ensure_webhook_subscription(
      "sync-test.myshopify.com",
      "shpat_test",
      topic: "BULK_OPERATIONS_FINISH",
      uri: "https://new.example/webhooks/bulk-operations-finish"
    )

    assert_equal "https://new.example/webhooks/bulk-operations-finish", subscription["uri"]
    assert client.calls.any? { |call| call["query"].include?("webhookSubscriptionUpdate") }
    refute client.calls.any? { |call| call["query"].include?("webhookSubscriptionCreate") }
  end

  def test_first_time_sync_creates_initial_and_remaining_batches
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeBatchShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger_first_time(shop: shop)
    assert_equal true, result["started"]

    wait_for_batch_summary(store, shop["shop_domain"], "full_6_months_sync_completed")
    batches = store.batch_logs(shop["shop_domain"])
    initial_batches = batches.select { |batch| batch["batch_type"] == "initial_3_days" }
    remaining_batches = batches.select { |batch| batch["batch_type"] == "remaining_6_months" }

    refute_empty initial_batches
    refute_empty remaining_batches
    assert initial_batches.all? { |batch| batch["priority"] == "high" }
    assert remaining_batches.all? { |batch| batch["priority"] == "normal" }
    assert batches.all? { |batch| batch["order_count"] <= 1000 }
    assert batches.all? { |batch| batch["status"] == "completed" }
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  def test_first_time_sync_splits_single_day_over_one_thousand_orders
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeHighVolumeDayShopifyClient.new)
    shop = store.shop("sync-test.myshopify.com")

    result = sync_engine.trigger_first_time(shop: shop)
    assert_equal true, result["started"]

    wait_for_batch_summary(store, shop["shop_domain"], "full_6_months_sync_completed")
    split_batches = store.batch_logs(shop["shop_domain"]).select { |batch| batch["batch_type"] == "single_day_split" }

    assert_equal 4, split_batches.length
    assert_equal [1000, 1000, 1000, 200], split_batches.map { |batch| batch["order_count"] }
    assert split_batches.all? { |batch| batch["status"] == "completed" }
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  def test_mock_first_time_sync_uses_batch_logs_and_imports_recent_mock_orders
    store, sync_engine, database_path = build_mock_sync_engine
    shop = store.shop(SendInvoice::MockData::DEMO_SHOP_DOMAIN)

    result = sync_engine.trigger_first_time(shop: shop)
    assert_equal true, result["started"]

    wait_for_batch_summary(store, shop["shop_domain"], "full_6_months_sync_completed")
    batches = store.batch_logs(shop["shop_domain"])
    orders = store.orders(shop["shop_domain"], limit: 200)["orders"]
    planned_order_count = batches.sum { |batch| batch["order_count"] }

    refute_empty batches
    assert batches.any? { |batch| batch["batch_type"] == "initial_3_days" && batch["priority"] == "high" }
    assert batches.any? { |batch| batch["batch_type"] == "remaining_6_months" && batch["priority"] == "normal" }
    assert batches.all? { |batch| batch["order_count"] <= 1000 }
    assert_equal planned_order_count, orders.length
    assert_equal "completed", store.latest_sync_log(shop["shop_domain"])["status"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
  end

  def test_incremental_sync_fetches_all_line_items_beyond_first_hundred
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeLineItemPaginationShopifyClient.new)
    shop_domain = "sync-test.myshopify.com"
    shop = store.shop(shop_domain)

    result = sync_engine.trigger(shop: shop, type: "full")
    assert_equal true, result["started"]

    wait_for_sync(store, shop_domain)
    order = store.orders(shop_domain, limit: 10)["orders"].first

    assert_equal "#3001", order["name"]
    assert_equal 150, order["line_items"].length
    assert_equal "LINE-150", order["line_items"].last["sku"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  def test_bulk_sync_imports_all_line_items_beyond_first_hundred
    store, sync_engine, _shopify_client, database_path = build_real_sync_engine(FakeLargeBulkLineItemsShopifyClient.new)
    shop_domain = "sync-test.myshopify.com"
    shop = store.shop(shop_domain)

    result = sync_engine.trigger_bulk(shop: shop, type: "full")
    assert_equal true, result["started"]

    wait_for_sync(store, shop_domain)
    job = wait_for_bulk_job(store, shop_domain)
    order = store.orders(shop_domain, limit: 10)["orders"].first

    assert_equal "completed", job["status"]
    assert_equal "#4001", order["name"]
    assert_equal 150, order["line_items"].length
    assert_equal "BULK-LINE-150", order["line_items"].last["sku"]
  ensure
    FileUtils.rm_f(database_path) if database_path
    clear_shopify_env
  end

  private

  class FakeShopifyClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def valid_shop_domain?(shop)
      shop.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9-]*\.myshopify\.com\z/)
    end

    def verify_webhook_hmac(raw_body, provided_hmac)
      digest = OpenSSL::HMAC.digest("sha256", "test-secret", raw_body)
      provided = Base64.strict_decode64(provided_hmac)
      provided == digest
    rescue ArgumentError
      false
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
                  "pageInfo" => {
                    "hasNextPage" => false,
                    "endCursor" => nil
                  },
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

  class FakeLineItemPaginationShopifyClient < FakeShopifyClient
    def graph_ql(_shop_domain, _access_token, query, variables = {})
      if query.include?("query OrderLineItems")
        cursor = variables["cursor"]
        page = cursor == "line-page-2" ? second_line_item_page : first_line_item_page
        return { "order" => { "id" => "gid://shopify/Order/3001", "lineItems" => page } }
      end

      @calls << variables
      {
        "orders" => {
          "pageInfo" => {
            "hasNextPage" => false,
            "endCursor" => nil
          },
          "edges" => [
            {
              "node" => {
                "id" => "gid://shopify/Order/3001",
                "name" => "#3001",
                "createdAt" => "2026-06-15T08:00:00Z",
                "updatedAt" => "2026-06-15T10:00:00Z",
                "fullyPaid" => true,
                "displayFinancialStatus" => "PAID",
                "displayFulfillmentStatus" => "FULFILLED",
                "totalDiscountsSet" => money("0.00"),
                "totalPriceSet" => money("500.00"),
                "totalRefundedSet" => money("0.00"),
                "totalShippingPriceSet" => money("25.00"),
                "totalTaxSet" => money("15.00"),
                "totalTipReceivedSet" => money("0.00"),
                "totalWeight" => 400,
                "transactions" => [{ "amountSet" => money("500.00") }],
                "customer" => {
                  "id" => "gid://shopify/Customer/3",
                  "firstName" => "Linus",
                  "lastName" => "Torvalds",
                  "email" => "linus@example.com",
                  "phone" => nil
                },
                "lineItems" => first_line_item_page
              }
            }
          ]
        }
      }
    end

    private

    def first_line_item_page
      {
        "pageInfo" => {
          "hasNextPage" => true,
          "endCursor" => "line-page-2"
        },
        "edges" => build_line_item_edges(1, 100)
      }
    end

    def second_line_item_page
      {
        "pageInfo" => {
          "hasNextPage" => false,
          "endCursor" => nil
        },
        "edges" => build_line_item_edges(101, 150)
      }
    end

    def build_line_item_edges(start_index, finish_index)
      (start_index..finish_index).map do |index|
        {
          "node" => {
            "id" => "gid://shopify/Order/3001/LineItem/#{index}",
            "sku" => format("LINE-%03d", index),
            "title" => "Item #{index}",
            "variantTitle" => "Default",
            "vendor" => "Long Order Vendor",
            "quantity" => 1,
            "currentQuantity" => 1,
            "originalTotalSet" => money("3.00")
          }
        }
      end
    end
  end

  class FakeLargeBulkLineItemsShopifyClient < FakeBulkShopifyClient
    private

    def bulk_lines
      order_id = "gid://shopify/Order/4001"
      order = JSON.generate({
        "id" => order_id,
        "name" => "#4001",
        "createdAt" => "2026-06-16T10:00:00Z",
        "updatedAt" => "2026-06-16T12:00:00Z",
        "fullyPaid" => true,
        "displayFinancialStatus" => "PAID",
        "displayFulfillmentStatus" => "FULFILLED",
        "totalDiscountsSet" => money("0.00"),
        "totalPriceSet" => money("750.00"),
        "totalRefundedSet" => money("0.00"),
        "totalShippingPriceSet" => money("30.00"),
        "totalTaxSet" => money("20.00"),
        "totalTipReceivedSet" => money("0.00"),
        "totalWeight" => 500,
        "transactions" => [{ "amountSet" => money("750.00") }],
        "customer" => {
          "id" => "gid://shopify/Customer/4",
          "firstName" => "Margaret",
          "lastName" => "Hamilton",
          "email" => "margaret@example.com",
          "phone" => nil
        }
      })

      line_items = (1..150).map do |index|
        JSON.generate({
          "__parentId" => order_id,
          "id" => "#{order_id}/LineItem/#{index}",
          "sku" => format("BULK-LINE-%03d", index),
          "title" => "Bulk Item #{index}",
          "variantTitle" => "Default",
          "vendor" => "Bulk Overflow Vendor",
          "quantity" => 1,
          "currentQuantity" => 1,
          "originalTotalSet" => money("5.00")
        })
      end

      [order] + line_items
    end
  end

  class FakeFailingBulkShopifyClient < FakeShopifyClient
    def start_bulk_query(_shop_domain, _access_token, _query)
      raise "Shopify bulk query error: temporary Shopify failure"
    end
  end

  class FakeWebhookSubscriptionClient < SendInvoice::ShopifyClient
    attr_reader :calls

    def initialize(existing)
      @existing = existing
      @calls = []
    end

    def graph_ql(_shop_domain, _access_token, query, variables = {})
      @calls << { "query" => query, "variables" => variables }

      if query.include?("query WebhookSubscriptions")
        { "webhookSubscriptions" => { "nodes" => @existing } }
      elsif query.include?("webhookSubscriptionUpdate")
        {
          "webhookSubscriptionUpdate" => {
            "webhookSubscription" => {
              "id" => variables["id"],
              "topic" => "BULK_OPERATIONS_FINISH",
              "uri" => variables.dig("subscription", "uri")
            },
            "userErrors" => []
          }
        }
      else
        raise "Unexpected GraphQL query"
      end
    end
  end

  class FakeBatchShopifyClient < FakeShopifyClient
    def order_count(_shop_domain, _access_token, query)
      start_time, = extract_created_range(query)
      offset = (Time.now.utc.to_date - start_time.to_date).to_i
      {
        0 => 150,
        1 => 200,
        2 => 300,
        4 => 250,
        5 => 220,
        6 => 180
      }.fetch(offset, 0)
    end

    private

    def extract_created_range(query)
      [
        Time.parse(query[/created_at:>=([^ ]+)/, 1]),
        Time.parse(query[/created_at:<([^ ]+)/, 1])
      ]
    end
  end

  class FakeHighVolumeDayShopifyClient < FakeBatchShopifyClient
    def order_count(_shop_domain, _access_token, query)
      start_time, = send(:extract_created_range, query)
      offset = (Time.now.utc.to_date - start_time.to_date).to_i
      offset.zero? ? 3200 : 0
    end
  end

  def build_app(onboarded:, order_count:)
    database_path = File.join(Dir.tmpdir, "send_invoice_test_#{Process.pid}_#{rand(1_000_000)}.sqlite3")
    root = File.expand_path("../..", __dir__)
    ENV["DATABASE_PATH"] = database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
    ENV.delete("BACKGROUND_BACKEND")

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

  def build_real_sync_engine(shopify_client = FakeShopifyClient.new, env_overrides = {})
    database_path = File.join(Dir.tmpdir, "send_invoice_real_sync_test_#{Process.pid}_#{rand(1_000_000)}.sqlite3")
    root = File.expand_path("../..", __dir__)
    ENV["DATABASE_PATH"] = database_path
    ENV["SHOPIFY_API_KEY"] = "test-key"
    ENV["SHOPIFY_API_SECRET"] = "test-secret"
    ENV["MOCK_MODE"] = "false"
    ENV.delete("AUTO_SYNC_ENABLED")
    ENV.delete("BACKGROUND_BACKEND")
    env_overrides.each { |key, value| ENV[key] = value }

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

    [store, sync_engine, shopify_client, database_path, config]
  end

  def build_mock_sync_engine
    database_path = File.join(Dir.tmpdir, "send_invoice_mock_sync_test_#{Process.pid}_#{rand(1_000_000)}.sqlite3")
    root = File.expand_path("../..", __dir__)
    ENV["DATABASE_PATH"] = database_path
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV["MOCK_MODE"] = "true"
    ENV.delete("BACKGROUND_BACKEND")

    config = SendInvoice::Configuration.load(root: root)
    database = SendInvoice::Database.new(config)
    SendInvoice::Migrator.new(database).run
    store = SendInvoice::Store.new(database)
    store.ensure_shop(SendInvoice::MockData::DEMO_SHOP_DOMAIN, {
      "shop_name" => SendInvoice::MockData::DEMO_SHOP_NAME,
      "onboarded" => true
    })
    shopify_client = SendInvoice::ShopifyClient.new(config)
    sync_engine = SendInvoice::SyncEngine.new(config: config, store: store, shopify_client: shopify_client)

    [store, sync_engine, database_path]
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

  def wait_for_batch_summary(store, shop_domain, status)
    100.times do
      summary = store.batch_summary(shop_domain)
      return summary if summary["status"] == status

      sleep 0.05
    end

    flunk "Timed out waiting for batch sync status #{status}"
  end

  def webhook_headers(body, topic: "bulk_operations/finish", shop_domain: "sync-test.myshopify.com")
    digest = OpenSSL::HMAC.digest("sha256", "test-secret", body)
    {
      "x-shopify-hmac-sha256" => Base64.strict_encode64(digest),
      "x-shopify-topic" => topic,
      "x-shopify-shop-domain" => shop_domain,
      "x-shopify-webhook-id" => "webhook-test-id"
    }
  end

  def admin_session_cookies(store, config, shop_domain)
    session_id = SecureRandom.hex(24)
    store.save_session(session_id, shop_domain, {
      "shop_domain" => shop_domain,
      "admin_shop_domain" => shop_domain,
      "queue_ops_admin_granted" => true
    })
    [WEBrick::Cookie.new(config.session_cookie_name, session_id)]
  end

  def clear_shopify_env
    ENV.delete("SHOPIFY_API_KEY")
    ENV.delete("SHOPIFY_API_SECRET")
    ENV.delete("MOCK_MODE")
    ENV.delete("BACKGROUND_BACKEND")
  end

  def perform(app, method, path, query = {}, cookies = [], body = "", headers = {})
    request = Request.new(method, path, query, headers, cookies, body)
    response = Response.new(nil, nil, [], {})
    app.handle(request, response)
    response
  end
end
