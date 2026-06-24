# frozen_string_literal: true

require "json"
require "base64"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module SendInvoice
  class ShopifyClient
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
      query = URI.encode_www_form(
        client_id: @config.shopify_api_key,
        scope: @config.shopify_scopes.join(","),
        redirect_uri: redirect_uri,
        state: state
      )
      "https://#{shop}/admin/oauth/authorize?#{query}"
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

    def fetch_shop_info(shop, access_token)
      uri = URI("https://#{shop}/admin/api/#{@config.api_version}/shop.json")
      response = request(uri, Net::HTTP::Get.new(uri), access_token: access_token)
      JSON.parse(response.body).fetch("shop", {})
    end

    def graph_ql(shop, access_token, query, variables = {})
      uri = URI("https://#{shop}/admin/api/#{@config.api_version}/graphql.json")
      response = post_json(uri, { query: query, variables: variables }, access_token: access_token)
      payload = JSON.parse(response.body)

      if payload["errors"] && !payload["errors"].empty?
        raise "Shopify GraphQL error: #{payload['errors'].map { |error| error['message'] }.join(', ')}"
      end

      payload.fetch("data")
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
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        response = http.request(request)
        return response if response.is_a?(Net::HTTPSuccess)

        raise "Shopify request failed: #{response.code} #{response.body}"
      end
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
