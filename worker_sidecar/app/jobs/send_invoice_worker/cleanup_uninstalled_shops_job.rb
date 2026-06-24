# frozen_string_literal: true

module SendInvoiceWorker
  class CleanupUninstalledShopsJob < ApplicationJob
    queue_as :maintenance

    def perform
      Runtime.instance.sync_engine.cleanup_uninstalled_shop_data
    end
  end
end
