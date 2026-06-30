# frozen_string_literal: true

require "singleton"

shared_lib_path = File.expand_path("../../../ruby_app/lib", __dir__)
$LOAD_PATH.unshift(shared_lib_path) unless $LOAD_PATH.include?(shared_lib_path)

require "logger"

require "send_invoice/configuration"
require "send_invoice/database"
require "send_invoice/error_reporter"
require "send_invoice/mock_data"
require "send_invoice/shopify_client"
require "send_invoice/store"
require "send_invoice/sync_engine"
require "send_invoice/token_refresher"

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

    def token_refresher
      @token_refresher ||= SendInvoice::TokenRefresher.new(store: store, shopify_client: shopify_client)
    end

    def logger
      @logger ||= begin
        log = Logger.new($stdout)
        log.formatter = proc { |_severity, _time, _progname, message| "#{message}\n" }
        log
      end
    end

    def error_reporter
      @error_reporter ||= SendInvoice::ErrorReporter.new(
        logger: logger,
        webhook_url: configuration.error_webhook_url,
        environment: configuration.app_env
      )
    end

    def fetch_shop!(shop_domain)
      shop = store.shop(shop_domain)
      raise "Unknown shop: #{shop_domain}" unless shop
      raise "Shop uninstalled: #{shop_domain}" if shop["uninstalled_at"]

      # Refresh an expiring offline token before it's used for live sync.
      token_refresher.fresh_shop(shop)
    end
  end
end
