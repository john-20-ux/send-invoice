# frozen_string_literal: true

require "webrick"

require "send_invoice/app"
require "send_invoice/configuration"
require "send_invoice/database"
require "send_invoice/migrator"
require "send_invoice/shopify_client"
require "send_invoice/store"
require "send_invoice/sync_engine"

module SendInvoice
  module Boot
    module_function

    def start
      # Flush logs immediately so container/platform log streams stay live.
      $stdout.sync = true
      $stderr.sync = true
      root = File.expand_path("../../..", __dir__)
      config = Configuration.load(root: root)
      database = Database.new(config)
      Migrator.new(database).run

      store = Store.new(database)
      if config.mock_mode?
        store.ensure_shop(MockData::DEMO_SHOP_DOMAIN, "shop_name" => MockData::DEMO_SHOP_NAME)
      end

      shopify_client = ShopifyClient.new(config)
      Thread.new { register_webhooks(config, store, shopify_client) } unless config.mock_mode?
      sync_engine = SyncEngine.new(config: config, store: store, shopify_client: shopify_client)
      sync_engine.start_scheduler
      sync_engine.start_uninstall_cleanup_worker
      application = App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)

      server = WEBrick::HTTPServer.new(
        Port: config.port,
        BindAddress: config.bind_address,
        AccessLog: [],
        Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
      )

      server.mount "/assets", WEBrick::HTTPServlet::FileHandler, config.public_path
      server.mount "/design", WEBrick::HTTPServlet::FileHandler, File.join(config.root, "design")
      server.mount_proc("/") { |req, res| application.handle(req, res) }

      trap("INT") { server.shutdown }
      trap("TERM") { server.shutdown }

      puts "Ruby app listening on #{config.bind_address}:#{config.port}"
      puts "Configured host: #{config.host}"
      puts "Mode: #{config.mock_mode? ? 'mock' : 'shopify'}"
      server.start
    end

    def register_webhooks(config, store, shopify_client)
      store.syncable_shops.each do |shop|
        shopify_client.ensure_webhook_subscription(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          topic: "BULK_OPERATIONS_FINISH",
          uri: config.bulk_finish_webhook_uri
        )
        shopify_client.ensure_webhook_subscription(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          topic: "APP_UNINSTALLED",
          uri: config.app_uninstalled_webhook_uri
        )

        unless config.order_webhooks_enabled?
          puts "[send-invoice] order webhooks disabled (ENABLE_ORDER_WEBHOOKS not set); " \
               "skipping ORDERS_* topics for #{shop['shop_domain']} until Protected Customer Data access is approved."
          next
        end

        shopify_client.ensure_webhook_subscription(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          topic: "ORDERS_CREATE",
          uri: config.orders_changed_webhook_uri
        )
        shopify_client.ensure_webhook_subscription(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          topic: "ORDERS_UPDATED",
          uri: config.orders_changed_webhook_uri
        )
        shopify_client.ensure_webhook_subscription(
          shop.fetch("shop_domain"),
          shop.fetch("access_token"),
          topic: "ORDERS_EDITED",
          uri: config.orders_changed_webhook_uri
        )
      rescue StandardError => e
        warn "[send-invoice] webhook reconciliation failed for #{shop['shop_domain']}: #{e.class}: #{e.message}"
      end
    end
  end
end
