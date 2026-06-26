# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

require "send_invoice/invoice_composition"
require "send_invoice/invoice_document"
require "send_invoice/invoice_mailer"
require "send_invoice/invoice_pdf"
require "send_invoice/view_helpers"

module SendInvoice
  # Evaluates merchant automation rules against synced orders, schedules invoice
  # and payment-reminder events, and processes those events by reusing the same
  # invoice document / PDF / mailer flow as manual sends. Designed to be safe
  # under repeated webhooks, syncs, retries, and restarts: enqueueing is keyed by
  # event_key and sending is keyed by a delivery idempotency key.
  class InvoiceAutomationEngine
    include ViewHelpers
    include InvoiceComposition

    PAID_STATUSES = %w[paid partially_paid].freeze
    EMAIL_PATTERN = /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/.freeze

    DEFAULT_INVOICE_TEMPLATE = {
      subject: "Invoice {{invoice_number}} for order {{order_name}}",
      body: "Hi {{customer_name}},\n\nYour invoice for order {{order_name}} is attached.\n\n" \
             "You can download it here: {{invoice_link}}\n\nThank you,\n{{shop_name}}"
    }.freeze

    DEFAULT_REMINDER_TEMPLATE = {
      subject: "Payment reminder for invoice {{invoice_number}}",
      body: "Hi {{customer_name}},\n\nThis is a reminder that payment for order {{order_name}} is still pending.\n\n" \
             "Invoice total: {{total_price}} {{currency}}\nDue date: {{due_date}}\n\n" \
             "You can download your invoice here: {{invoice_link}}\n\nThank you,\n{{shop_name}}"
    }.freeze

    def initialize(config:, store:)
      @config = config
      @store = store
      @scheduler_thread = nil
    end

    def automation_active?
      @config.invoice_automation_enabled?
    end

    # Batch entry point used by the sync engine. Loads enabled rules once per
    # shop, then evaluates each order against the appropriate triggers.
    def handle_synced_orders(shop_domain:, orders:, previous_status_map: {})
      return unless automation_active?
      return if Array(orders).empty?

      rules = @store.list_invoice_automation_rules(shop_domain, enabled: true)
      return if rules.empty?

      grouped = rules.group_by { |rule| rule["trigger_event"] }
      reminder_rules = grouped["payment_reminder_due"] || []

      Array(orders).each do |order|
        previous = previous_status_map[order["id"].to_s]
        enqueue_for_order(shop_domain, order, previous, grouped, reminder_rules)
      end
    rescue StandardError => e
      warn "[send-invoice] automation enqueue failed for #{shop_domain}: #{e.class}: #{e.message}"
    end

    # Per-order entry point (webhooks / tests). event_type is accepted for
    # spec compatibility but transitions are derived from previous_order.
    def handle_order_event(shop_domain:, order:, event_type: nil, previous_order: nil)
      return unless automation_active?

      rules = @store.list_invoice_automation_rules(shop_domain, enabled: true)
      return if rules.empty?

      grouped = rules.group_by { |rule| rule["trigger_event"] }
      reminder_rules = grouped["payment_reminder_due"] || []
      enqueue_for_order(shop_domain, order, previous_order, grouped, reminder_rules)
    end

    def process_due_events(limit: nil)
      limit ||= @config.invoice_automation_batch_size
      events = @store.due_invoice_automation_events(limit: limit)
      events.each do |event|
        process_event(event)
      rescue StandardError => e
        warn "[send-invoice] automation event #{event['id']} crashed: #{e.class}: #{e.message}"
      end
      events.length
    end

    def process_event(event)
      return unless @store.lock_invoice_automation_event(event["id"])

      event = @store.find_invoice_automation_event(event["id"])

      begin
        shop = @store.shop(event["shop_domain"])
        order = @store.order(event["shop_domain"], event["order_id"])
        rule = event["rule_id"] && @store.find_invoice_automation_rule(event["shop_domain"], event["rule_id"])

        unless shop && order && rule && rule["enabled"]
          return @store.mark_invoice_automation_event_skipped(event["id"], "missing_order_or_disabled_rule")
        end

        if event["event_type"] == "payment_reminder_due" && paid?(order)
          return @store.mark_invoice_automation_event_skipped(event["id"], "order_paid")
        end

        unless rule_matches_order?(rule, order)
          return @store.mark_invoice_automation_event_skipped(event["id"], "conditions_not_matched")
        end

        recipient = order["customer_email"].to_s.strip
        return @store.mark_invoice_automation_event_skipped(event["id"], "missing_email") unless recipient =~ EMAIL_PATTERN

        idempotency_key = delivery_idempotency_key(
          event["shop_domain"], order["id"], rule["id"], event["event_type"], event["stage"], recipient
        )
        if @store.successful_invoice_delivery_for_idempotency_key(idempotency_key)
          return @store.mark_invoice_automation_event_succeeded(event["id"])
        end

        send_for_rule(shop, order, rule, event, recipient, idempotency_key)
        @store.mark_invoice_automation_event_succeeded(event["id"])
      rescue StandardError => e
        handle_event_failure(event, e)
      end
    end

    # Re-send a previously failed/sent delivery for the same order. Uses a fresh
    # idempotency context so the merchant can intentionally resend.
    def retry_delivery(delivery_id:, shop_domain:)
      original = @store.find_invoice_delivery(shop_domain, delivery_id)
      raise "Delivery not found" unless original

      shop = @store.shop(shop_domain)
      order = @store.order(shop_domain, original["order_id"])
      raise "Order not found for delivery" unless shop && order

      recipient = present_str(original["recipient_email"]) || order["customer_email"].to_s.strip
      raise "A valid recipient email is required to retry." unless recipient.to_s =~ EMAIL_PATTERN

      link_url = create_public_link(shop_domain, order["id"])
      tokens = placeholder_tokens(shop, order, link_url)
      subject = render_placeholders(present_str(original["subject"]) || DEFAULT_INVOICE_TEMPLATE[:subject], tokens)
      body = render_placeholders(present_str(original["body_text"]) || DEFAULT_INVOICE_TEMPLATE[:body], tokens)

      deliver_invoice(
        shop: shop, order: order, recipient: recipient, subject: subject, body: body,
        source: "retry", retry_of_delivery_id: original["id"], attach_pdf: true
      )
    end

    def resend_invoice(shop_domain:, order_id:, recipient: nil, reason: "manual_resend")
      shop = @store.shop(shop_domain)
      order = @store.order(shop_domain, order_id)
      raise "Order not found" unless shop && order

      to = present_str(recipient) || order["customer_email"].to_s.strip
      raise "A valid recipient email is required to resend." unless to.to_s =~ EMAIL_PATTERN

      draft = invoice_delivery_draft_for(shop, order)
      link_url = create_public_link(shop_domain, order_id)
      tokens = placeholder_tokens(shop, order, link_url)
      subject = render_placeholders(present_str(draft["subject"]) || DEFAULT_INVOICE_TEMPLATE[:subject], tokens)
      body = render_placeholders(present_str(draft["body_text"]) || DEFAULT_INVOICE_TEMPLATE[:body], tokens)

      deliver_invoice(
        shop: shop, order: order, recipient: to, subject: subject, body: body,
        source: reason, attach_pdf: true
      )
    end

    def start_scheduler
      return false unless @config.invoice_automation_enabled?
      return false if @scheduler_thread&.alive?

      @scheduler_thread = Thread.new do
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
        loop do
          begin
            process_due_events
          rescue StandardError => e
            warn "[send-invoice] automation dispatcher failed: #{e.class}: #{e.message}"
          ensure
            sleep @config.invoice_automation_poll_interval_seconds
          end
        end
      end

      true
    end

    private

    def enqueue_for_order(shop_domain, order, previous, grouped, reminder_rules)
      evaluate_trigger(shop_domain, order, "order_created", grouped["order_created"]) if previous.nil?

      if transitioned_to_paid?(previous, order)
        evaluate_trigger(shop_domain, order, "order_paid", grouped["order_paid"])
        @store.cancel_invoice_automation_events_for_order(
          shop_domain: shop_domain,
          order_id: order["id"],
          event_type: "payment_reminder_due"
        )
      end

      evaluate_trigger(shop_domain, order, "order_fulfilled", grouped["order_fulfilled"]) if transitioned_to_fulfilled?(previous, order)

      enqueue_payment_reminders(shop_domain, order, reminder_rules) unless paid?(order)
    end

    def evaluate_trigger(shop_domain, order, trigger_event, rules)
      Array(rules).each do |rule|
        next unless rule_matches_order?(rule, order)

        @store.enqueue_invoice_automation_event(
          shop_domain: shop_domain,
          order_id: order["id"],
          rule_id: rule["id"],
          event_type: trigger_event,
          event_key: event_key(shop_domain, rule["id"], order["id"], trigger_event, "invoice"),
          stage: "invoice",
          run_after: now_iso
        )
      end
    end

    def enqueue_payment_reminders(shop_domain, order, reminder_rules)
      base = parse_time(order["created_at"])
      return unless base

      Array(reminder_rules).each do |rule|
        next unless rule_matches_order?(rule, order)

        schedule = rule["reminder_schedule"] || {}
        days = Array(schedule["days_after_order"]).map(&:to_i).select(&:positive?).uniq.sort
        max = schedule["max_reminders"].to_i
        days = days.first(max) if max.positive?

        days.each do |day|
          stage = "day_#{day}"
          @store.enqueue_invoice_automation_event(
            shop_domain: shop_domain,
            order_id: order["id"],
            rule_id: rule["id"],
            event_type: "payment_reminder_due",
            event_key: event_key(shop_domain, rule["id"], order["id"], "payment_reminder_due", stage),
            stage: stage,
            run_after: (base + (day * 86_400)).utc.iso8601
          )
        end
      end
    end

    def send_for_rule(shop, order, rule, event, recipient, idempotency_key)
      action = rule["action"] || {}
      reminder = event["event_type"] == "payment_reminder_due"
      link_url = truthy(action.fetch("include_invoice_link", true)) ? create_public_link(shop["shop_domain"], order["id"]) : nil

      subject_template, body_template = resolve_templates(shop, action, reminder)
      tokens = placeholder_tokens(shop, order, link_url)

      deliver_invoice(
        shop: shop,
        order: order,
        recipient: recipient,
        subject: render_placeholders(subject_template, tokens),
        body: render_placeholders(body_template, tokens),
        source: reminder ? "automation_reminder" : "automation",
        rule_id: rule["id"],
        event_id: event["id"],
        stage: event["stage"],
        idempotency_key: idempotency_key,
        attach_pdf: truthy(action.fetch("attach_pdf", true))
      )
    end

    def resolve_templates(shop, action, reminder)
      subject = present_str(action["subject"])
      body = present_str(action["body"])
      return [subject, body] if subject && body

      unless reminder
        email_config = merged_notification_config(shop)["email"] || {}
        subject ||= present_str(email_config["subject"])
        body ||= present_str(email_config["body"])
      end

      defaults = reminder ? DEFAULT_REMINDER_TEMPLATE : DEFAULT_INVOICE_TEMPLATE
      [subject || defaults[:subject], body || defaults[:body]]
    end

    # Shared send path: builds the invoice document, optionally attaches the PDF,
    # delivers via the existing mailer, and records the attempt (success or
    # failure) in invoice_deliveries with automation metadata.
    def deliver_invoice(shop:, order:, recipient:, subject:, body:, source:, rule_id: nil, event_id: nil, stage: nil, idempotency_key: nil, retry_of_delivery_id: nil, attach_pdf: true)
      builder = invoice_document_for(shop, order)
      pdf = attach_pdf ? InvoicePdf.new.generate(builder.payload) : nil

      begin
        result = InvoiceMailer.new(@config).deliver(
          to: recipient,
          subject: subject,
          body: body,
          pdf_bytes: pdf,
          filename: builder.filename,
          reply_to: shop["owner_email"]
        )

        @store.create_invoice_delivery(shop["shop_domain"], order["id"], {
          "recipient_email" => recipient,
          "subject" => subject,
          "body_text" => body,
          "invoice_filename" => builder.filename,
          "delivery_status" => result["status"],
          "delivery_channel" => result["channel"],
          "delivery_target" => result["target"],
          "external_message_id" => result["external_message_id"],
          "outbox_path" => result["outbox_path"],
          "pdf_size_bytes" => pdf ? pdf.bytesize : 0,
          "delivery_source" => source,
          "automation_rule_id" => rule_id,
          "automation_event_id" => event_id,
          "delivery_stage" => stage,
          "idempotency_key" => idempotency_key,
          "retry_of_delivery_id" => retry_of_delivery_id,
          "sent_at" => Time.now.utc.iso8601
        })
      rescue StandardError => e
        @store.create_invoice_delivery(shop["shop_domain"], order["id"], {
          "recipient_email" => recipient,
          "subject" => subject,
          "body_text" => body,
          "invoice_filename" => builder.filename,
          "delivery_status" => "failed",
          "delivery_channel" => @config.smtp_configured? ? "smtp" : "local_outbox",
          "delivery_target" => @config.smtp_configured? ? "#{@config.smtp_host}:#{@config.smtp_port}" : @config.outbox_path,
          "pdf_size_bytes" => pdf ? pdf.bytesize : 0,
          "delivery_source" => source,
          "automation_rule_id" => rule_id,
          "automation_event_id" => event_id,
          "delivery_stage" => stage,
          "idempotency_key" => idempotency_key,
          "retry_of_delivery_id" => retry_of_delivery_id,
          "error_message" => e.message
        })
        raise
      end
    end

    def handle_event_failure(event, error)
      attempts = event["attempts"].to_i
      max_attempts = event["max_attempts"].to_i
      message = error.message.to_s[0, 500]

      if attempts >= max_attempts
        @store.mark_invoice_automation_event_dead(event["id"], message)
      else
        @store.mark_invoice_automation_event_failed(event["id"], error: message, retry_at: retry_at_for(attempts))
      end

      warn "[send-invoice] automation event #{event['id']} failed (attempt #{attempts}/#{max_attempts}): #{error.class}: #{error.message}"
    end

    def retry_at_for(attempts)
      delay = attempts <= 1 ? 300 : 1800
      (Time.now.utc + delay).iso8601
    end

    def create_public_link(shop_domain, order_id)
      token = SecureRandom.urlsafe_base64(32)
      token_hash = Digest::SHA256.hexdigest(token)
      expires_at = (Time.now.utc + (@config.invoice_public_link_ttl_days * 86_400)).iso8601
      @store.create_invoice_public_link(
        shop_domain: shop_domain,
        order_id: order_id,
        token_hash: token_hash,
        expires_at: expires_at
      )
      @config.invoice_public_link_url(token)
    end

    def placeholder_tokens(shop, order, link_url)
      builder = invoice_document_for(shop, order)
      builder.tokens.merge(
        "order_id" => order["id"].to_s,
        "customer_email" => order["customer_email"].to_s,
        "total_price" => format_money(order["total_price_amount"], order["total_price_currency"]),
        "currency" => order["total_price_currency"].to_s,
        "invoice_link" => link_url.to_s,
        "days_overdue" => days_overdue(order).to_s
      )
    end

    # Replaces only known {{tokens}}; unknown placeholders are left untouched.
    def render_placeholders(text, tokens)
      rendered = text.to_s.dup
      tokens.each { |key, value| rendered = rendered.gsub("{{#{key}}}", value.to_s) }
      rendered
    end

    def rule_matches_order?(rule, order)
      conditions = rule["conditions"] || {}

      if truthy(conditions.fetch("require_customer_email", true)) && order["customer_email"].to_s.strip.empty?
        return false
      end

      financial = normalized_list(conditions["financial_status"])
      return false if !financial.empty? && !financial.include?(status_token(order["financial_status"]))

      fulfillment = normalized_list(conditions["fulfillment_status"])
      return false if !fulfillment.empty? && !fulfillment.include?(status_token(order["fulfillment_status"]))

      tags = order_tags(order)
      include_tags = normalized_list(conditions["include_tags"])
      return false if !include_tags.empty? && (tags & include_tags).empty?

      exclude_tags = normalized_list(conditions["exclude_tags"])
      return false if !exclude_tags.empty? && !(tags & exclude_tags).empty?

      total = order["total_price_amount"].to_f
      min_total = conditions["min_total"]
      return false if present_number?(min_total) && total < min_total.to_f

      max_total = conditions["max_total"]
      return false if present_number?(max_total) && total > max_total.to_f

      true
    end

    def order_tags(order)
      raw = order["tags"]
      raw = order.dig("raw_data", "tags") if raw.nil? && order["raw_data"].is_a?(Hash)
      list = case raw
             when Array then raw
             when String then raw.split(",")
             else []
             end
      list.map { |tag| tag.to_s.downcase.strip }.reject(&:empty?)
    end

    def transitioned_to_paid?(previous, order)
      paid?(order) && !(previous && paid?(previous))
    end

    def transitioned_to_fulfilled?(previous, order)
      fulfilled?(order) && !(previous && fulfilled?(previous))
    end

    def paid?(record)
      return true if record["fully_paid"]

      PAID_STATUSES.include?(status_token(record["financial_status"]))
    end

    def fulfilled?(record)
      status_token(record["fulfillment_status"]) == "fulfilled"
    end

    def days_overdue(order)
      created = parse_time(order["created_at"])
      return 0 unless created

      due = created + (7 * 86_400)
      diff = ((Time.now.utc - due) / 86_400).floor
      diff.positive? ? diff : 0
    end

    def event_key(shop_domain, rule_id, order_id, event_type, stage)
      [shop_domain, rule_id, order_id, event_type, stage].join("|")
    end

    def delivery_idempotency_key(shop_domain, order_id, rule_id, event_type, stage, recipient)
      [shop_domain, order_id, rule_id, event_type, stage, recipient].join("|")
    end

    def status_token(value)
      value.to_s.downcase.strip
    end

    def normalized_list(value)
      Array(value).map { |item| item.to_s.downcase.strip }.reject(&:empty?)
    end

    def truthy(value)
      return false if value.nil?
      return value unless value.is_a?(String)

      !%w[0 false no off].include?(value.downcase.strip)
    end

    def present_str(value)
      str = value.to_s
      str.strip.empty? ? nil : str
    end

    def present_number?(value)
      return false if value.nil?
      return false if value.is_a?(String) && value.strip.empty?

      true
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def now_iso
      Time.now.utc.iso8601
    end
  end
end
