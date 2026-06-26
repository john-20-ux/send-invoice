# frozen_string_literal: true

require "send_invoice/view_helpers"
require "send_invoice/invoice_document"
require "send_invoice/mock_data"

module SendInvoice
  # Shared invoice/notification config composition used by both the web App and
  # the InvoiceAutomationEngine so manual and automated sends build identical
  # documents and email drafts from the same merchant configuration.
  module InvoiceComposition
    def merged_invoice_config(shop)
      normalize_invoice_config(
        deep_merge(MockData::DEFAULT_INVOICE_TEMPLATE_CONFIG, shop["invoice_template_config"] || {})
      )
    end

    def merged_notification_config(shop)
      deep_merge(MockData::DEFAULT_NOTIFICATION_CONFIG, shop["notification_config"] || {})
    end

    def invoice_document_for(shop, order)
      InvoiceDocument.new(
        shop: shop,
        order: order,
        invoice_config: merged_invoice_config(shop)
      )
    end

    def invoice_delivery_draft_for(shop, order)
      notification_config = merged_notification_config(shop)
      email_config = notification_config["email"] || {}
      document = invoice_document_for(shop, order)
      {
        "recipient_email" => order["customer_email"].to_s,
        "subject" => document.render_template(email_config["subject"].to_s),
        "body_text" => document.render_template(email_config["body"].to_s)
      }
    end

    def deep_merge(base, override)
      merged = Marshal.load(Marshal.dump(base))
      override.each do |key, value|
        if merged[key].is_a?(Hash) && value.is_a?(Hash)
          merged[key] = deep_merge(merged[key], value)
        else
          merged[key] = value
        end
      end
      merged
    end

    def normalize_invoice_config(config)
      defaults = MockData::DEFAULT_INVOICE_TEMPLATE_CONFIG
      normalized = deep_merge(defaults, config || {})

      %w[
        template currency_symbol accent_color surface_tone font_family density
        header_align logo_text company_name tagline address phone email website gst
        bill_to client_address client_email invoice_number invoice_date due_date
        payment_terms notes bank_details terms
      ].each do |key|
        value = normalized[key].to_s
        normalized[key] = value.strip.empty? ? defaults[key] : value
      end

      visible_defaults = defaults["visible_fields"] || {}
      visible_fields = normalized["visible_fields"].is_a?(Hash) ? normalized["visible_fields"] : {}
      normalized["visible_fields"] = visible_defaults.each_with_object({}) do |(field, default_value), memo|
        memo[field] = visible_fields.key?(field) ? !!visible_fields[field] : default_value
      end

      normalized["line_items"] = Array(normalized["line_items"]).map do |line_item|
        next unless line_item.is_a?(Hash)

        {
          "desc" => line_item["desc"].to_s,
          "qty" => line_item["qty"].to_f,
          "rate" => line_item["rate"].to_f,
          "discount" => line_item["discount"].to_f,
          "tax" => line_item["tax"].to_f
        }
      end.compact

      normalized["line_items"] = defaults["line_items"] if normalized["line_items"].empty?
      normalized
    end
  end
end
