# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module SendInvoice
  # Thin client for the Meta WhatsApp Cloud API. Uses business-level credentials
  # (one phone number for the whole app) supplied via configuration.
  #
  # Note: WhatsApp only allows free-form text to a user within 24h of their last
  # message to the business. Outside that window a pre-approved template is
  # required, so send_text may return a template-required error from Meta, which
  # we surface verbatim.
  #
  # See https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
  class WhatsAppClient
    class Error < StandardError; end

    OPEN_TIMEOUT = Integer(ENV.fetch("WHATSAPP_HTTP_OPEN_TIMEOUT", "10"))
    READ_TIMEOUT = Integer(ENV.fetch("WHATSAPP_HTTP_READ_TIMEOUT", "30"))
    MAX_RETRIES = Integer(ENV.fetch("WHATSAPP_MAX_RETRIES", "3"))
    RETRY_BASE_SECONDS = Float(ENV.fetch("WHATSAPP_RETRY_BASE_SECONDS", "0.5"))
    RETRYABLE_NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, IOError
    ].freeze

    def initialize(config)
      @config = config
    end

    # Sends a plain text WhatsApp message. `to` is a phone number in international
    # format (e.g. "+1 555 000 1234" or "15550001234"). Returns the parsed
    # response (with the outbound message id) or raises with Meta's error message.
    def send_text(to, body)
      recipient = normalize_number(to)
      raise Error, "Missing WhatsApp recipient number" if recipient.empty?
      raise Error, "Missing WhatsApp message body" if body.to_s.strip.empty?

      url = "https://graph.facebook.com/#{@config.whatsapp_api_version}/#{@config.whatsapp_phone_number_id}/messages"
      payload = post_json(url, {
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => recipient,
        "type" => "text",
        "text" => { "preview_url" => false, "body" => body.to_s }
      })

      if payload["error"]
        message = payload.dig("error", "message") || "unknown_error"
        raise Error, "WhatsApp send failed: #{message}"
      end

      payload
    end

    # Digits only; Meta expects the number without a leading "+" or separators.
    def normalize_number(value)
      value.to_s.gsub(/[^0-9]/, "")
    end

    private

    def post_json(url, payload)
      uri = URI(url)
      attempt = 0

      loop do
        attempt += 1
        response =
          begin
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/json"
            request["Authorization"] = "Bearer #{@config.whatsapp_access_token}"
            request.body = JSON.generate(payload)
            Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
              http.request(request)
            end
          rescue *RETRYABLE_NETWORK_ERRORS => e
            raise Error, "WhatsApp request error: #{e.class}: #{e.message}" if attempt > MAX_RETRIES

            sleep(RETRY_BASE_SECONDS * (2**(attempt - 1)))
            next
          end

        # Meta returns JSON for both success and error (with an HTTP 4xx on error),
        # so parse the body regardless of status and let the caller inspect "error".
        body = response.body.to_s
        return body.empty? ? {} : JSON.parse(body)
      end
    end
  end
end
