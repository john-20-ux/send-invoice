# frozen_string_literal: true

require "json"
require "base64"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module SendInvoice
  class ShopifyClient
    # Raised when Shopify keeps rate-limiting after we exhaust retries; callers
    # can surface a friendly "please retry shortly" message.
    class RateLimitError < StandardError; end

    MAX_RETRIES = Integer(ENV.fetch("SHOPIFY_MAX_RETRIES", "4"))
    RETRY_BASE_SECONDS = Float(ENV.fetch("SHOPIFY_RETRY_BASE_SECONDS", "0.5"))
    RETRY_MAX_SECONDS = Float(ENV.fetch("SHOPIFY_RETRY_MAX_SECONDS", "8"))
    OPEN_TIMEOUT = Integer(ENV.fetch("SHOPIFY_HTTP_OPEN_TIMEOUT", "10"))
    READ_TIMEOUT = Integer(ENV.fetch("SHOPIFY_HTTP_READ_TIMEOUT", "30"))
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    RETRYABLE_NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, IOError
    ].freeze

    def initialize(config)
      @config = config
    end

    def valid_shop_domain?(shop)
      shop.to_s.match?(/\A[a-zA-Z0-9][a-zA-Z0-9-]*\.myshopify\.com\z/)
    end

    def generate_nonce
      SecureRandom.hex(16)
    end

    def build_auth_url(shop, redirect_uri, state)
      params = [
        ["client_id", @config.shopify_api_key],
        ["scope", @config.shopify_scopes.join(",")],
        ["redirect_uri", redirect_uri],
        ["state", state]
      ]
      # Opt into expiring offline access tokens (token rotation); the exchange
      # then returns expires_in + refresh_token.
      params << ["grant_options[]", "expiring_offline_access_token"] if @config.respond_to?(:expiring_tokens?) && @config.expiring_tokens?
      "https://#{shop}/admin/oauth/authorize?#{URI.encode_www_form(params)}"
    end

    def verify_hmac(params)
      params = params.dup
      provided = params.delete("hmac")
      return false if provided.to_s.empty?

      message = params.keys.sort.map { |key| "#{key}=#{params[key]}" }.join("&")
      digest = OpenSSL::HMAC.hexdigest("sha256", @config.shopify_api_secret, message)
      secure_compare(provided, digest)
    end

    def verify_webhook_hmac(raw_body, provided_hmac)
      return false if provided_hmac.to_s.empty?

      digest = OpenSSL::HMAC.digest("sha256", @config.shopify_api_secret, raw_body.to_s)
      provided = Base64.strict_decode64(provided_hmac.to_s)
      secure_compare(provided, digest)
    rescue ArgumentError
      false
    end

    def exchange_token(shop, code)
      uri = URI("https://#{shop}/admin/oauth/access_token")
      response = post_json(uri, {
        client_id: @config.shopify_api_key,
        client_secret: @config.shopify_api_secret,
        code: code
      })
      JSON.parse(response.body)
    end

    # Exchange a refresh token for a new (access_token, refresh_token) pair when
    # using expiring offline access tokens.
    def refresh_access_token(shop, refresh_token)
      uri = URI("https://#{shop}/admin/oauth/access_token")
      response = post_json(uri, {
        client_id: @config.shopify_api_key,
        client_secret: @config.shopify_api_secret,
        grant_type: "refresh_token",
        refresh_token: refresh_token
      })
      JSON.parse(response.body)
    end

    def fetch_shop_info(shop, access_token)
      uri = URI("https://#{shop}/admin/api/#{@config.api_version}/shop.json")
      response = request(uri, Net::HTTP::Get.new(uri), access_token: access_token)
      JSON.parse(response.body).fetch("shop", {})
    end

    def graph_ql(shop, access_token, query, variables = {})
      uri = URI("https://#{shop}/admin/api/#{@config.api_version}/graphql.json")
      attempt = 0

      loop do
        attempt += 1
        response = post_json(uri, { query: query, variables: variables }, access_token: access_token)
        payload = JSON.parse(response.body)

        # GraphQL cost throttling returns HTTP 200 with a THROTTLED error.
        if graphql_throttled?(payload) && attempt <= MAX_RETRIES
          sleep(graphql_throttle_delay(payload, attempt))
          next
        end

        if payload["errors"] && !payload["errors"].empty?
          raise RateLimitError, "Shopify API rate limit reached. Please retry shortly." if graphql_throttled?(payload)

          raise "Shopify GraphQL error: #{payload['errors'].map { |error| error['message'] }.join(', ')}"
        end

        return payload.fetch("data")
      end
    end

    def graphql_throttled?(payload)
      Array(payload["errors"]).any? do |error|
        error.is_a?(Hash) && error.dig("extensions", "code") == "THROTTLED"
      end
    end

    # Wait based on Shopify's reported throttleStatus when available, else backoff.
    def graphql_throttle_delay(payload, attempt)
      cost = payload.dig("extensions", "cost")
      status = cost && cost["throttleStatus"]
      if status
        requested = cost["requestedQueryCost"].to_f
        available = status["currentlyAvailable"].to_f
        restore = status["restoreRate"].to_f
        if restore.positive? && requested > available
          wait = (requested - available) / restore
          return [[wait, RETRY_MAX_SECONDS].min, RETRY_BASE_SECONDS].max
        end
      end

      retry_delay(attempt)
    end

    # Shopify Billing: create a recurring app subscription. Returns the
    # confirmationUrl (send the merchant there to approve) and the subscription.
    def create_app_subscription(shop, access_token, name:, amount:, currency:, return_url:, trial_days: 0, test: true)
      variables = {
        "name" => name,
        "returnUrl" => return_url,
        "test" => test,
        "trialDays" => trial_days.to_i,
        "lineItems" => [{
          "plan" => {
            "appRecurringPricingDetails" => {
              "price" => { "amount" => amount, "currencyCode" => currency },
              "interval" => "EVERY_30_DAYS"
            }
          }
        }]
      }
      data = graph_ql(shop, access_token, <<~GRAPHQL, variables)
        mutation CreateAppSubscription($name: String!, $returnUrl: URL!, $test: Boolean, $trialDays: Int, $lineItems: [AppSubscriptionLineItemInput!]!) {
          appSubscriptionCreate(name: $name, returnUrl: $returnUrl, test: $test, trialDays: $trialDays, lineItems: $lineItems) {
            confirmationUrl
            appSubscription { id status }
            userErrors { field message }
          }
        }
      GRAPHQL
      result = data.fetch("appSubscriptionCreate")
      errors = result["userErrors"] || []
      raise "Shopify billing error: #{errors.map { |error| error['message'] }.join(', ')}" unless errors.empty?

      result
    end

    # Cancels a recurring subscription (e.g. when downgrading to the free plan)
    # so the merchant stops being billed. No-op-safe if the id is blank.
    def cancel_app_subscription(shop, access_token, subscription_id)
      return if subscription_id.to_s.empty?

      data = graph_ql(shop, access_token, <<~GRAPHQL, { "id" => subscription_id })
        mutation CancelAppSubscription($id: ID!) {
          appSubscriptionCancel(id: $id) {
            appSubscription { id status }
            userErrors { field message }
          }
        }
      GRAPHQL
      result = data.fetch("appSubscriptionCancel")
      errors = result["userErrors"] || []
      raise "Shopify billing error: #{errors.map { |error| error['message'] }.join(', ')}" unless errors.empty?

      result
    end

    # Returns the merchant's currently ACTIVE app subscription, or nil.
    def active_subscription(shop, access_token)
      data = graph_ql(shop, access_token, <<~GRAPHQL)
        query ActiveSubscriptions {
          currentAppInstallation {
            activeSubscriptions { id name status }
          }
        }
      GRAPHQL
      subscriptions = data.dig("currentAppInstallation", "activeSubscriptions") || []
      subscriptions.find { |subscription| subscription["status"] == "ACTIVE" }
    end

    def start_bulk_query(shop, access_token, query)
      data = graph_ql(shop, access_token, <<~GRAPHQL, { "query" => query })
        mutation StartBulkQuery($query: String!) {
          bulkOperationRunQuery(query: $query) {
            bulkOperation {
              id
              status
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL
      result = data.fetch("bulkOperationRunQuery")
      errors = result.fetch("userErrors", [])
      unless errors.empty?
        raise "Shopify bulk query error: #{errors.map { |error| error['message'] }.join(', ')}"
      end

      result.fetch("bulkOperation")
    end

    def bulk_operation(shop, access_token, operation_id)
      data = graph_ql(shop, access_token, <<~GRAPHQL, { "id" => operation_id })
        query BulkOperation($id: ID!) {
          bulkOperation(id: $id) {
            id
            status
            errorCode
            createdAt
            completedAt
            objectCount
            fileSize
            url
            partialDataUrl
          }
        }
      GRAPHQL

      data.fetch("bulkOperation")
    end

    def order_count(shop, access_token, query)
      data = graph_ql(shop, access_token, <<~GRAPHQL, { "query" => query })
        query OrderCount($query: String) {
          ordersCount(query: $query, limit: null) {
            count
            precision
          }
        }
      GRAPHQL

      data.fetch("ordersCount").fetch("count").to_i
    end

    def ensure_webhook_subscription(shop, access_token, topic:, uri:)
      data = graph_ql(shop, access_token, <<~GRAPHQL, { "topics" => [topic] })
        query WebhookSubscriptions($topics: [WebhookSubscriptionTopic!]) {
          webhookSubscriptions(first: 50, topics: $topics) {
            nodes {
              id
              topic
              uri
            }
          }
        }
      GRAPHQL

      existing = data.fetch("webhookSubscriptions").fetch("nodes", []).find do |subscription|
        subscription["topic"] == topic && subscription["uri"] == uri
      end
      return existing if existing

      stale = data.fetch("webhookSubscriptions").fetch("nodes", []).find do |subscription|
        subscription["topic"] == topic
      end
      return update_webhook_subscription(shop, access_token, stale.fetch("id"), uri) if stale

      variables = {
        "topic" => topic,
        "subscription" => { "uri" => uri, "format" => "JSON" }
      }
      data = graph_ql(shop, access_token, <<~GRAPHQL, variables)
        mutation CreateWebhookSubscription(
          $topic: WebhookSubscriptionTopic!,
          $subscription: WebhookSubscriptionInput!
        ) {
          webhookSubscriptionCreate(topic: $topic, webhookSubscription: $subscription) {
            webhookSubscription {
              id
              topic
              uri
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      result = data.fetch("webhookSubscriptionCreate")
      errors = result.fetch("userErrors", [])
      unless errors.empty?
        raise "Shopify webhook subscription error: #{errors.map { |error| error['message'] }.join(', ')}"
      end

      result.fetch("webhookSubscription")
    end

    def stream_bulk_result(url)
      uri = URI(url)
      buffer = +""
      request = Net::HTTP::Get.new(uri)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise "Shopify bulk result download failed: #{response.code} #{response.body}"
          end

          response.read_body do |chunk|
            buffer << chunk
            while (index = buffer.index("\n"))
              line = buffer.slice!(0..index).strip
              yield line unless line.empty?
            end
          end
        end
      end

      line = buffer.strip
      yield line unless line.empty?
    end

    private

    def update_webhook_subscription(shop, access_token, subscription_id, uri)
      variables = {
        "id" => subscription_id,
        "subscription" => { "uri" => uri, "format" => "JSON" }
      }
      data = graph_ql(shop, access_token, <<~GRAPHQL, variables)
        mutation UpdateWebhookSubscription(
          $id: ID!,
          $subscription: WebhookSubscriptionInput!
        ) {
          webhookSubscriptionUpdate(id: $id, webhookSubscription: $subscription) {
            webhookSubscription {
              id
              topic
              uri
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      result = data.fetch("webhookSubscriptionUpdate")
      errors = result.fetch("userErrors", [])
      unless errors.empty?
        raise "Shopify webhook subscription update error: #{errors.map { |error| error['message'] }.join(', ')}"
      end

      result.fetch("webhookSubscription")
    end

    def post_json(uri, payload, access_token: nil)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["X-Shopify-Access-Token"] = access_token if access_token
      request.body = JSON.generate(payload)
      request(uri, request, access_token: access_token)
    end

    def request(uri, request, access_token: nil)
      request["X-Shopify-Access-Token"] = access_token if access_token
      attempt = 0

      loop do
        attempt += 1
        response =
          begin
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
              http.request(request)
            end
          rescue *RETRYABLE_NETWORK_ERRORS => e
            raise "Shopify request error: #{e.class}: #{e.message}" if attempt > MAX_RETRIES

            sleep(retry_delay(attempt))
            next
          end

        return response if response.is_a?(Net::HTTPSuccess)

        code = response.code.to_i
        if RETRYABLE_STATUSES.include?(code) && attempt <= MAX_RETRIES
          sleep(retry_delay(attempt, response))
          next
        end

        raise RateLimitError, "Shopify API rate limit reached. Please retry shortly." if code == 429

        raise "Shopify request failed: #{response.code} #{response.body}"
      end
    end

    # Exponential backoff with jitter; honors a Retry-After header when present.
    def retry_delay(attempt, response = nil)
      if response && response["Retry-After"]
        after = response["Retry-After"].to_f
        return after if after.positive?
      end

      delay = RETRY_BASE_SECONDS * (2**(attempt - 1))
      [delay, RETRY_MAX_SECONDS].min + rand * 0.25
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      left_bytes = left.unpack("C*")
      result = 0
      right.each_byte.with_index { |byte, index| result |= byte ^ left_bytes[index] }
      result.zero?
    end
  end
end
