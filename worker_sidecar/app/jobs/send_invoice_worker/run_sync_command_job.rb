# frozen_string_literal: true

module SendInvoiceWorker
  class RunSyncCommandJob < ApplicationJob
    queue_as :incremental

    def perform(shop_domain, type = "incremental", skip_rate_limit = false, request_id = nil)
      runtime = Runtime.instance
      runtime.store.mark_async_job_request_running(request_id) if request_id

      shop = runtime.fetch_shop!(shop_domain)
      prepared = runtime.sync_engine.prepare_sync_command(
        shop: shop,
        type: type,
        skip_rate_limit: skip_rate_limit
      )
      return resolve_unstarted_async_request(runtime: runtime, request_id: request_id, prepared: prepared, phase: "run_sync") unless prepared["started"]

      runtime.sync_engine.run_sync_command(
        shop: shop,
        type: type,
        sync_log_id: prepared.fetch("syncLogId"),
        last_order_updated_at: prepared["lastOrderUpdatedAt"],
        command_key: prepared["commandKey"],
        lock_owner_id: prepared["lockOwnerId"]
      )
      runtime.store.complete_async_job_request(request_id) if request_id
    rescue StandardError => e
      handle_async_request_failure(runtime: runtime, request_id: request_id, error: e, phase: "run_sync")
    end
  end
end
