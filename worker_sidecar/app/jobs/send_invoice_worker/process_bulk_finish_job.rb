# frozen_string_literal: true

module SendInvoiceWorker
  class ProcessBulkFinishJob < ApplicationJob
    queue_as :webhooks

    def perform(shop_domain, operation_id, request_id = nil)
      runtime = Runtime.instance
      runtime.store.mark_async_job_request_running(request_id) if request_id
      shop = runtime.fetch_shop!(shop_domain)
      runtime.sync_engine.run_bulk_finish_command(shop: shop, operation_id: operation_id)
      runtime.store.complete_async_job_request(request_id) if request_id
    rescue StandardError => e
      handle_async_request_failure(runtime: runtime, request_id: request_id, error: e, phase: "process_bulk_finish")
    end
  end
end
