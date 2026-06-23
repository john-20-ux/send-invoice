# frozen_string_literal: true

require "json"
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

    private

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
