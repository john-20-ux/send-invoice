# frozen_string_literal: true

module SendInvoice
  class Configuration
    attr_reader :api_version,
                :app_root,
                :auto_sync_enabled,
                :auto_sync_interval_seconds,
                :background_backend,
                :bind_address,
                :database_path,
                :host,
                :order_webhooks_enabled,
                :outbox_path,
                :port,
                :public_path,
                :root,
                :session_cookie_name,
                :smtp_authentication,
                :smtp_from_email,
                :smtp_from_name,
                :smtp_host,
                :smtp_password,
                :smtp_port,
                :smtp_use_tls,
                :smtp_username,
                :shopify_api_key,
                :shopify_api_secret,
                :shopify_scopes,
                :sync_api_secret,
                :uninstall_cleanup_interval_seconds,
                :views_path

    def self.load(root:)
      env = {}
      load_env_file(File.join(root, ".env"), env)
      load_env_file(File.join(root, ".env.local"), env)
      env.each { |key, value| ENV[key] = value unless ENV.key?(key) }
      new(root: root, env: ENV)
    end

    def self.load_env_file(path, target)
      return unless File.exist?(path)

      File.readlines(path).each do |line|
        next if line.strip.empty? || line.lstrip.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value

        cleaned = value.strip
        cleaned = cleaned[1..-2] if cleaned.start_with?('"') && cleaned.end_with?('"')
        target[key.strip] = cleaned
      end
    end

    def initialize(root:, env:)
      @root = root
      @app_root = File.join(root, "ruby_app")
      @views_path = File.join(@app_root, "views")
      @public_path = File.join(@app_root, "public")
      @outbox_path = env["OUTBOX_PATH"] || File.join(@app_root, "tmp", "outbox")
      @bind_address = env["BIND_ADDRESS"] || "0.0.0.0"
      @database_path = env["DATABASE_PATH"] || File.join(@app_root, "db", "send_invoice.sqlite3")
      @background_backend = (env["BACKGROUND_BACKEND"] || "threads").to_s.strip
      @port = Integer(env["PORT"] || "3000", 10)
      @host = env["HOST"] || "http://localhost:3000"
      @shopify_api_key = env["SHOPIFY_API_KEY"].to_s
      @shopify_api_secret = env["SHOPIFY_API_SECRET"].to_s
      @shopify_scopes = env.fetch("SHOPIFY_SCOPES", "read_orders").split(",").map(&:strip).reject(&:empty?)
      @api_version = env["SHOPIFY_API_VERSION"] || "2026-04"
      @auto_sync_enabled = env["AUTO_SYNC_ENABLED"] == "true"
      # Order webhook topics (ORDERS_CREATE/UPDATED/EDITED) carry protected customer
      # data and require approved Protected Customer Data access in the Partner
      # Dashboard. Keep them off until that access is granted to avoid registration
      # errors; the scheduled bulk sync covers order updates in the meantime.
      @order_webhooks_enabled = env["ENABLE_ORDER_WEBHOOKS"] == "true"
      @auto_sync_interval_seconds = [Integer(env["AUTO_SYNC_INTERVAL_SECONDS"] || "300", 10), 60].max
      @uninstall_cleanup_interval_seconds = [Integer(env["UNINSTALL_CLEANUP_INTERVAL_SECONDS"] || "300", 10), 60].max
      @sync_api_secret = env["SYNC_API_SECRET"].to_s
      @session_cookie_name = env["SESSION_COOKIE_NAME"] || "send_invoice_session"
      @smtp_host = env["SMTP_HOST"].to_s
      @smtp_port = Integer(env["SMTP_PORT"] || "587", 10)
      @smtp_username = env["SMTP_USERNAME"].to_s
      @smtp_password = env["SMTP_PASSWORD"].to_s
      @smtp_authentication = (env["SMTP_AUTHENTICATION"] || "plain").to_s
      @smtp_from_email = env["SMTP_FROM_EMAIL"].to_s
      @smtp_from_name = env["SMTP_FROM_NAME"].to_s
      @smtp_use_tls = env["SMTP_USE_TLS"] != "false"
      @encryption_key = env["ENCRYPTION_KEY"].to_s
      # Opt into Shopify expiring offline access tokens (rotation). Required by
      # Shopify in 2026; keep configurable so existing installs can roll over.
      @expiring_tokens = env.fetch("EXPIRING_OFFLINE_TOKENS", "true") != "false"
      # Observability: optional alert webhook (Slack-compatible) + environment tag.
      @error_webhook_url = (env["ERROR_WEBHOOK_URL"] || env["SLACK_WEBHOOK_URL"]).to_s
      @app_env = env["APP_ENV"] || env["RACK_ENV"] || "development"
      @mock_mode = env["MOCK_MODE"] == "true" || @shopify_api_key.empty? || @shopify_api_secret.empty?
    end

    attr_reader :encryption_key, :error_webhook_url, :app_env

    def mock_mode?
      @mock_mode
    end

    def expiring_tokens?
      @expiring_tokens
    end

    def encryption_configured?
      !@encryption_key.to_s.strip.empty?
    end

    def order_webhooks_enabled?
      @order_webhooks_enabled
    end

    def smtp_configured?
      !@smtp_host.empty? && !@smtp_from_email.empty?
    end

    def db_queue_backend?
      @background_backend == "db_queue"
    end

    def production?
      ENV["RACK_ENV"] == "production" || ENV["APP_ENV"] == "production"
    end

    def bulk_finish_webhook_uri
      "#{@host.sub(%r{/\z}, '')}/webhooks/bulk-operations-finish"
    end

    def app_uninstalled_webhook_uri
      "#{@host.sub(%r{/\z}, '')}/webhooks/app-uninstalled"
    end

    def orders_changed_webhook_uri
      "#{@host.sub(%r{/\z}, '')}/webhooks/orders-changed"
    end
  end
end
