# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "mail"

module SendInvoice
  class InvoiceMailer
    def initialize(config)
      @config = config
    end

    def deliver(to:, subject:, body:, filename:, pdf_bytes: nil, reply_to: nil)
      message_id = "#{SecureRandom.hex(12)}@send-invoice.local"
      mail = build_message(
        to: to,
        subject: subject,
        body: body,
        pdf_bytes: pdf_bytes,
        filename: filename,
        message_id: message_id,
        reply_to: reply_to
      )

      if @config.smtp_configured?
        send_via_smtp(mail)
        {
          "status" => "sent",
          "channel" => "smtp",
          "target" => "#{@config.smtp_host}:#{@config.smtp_port}",
          "external_message_id" => "<#{message_id}>",
          "outbox_path" => nil
        }
      else
        outbox_path = write_to_outbox(filename, mail.to_s)
        {
          "status" => "outbox",
          "channel" => "local_outbox",
          "target" => outbox_path,
          "external_message_id" => "<#{message_id}>",
          "outbox_path" => outbox_path
        }
      end
    end

    private

    def build_message(to:, subject:, body:, pdf_bytes:, filename:, message_id:, reply_to:)
      from_name = @config.smtp_from_name.to_s.empty? ? "Send Invoice" : @config.smtp_from_name
      from_email = @config.smtp_from_email.to_s.empty? ? "no-reply@send-invoice.local" : @config.smtp_from_email
      attachment_name = sanitize_header(filename)

      mail = Mail.new
      mail.from = from_address(from_email, from_name)
      mail.to = sanitize_header(to)
      mail.reply_to = sanitize_header(reply_to) unless reply_to.to_s.empty?
      mail.subject = sanitize_header(subject)
      mail.message_id = message_id
      mail.body = body.to_s
      mail.attachments[attachment_name] = { mime_type: "application/pdf", content: pdf_bytes } unless pdf_bytes.nil?
      mail
    end

    def from_address(email, name)
      address = Mail::Address.new(email)
      address.display_name = sanitize_header(name)
      address.format
    rescue StandardError
      email
    end

    # Defense in depth: even though Mail encodes header values, strip CR/LF and
    # other control characters from anything merchant-supplied (subject, drafts,
    # filename) before it reaches a header, so no value can inject a new header.
    def sanitize_header(raw)
      raw.to_s.gsub(/[\r\n]+/, " ").gsub(/[[:cntrl:]]/, "").strip
    end

    def send_via_smtp(mail)
      mail.delivery_method(:smtp,
        address: @config.smtp_host,
        port: @config.smtp_port,
        domain: "localhost",
        user_name: @config.smtp_username.empty? ? nil : @config.smtp_username,
        password: @config.smtp_username.empty? ? nil : @config.smtp_password,
        authentication: @config.smtp_username.empty? ? nil : @config.smtp_authentication.to_sym,
        enable_starttls_auto: @config.smtp_use_tls)
      mail.deliver!
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
