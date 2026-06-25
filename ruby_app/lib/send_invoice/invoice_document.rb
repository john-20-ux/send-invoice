# frozen_string_literal: true

module SendInvoice
  class InvoiceDocument
    include ViewHelpers

    def initialize(shop:, order:, invoice_config:)
      @shop = shop
      @order = order
      @invoice_config = invoice_config
    end

    def payload
      @payload ||= begin
        raw = @order["raw_data"].is_a?(Hash) ? @order["raw_data"] : {}
        shipping_lines = address_lines(raw["shippingAddress"] || {})
        billing_lines = address_lines(raw["billingAddress"] || {})
        customer_name = [@order["customer_first_name"], @order["customer_last_name"]].compact.join(" ").strip
        invoice_date = format_date(@order["created_at"])
        due_date = format_date(invoice_due_time)
        line_items = Array(@order["line_items"]).map do |line_item|
          {
            "desc" => line_item["title"].to_s,
            "variant" => line_item["variantTitle"].to_s,
            "sku" => line_item["sku"].to_s,
            "vendor" => line_item["vendor"].to_s,
            "qty" => line_item["quantity"].to_i,
            "rate" => line_rate(line_item),
            "total" => line_item["totalAmount"].to_f
          }
        end

        {
          "shop_name" => @shop["shop_name"],
          "company_name" => @invoice_config["company_name"],
          "tagline" => @invoice_config["tagline"],
          "address" => @invoice_config["address"],
          "phone" => @invoice_config["phone"],
          "email" => @invoice_config["email"],
          "website" => @invoice_config["website"],
          "gst" => @invoice_config["gst"],
          "bill_to" => customer_name.empty? ? @invoice_config["bill_to"] : customer_name,
          "client_address" => (billing_lines.any? ? billing_lines : shipping_lines).join("\n"),
          "client_email" => @order["customer_email"].to_s,
          "invoice_number" => derived_invoice_number,
          "invoice_date" => invoice_date,
          "due_date" => due_date,
          "payment_terms" => @invoice_config["payment_terms"],
          "notes" => @invoice_config["notes"],
          "bank_details" => @invoice_config["bank_details"],
          "terms" => @invoice_config["terms"],
          "template" => @invoice_config["template"],
          "currency_symbol" => @invoice_config["currency_symbol"],
          "accent_color" => @invoice_config["accent_color"],
          "surface_tone" => @invoice_config["surface_tone"],
          "font_family" => @invoice_config["font_family"],
          "density" => @invoice_config["density"],
          "header_align" => @invoice_config["header_align"],
          "logo_text" => @invoice_config["logo_text"],
          "visible_fields" => @invoice_config["visible_fields"] || {},
          "order_name" => @order["name"],
          "line_items" => line_items,
          "subtotal_amount" => line_items.sum { |line_item| line_item["total"] },
          "discounts_amount" => @order["total_discounts_amount"].to_f,
          "shipping_amount" => @order["total_shipping_amount"].to_f,
          "tax_amount" => @order["total_tax_amount"].to_f,
          "total_amount" => @order["total_price_amount"].to_f,
          "currency" => @order["total_price_currency"]
        }
      end
    end

    def tokens
      document = payload
      {
        "company" => document["company_name"].to_s,
        "shop_name" => document["shop_name"].to_s,
        "name" => document["bill_to"].to_s,
        "customer_name" => document["bill_to"].to_s,
        "recipient_email" => document["client_email"].to_s,
        "invoice_number" => document["invoice_number"].to_s,
        "invoice_date" => document["invoice_date"].to_s,
        "due_date" => document["due_date"].to_s,
        "order_name" => document["order_name"].to_s,
        "invoice_total" => format_money(document["total_amount"], document["currency"]),
        "payment_terms" => document["payment_terms"].to_s
      }
    end

    def render_template(text)
      rendered = text.to_s.dup
      tokens.each do |key, value|
        rendered.gsub!("{{#{key}}}", value.to_s)
      end
      rendered
    end

    def filename
      "invoice-#{derived_invoice_number.downcase.gsub(/[^a-z0-9]+/, '-')}.pdf"
    end

    private

    def derived_invoice_number
      @derived_invoice_number ||= begin
        numeric = @order["name"].to_s.gsub(/[^0-9A-Za-z]+/, "")
        return @invoice_config["invoice_number"] if numeric.empty?

        "INV-#{numeric}"
      end
    end

    def invoice_due_time
      Time.parse(@order["created_at"].to_s) + (7 * 86_400)
    rescue ArgumentError
      Time.now.utc + (7 * 86_400)
    end

    def line_rate(line_item)
      quantity = line_item["quantity"].to_f
      total = line_item["totalAmount"].to_f
      return total if quantity <= 0

      total / quantity
    end
  end
end
