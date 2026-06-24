# frozen_string_literal: true

require "singleton"

shared_lib_path = File.expand_path("../../../ruby_app/lib", __dir__)
$LOAD_PATH.unshift(shared_lib_path) unless $LOAD_PATH.include?(shared_lib_path)

require "send_invoice/configuration"
require "send_invoice/database"
require "send_invoice/mock_data"
require "send_invoice/shopify_client"
require "send_invoice/store"
require "send_invoice/sync_engine"

module SendInvoiceWorker
  class Runtime
    include Singleton

    def repo_root
      @repo_root ||= File.expand_path("../../..", __dir__)
    end

    def configuration
      @configuration ||= SendInvoice::Configuration.load(root: repo_root)
    end

    def database
      @database ||= SendInvoice::Database.new(configuration)
    end

    def store
      @store ||= SendInvoice::Store.new(database)
    end

    def shopify_client
      @shopify_client ||= SendInvoice::ShopifyClient.new(configuration)
    end

    def sync_engine
      @sync_engine ||= SendInvoice::SyncEngine.new(
        config: configuration,
        store: store,
        shopify_client: shopify_client
      )
    end

    def fetch_shop!(shop_domain)
      shop = store.shop(shop_domain)
      raise "Unknown shop: #{shop_domain}" unless shop
      raise "Shop uninstalled: #{shop_domain}" if shop["uninstalled_at"]

      shop
    end
  end
end
