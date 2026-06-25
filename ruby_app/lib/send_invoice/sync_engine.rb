# frozen_string_literal: true

require "json"
require "date"
require "thread"
require "time"

module SendInvoice
  class SyncEngine
    RATE_LIMIT_SECONDS = 300
    BULK_POLL_SECONDS = 5
    UNINSTALL_RETENTION_MONTHS = 3
    UNINSTALL_DELETION_DELAY_SECONDS = 48 * 60 * 60
    FIRST_TIME_MONTHS = 6
    INITIAL_SYNC_DAYS = 3
    MAX_BATCH_ORDERS = 1_000

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
                pageInfo {
                  hasNextPage
                  endCursor
                }
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

    ORDER_LINE_ITEMS_QUERY = <<~GRAPHQL
      query OrderLineItems($id: ID!, $cursor: String) {
        order(id: $id) {
          id
          lineItems(first: 100, after: $cursor) {
            pageInfo {
              hasNextPage
              endCursor
            }
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
      @cleanup_thread = nil
    end

    def trigger(shop:, type: "incremental", skip_rate_limit: false)
      return enqueue_sync_request(shop: shop, type: type, skip_rate_limit: skip_rate_limit) if @config.db_queue_backend?

      prepared = prepare_sync_command(shop: shop, type: type, skip_rate_limit: skip_rate_limit)
      return prepared unless prepared["started"]

      launch_async do
        run_sync_command(
          shop: shop,
          type: type,
          sync_log_id: prepared.fetch("syncLogId"),
          last_order_updated_at: prepared["lastOrderUpdatedAt"]
        )
      end

      prepared.slice("started", "syncLogId")
    end

    def prepare_sync_command(shop:, type: "incremental", skip_rate_limit: false)
      shop_domain = shop.fetch("shop_domain")
      command_key = sync_command_key(type)
      owner_id = SecureRandom.uuid
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?

      if type == "incremental" && !skip_rate_limit
        limited_for = rate_limited_for(shop_domain)
        return { "started" => false, "message" => "Rate limited. Try again in #{limited_for}s." } if limited_for
      end
      return { "started" => false, "message" => "Sync already queued or in progress" } unless @store.claim_sync_command_lock(shop_domain, command_key, owner_id: owner_id)

      sync_state = type == "incremental" ? @store.sync_state(shop_domain) : nil
      last_order_updated_at = sync_state && sync_state["last_order_updated_at"]
      total_estimated = @config.mock_mode? ? filtered_mock_orders(last_order_updated_at).length : 0
      sync_log = @store.create_sync_log(shop_domain, total_estimated: total_estimated)
      touch_rate_limit(shop_domain) if type == "incremental" && !skip_rate_limit

      {
        "started" => true,
        "syncLogId" => sync_log["id"],
        "lastOrderUpdatedAt" => last_order_updated_at,
        "commandKey" => command_key,
        "lockOwnerId" => owner_id
      }
    rescue StandardError
      @store.release_sync_command_lock(shop_domain, command_key, owner_id: owner_id) if shop_domain && command_key && owner_id
      raise
    end

    def run_sync_command(shop:, type:, sync_log_id:, last_order_updated_at: nil, command_key: sync_command_key(type), lock_owner_id: nil)
      if @config.mock_mode?
        run_mock_sync(sync_log_id, shop.fetch("shop_domain"), last_order_updated_at, type)
      else
        run_shopify_sync(sync_log_id, shop, last_order_updated_at, type)
      end
    rescue StandardError => e
      @store.fail_sync_log(sync_log_id, e.message)
      raise
    ensure
      @store.release_sync_command_lock(shop.fetch("shop_domain"), command_key, owner_id: lock_owner_id) if lock_owner_id
    end

    def trigger_bulk(shop:, type: "full")
      return enqueue_bulk_sync_request(shop: shop, type: type) if @config.db_queue_backend?

      prepared = prepare_bulk_sync_command(shop: shop, type: type)
      return prepared unless prepared["started"]

      if prepared["mode"] == "mock"
        launch_async do
          run_sync_command(
            shop: shop,
            type: type,
            sync_log_id: prepared.fetch("syncLogId"),
            last_order_updated_at: prepared["lastOrderUpdatedAt"],
            command_key: prepared["commandKey"],
            lock_owner_id: prepared["lockOwnerId"]
          )
        end
        return prepared.slice("started", "syncLogId", "mode")
      end

      launch_async do
        run_bulk_sync_command(
          shop: shop,
          type: type,
          sync_log_id: prepared.fetch("syncLogId"),
          bulk_job_id: prepared.fetch("bulkJobId"),
          command_key: prepared["commandKey"],
          lock_owner_id: prepared["lockOwnerId"]
        )
      end

      prepared.slice("started", "syncLogId", "bulkJobId", "mode")
    end

    def prepare_bulk_sync_command(shop:, type: "full")
      shop_domain = shop.fetch("shop_domain")
      command_key = bulk_sync_command_key(type)
      owner_id = SecureRandom.uuid
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?

      if @config.mock_mode?
        return prepare_sync_command(shop: shop, type: type, skip_rate_limit: true).merge("mode" => "mock")
      end
      return { "started" => false, "message" => "Bulk sync already queued or in progress" } unless @store.claim_sync_command_lock(shop_domain, command_key, owner_id: owner_id)

      sync_log = @store.create_sync_log(shop_domain, total_estimated: 0)
      job = @store.create_bulk_sync_job(shop_domain, {
        "sync_log_id" => sync_log["id"],
        "sync_type" => type,
        "status" => "queued"
      })

      {
        "started" => true,
        "syncLogId" => sync_log["id"],
        "bulkJobId" => job["id"],
        "mode" => "bulk",
        "commandKey" => command_key,
        "lockOwnerId" => owner_id
      }
    rescue StandardError
      @store.release_sync_command_lock(shop_domain, command_key, owner_id: owner_id) if shop_domain && command_key && owner_id
      raise
    end

    def run_bulk_sync_command(shop:, type:, sync_log_id:, bulk_job_id:, command_key: bulk_sync_command_key(type), lock_owner_id: nil)
      run_bulk_sync(bulk_job_id, sync_log_id, shop, type)
    rescue StandardError => e
      handle_bulk_failure(bulk_job_id, sync_log_id, shop, type, e)
      raise
    ensure
      @store.release_sync_command_lock(shop.fetch("shop_domain"), command_key, owner_id: lock_owner_id) if lock_owner_id
    end

    def trigger_first_time(shop:)
      return enqueue_first_time_sync_request(shop: shop) if @config.db_queue_backend?

      prepared = prepare_first_time_sync_command(shop: shop)
      return prepared unless prepared["started"]

      launch_async do
        run_first_time_sync_command(
          shop: shop,
          sync_log_id: prepared.fetch("syncLogId"),
          batches_planned: prepared.fetch("batchesPlanned"),
          command_key: prepared["commandKey"],
          lock_owner_id: prepared["lockOwnerId"]
        )
      end

      prepared.slice("started", "syncLogId", "mode")
    end

    def prepare_first_time_sync_command(shop:)
      shop_domain = shop.fetch("shop_domain")
      summary = @store.batch_summary(shop_domain)
      command_key = "orders:first_time"
      owner_id = SecureRandom.uuid
      current = @store.latest_sync_log(shop_domain)

      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?
      return { "started" => false, "message" => "First-time sync already queued or in progress" } unless @store.claim_sync_command_lock(shop_domain, command_key, owner_id: owner_id)

      sync_log = @store.create_sync_log(shop_domain, total_estimated: 0)
      {
        "started" => true,
        "syncLogId" => sync_log["id"],
        "mode" => "first_time",
        "batchesPlanned" => summary["totalBatches"].positive?,
        "commandKey" => command_key,
        "lockOwnerId" => owner_id
      }
    rescue StandardError
      @store.release_sync_command_lock(shop_domain, command_key, owner_id: owner_id) if shop_domain && command_key && owner_id
      raise
    end

    def run_first_time_sync_command(shop:, sync_log_id:, batches_planned: false, command_key: "orders:first_time", lock_owner_id: nil)
      shop_domain = shop.fetch("shop_domain")
      plan_first_time_sync_batches(shop) unless batches_planned
      process_first_time_batches(shop, sync_log_id)
      @store.complete_sync_log(sync_log_id, total_estimated: @store.batch_summary(shop_domain)["completedBatches"])
    rescue StandardError => e
      @store.fail_sync_log(sync_log_id, e.message)
      raise
    ensure
      @store.release_sync_command_lock(shop_domain, command_key, owner_id: lock_owner_id) if lock_owner_id
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
      return false if @config.db_queue_backend?
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

    def start_uninstall_cleanup_worker
      return false if @config.db_queue_backend?
      return false if @cleanup_thread&.alive?

      @cleanup_thread = Thread.new do
        Thread.current.abort_on_exception = false
        loop do
          begin
            cleanup_uninstalled_shop_data
          rescue StandardError => e
            warn "[send-invoice] uninstall cleanup failed: #{e.class}: #{e.message}"
          ensure
            sleep @config.uninstall_cleanup_interval_seconds
          end
        end
      end

      true
    end

    def status(shop_domain)
      latest = @store.latest_sync_log(shop_domain)
      last_completed = @store.last_completed_sync(shop_domain)
      batch_summary = sync_status_batch_summary(shop_domain)
      queued_request = latest_active_sync_request(shop_domain)

      return queued_status_payload(queued_request, last_completed, batch_summary) if queued_request && queued_request_newer_than_latest?(queued_request, latest)
      return idle_status unless latest

      if batch_summary["totalBatches"].positive? && !batch_summary["initialSyncCompleted"]
        return sync_status_payload(latest, last_completed).merge(batch_summary)
      end

      if batch_summary["totalBatches"].positive? && batch_summary["initialSyncCompleted"] && !batch_summary["remainingSyncCompleted"]
        return sync_status_payload(latest, last_completed).merge(batch_summary).merge(
          "status" => "completed",
          "lastSyncedAt" => Time.now.utc.iso8601
        )
      end

      sync_status_payload(latest, last_completed).merge(batch_summary)
    end

    def batch_status(shop_domain)
      @store.batch_summary(shop_domain)
    end

    def bulk_status(shop_domain)
      job = @store.latest_bulk_sync_job(shop_domain)
      queued_request = latest_active_bulk_request(shop_domain)

      if queued_request && (!job || queued_request_newer_than_reference?(queued_request, job["updated_at"] || job["started_at"]))
        payload = {
          "status" => "queued",
          "requestId" => queued_request["id"],
          "queuedAt" => queued_request["created_at"],
          "requestType" => queued_request["request_type"],
          "syncStatus" => status(shop_domain)
        }
        return job ? job.merge(payload) : payload
      end

      return { "status" => "idle" } unless job

      job.merge("syncStatus" => status(shop_domain))
    end

    def handle_bulk_finish(shop:, operation_id:)
      job = @store.bulk_sync_job_by_operation(shop.fetch("shop_domain"), operation_id)
      return false unless job
      return true if terminal_or_processing_bulk_status?(job["status"])

      if @config.db_queue_backend?
        @store.enqueue_async_job_request(
          shop_domain: shop.fetch("shop_domain"),
          request_type: "sync.bulk_finish",
          queue_name: "webhooks",
          dedupe_key: "sync.bulk_finish:#{job.fetch('id')}",
          payload: {
            "shop_domain" => shop.fetch("shop_domain"),
            "operation_id" => operation_id
          }
        )
        return true
      end

      launch_async do
        run_bulk_finish_command(shop: shop, operation_id: operation_id)
      end

      true
    end

    def run_bulk_finish_command(shop:, operation_id:)
      job = @store.bulk_sync_job_by_operation(shop.fetch("shop_domain"), operation_id)
      return false unless job
      return true if terminal_or_processing_bulk_status?(job["status"])

      operation = @shopify_client.bulk_operation(
        shop.fetch("shop_domain"),
        shop.fetch("access_token"),
        operation_id
      )
      process_finished_bulk_operation(job, shop, operation)
    rescue StandardError => e
      handle_bulk_failure(job["id"], job["sync_log_id"], shop, job["sync_type"], e) if job
      raise
    end

    def mark_shop_uninstalled(shop_domain)
      shop = @store.shop(shop_domain)
      return nil unless shop

      uninstalled_at = Time.now.utc
      scheduled_for_deletion_at = nil
      installed_at = parse_time(shop["installed_at"])

      if installed_at && uninstalled_at >= shift_months(installed_at, UNINSTALL_RETENTION_MONTHS)
        scheduled_for_deletion_at = (uninstalled_at + UNINSTALL_DELETION_DELAY_SECONDS).iso8601
      end

      @store.mark_shop_uninstalled(
        shop_domain,
        uninstalled_at: uninstalled_at.iso8601,
        scheduled_for_deletion_at: scheduled_for_deletion_at
      )
    end

    def cleanup_uninstalled_shop_data(reference_time: Time.now.utc)
      @store.due_data_deletion_shops(reference_time: reference_time.iso8601).each do |shop|
        next unless @store.claim_shop_data_deletion(shop.fetch("shop_domain"), claimed_at: reference_time.iso8601)

        begin
          @store.delete_shop_data(shop.fetch("shop_domain"))
        rescue StandardError
          @store.update_shop(shop.fetch("shop_domain"), "data_deletion_started_at" => nil)
          raise
        end
      end
    end

    private

    def enqueue_sync_request(shop:, type:, skip_rate_limit:)
      shop_domain = shop.fetch("shop_domain")
      dedupe_key = "sync.#{type}:#{shop_domain}"
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?
      if (existing_request = @store.active_async_job_request_by_dedupe(dedupe_key))
        return { "started" => false, "message" => "Sync already queued or in progress", "requestId" => existing_request["id"] }
      end

      if type == "incremental" && !skip_rate_limit
        limited_for = rate_limited_for(shop_domain)
        return { "started" => false, "message" => "Rate limited. Try again in #{limited_for}s." } if limited_for
      end

      request = @store.enqueue_async_job_request(
        shop_domain: shop_domain,
        request_type: type.to_s == "full" ? "sync.full" : "sync.incremental",
        queue_name: "incremental",
        dedupe_key: dedupe_key,
        payload: {
          "shop_domain" => shop_domain,
          "type" => type,
          "skip_rate_limit" => skip_rate_limit
        }
      )
      return { "started" => false, "message" => "Sync already queued or in progress", "requestId" => request["id"] } unless request["created"]

      touch_rate_limit(shop_domain) if type == "incremental" && !skip_rate_limit
      { "started" => true, "mode" => "queued", "requestId" => request["id"] }
    end

    def enqueue_bulk_sync_request(shop:, type:)
      shop_domain = shop.fetch("shop_domain")
      dedupe_key = "sync.bulk_start:#{type}:#{shop_domain}"
      current = @store.latest_sync_log(shop_domain)
      return { "started" => false, "message" => "Sync already in progress" } if current && current["status"] == "running"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?
      if (existing_request = @store.active_async_job_request_by_dedupe(dedupe_key))
        return { "started" => false, "message" => "Bulk sync already queued or in progress", "requestId" => existing_request["id"] }
      end

      request = @store.enqueue_async_job_request(
        shop_domain: shop_domain,
        request_type: "sync.bulk_start",
        queue_name: "bulk",
        dedupe_key: dedupe_key,
        payload: {
          "shop_domain" => shop_domain,
          "type" => type
        }
      )
      return { "started" => false, "message" => "Bulk sync already queued or in progress", "requestId" => request["id"] } unless request["created"]

      { "started" => true, "mode" => "queued", "requestId" => request["id"] }
    end

    def enqueue_first_time_sync_request(shop:)
      shop_domain = shop.fetch("shop_domain")
      dedupe_key = "sync.first_time:#{shop_domain}"
      return { "started" => false, "message" => "Missing Shopify access token" } if !@config.mock_mode? && shop["access_token"].to_s.empty?
      if (existing_request = @store.active_async_job_request_by_dedupe(dedupe_key))
        return { "started" => false, "message" => "First-time sync already queued or in progress", "requestId" => existing_request["id"] }
      end

      request = @store.enqueue_async_job_request(
        shop_domain: shop_domain,
        request_type: "sync.first_time",
        queue_name: "first_time",
        dedupe_key: dedupe_key,
        payload: {
          "shop_domain" => shop_domain
        }
      )
      return { "started" => false, "message" => "First-time sync already queued or in progress", "requestId" => request["id"] } unless request["created"]

      { "started" => true, "mode" => "queued", "requestId" => request["id"] }
    end

    def launch_async(&block)
      Thread.new do
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
        block.call
      end
    end

    def sync_command_key(type)
      type.to_s == "full" ? "orders:full" : "orders:incremental"
    end

    def bulk_sync_command_key(type)
      "bulk:#{type}"
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def sync_status_payload(latest, last_completed)
      {
        "status" => latest["status"],
        "ordersSynced" => latest["orders_synced"],
        "totalEstimated" => latest["total_estimated"],
        "startedAt" => latest["started_at"],
        "finishedAt" => latest["finished_at"],
        "errorMessage" => latest["error_message"],
        "lastSyncedAt" => last_completed && last_completed["finished_at"]
      }
    end

    def queued_status_payload(queued_request, last_completed, batch_summary)
      idle_status.merge(batch_summary).merge(
        "status" => "queued",
        "queuedAt" => async_request_queue_reference_time(queued_request),
        "queuedType" => queued_request["request_type"],
        "requestId" => queued_request["id"],
        "lastSyncedAt" => last_completed && last_completed["finished_at"]
      )
    end

    def latest_active_sync_request(shop_domain)
      @store.latest_active_async_job_request(
        shop_domain,
        request_types: %w[sync.incremental sync.full sync.first_time]
      )
    end

    def latest_active_bulk_request(shop_domain)
      @store.latest_active_async_job_request(
        shop_domain,
        request_types: %w[sync.bulk_start sync.bulk_finish]
      )
    end

    def queued_request_newer_than_latest?(queued_request, latest)
      return true unless latest

      queued_request_newer_than_reference?(queued_request, latest["started_at"])
    end

    def queued_request_newer_than_reference?(queued_request, reference_time)
      queued_at = parse_time(async_request_queue_reference_time(queued_request))
      reference = parse_time(reference_time)
      return true unless reference

      queued_at && queued_at >= reference
    end

    def async_request_queue_reference_time(queued_request)
      queued_request["updated_at"] || queued_request["created_at"]
    end

    def sync_status_batch_summary(shop_domain)
      summary = @store.batch_summary(shop_domain)
      first_time_status = summary.delete("status")
      summary.merge("firstTimeSyncStatus" => first_time_status)
    end

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

    def plan_first_time_sync_batches(shop)
      shop_domain = shop.fetch("shop_domain")
      sync_end_date = Time.now.utc
      sync_start_date = shift_months(sync_end_date, -FIRST_TIME_MONTHS)
      initial_start_date = [sync_end_date - (INITIAL_SYNC_DAYS * 86_400), sync_start_date].max
      sequence = 1

      sequence = create_order_based_batches(
        shop: shop,
        start_time: initial_start_date,
        end_time: sync_end_date,
        batch_type: "initial_3_days",
        priority: "high",
        sequence: sequence
      )

      create_order_based_batches(
        shop: shop,
        start_time: sync_start_date,
        end_time: initial_start_date,
        batch_type: "remaining_6_months",
        priority: "normal",
        sequence: sequence
      )

      @store.batch_summary(shop_domain)
    end

    def create_order_based_batches(shop:, start_time:, end_time:, batch_type:, priority:, sequence:)
      current_end = end_time.utc

      while current_end > start_time
        day_end = [end_of_day(current_end), end_time].min
        day_start = [start_of_day(current_end), start_time].max
        day_count = count_orders(shop, day_start, day_end)

        if day_count > MAX_BATCH_ORDERS
          pages = (day_count.to_f / MAX_BATCH_ORDERS).ceil
          pages.times do |page_index|
            create_batch(shop, day_start, day_end, "single_day_split", priority, sequence, [MAX_BATCH_ORDERS, day_count - (page_index * MAX_BATCH_ORDERS)].min, page_index)
            sequence += 1
          end
          current_end = day_start - 1
          next
        end

        batch_start = day_start
        batch_count = day_count
        scan_day = day_start - 1

        while scan_day > start_time
          candidate_start = [start_of_day(scan_day), start_time].max
          candidate_end = [end_of_day(scan_day), day_start - 1].min
          candidate_count = count_orders(shop, candidate_start, candidate_end)
          break if batch_count.positive? && batch_count + candidate_count > MAX_BATCH_ORDERS

          batch_start = candidate_start
          batch_count += candidate_count
          scan_day = candidate_start - 1
        end

        create_batch(shop, batch_start, day_end, batch_type, priority, sequence, batch_count, 0)
        sequence += 1
        current_end = batch_start - 1
      end

      sequence
    end

    def create_batch(shop, start_time, end_time, batch_type, priority, sequence, order_count, page_index)
      @store.create_batch_log(shop.fetch("shop_domain"), {
        "resource_name" => "ORDER",
        "sync_type" => "first_time_sync",
        "batch_type" => batch_type,
        "start_date" => start_time.utc.iso8601,
        "end_date" => end_time.utc.iso8601,
        "order_count" => order_count,
        "batch_sequence" => sequence,
        "status" => "pending",
        "priority" => priority,
        "page_index" => page_index,
        "page_limit" => MAX_BATCH_ORDERS
      })
    end

    def process_first_time_batches(shop, sync_log_id)
      loop do
        batch = @store.pending_batch_logs(shop.fetch("shop_domain")).first
        break unless batch

        process_batch(shop, batch, sync_log_id)
      end
    end

    def process_batch(shop, batch, sync_log_id)
      @store.update_batch_log(batch["id"], {
        "status" => "processing",
        "started_at" => Time.now.utc.iso8601,
        "error_message" => nil
      })

      query_filter = created_at_query(Time.parse(batch["start_date"]), Time.parse(batch["end_date"]))
      sync_orders_for_query(
        sync_log_id,
        shop,
        query_filter,
        "first_time_sync",
        max_orders: batch["page_limit"],
        skip_orders: batch["page_index"] * batch["page_limit"]
      )

      @store.update_batch_log(batch["id"], {
        "status" => "completed",
        "completed_at" => Time.now.utc.iso8601
      })
    rescue StandardError => e
      @store.update_batch_log(batch["id"], {
        "status" => "failed",
        "retry_count" => batch["retry_count"] + 1,
        "error_message" => e.message
      })
      raise
    end

    def count_orders(shop, start_time, end_time)
      if @config.mock_mode?
        MockData.orders.count do |order|
          created_at = Time.parse(order["created_at"])
          created_at >= start_time && created_at < end_time
        end
      else
        @shopify_client.order_count(shop.fetch("shop_domain"), shop.fetch("access_token"), created_at_query(start_time, end_time))
      end
    end

    def created_at_query(start_time, end_time)
      "created_at:>=#{start_time.utc.iso8601} created_at:<#{end_time.utc.iso8601}"
    end

    def start_of_day(time)
      Time.utc(time.year, time.month, time.day)
    end

    def end_of_day(time)
      start_of_day(time) + 86_400
    end

    def shift_months(time, months)
      base = Date.new(time.year, time.month, time.day)
      date = months.negative? ? (base << months.abs) : (base >> months)
      Time.utc(date.year, date.month, date.day, time.hour, time.min, time.sec)
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
      highest_order_updated_at = last_order_updated_at
      query_filter = sync_type == "incremental" && last_order_updated_at ? "updated_at:>=#{last_order_updated_at}" : nil
      result = sync_orders_for_query(sync_log_id, shop, query_filter, sync_type)
      highest_order_updated_at = [highest_order_updated_at, result["last_order_updated_at"]].compact.max

      @store.complete_sync_log(sync_log_id, total_estimated: result["synced"])
      @store.upsert_sync_state(shop.fetch("shop_domain"), {
        "last_order_updated_at" => highest_order_updated_at,
        "last_cursor" => nil,
        "last_sync_type" => sync_type
      })
    rescue StandardError => e
      @store.fail_sync_log(sync_log_id, e.message)
      raise
    end

    def sync_orders_for_query(sync_log_id, shop, query_filter, sync_type, max_orders: nil, skip_orders: 0)
      return sync_mock_orders_for_query(sync_log_id, shop, query_filter, sync_type, max_orders: max_orders, skip_orders: skip_orders) if @config.mock_mode?

      cursor = nil
      seen = 0
      synced = 0
      total_estimated = 0
      highest_order_updated_at = nil

      loop do
        data = @shopify_client.graph_ql(shop.fetch("shop_domain"), shop.fetch("access_token"), ORDERS_QUERY, {
          "cursor" => cursor,
          "query" => query_filter
        })

        edges = data.fetch("orders", {}).fetch("edges", [])
        page_info = data.fetch("orders", {}).fetch("pageInfo", {})

        unless edges.empty?
          nodes = edges.map { |edge| edge.fetch("node") }

          if skip_orders.positive? && seen + nodes.length <= skip_orders
            seen += nodes.length
            cursor = page_info["endCursor"]
            break unless page_info["hasNextPage"]

            next
          elsif skip_orders.positive? && seen < skip_orders
            nodes = nodes.drop(skip_orders - seen)
            seen = skip_orders
          end

          remaining = max_orders ? max_orders - synced : nodes.length
          nodes = nodes.first(remaining) if max_orders

          nodes = nodes.map { |node| complete_order_line_items(shop, node) }
          orders = nodes.map { |node| map_order_node(node, shop.fetch("shop_domain")) }
          @store.upsert_orders(orders)
          highest_order_updated_at = [highest_order_updated_at, max_order_updated_at(orders)].compact.max
          synced += orders.length
          total_estimated = [synced, total_estimated].max
          @store.update_sync_log_progress(sync_log_id, synced, total_estimated)
        end

        break if max_orders && synced >= max_orders
        break unless page_info["hasNextPage"]

        cursor = page_info["endCursor"]
      end

      { "synced" => synced, "last_order_updated_at" => highest_order_updated_at }
    end

    def sync_mock_orders_for_query(sync_log_id, shop, query_filter, _sync_type, max_orders: nil, skip_orders: 0)
      orders = filtered_mock_orders_for_query(query_filter)
      orders = orders.drop(skip_orders)
      orders = orders.first(max_orders) if max_orders
      orders = orders.map do |order|
        order.merge(
          "shop_domain" => shop.fetch("shop_domain"),
          "updated_at" => order["updated_at"] || order["created_at"],
          "synced_at" => Time.now.utc.iso8601
        )
      end

      unless orders.empty?
        @store.upsert_orders(orders)
        @store.update_sync_log_progress(sync_log_id, orders.length, orders.length)
      end

      { "synced" => orders.length, "last_order_updated_at" => max_order_updated_at(orders) }
    end

    def filtered_mock_orders_for_query(query_filter)
      orders = MockData.orders
      return orders unless query_filter

      if (created_start = query_filter[/created_at:>=([^ ]+)/, 1])
        start_time = Time.parse(created_start)
        orders = orders.select { |order| Time.parse(order["created_at"]) >= start_time }
      end

      if (created_end = query_filter[/created_at:<([^ ]+)/, 1])
        end_time = Time.parse(created_end)
        orders = orders.select { |order| Time.parse(order["created_at"]) < end_time }
      end

      if (updated_start = query_filter[/updated_at:>=([^ ]+)/, 1])
        start_time = Time.parse(updated_start)
        orders = orders.select { |order| Time.parse(order["updated_at"] || order["created_at"]) >= start_time }
      end

      orders
    end

    def complete_order_line_items(shop, node)
      connection = node["lineItems"] || {}
      page_info = connection["pageInfo"] || {}
      return node unless page_info["hasNextPage"]

      edges = Array(connection["edges"]).dup
      cursor = page_info["endCursor"]

      loop do
        data = @shopify_client.graph_ql(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          ORDER_LINE_ITEMS_QUERY,
          {
            "id" => node.fetch("id"),
            "cursor" => cursor
          }
        )

        order = data.fetch("order")
        line_items = order.fetch("lineItems", {})
        edges.concat(Array(line_items["edges"]))
        page_info = line_items["pageInfo"] || {}
        break unless page_info["hasNextPage"]

        cursor = page_info["endCursor"]
      end

      node.merge(
        "lineItems" => {
          "edges" => edges,
          "pageInfo" => {
            "hasNextPage" => false,
            "endCursor" => cursor
          }
        }
      )
    end

    def run_bulk_sync(job_id, sync_log_id, shop, sync_type)
      query = bulk_orders_query(shop.fetch("shop_domain"), sync_type)
      operation = @shopify_client.start_bulk_query(shop.fetch("shop_domain"), shop.fetch("access_token"), query)
      operation_id = operation.fetch("id")

      @store.update_bulk_sync_job(job_id, {
        "shopify_bulk_operation_id" => operation_id,
        "status" => normalize_bulk_status(operation["status"]) == "completed" ? "running" : normalize_bulk_status(operation["status"])
      })

      loop do
        operation = @shopify_client.bulk_operation(shop.fetch("shop_domain"), shop.fetch("access_token"), operation_id)
        status = normalize_bulk_status(operation["status"])
        attributes = bulk_operation_attributes(operation)
        attributes["status"] = status unless status == "completed"
        @store.update_bulk_sync_job(job_id, attributes)

        case status
        when "completed"
          process_finished_bulk_operation(
            @store.bulk_sync_job(job_id),
            shop,
            operation
          )
          break
        when "failed", "canceled", "expired"
          raise "Shopify bulk operation #{status}: #{operation['errorCode']}"
        else
          sleep BULK_POLL_SECONDS
        end
      end
    end

    def process_finished_bulk_operation(job, shop, operation)
      status = normalize_bulk_status(operation["status"])
      if status != "completed"
        raise "Shopify bulk operation #{status}: #{operation['errorCode']}"
      end

      claimed = @store.claim_bulk_sync_job(
        job.fetch("id"),
        from_statuses: %w[queued created running],
        status: "downloading"
      )
      return false unless claimed

      @store.update_bulk_sync_job(job["id"], bulk_operation_attributes(operation))
      url = operation["url"] || operation["partialDataUrl"]
      raise "Shopify bulk operation completed without a result URL" if url.to_s.empty?

      result = import_bulk_result(url, shop.fetch("shop_domain"), job.fetch("sync_log_id"), job.fetch("id"))
      @store.complete_sync_log(job["sync_log_id"], total_estimated: result["imported_count"])
      @store.upsert_sync_state(shop.fetch("shop_domain"), {
        "last_order_updated_at" => result["last_order_updated_at"],
        "last_cursor" => nil,
        "last_sync_type" => "bulk_#{job.fetch('sync_type')}"
      })
      @store.update_bulk_sync_job(job["id"], {
        "status" => "completed",
        "imported_count" => result["imported_count"],
        "completed_at" => Time.now.utc.iso8601
      })
      true
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

    def terminal_or_processing_bulk_status?(status)
      %w[
        downloading importing completed failed canceled expired
        fallback_running fallback_completed fallback_failed
      ].include?(status.to_s)
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
