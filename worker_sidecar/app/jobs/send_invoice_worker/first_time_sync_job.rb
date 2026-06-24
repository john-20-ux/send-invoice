# frozen_string_literal: true

module SendInvoiceWorker
  class FirstTimeSyncJob < ApplicationJob
    queue_as :first_time

    def perform(shop_domain, request_id = nil)
      runtime = Runtime.instance
      runtime.store.mark_async_job_request_running(request_id) if request_id
      shop = runtime.fetch_shop!(shop_domain)
      prepared = runtime.sync_engine.prepare_first_time_sync_command(shop: shop)
      return resolve_unstarted_async_request(runtime: runtime, request_id: request_id, prepared: prepared, phase: "first_time_sync") unless prepared["started"]

      runtime.sync_engine.run_first_time_sync_command(
        shop: shop,
        sync_log_id: prepared.fetch("syncLogId"),
        batches_planned: prepared.fetch("batchesPlanned"),
        command_key: prepared["commandKey"],
        lock_owner_id: prepared["lockOwnerId"]
      )
      runtime.store.complete_async_job_request(request_id) if request_id
    rescue StandardError => e
      handle_async_request_failure(runtime: runtime, request_id: request_id, error: e, phase: "first_time_sync")
    end
  end
end
