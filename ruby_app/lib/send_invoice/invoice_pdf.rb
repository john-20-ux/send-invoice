# frozen_string_literal: true

require "prawn"
require "prawn/table"

module SendInvoice
  # Renders the invoice as a styled PDF that mirrors the on-screen invoice
  # (and the template studio preview): accent-colored branding, an issuer/bill-to
  # grid, a line-item table, a totals stack, and an optional footer. Built with
  # Prawn (pure Ruby) so it needs no system binaries to deploy.
  class InvoicePdf
    TEXT = "24282d"
    MUTED = "667085"
    LINE = "d7dce3"
    DEFAULT_ACCENT = "0f6e58"

    def generate(document)
      accent = sanitize_hex(document["accent_color"], DEFAULT_ACCENT)
      symbol = document["currency_symbol"].to_s
      visible = document["visible_fields"] || {}

      pdf = Prawn::Document.new(page_size: "A4", margin: 44)
      pdf.font(base_font(document["font_family"]))
      pdf.fill_color TEXT

      render_header(pdf, document, accent)
      render_parties(pdf, document, visible)
      render_line_items(pdf, document, accent, symbol)
      render_totals(pdf, document, accent, symbol)
      render_footer(pdf, document, visible)

      pdf.render
    end

    private

    def render_header(pdf, document, accent)
      top = pdf.cursor
      meta_width = 170

      pdf.bounding_box([pdf.bounds.width - meta_width, top], width: meta_width, height: 64) do
        pdf.text document["invoice_number"].to_s, size: 13, style: :bold, align: :right
        pdf.move_down 2
        pdf.fill_color MUTED
        pdf.text document["invoice_date"].to_s, size: 9, align: :right
        pdf.text document["due_date"].to_s, size: 9, align: :right
        pdf.fill_color TEXT
      end

      pdf.bounding_box([0, top], width: pdf.bounds.width - meta_width - 20, height: 64) do
        logo = document["logo_text"].to_s
        unless logo.empty?
          pdf.fill_color accent
          pdf.fill_rounded_rectangle [0, pdf.cursor], 42, 42, 6
          pdf.fill_color "ffffff"
          pdf.formatted_text_box [{ text: logo, styles: [:bold], size: 13 }],
                                 at: [0, pdf.cursor - 14], width: 42, align: :center
          pdf.fill_color TEXT
        end

        x = logo.empty? ? 0 : 52
        pdf.bounding_box([x, pdf.cursor], width: pdf.bounds.width - x) do
          badge = document["template"].to_s
          unless badge.empty?
            pdf.fill_color accent
            pdf.text badge.upcase, size: 7.5, style: :bold, character_spacing: 1
            pdf.fill_color TEXT
            pdf.move_down 2
          end
          pdf.text document["company_name"].to_s, size: 16, style: :bold
          tagline = document["tagline"].to_s
          unless tagline.empty?
            pdf.fill_color MUTED
            pdf.text tagline, size: 9.5
            pdf.fill_color TEXT
          end
        end
      end

      pdf.move_cursor_to top - 64
      pdf.stroke_color accent
      pdf.line_width 2
      pdf.stroke_horizontal_rule
      pdf.line_width 1
      pdf.stroke_color LINE
      pdf.move_down 18
    end

    def render_parties(pdf, document, visible)
      issuer = [document["address"], document["phone"], document["email"]]
      issuer << document["gst"] if visible["gst"]
      issuer << document["website"] if visible["website"]

      bill = [document["bill_to"]]
      bill.concat(document["client_address"].to_s.split("\n"))
      bill << document["client_email"]
      bill << document["payment_terms"]

      issuer_text = clean_lines(issuer)
      bill_text = clean_lines(bill)

      pdf.table([["ISSUER", "BILL TO"], [issuer_text, bill_text]], width: pdf.bounds.width) do |table|
        table.cells.borders = []
        table.cells.padding = [0, 14, 0, 0]
        table.cells.size = 9.5
        table.cells.leading = 2
        table.column(0).width = pdf.bounds.width / 2.0
        table.row(0).text_color = MUTED
        table.row(0).size = 8
        table.row(0).font_style = :bold
        table.row(1).padding = [5, 14, 0, 0]
      end

      pdf.move_down 22
    end

    def render_line_items(pdf, document, accent, symbol)
      header = ["Description", "Qty", "Rate", "Amount"]
      rows = Array(document["line_items"]).map do |line_item|
        desc = line_item["desc"].to_s
        desc += "\n#{line_item['variant']}" unless line_item["variant"].to_s.empty?
        [desc, line_item["qty"].to_s, money(symbol, line_item["rate"]), money(symbol, line_item["total"])]
      end
      rows = [["No line items on this order", "", "", ""]] if rows.empty?

      pdf.table([header] + rows, width: pdf.bounds.width) do |table|
        table.header = true
        table.cells.borders = [:bottom]
        table.cells.border_color = LINE
        table.cells.border_width = 0.5
        table.cells.padding = [7, 6, 7, 6]
        table.cells.size = 9.5
        table.column(0).width = pdf.bounds.width * 0.52
        table.column(1).align = :right
        table.column(2).align = :right
        table.column(3).align = :right
        table.row(0).font_style = :bold
        table.row(0).text_color = "ffffff"
        table.row(0).background_color = accent
        table.row(0).borders = []
      end

      pdf.move_down 16
    end

    def render_totals(pdf, document, accent, symbol)
      data = [
        ["Subtotal", money(symbol, document["subtotal_amount"])],
        ["Discounts", money(symbol, document["discounts_amount"])],
        ["Shipping", money(symbol, document["shipping_amount"])],
        ["Tax", money(symbol, document["tax_amount"])],
        ["Total", money(symbol, document["total_amount"])]
      ]
      width = 230
      last = data.length - 1

      pdf.indent(pdf.bounds.width - width) do
        pdf.table(data, width: width) do |table|
          table.cells.borders = []
          table.cells.padding = [3, 0, 3, 0]
          table.cells.size = 9.5
          table.column(1).align = :right
          table.row(last).font_style = :bold
          table.row(last).size = 11.5
          table.row(last).text_color = accent
          table.row(last).borders = [:top]
          table.row(last).border_color = LINE
          table.row(last).padding = [7, 0, 3, 0]
        end
      end

      pdf.move_down 20
    end

    def render_footer(pdf, document, visible)
      parts = []
      parts << document["notes"] if visible["notes"]
      parts << document["bank_details"] if visible["bank_details"]
      parts << document["terms"] if visible["terms"]
      parts = parts.map(&:to_s).reject(&:empty?)
      return if parts.empty?

      pdf.stroke_color LINE
      pdf.stroke_horizontal_rule
      pdf.move_down 10
      pdf.fill_color MUTED
      parts.each do |part|
        pdf.text part, size: 9, leading: 2
        pdf.move_down 4
      end
      pdf.fill_color TEXT
    end

    def clean_lines(values)
      values.map(&:to_s).reject(&:empty?).join("\n")
    end

    def money(symbol, amount)
      "#{symbol}#{format('%.2f', amount.to_f)}"
    end

    def base_font(font_family)
      family = font_family.to_s.downcase
      return "Times-Roman" if family.match?(/serif|georgia|times/)
      return "Courier" if family.match?(/mono|courier/)

      "Helvetica"
    end

    def sanitize_hex(value, fallback)
      hex = value.to_s.delete("#").strip
      hex.match?(/\A[0-9a-fA-F]{6}\z/) ? hex : fallback
    end
  end
end
