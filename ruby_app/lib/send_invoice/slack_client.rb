# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module SendInvoice
  # Thin client for Slack's OAuth v2 install flow.
  #
  # Flow:
  #   1. Send the user to authorize_url(...) so they pick a workspace/channel.
  #   2. Slack redirects back with ?code=...&state=...
  #   3. exchange_code(code, redirect_uri) trades the code for a bot token via
  #      https://slack.com/api/oauth.v2.access.
  #
  # See https://docs.slack.dev/reference/methods/oauth.v2.access/
  class SlackClient
    class Error < StandardError; end

    AUTHORIZE_URL = "https://slack.com/oauth/v2/authorize"
    ACCESS_TOKEN_URL = "https://slack.com/api/oauth.v2.access"
    CHAT_POST_MESSAGE_URL = "https://slack.com/api/chat.postMessage"
    CONVERSATIONS_LIST_URL = "https://slack.com/api/conversations.list"
    OPEN_TIMEOUT = Integer(ENV.fetch("SLACK_HTTP_OPEN_TIMEOUT", "10"))
    READ_TIMEOUT = Integer(ENV.fetch("SLACK_HTTP_READ_TIMEOUT", "30"))
    MAX_RETRIES = Integer(ENV.fetch("SLACK_MAX_RETRIES", "3"))
    RETRY_BASE_SECONDS = Float(ENV.fetch("SLACK_RETRY_BASE_SECONDS", "0.5"))
    RETRYABLE_NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, IOError
    ].freeze

    def initialize(config)
      @config = config
    end

    def generate_nonce
      SecureRandom.hex(16)
    end

    # URL the merchant is redirected to so they can grant the app access to a
    # workspace and channel. `scope` is the bot-token scope list.
    def authorize_url(redirect_uri, state)
      params = [
        ["client_id", @config.slack_client_id],
        ["scope", @config.slack_scopes.join(",")],
        ["redirect_uri", redirect_uri],
        ["state", state]
      ]
      "#{AUTHORIZE_URL}?#{URI.encode_www_form(params)}"
    end

    # Exchanges the temporary authorization code for an access token. Returns the
    # parsed Slack response hash (which includes access_token, scope, team, and
    # incoming_webhook when the incoming-webhook scope was requested).
    #
    # Slack always responds HTTP 200; success/failure is carried by the "ok"
    # field, so we raise on ok:false with Slack's own error code.
    def exchange_code(code, redirect_uri)
      payload = post_form(ACCESS_TOKEN_URL, {
        "client_id" => @config.slack_client_id,
        "client_secret" => @config.slack_client_secret,
        "code" => code,
        "redirect_uri" => redirect_uri
      })

      raise Error, "Slack OAuth failed: #{payload['error'] || 'unknown_error'}" unless payload["ok"]

      payload
    end

    # Posts a message to a stored incoming-webhook URL. Slack returns HTTP 200
    # with the body "ok" on success, or a non-200 with an error string (e.g.
    # "channel_not_found", "no_service") which we surface as an Error.
    def post_incoming_webhook(webhook_url, text)
      raise Error, "Missing Slack webhook URL" if webhook_url.to_s.empty?

      body = post_json(webhook_url, { "text" => text })
      raise Error, "Slack webhook rejected the message: #{body}" unless body.strip == "ok"

      true
    end

    # Posts a message to a channel via the Web API using the bot token obtained
    # during OAuth. `channel` may be a channel ID (e.g. "C0123") or name (e.g.
    # "#general"). Works for public channels (with chat:write.public) and for
    # private channels the bot has been invited to. Returns the parsed response.
    #
    # See https://docs.slack.dev/reference/methods/chat.postMessage/
    def post_message(token, channel, text)
      raise Error, "Missing Slack bot token" if token.to_s.empty?
      raise Error, "Missing Slack channel" if channel.to_s.empty?

      body = post_json(
        CHAT_POST_MESSAGE_URL,
        { "channel" => channel, "text" => text },
        headers: { "Authorization" => "Bearer #{token}" }
      )
      payload = JSON.parse(body)
      raise Error, "Slack rejected the message: #{payload['error'] || 'unknown_error'}" unless payload["ok"]

      payload
    end

    # Lists channels the bot can see, for a channel picker. Requires channels:read
    # (public) and groups:read (private the bot is in). Follows cursor pagination.
    # Returns an array of { "id", "name", "is_private" } sorted by name.
    #
    # See https://docs.slack.dev/reference/methods/conversations.list/
    def list_channels(token, types: "public_channel,private_channel", page_limit: 200, max_pages: 10)
      raise Error, "Missing Slack bot token" if token.to_s.empty?

      channels = []
      cursor = nil
      max_pages.times do
        form = { "types" => types, "limit" => page_limit, "exclude_archived" => "true" }
        form["cursor"] = cursor unless cursor.to_s.empty?
        payload = post_form(CONVERSATIONS_LIST_URL, form, headers: { "Authorization" => "Bearer #{token}" })
        raise Error, "Slack rejected conversations.list: #{payload['error'] || 'unknown_error'}" unless payload["ok"]

        Array(payload["channels"]).each do |channel|
          channels << {
            "id" => channel["id"],
            "name" => channel["name"],
            "is_private" => channel["is_private"] ? true : false
          }
        end

        cursor = payload.dig("response_metadata", "next_cursor").to_s
        break if cursor.empty?
      end

      channels.sort_by { |channel| channel["name"].to_s }
    end

    private

    def post_json(url, payload, headers: {})
      uri = URI(url)
      attempt = 0

      loop do
        attempt += 1
        response =
          begin
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/json"
            headers.each { |key, value| request[key] = value }
            request.body = JSON.generate(payload)
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
              http.request(request)
            end
          rescue *RETRYABLE_NETWORK_ERRORS => e
            raise Error, "Slack request error: #{e.class}: #{e.message}" if attempt > MAX_RETRIES

            sleep(RETRY_BASE_SECONDS * (2**(attempt - 1)))
            next
          end

        raise Error, "Slack request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

        return response.body.to_s
      end
    end

    def post_form(url, form, headers: {})
      uri = URI(url)
      attempt = 0

      loop do
        attempt += 1
        response =
          begin
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/x-www-form-urlencoded"
            headers.each { |key, value| request[key] = value }
            request.body = URI.encode_www_form(form)
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
              http.request(request)
            end
          rescue *RETRYABLE_NETWORK_ERRORS => e
            raise Error, "Slack request error: #{e.class}: #{e.message}" if attempt > MAX_RETRIES

            sleep(RETRY_BASE_SECONDS * (2**(attempt - 1)))
            next
          end

        raise Error, "Slack request failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        return JSON.parse(response.body)
      end
    end
  end
end
