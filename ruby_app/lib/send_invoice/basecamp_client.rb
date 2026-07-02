# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module SendInvoice
  # Client for Basecamp 3 via the 37signals OAuth 2 flow.
  #
  # Flow:
  #   1. authorize_url(...) -> user grants access on launchpad.37signals.com
  #   2. exchange_code(code) -> { access_token, refresh_token, expires_in }
  #   3. authorization(token) -> the accounts the user can access (pick a bc3 one)
  #   4. list_projects / post_message against https://3.basecampapi.com/{account}
  #
  # Basecamp requires a descriptive User-Agent with contact info on every request.
  #
  # See https://github.com/basecamp/api and
  # https://github.com/basecamp/api/blob/master/sections/authentication.md
  class BasecampClient
    class Error < StandardError; end
    # Raised specifically when the access token is expired/invalid, so callers can
    # refresh and retry.
    class UnauthorizedError < Error; end

    AUTHORIZE_URL = "https://launchpad.37signals.com/authorization/new"
    TOKEN_URL = "https://launchpad.37signals.com/authorization/token"
    AUTHORIZATION_URL = "https://launchpad.37signals.com/authorization.json"
    API_BASE = "https://3.basecampapi.com"
    OPEN_TIMEOUT = Integer(ENV.fetch("BASECAMP_HTTP_OPEN_TIMEOUT", "10"))
    READ_TIMEOUT = Integer(ENV.fetch("BASECAMP_HTTP_READ_TIMEOUT", "30"))
    MAX_RETRIES = Integer(ENV.fetch("BASECAMP_MAX_RETRIES", "3"))
    RETRY_BASE_SECONDS = Float(ENV.fetch("BASECAMP_RETRY_BASE_SECONDS", "0.5"))
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

    def authorize_url(redirect_uri, state)
      params = [
        ["type", "web_server"],
        ["client_id", @config.basecamp_client_id],
        ["redirect_uri", redirect_uri],
        ["state", state]
      ]
      "#{AUTHORIZE_URL}?#{URI.encode_www_form(params)}"
    end

    def exchange_code(code, redirect_uri)
      request_token(
        "type" => "web_server",
        "client_id" => @config.basecamp_client_id,
        "client_secret" => @config.basecamp_client_secret,
        "redirect_uri" => redirect_uri,
        "code" => code
      )
    end

    def refresh_access_token(refresh_token)
      request_token(
        "type" => "refresh",
        "refresh_token" => refresh_token,
        "client_id" => @config.basecamp_client_id,
        "client_secret" => @config.basecamp_client_secret
      )
    end

    # The bc3 accounts this token can access: [{ "id", "name", "href" }].
    def accounts(token)
      payload = get_json(AUTHORIZATION_URL, token)
      Array(payload["accounts"])
        .select { |account| account["product"] == "bc3" }
        .map { |account| { "id" => account["id"], "name" => account["name"], "href" => account["href"] } }
    end

    # Projects (that have a message board) for an account, for the project picker.
    # Returns [{ "id", "name", "message_board_id" }] — projects without a message
    # board are skipped since we can't post to them.
    def list_projects(account_id, token, page_limit: 100)
      projects = []
      Array(get_json("#{API_BASE}/#{account_id}/projects.json", token)).each do |project|
        board = Array(project["dock"]).find { |tool| tool["name"] == "message_board" && tool["enabled"] }
        next unless board

        projects << { "id" => project["id"], "name" => project["name"], "message_board_id" => board["id"] }
      end
      projects.first(page_limit).sort_by { |project| project["name"].to_s }
    end

    # Posts a message to a project's message board. Returns the created message.
    def post_message(account_id, token, project_id, board_id, subject, content)
      url = "#{API_BASE}/#{account_id}/buckets/#{project_id}/message_boards/#{board_id}/messages.json"
      post_json(url, token, { "subject" => subject, "content" => content, "status" => "active" })
    end

    private

    def request_token(form)
      # Basecamp's token endpoint takes params in the query string on a POST.
      uri = URI(TOKEN_URL)
      uri.query = URI.encode_www_form(form)
      body = http_request(Net::HTTP::Post.new(uri), uri)
      payload = body.empty? ? {} : JSON.parse(body)
      raise Error, "Basecamp OAuth failed: #{payload['error'] || 'unknown_error'}" if payload["error"] || payload["access_token"].nil?

      payload
    end

    def get_json(url, token)
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      apply_headers(request, token)
      body = http_request(request, uri)
      body.empty? ? {} : JSON.parse(body)
    end

    def post_json(url, token, payload)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      apply_headers(request, token)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      body = http_request(request, uri)
      body.empty? ? {} : JSON.parse(body)
    end

    def apply_headers(request, token)
      request["Authorization"] = "Bearer #{token}"
      request["User-Agent"] = @config.basecamp_user_agent
      request["Accept"] = "application/json"
    end

    def http_request(request, uri)
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
            raise Error, "Basecamp request error: #{e.class}: #{e.message}" if attempt > MAX_RETRIES

            sleep(RETRY_BASE_SECONDS * (2**(attempt - 1)))
            next
          end

        raise UnauthorizedError, "Basecamp token expired or invalid" if response.code.to_i == 401

        return response.body.to_s if response.is_a?(Net::HTTPSuccess)

        raise Error, "Basecamp request failed: #{response.code} #{response.body}"
      end
    end
  end
end
