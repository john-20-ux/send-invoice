# frozen_string_literal: true

module SendInvoiceWorker
  class DrainAppJobRequestsJob < ApplicationJob
    queue_as :maintenance

    BATCH_LIMIT = 50

    def perform
      runtime = Runtime.instance
      worker_id = "sidecar-#{Process.pid}"

      runtime.store.due_async_job_requests(limit: BATCH_LIMIT).each do |request|
        next unless runtime.store.claim_async_job_request(request.fetch("id"), worker_id: worker_id)

        dispatch_request(runtime, request.fetch("id"))
      rescue StandardError => e
        warn "[send-invoice-worker] request dispatch failed for #{request['id']}: #{e.class}: #{e.message}"
      end
    end

    private

    def dispatch_request(runtime, request_id)
      request = runtime.store.async_job_request(request_id)
      payload = request.fetch("payload")

      case request.fetch("request_type")
      when "sync.incremental", "sync.full"
        RunSyncCommandJob.perform_later(
          payload.fetch("shop_domain"),
          payload.fetch("type"),
          payload["skip_rate_limit"],
          request_id
        )
      when "sync.first_time"
        FirstTimeSyncJob.perform_later(payload.fetch("shop_domain"), request_id)
      when "sync.bulk_start"
        StartBulkSyncJob.perform_later(payload.fetch("shop_domain"), payload["type"] || "full", request_id)
      when "sync.bulk_finish"
        ProcessBulkFinishJob.perform_later(payload.fetch("shop_domain"), payload.fetch("operation_id"), request_id)
      else
        raise "Unsupported async job request type: #{request.fetch('request_type')}"
      end

      runtime.store.mark_async_job_request_dispatched(request_id)
    rescue StandardError => e
      handle_async_request_failure(runtime: runtime, request_id: request_id, error: e, phase: "dispatch")
    end
  end
end
