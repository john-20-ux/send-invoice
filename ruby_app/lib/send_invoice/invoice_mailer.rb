# frozen_string_literal: true

require "base64"
require "fileutils"
require "securerandom"

module SendInvoice
  class InvoiceMailer
    def initialize(config)
      @config = config
    end

    def deliver(to:, subject:, body:, pdf_bytes:, filename:, reply_to: nil)
      message_id = "<#{SecureRandom.hex(12)}@send-invoice.local>"
      from_name = @config.smtp_from_name.to_s.empty? ? "Send Invoice" : @config.smtp_from_name
      from_email = @config.smtp_from_email.to_s.empty? ? "no-reply@send-invoice.local" : @config.smtp_from_email
      mime = build_message(
        from_name: from_name,
        from_email: from_email,
        to: to,
        subject: subject,
        body: body,
        pdf_bytes: pdf_bytes,
        filename: filename,
        message_id: message_id,
        reply_to: reply_to
      )

      if @config.smtp_configured?
        send_via_smtp(from_email, to, mime)
        {
          "status" => "sent",
          "channel" => "smtp",
          "target" => "#{@config.smtp_host}:#{@config.smtp_port}",
          "external_message_id" => message_id,
          "outbox_path" => nil
        }
      else
        outbox_path = write_to_outbox(filename, mime)
        {
          "status" => "outbox",
          "channel" => "local_outbox",
          "target" => outbox_path,
          "external_message_id" => message_id,
          "outbox_path" => outbox_path
        }
      end
    end

    private

    def build_message(from_name:, from_email:, to:, subject:, body:, pdf_bytes:, filename:, message_id:, reply_to:)
      boundary = "send-invoice-#{SecureRandom.hex(12)}"
      encoded_pdf = [pdf_bytes].pack("m0")

      lines = []
      lines << "From: #{from_name} <#{from_email}>"
      lines << "To: #{to}"
      lines << "Reply-To: #{reply_to}" unless reply_to.to_s.empty?
      lines << "Subject: #{subject}"
      lines << "Message-ID: #{message_id}"
      lines << "MIME-Version: 1.0"
      lines << "Content-Type: multipart/mixed; boundary=#{boundary}"
      lines << ""
      lines << "--#{boundary}"
      lines << "Content-Type: text/plain; charset=UTF-8"
      lines << "Content-Transfer-Encoding: 8bit"
      lines << ""
      lines << body.to_s
      lines << ""
      lines << "--#{boundary}"
      lines << "Content-Type: application/pdf; name=\"#{filename}\""
      lines << "Content-Transfer-Encoding: base64"
      lines << "Content-Disposition: attachment; filename=\"#{filename}\""
      lines << ""
      lines << encoded_pdf.scan(/.{1,76}/).join("\r\n")
      lines << "--#{boundary}--"
      lines << ""
      lines.join("\r\n")
    end

    def send_via_smtp(from_email, to, message)
      require "net/smtp"

      smtp = Net::SMTP.new(@config.smtp_host, @config.smtp_port)
      smtp.enable_starttls_auto if @config.smtp_use_tls
      authentication = @config.smtp_username.empty? ? nil : @config.smtp_authentication.to_sym

      smtp.start(
        "localhost",
        @config.smtp_username.empty? ? nil : @config.smtp_username,
        @config.smtp_username.empty? ? nil : @config.smtp_password,
        authentication
      ) do |smtp_session|
        smtp_session.send_message(message, from_email, to)
      end
    end

    def write_to_outbox(filename, mime)
      FileUtils.mkdir_p(@config.outbox_path)
      safe_name = filename.to_s.gsub(/[^a-zA-Z0-9.\-_]+/, "-")
      path = File.join(@config.outbox_path, "#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{safe_name}.eml")
      File.write(path, mime)
      path
    end
  end
end
