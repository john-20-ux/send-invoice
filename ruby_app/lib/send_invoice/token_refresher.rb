# frozen_string_literal: true

require "time"

module SendInvoice
  # Refreshes expiring offline access tokens before they lapse. Call
  # `fresh_shop(shop)` right before making live Shopify API calls; it returns the
  # shop with a still-valid token, transparently refreshing and persisting a new
  # token/refresh-token pair when the current one is within REFRESH_BUFFER of
  # expiry. Permanent (non-expiring) tokens pass through untouched.
  class TokenRefresher
    # Refresh a bit early so in-flight requests never race the expiry.
    REFRESH_BUFFER_SECONDS = 300

    def initialize(store:, shopify_client:, logger: nil)
      @store = store
      @shopify_client = shopify_client
      @logger = logger
    end

    def fresh_shop(shop)
      return shop unless shop
      return shop unless refresh_needed?(shop)

      refresh_token = shop["refresh_token"].to_s
      return shop if refresh_token.empty?

      shop_domain = shop["shop_domain"]
      data = @shopify_client.refresh_access_token(shop_domain, refresh_token)
      access_token = data["access_token"]
      return shop if access_token.to_s.empty?

      now = Time.now.utc
      refresh_expires_in = data["refresh_token_expires_in"]
      @store.update_shop_tokens(
        shop_domain,
        access_token: access_token,
        token_expires_at: data["expires_in"] ? (now + data["expires_in"].to_i).iso8601 : nil,
        refresh_token: data["refresh_token"] || refresh_token,
        refresh_token_expires_at: refresh_expires_in ? (now + refresh_expires_in.to_i).iso8601 : nil,
        scopes: data["scope"]
      )
    rescue StandardError => e
      @logger&.warn("[TokenRefresher] refresh failed for #{shop && shop['shop_domain']}: #{e.class}: #{e.message}")
      shop
    end

    private

    def refresh_needed?(shop)
      expires_at = shop["token_expires_at"].to_s
      return false if expires_at.empty? # permanent token

      Time.parse(expires_at) - Time.now.utc <= REFRESH_BUFFER_SECONDS
    rescue ArgumentError
      false
    end
  end
end
