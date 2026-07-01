# frozen_string_literal: true

require "cgi"
require "erb"
require "i18n"
require "time"
require "uri"

module SendInvoice
  module ViewHelpers
    # Translate a key for the current locale. Values may contain trusted HTML
    # (e.g. <strong>); interpolate with keyword args: t("plans.choose", name: x).
    def t(key, **options)
      I18n.t(key, **options)
    end

    CURRENCY_SYMBOLS = {
      "USD" => "$",
      "EUR" => "EUR ",
      "GBP" => "GBP ",
      "INR" => "INR "
    }.freeze

    def format_money(amount, currency = "USD")
      symbol = CURRENCY_SYMBOLS.fetch(currency.to_s, "#{currency} ")
      value = amount.to_f
      sign = value.negative? ? "-" : ""
      "#{sign}#{symbol}#{group_thousands(format('%.2f', value.abs))}"
    end

    # Add thousands separators to a plain decimal string ("2354.73" -> "2,354.73").
    def group_thousands(value)
      whole, fraction = value.to_s.split(".")
      negative = whole.start_with?("-")
      whole = whole.delete_prefix("-")
      whole = whole.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      grouped = fraction ? "#{whole}.#{fraction}" : whole
      negative ? "-#{grouped}" : grouped
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

    def humanize_status(status)
      status.to_s.split(/[_\s]+/).reject(&:empty?).map(&:capitalize).join(" ")
    end

    # Inline nav icons keyed by route, used by the collapsible sidebar rail.
    def nav_icon(path)
      paths = {
        "/dashboard" => '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/>',
        "/orders" => '<path d="M5 3h14v18l-3-2-2 2-2-2-2 2-3-2z"/><path d="M9 8h6M9 12h6"/>',
        "/vendors" => '<circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0112 0"/><path d="M16 7a3 3 0 010 6M21 20a6 6 0 00-5-5.9"/>',
        "/invoice-templates" => '<path d="M6 3h9l3 3v15H6z"/><path d="M9 9h6M9 13h6M9 17h4"/>',
        "/notifications" => '<path d="M6 9a6 6 0 0112 0c0 5 2 7 2 7H4s2-2 2-7"/><path d="M10 20a2 2 0 004 0"/>',
        "/settings" => '<circle cx="12" cy="12" r="3"/><path d="M19.4 13a1.7 1.7 0 00.3 1.9l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-3 1.2 2 2 0 11-4 0 1.7 1.7 0 00-3-1.2l-.1.1a2 2 0 11-2.8-2.8l.1-.1A1.7 1.7 0 004.6 13a2 2 0 110-4 1.7 1.7 0 001.5-2.6l-.1-.1a2 2 0 112.8-2.8l.1.1A1.7 1.7 0 0011 4.6a2 2 0 114 0 1.7 1.7 0 003 1.2l.1-.1a2 2 0 112.8 2.8l-.1.1A1.7 1.7 0 0019.4 11a2 2 0 110 4z"/>',
        "/support" => '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5"/><path d="M5 5l3.5 3.5M19 5l-3.5 3.5M5 19l3.5-3.5M19 19l-3.5-3.5"/>',
        "/queue-ops" => '<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/>'
      }
      inner = paths[path] || '<circle cx="12" cy="12" r="3.5"/>'
      %(<svg class="nav-icon" viewBox="0 0 24 24" width="18" height="18" fill="none" ) +
        %(stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{inner}</svg>)
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
