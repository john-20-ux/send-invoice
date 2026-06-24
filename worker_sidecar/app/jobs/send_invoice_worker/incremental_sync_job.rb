# frozen_string_literal: true

module SendInvoiceWorker
  class IncrementalSyncJob < ApplicationJob
    queue_as :incremental

    def perform(shop_domain)
      runtime = Runtime.instance
      shop = runtime.fetch_shop!(shop_domain)
      prepared = runtime.sync_engine.prepare_sync_command(shop: shop, type: "incremental", skip_rate_limit: true)
      return prepared unless prepared["started"]

      runtime.sync_engine.run_sync_command(
        shop: shop,
        type: "incremental",
        sync_log_id: prepared.fetch("syncLogId"),
        last_order_updated_at: prepared["lastOrderUpdatedAt"],
        command_key: prepared["commandKey"],
        lock_owner_id: prepared["lockOwnerId"]
      )
    end
  end
end
