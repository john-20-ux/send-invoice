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
      root = File.expand_path("../../..", __dir__)
      config = Configuration.load(root: root)
      database = Database.new(config)
      Migrator.new(database).run

      store = Store.new(database)
      if config.mock_mode?
        store.ensure_shop(MockData::DEMO_SHOP_DOMAIN, "shop_name" => MockData::DEMO_SHOP_NAME)
      end

      shopify_client = ShopifyClient.new(config)
      sync_engine = SyncEngine.new(config: config, store: store, shopify_client: shopify_client)
      sync_engine.start_scheduler
      application = App.new(config: config, store: store, sync_engine: sync_engine, shopify_client: shopify_client)

      server = WEBrick::HTTPServer.new(
        Port: config.port,
        BindAddress: "127.0.0.1",
        AccessLog: [],
        Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
      )

      server.mount "/assets", WEBrick::HTTPServlet::FileHandler, config.public_path
      server.mount "/design", WEBrick::HTTPServlet::FileHandler, File.join(config.root, "design")
      server.mount_proc("/") { |req, res| application.handle(req, res) }

      trap("INT") { server.shutdown }
      trap("TERM") { server.shutdown }

      puts "Ruby app listening on http://localhost:#{config.port}"
      puts "Mode: #{config.mock_mode? ? 'mock' : 'shopify'}"
      server.start
    end
  end
end
