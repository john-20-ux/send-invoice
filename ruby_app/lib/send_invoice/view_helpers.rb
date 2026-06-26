# frozen_string_literal: true

require "cgi"
require "erb"
require "time"
require "uri"

module SendInvoice
  module ViewHelpers
    CURRENCY_SYMBOLS = {
      "USD" => "$",
      "EUR" => "EUR ",
      "GBP" => "GBP ",
      "INR" => "INR "
    }.freeze

    def format_money(amount, currency = "USD")
      symbol = CURRENCY_SYMBOLS.fetch(currency.to_s, "#{currency} ")
      "#{symbol}#{format('%.2f', amount.to_f)}"
    end

    def format_date(value)
      return "-" unless value

      Time.parse(value.to_s).strftime("%b %-d, %Y")
    end

    def format_datetime(value)
      return "-" unless value

      Time.parse(value.to_s).strftime("%b %-d, %Y at %-I:%M %p")
    end

    def format_weight(value)
      amount = value.to_f
      return "-" unless amount.positive?

      if amount >= 1000
        "#{format('%.2f', amount / 1000.0)} kg"
      else
        "#{amount.round} g"
      end
    end

    def time_ago(value)
      return "never" unless value

      seconds = Time.now - Time.parse(value.to_s)
      if seconds < 60
        "#{seconds.to_i}s ago"
      elsif seconds < 3600
        "#{(seconds / 60).to_i}m ago"
      elsif seconds < 86_400
        "#{(seconds / 3600).to_i}h ago"
      else
        "#{(seconds / 86_400).to_i}d ago"
      end
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def active_path?(current_path, candidate)
      current_path == candidate || (candidate != "/dashboard" && current_path.start_with?(candidate))
    end

    def badge_class(status)
      case status.to_s
      when "PAID", "FULFILLED", "completed"
        "badge badge-success"
      when "PARTIALLY_PAID", "PARTIALLY_FULFILLED", "IN_PROGRESS", "running"
        "badge badge-warn"
      when "REFUNDED", "PARTIALLY_REFUNDED", "failed"
        "badge badge-danger"
      else
        "badge badge-muted"
      end
    end

    def flash_class(type)
      case type.to_s
      when "error"
        "flash flash-error"
      else
        "flash flash-info"
      end
    end

    def percentage(value, total)
      total = total.to_i
      return 0 if total <= 0

      ((value.to_f / total) * 100).round
    end

    def slugify(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    end

    def query_path(path, params = {})
      filtered = params.each_with_object({}) do |(key, value), memo|
        next if value.nil?
        next if value.respond_to?(:empty?) && value.empty?

        memo[key] = value
      end
      query = URI.encode_www_form(filtered)
      query.empty? ? path : "#{path}?#{query}"
    end

    def order_detail_path(order_id, shop_domain = nil)
      query_path("/orders/detail", { "order_id" => order_id.to_s, "shop" => shop_domain })
    end

    def order_invoice_path(order_id, shop_domain = nil)
      query_path("/orders/invoice", { "order_id" => order_id.to_s, "shop" => shop_domain })
    end

    def order_invoice_pdf_path(order_id, shop_domain = nil)
      query_path("/orders/invoice.pdf", { "order_id" => order_id.to_s, "shop" => shop_domain })
    end

    def order_send_invoice_path(order_id, shop_domain = nil)
      query_path("/orders/send-invoice", { "order_id" => order_id.to_s, "shop" => shop_domain })
    end

    def address_lines(address)
      return [] unless address.is_a?(Hash)

      name = [address["name"], address["firstName"], address["lastName"]].compact.join(" ").strip
      city_line = [
        address["city"],
        address["province"] || address["provinceCode"],
        address["zip"] || address["postalCode"]
      ].compact.reject(&:empty?).join(", ")

      [
        name,
        address["company"],
        address["address1"],
        address["address2"],
        city_line,
        address["country"] || address["countryCodeV2"],
        address["phone"]
      ].compact.reject(&:empty?)
    end
  end
end
