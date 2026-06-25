# frozen_string_literal: true

module SendInvoice
  class InvoicePdf
    PAGE_WIDTH = 595
    PAGE_HEIGHT = 842
    PAGE_LINE_LIMIT = 46

    def generate(document)
      lines = build_lines(document)
      page_chunks = lines.each_slice(PAGE_LINE_LIMIT).to_a
      objects = []

      objects << "<< /Type /Catalog /Pages 2 0 R >>"
      page_ids = []
      content_ids = []

      page_chunks.each_with_index do |chunk, index|
        content_id = 3 + (index * 2)
        page_id = content_id + 1
        content_ids << content_id
        page_ids << page_id
      end

      kids = page_ids.map { |id| "#{id} 0 R" }.join(" ")
      objects << "<< /Type /Pages /Kids [ #{kids} ] /Count #{page_ids.length} >>"

      page_chunks.each_with_index do |chunk, index|
        content = page_stream(chunk)
        objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
        objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{PAGE_WIDTH} #{PAGE_HEIGHT}] /Resources << /Font << /F1 #{3 + (page_chunks.length * 2)} 0 R >> >> /Contents #{content_ids[index]} 0 R >>"
      end

      objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

      buffer = +"%PDF-1.4\n"
      offsets = []
      objects.each_with_index do |object, index|
        offsets << buffer.bytesize
        buffer << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      end

      xref_offset = buffer.bytesize
      buffer << "xref\n0 #{objects.length + 1}\n"
      buffer << "0000000000 65535 f \n"
      offsets.each do |offset|
        buffer << format("%010d 00000 n \n", offset)
      end
      buffer << "trailer << /Size #{objects.length + 1} /Root 1 0 R >>\n"
      buffer << "startxref\n#{xref_offset}\n%%EOF\n"
      buffer
    end

    private

    def build_lines(document)
      visible = document["visible_fields"] || {}
      lines = []
      lines << document["company_name"]
      lines << document["tagline"] unless document["tagline"].to_s.empty?
      lines.concat(document["address"].to_s.split("\n"))
      lines << document["phone"] unless document["phone"].to_s.empty?
      lines << document["email"] unless document["email"].to_s.empty?
      lines << document["website"] if visible["website"] && !document["website"].to_s.empty?
      lines << document["gst"] if visible["gst"] && !document["gst"].to_s.empty?
      lines << ""
      lines << "Invoice #{document['invoice_number']}"
      lines << "Order #{document['order_name']}"
      lines << "Invoice date: #{document['invoice_date']}"
      lines << "Due date: #{document['due_date']}"
      lines << ""
      lines << "Bill to:"
      lines << document["bill_to"]
      lines.concat(document["client_address"].to_s.split("\n")) unless document["client_address"].to_s.empty?
      lines << document["client_email"] unless document["client_email"].to_s.empty?
      lines << ""
      lines << "Items"

      Array(document["line_items"]).each do |line_item|
        descriptor = [line_item["desc"], line_item["variant"]].reject(&:empty?).join(" / ")
        lines << "#{descriptor} | Qty #{line_item['qty']} | Rate #{money(document, line_item['rate'])} | Total #{money(document, line_item['total'])}"
      end

      lines << ""
      lines << "Subtotal: #{money(document, document['subtotal_amount'])}"
      lines << "Discounts: #{money(document, -document['discounts_amount'].to_f)}"
      lines << "Shipping: #{money(document, document['shipping_amount'])}"
      lines << "Tax: #{money(document, document['tax_amount'])}"
      lines << "Total: #{money(document, document['total_amount'])}"
      lines << ""
      lines << "Payment terms: #{document['payment_terms']}" unless document["payment_terms"].to_s.empty?
      lines << "Notes: #{document['notes']}" if visible["notes"] && !document["notes"].to_s.empty?
      lines << "Bank details: #{document['bank_details']}" if visible["bank_details"] && !document["bank_details"].to_s.empty?
      lines << "Terms: #{document['terms']}" if visible["terms"] && !document["terms"].to_s.empty?
      lines
    end

    def money(document, amount)
      "#{document['currency_symbol']}#{format('%.2f', amount.to_f)}"
    end

    def page_stream(lines)
      content = +"BT\n/F1 11 Tf\n50 790 Td\n14 TL\n"
      lines.each_with_index do |line, index|
        content << "(#{escape_text(line.to_s)}) Tj\n"
        content << "T*\n" unless index == lines.length - 1
      end
      content << "ET"
      content
    end

    def escape_text(text)
      text.gsub("\\", "\\\\").gsub("(", "\\(").gsub(")", "\\)")
    end
  end
end
