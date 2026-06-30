# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module SendInvoice
  # Reports exceptions to the structured log and, when ERROR_WEBHOOK_URL is set,
  # to a Slack-compatible incoming webhook. Vendor-agnostic: point the webhook at
  # Slack, a relay, or drop a Sentry SDK in later without changing call sites.
  # Tokens, encrypted blobs, and emails are redacted from messages.
  class ErrorReporter
    REDACTIONS = [
      [/shp[a-z]{2}_[A-Za-z0-9-]+/, "[REDACTED_TOKEN]"],
      [/enc:v1:[A-Za-z0-9+\/=]+/, "[REDACTED_TOKEN]"],
      [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "[REDACTED_EMAIL]"]
    ].freeze

    def initialize(logger:, webhook_url: nil, environment: "development")
      @logger = logger
      @webhook_url = webhook_url.to_s
      @environment = environment.to_s
    end

    def report(error, context = {})
      log(error, context)
      deliver(error, context) unless @webhook_url.empty?
    rescue StandardError => e
      @logger&.warn("[ErrorReporter] delivery failed: #{e.class}: #{e.message}")
    end

    private

    def log(error, context)
      data = {
        "level" => "error",
        "event" => "exception",
        "environment" => @environment,
        "error" => error.class.name,
        "message" => redact(error.message),
        "backtrace" => Array(error.backtrace).first(5).map { |line| redact(line) }
      }.merge(stringify(context))
      @logger&.error(JSON.generate(data))
    end

    def deliver(error, context)
      uri = URI(@webhook_url)
      lines = []
      lines << "*[send-invoice/#{@environment}]* #{error.class}: #{redact(error.message)}"
      lines << context.map { |key, value| "#{key}=#{redact(value.to_s)}" }.join("  ") unless context.empty?
      lines.concat(Array(error.backtrace).first(3).map { |line| redact(line) })

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 3
      http.read_timeout = 3
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate({ "text" => lines.join("\n") })
      http.request(request)
    end

    def stringify(context)
      context.each_with_object({}) { |(key, value), acc| acc[key.to_s] = redact(value.to_s) }
    end

    def redact(value)
      out = value.to_s
      REDACTIONS.each { |pattern, replacement| out = out.gsub(pattern, replacement) }
      out
    end
  end
end
