# frozen_string_literal: true

module SendInvoiceWorker
  class EnqueueIncrementalSyncsJob < ApplicationJob
    queue_as :maintenance

    def perform
      runtime = Runtime.instance
      runtime.store.syncable_shops.each do |shop|
        RunSyncCommandJob.perform_later(shop.fetch("shop_domain"), "incremental", true)
      end
    end
  end
end
