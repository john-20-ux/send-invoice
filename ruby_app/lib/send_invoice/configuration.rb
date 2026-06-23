# frozen_string_literal: true

module SendInvoice
  class Configuration
    attr_reader :api_version,
                :app_root,
                :auto_sync_enabled,
                :auto_sync_interval_seconds,
                :database_path,
                :host,
                :port,
                :public_path,
                :root,
                :session_cookie_name,
                :shopify_api_key,
                :shopify_api_secret,
                :shopify_scopes,
                :sync_api_secret,
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
      @database_path = env["DATABASE_PATH"] || File.join(@app_root, "db", "send_invoice.sqlite3")
      @port = Integer(env["PORT"] || "3000", 10)
      @host = env["HOST"] || "http://localhost:3000"
      @shopify_api_key = env["SHOPIFY_API_KEY"].to_s
      @shopify_api_secret = env["SHOPIFY_API_SECRET"].to_s
      @shopify_scopes = env.fetch("SHOPIFY_SCOPES", "read_orders").split(",").map(&:strip).reject(&:empty?)
      @api_version = env["SHOPIFY_API_VERSION"] || "2026-04"
      @auto_sync_enabled = env["AUTO_SYNC_ENABLED"] == "true"
      @auto_sync_interval_seconds = [Integer(env["AUTO_SYNC_INTERVAL_SECONDS"] || "300", 10), 60].max
      @sync_api_secret = env["SYNC_API_SECRET"].to_s
      @session_cookie_name = env["SESSION_COOKIE_NAME"] || "send_invoice_session"
      @mock_mode = env["MOCK_MODE"] == "true" || @shopify_api_key.empty? || @shopify_api_secret.empty?
    end

    def mock_mode?
      @mock_mode
    end

    def production?
      ENV["RACK_ENV"] == "production" || ENV["APP_ENV"] == "production"
    end
  end
end
