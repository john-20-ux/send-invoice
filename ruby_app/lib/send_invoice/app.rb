# frozen_string_literal: true

require "erb"
require "json"
require "securerandom"
require "time"
require "uri"
require "webrick"

require "send_invoice/mock_data"
require "send_invoice/view_helpers"

module SendInvoice
  class App
    include ViewHelpers

    class UnauthorizedError < StandardError; end
    class NotFoundError < StandardError; end

    NAV_ITEMS = [
      { "label" => "Home", "path" => "/dashboard" },
      { "label" => "Orders", "path" => "/orders" },
      { "label" => "Vendors", "path" => "/vendors" },
      { "label" => "Invoice Templates", "path" => "/invoice-templates" },
      { "label" => "Notifications", "path" => "/notifications" },
      { "label" => "Settings", "path" => "/settings" },
      { "label" => "Support", "path" => "/support" }
    ].freeze

    ADMIN_NAV_ITEMS = [
      { "label" => "Queue Ops", "path" => "/queue-ops" }
    ].freeze

    ASYNC_REQUEST_STATUSES = %w[queued claimed dispatched running completed failed].freeze

    class TemplateContext
      include ViewHelpers

      def initialize(app, locals = {})
        @app = app
        locals.each { |key, value| instance_variable_set("@#{key}", value) }
      end

      def render_partial(name, locals = {})
        @app.render_partial(name, locals)
      end

      def binding_context
        binding
      end
    end

    def initialize(config:, store:, sync_engine:, shopify_client:)
      @config = config
      @store = store
      @sync_engine = sync_engine
      @shopify_client = shopify_client
    end

    def handle(req, res)
      @request = req
      @response = res
      @session_id = nil
      @session = nil
      @response["Content-Type"] = "text/html; charset=utf-8"
      load_session unless webhook_request?

      route!
    rescue UnauthorizedError => e
      if api_request? || webhook_request?
        respond_json({ error: e.message }, status: 401)
      else
        flash!("error", e.message)
        redirect_to("/onboarding")
      end
    rescue NotFoundError
      render_page("pages/not_found", {
        page_title: "Not Found",
        current_path: @request.path,
        shop: current_shop(optional: true),
        sync_status: current_sync_status(optional: true)
      }, status: 404)
    rescue StandardError => e
      warn "[send-invoice] #{e.class}: #{e.message}"
      warn e.backtrace.first(10).join("\n")
      if api_request? || webhook_request?
        respond_json({ error: "Internal server error" }, status: 500)
      else
        flash!("error", "Something went wrong while rendering this page.")
        render_page("pages/not_found", {
          page_title: "Server Error",
          current_path: @request.path,
          shop: current_shop(optional: true),
          sync_status: current_sync_status(optional: true)
        }, status: 500)
      end
    ensure
      persist_session
    end

    def render_partial(name, locals = {})
      template_path = File.join(@config.views_path, "partials", "#{name}.erb")
      context = TemplateContext.new(self, base_locals.merge(locals))
      ERB.new(File.read(template_path)).result(context.binding_context)
    end

    private

    def route!
      case [@request.request_method, @request.path]
      when ["GET", "/health"]
        respond_json({ status: "ok", timestamp: Time.now.utc.iso8601 })
      when ["GET", "/"]
        handle_root
      when ["GET", "/auth"]
        handle_auth_start
      when ["GET", "/auth/callback"]
        handle_auth_callback
      when ["POST", "/webhooks/bulk-operations-finish"]
        handle_bulk_operations_finish_webhook
      when ["POST", "/webhooks/app-uninstalled"]
        handle_app_uninstalled_webhook
      when ["POST", "/webhooks/orders-changed"]
        handle_orders_changed_webhook
      when ["GET", "/onboarding"], ["GET", "/onboarding/step-1"]
        render_onboarding(1)
      when ["GET", "/onboarding/step-2"]
        render_onboarding(2)
      when ["GET", "/onboarding/step-3"]
        render_onboarding(3)
      when ["POST", "/onboarding/email"]
        handle_onboarding_email
      when ["POST", "/onboarding/connect"]
        handle_onboarding_connect
      when ["GET", "/onboarding/complete"]
        handle_onboarding_complete
      when ["GET", "/dashboard"]
        render_dashboard
      when ["GET", "/orders"]
        render_orders
      when ["POST", "/orders/sync"]
        handle_manual_sync
      when ["GET", "/queue-ops"]
        render_queue_ops
      when ["POST", "/queue-ops/retry-latest-failed"]
        handle_queue_ops_retry_latest_failed
      when ["POST", "/queue-ops/retry-all-failed"]
        handle_queue_ops_retry_all_failed
      when ["GET", "/vendors"]
        render_vendors
      when ["POST", "/vendors"]
        handle_vendor_edits
      when ["GET", "/invoice-templates"]
        render_invoice_templates
      when ["POST", "/invoice-templates"]
        handle_invoice_template_save
      when ["GET", "/notifications"]
        render_notifications
      when ["POST", "/notifications"]
        handle_notification_save
      when ["GET", "/settings"]
        render_settings
      when ["POST", "/settings"]
        handle_settings_save
      when ["GET", "/settings/plans"]
        render_plans
      when ["POST", "/settings/plans"]
        handle_plan_change
      when ["GET", "/support"]
        render_support
      when ["POST", "/support"]
        handle_support_submit
      when ["GET", "/api/shop"]
        api_shop
      when ["PUT", "/api/shop/email"]
        api_update_shop_email
      when ["GET", "/api/orders"]
        api_orders
      when ["POST", "/api/sync"]
        api_sync
      when ["POST", "/api/sync/bulk"]
        api_bulk_sync
      when ["GET", "/api/sync/bulk/status"]
        api_bulk_sync_status
      when ["POST", "/api/sync/all"]
        api_sync_all
      when ["GET", "/api/sync/status"]
        api_sync_status
      when ["GET", "/api/sync/batches/status"]
        api_batch_sync_status
      when ["GET", "/api/async-requests"]
        api_async_requests
      when ["POST", "/api/async-requests/retry-latest-failed"]
        api_retry_latest_failed_async_request
      when ["POST", "/api/async-requests/retry-all-failed"]
        api_retry_all_failed_async_requests
      else
        return api_order_detail if @request.request_method == "GET" && @request.path.start_with?("/api/orders/")
        return api_retry_async_request if @request.request_method == "POST" && @request.path.start_with?("/api/async-requests/") && @request.path.end_with?("/retry")
        return api_delete_async_request if @request.request_method == "DELETE" && @request.path.start_with?("/api/async-requests/")
        return handle_queue_ops_retry_async_request if @request.request_method == "POST" && @request.path.start_with?("/queue-ops/requests/") && @request.path.end_with?("/retry")
        return handle_queue_ops_delete_async_request if @request.request_method == "POST" && @request.path.start_with?("/queue-ops/requests/") && @request.path.end_with?("/delete")
        return handle_queue_ops_retry_batch_log if @request.request_method == "POST" && @request.path.start_with?("/queue-ops/batches/") && @request.path.end_with?("/retry")
        return render_vendor_invoice if @request.request_method == "GET" && @request.path.start_with?("/vendors/")

        raise NotFoundError
      end
    end

    def handle_root
      shop = current_shop(optional: true)
      if shop && shop["onboarded"]
        redirect_to("/dashboard")
      else
        redirect_to("/onboarding")
      end
    end

    def handle_auth_start
      requested_shop = single_value(params["shop"])

      if @config.mock_mode?
        shop_domain = @shopify_client.valid_shop_domain?(requested_shop.to_s) ? requested_shop : MockData::DEMO_SHOP_DOMAIN
        @session["shop_domain"] = shop_domain
        @session["admin_shop_domain"] = shop_domain
        @store.ensure_shop(shop_domain, "shop_name" => MockData::DEMO_SHOP_NAME)
        redirect_to("/onboarding?shop=#{URI.encode_www_form_component(shop_domain)}")
        return
      end

      unless @shopify_client.valid_shop_domain?(requested_shop.to_s)
        raise UnauthorizedError, "Missing or invalid shop parameter. Expected: your-store.myshopify.com"
      end

      state = @shopify_client.generate_nonce
      @session["state"] = state
      @session["shop_domain"] = requested_shop
      redirect_uri = "#{@config.host}/auth/callback"
      redirect_to(@shopify_client.build_auth_url(requested_shop, redirect_uri, state))
    end

    def handle_auth_callback
      if @config.mock_mode?
        @session["shop_domain"] = MockData::DEMO_SHOP_DOMAIN
        redirect_to("/onboarding?shop=#{URI.encode_www_form_component(MockData::DEMO_SHOP_DOMAIN)}")
        return
      end

      shop = single_value(params["shop"])
      code = single_value(params["code"])
      state = single_value(params["state"])

      raise UnauthorizedError, "Invalid shop domain" unless @shopify_client.valid_shop_domain?(shop.to_s)
      raise UnauthorizedError, "Missing required OAuth parameters" if [code, state, params["hmac"]].any?(&:nil?)
      raise UnauthorizedError, "Invalid state parameter. Possible CSRF attack." unless state == @session["state"]
      raise UnauthorizedError, "HMAC verification failed" unless @shopify_client.verify_hmac(stringified_params)

      token_data = @shopify_client.exchange_token(shop, code)
      shop_info = @shopify_client.fetch_shop_info(shop, token_data.fetch("access_token"))
      @store.ensure_shop(shop, {
        "access_token" => token_data.fetch("access_token"),
        "scopes" => token_data["scope"],
        "shop_name" => shop_info["name"] || shop.split(".").first
      })
      register_shop_webhooks(shop, token_data.fetch("access_token"))
      @session["shop_domain"] = shop
      @session["admin_shop_domain"] = shop
      @session.delete("state")
      redirect_to("/onboarding?shop=#{URI.encode_www_form_component(shop)}")
    end

    def render_onboarding(step)
      shop = current_shop(optional: true)
      sync_status = shop ? @sync_engine.status(shop["shop_domain"]) : @sync_engine.send(:idle_status)
      render_page("pages/onboarding", {
        page_title: "Onboarding",
        current_path: @request.path,
        shop: shop,
        sync_status: sync_status,
        onboarding_step: step,
        mock_mode: @config.mock_mode?,
        can_connect: shop || @config.mock_mode?
      })
    end

    def handle_onboarding_email
      shop = ensure_shop_for_onboarding
      email = single_value(params["email"]).to_s.strip
      if !email.empty? && !email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        flash!("error", "Please enter a valid email address.")
        redirect_to("/onboarding")
        return
      end

      @store.update_shop(shop["shop_domain"], "owner_email" => email.empty? ? nil : email)
      redirect_to("/onboarding/step-2")
    end

    def handle_onboarding_connect
      shop_domain = single_value(params["shop_domain"]).to_s.strip
      if shop_domain.empty?
        shop = current_shop(optional: true)
        shop_domain = shop && shop["shop_domain"].to_s
      end

      unless @shopify_client.valid_shop_domain?(shop_domain)
        flash!("error", "Invalid shop domain. Must match *.myshopify.com")
        redirect_to("/onboarding/step-2")
        return
      end

      @session["shop_domain"] = shop_domain
      @session["admin_shop_domain"] = shop_domain
      @store.ensure_shop(shop_domain, "shop_name" => current_shop_name(shop_domain))
      redirect_to("/onboarding/step-3")
    end

    def handle_onboarding_complete
      shop = require_onboarded_ready_shop
      @store.update_shop(shop["shop_domain"], "onboarded" => true)
      flash!("info", "Store synced. Your Shopify data is ready.")
      redirect_to("/dashboard")
    end

    def render_dashboard
      shop = require_onboarded_shop
      orders = @store.all_orders(shop["shop_domain"])
      total_revenue = orders.sum { |order| order["total_price_amount"] }
      stats = {
        "total_orders" => orders.length,
        "total_revenue" => total_revenue,
        "paid_orders" => orders.count { |order| order["fully_paid"] },
        "fulfilled" => orders.count { |order| order["fulfillment_status"] == "FULFILLED" }
      }

      daily_points = last_30_day_revenue(orders)
      status_points = orders.group_by { |order| order["financial_status"] }.map do |status, records|
        { "status" => status, "count" => records.length }
      end.sort_by { |item| -item["count"] }

      render_page("pages/dashboard", {
        page_title: "Dashboard",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        stats: stats,
        daily_points: daily_points,
        status_points: status_points,
        max_daily_revenue: [daily_points.map { |point| point["revenue"] }.max.to_f, 1].max
      })
    end

    def render_orders
      shop = require_onboarded_shop
      filters = {
        from: single_value(params["from"]),
        to: single_value(params["to"]),
        page: single_value(params["page"]) || 1,
        limit: single_value(params["limit"]) || 25,
        search: single_value(params["search"])
      }
      result = @store.orders(shop["shop_domain"], filters)
      selected_order = single_value(params["order_id"])
      order = selected_order ? @store.order(shop["shop_domain"], selected_order) : nil

      render_page("pages/orders", {
        page_title: "Orders",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        filters: filters,
        order_result: result,
        selected_order: order,
        pagination_path: "/orders"
      })
    end

    def handle_manual_sync
      shop = require_onboarded_shop
      result = @sync_engine.trigger(shop: shop, type: "incremental")
      if result["started"]
        flash!("info", "Sync started. Orders are being synced from Shopify.")
      else
        flash!("error", result["message"] || "Sync unavailable")
      end
      redirect_to(back_path("/orders"))
    end

    def render_queue_ops
      shop = require_admin_shop_for_current_shop
      statuses = requested_async_request_statuses(default: ASYNC_REQUEST_STATUSES)
      limit = requested_async_request_limit(default: 25)
      page = requested_async_request_page
      total = @store.async_job_request_count(shop_domain: shop["shop_domain"], statuses: statuses)
      total_pages = [(total.to_f / limit).ceil, 1].max
      page = [[page, 1].max, total_pages].min
      requests = @store.async_job_requests(
        shop_domain: shop["shop_domain"],
        statuses: statuses,
        limit: limit,
        offset: (page - 1) * limit
      )

      render_page("pages/queue_ops", {
        page_title: "Queue Ops",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        async_request_result: {
          "requests" => requests,
          "statuses" => statuses,
          "page" => page,
          "limit" => limit,
          "total" => total,
          "total_pages" => total_pages
        },
        async_request_counts: @store.async_job_request_status_counts(shop_domain: shop["shop_domain"]),
        batch_summary: @store.batch_summary(shop["shop_domain"]),
        recent_batch_logs: @store.batch_logs(shop["shop_domain"]).last(12).reverse,
        latest_sync_log: @store.latest_sync_log(shop["shop_domain"]),
        last_completed_sync: @store.last_completed_sync(shop["shop_domain"]),
        sync_state: @store.sync_state(shop["shop_domain"]),
        latest_bulk_job: @store.latest_bulk_sync_job(shop["shop_domain"])
      })
    end

    def handle_queue_ops_retry_latest_failed
      shop = require_admin_shop_for_current_shop
      retried = @store.retry_latest_failed_async_job_request(shop_domain: shop["shop_domain"])

      if retried
        flash!("info", "Retried the latest failed background request.")
      else
        flash!("error", "No failed background requests found.")
      end

      redirect_to(back_path(queue_ops_path(shop["shop_domain"])))
    end

    def handle_queue_ops_retry_all_failed
      shop = require_admin_shop_for_current_shop
      retried_count = @store.retry_all_failed_async_job_requests(shop_domain: shop["shop_domain"])

      if retried_count.positive?
        flash!("info", "Retried #{retried_count} failed background request#{retried_count == 1 ? '' : 's'}.")
      else
        flash!("error", "No failed background requests found.")
      end

      redirect_to(back_path(queue_ops_path(shop["shop_domain"])))
    end

    def handle_queue_ops_retry_async_request
      shop = require_admin_shop_for_current_shop
      request = shop_async_job_request_from_path

      if request && @store.retry_failed_async_job_request(request["id"])
        flash!("info", "Retried background request #{request['id']}.")
      elsif request
        flash!("error", "Only failed background requests can be retried.")
      else
        flash!("error", "Background request not found.")
      end

      redirect_to(back_path(queue_ops_path(shop["shop_domain"])))
    end

    def handle_queue_ops_delete_async_request
      shop = require_admin_shop_for_current_shop
      request = shop_async_job_request_from_path

      if request && @store.delete_async_job_request(request["id"], allowed_statuses: %w[failed completed])
        flash!("info", "Removed background request #{request['id']}.")
      elsif request
        flash!("error", "Only failed or completed background requests can be removed.")
      else
        flash!("error", "Background request not found.")
      end

      redirect_to(back_path(queue_ops_path(shop["shop_domain"])))
    end

    def handle_queue_ops_retry_batch_log
      shop = require_admin_shop_for_current_shop
      batch = shop_batch_log_from_path

      if batch.nil?
        flash!("error", "Batch log not found.")
      elsif batch["status"] != "failed"
        flash!("error", "Only failed batch logs can be retried.")
      else
        @store.retry_failed_batch_log(batch["id"])
        result = @sync_engine.trigger_first_time(shop: shop)

        if result["started"]
          flash!("info", "Retried batch #{batch['id']} and resumed first-time sync processing.")
        else
          flash!("info", "Batch #{batch['id']} is retryable. #{result['message'] || 'First-time sync is already queued or running.'}")
        end
      end

      redirect_to(back_path(queue_ops_path(shop["shop_domain"])))
    end

    def render_vendors
      shop = require_onboarded_shop
      orders = @store.all_orders(shop["shop_domain"])
      summaries = vendor_summaries(shop, orders)
      selected_slug = @request.path.split("/")[2]
      render_page("pages/vendors", {
        page_title: "Vendors",
        current_path: "/vendors",
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        vendor_summaries: summaries,
        selected_vendor_slug: selected_slug
      })
    end

    def handle_vendor_edits
      shop = require_onboarded_shop
      current = shop["vendor_edits"]
      params.each do |key, value|
        next unless key.start_with?("rate__") || key.start_with?("deductions__")

        slug = key.split("__", 2).last
        vendor_name = single_value(params["vendor_name__#{slug}"])
        next if vendor_name.to_s.strip.empty?

        current[vendor_name] ||= {}
        if key.start_with?("rate__")
          current[vendor_name]["rate"] = value.to_f
        else
          current[vendor_name]["deductions"] = value.to_f
        end
      end

      @store.update_shop(shop["shop_domain"], "vendor_edits" => current)
      flash!("info", "Vendor commission settings saved.")
      redirect_to("/vendors")
    end

    def render_vendor_invoice
      slug = @request.path.split("/")[2]
      raise NotFoundError if slug.to_s.empty?

      shop = require_onboarded_shop
      summary = vendor_summaries(shop, @store.all_orders(shop["shop_domain"])).find do |vendor|
        slugify(vendor["name"]) == slug
      end
      raise NotFoundError unless summary

      render_page("pages/vendor_invoice", {
        page_title: "#{summary['name']} Payout",
        current_path: "/vendors",
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        vendor_summary: summary
      }, layout: "print")
    end

    def render_invoice_templates
      shop = require_onboarded_shop
      render_page("pages/invoice_templates", {
        page_title: "Invoice Templates",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        invoice_config: merged_invoice_config(shop)
      })
    end

    def handle_invoice_template_save
      shop = require_onboarded_shop
      config = merged_invoice_config(shop)

      %w[
        template currency_symbol company_name tagline address phone email website gst
        bill_to client_address client_email invoice_number invoice_date due_date
        payment_terms notes bank_details terms
      ].each do |key|
        config[key] = single_value(params[key]).to_s
      end

      visible = config["visible_fields"] || {}
      %w[website terms].each do |field|
        visible[field] = single_value(params["visible_#{field}"]) == "1"
      end
      config["visible_fields"] = visible

      config["line_items"] = 2.times.map do |index|
        {
          "desc" => single_value(params["line_desc_#{index}"]).to_s,
          "qty" => single_value(params["line_qty_#{index}"]).to_f,
          "rate" => single_value(params["line_rate_#{index}"]).to_f,
          "discount" => single_value(params["line_discount_#{index}"]).to_f,
          "tax" => single_value(params["line_tax_#{index}"]).to_f
        }
      end

      @store.update_shop(shop["shop_domain"], "invoice_template_config" => config)
      flash!("info", "Invoice template updated.")
      redirect_to("/invoice-templates")
    end

    def render_notifications
      shop = require_onboarded_shop
      render_page("pages/notifications", {
        page_title: "Notifications",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        notification_config: merged_notification_config(shop)
      })
    end

    def handle_notification_save
      shop = require_onboarded_shop
      config = merged_notification_config(shop)
      config["email"] = {
        "enabled" => single_value(params["email_enabled"]) == "1",
        "subject" => single_value(params["email_subject"]).to_s,
        "body" => single_value(params["email_body"]).to_s
      }
      config["whatsapp"] = {
        "enabled" => single_value(params["whatsapp_enabled"]) == "1",
        "phone" => single_value(params["whatsapp_phone"]).to_s,
        "message" => single_value(params["whatsapp_message"]).to_s
      }
      config["slack"] = {
        "enabled" => single_value(params["slack_enabled"]) == "1",
        "channel" => single_value(params["slack_channel"]).to_s
      }
      config["basecamp"] = {
        "enabled" => single_value(params["basecamp_enabled"]) == "1",
        "project" => single_value(params["basecamp_project"]).to_s
      }

      @store.update_shop(shop["shop_domain"], "notification_config" => config)
      flash!("info", "Notification settings updated.")
      redirect_to("/notifications")
    end

    def render_settings
      shop = require_onboarded_shop
      render_page("pages/settings", {
        page_title: "Settings",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"])
      })
    end

    def handle_settings_save
      shop = require_onboarded_shop
      @store.update_shop(shop["shop_domain"], {
        "tax_rate" => single_value(params["tax_rate"]).to_f,
        "currency" => single_value(params["currency"]).to_s,
        "font_name" => single_value(params["font_name"]).to_s
      })
      flash!("info", "Invoice settings updated.")
      redirect_to("/settings")
    end

    def render_plans
      shop = require_onboarded_shop
      render_page("pages/plans", {
        page_title: "Plans",
        current_path: "/settings/plans",
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        plans: plan_definitions
      })
    end

    def handle_plan_change
      shop = require_onboarded_shop
      plan = single_value(params["plan"]).to_s
      if plan == "enterprise"
        flash!("info", "Contact sales and we will reach out to discuss your needs.")
      else
        @store.update_shop(shop["shop_domain"], "current_plan" => plan)
        flash!("info", "Plan updated to #{plan.capitalize}.")
      end
      redirect_to("/settings/plans")
    end

    def render_support
      shop = require_onboarded_shop
      render_page("pages/support", {
        page_title: "Support",
        current_path: @request.path,
        shop: shop,
        sync_status: @sync_engine.status(shop["shop_domain"]),
        faq: faq_items
      })
    end

    def handle_support_submit
      require_onboarded_shop
      flash!("info", "Message sent. We will get back to you within 24 hours.")
      redirect_to("/support")
    end

    def api_shop
      shop = require_shop
      last_sync = @store.last_completed_sync(shop["shop_domain"])
      respond_json({
        shopDomain: shop["shop_domain"],
        shopName: shop["shop_name"],
        ownerEmail: shop["owner_email"],
        installedAt: shop["installed_at"],
        hasCompletedInitialSync: !last_sync.nil?
      })
    end

    def api_update_shop_email
      shop = require_shop
      payload = request_payload
      email = payload["email"].to_s.strip

      if !email.empty? && !email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/)
        respond_json({ error: "Invalid email format" }, status: 400)
        return
      end

      @store.update_shop(shop["shop_domain"], "owner_email" => (email.empty? ? nil : email))
      respond_json({ success: true })
    end

    def api_orders
      shop = require_shop
      result = @store.orders(shop["shop_domain"], {
        from: single_value(params["from"]),
        to: single_value(params["to"]),
        page: single_value(params["page"]) || 1,
        limit: single_value(params["limit"]) || 25,
        search: single_value(params["search"])
      })
      respond_json({
        orders: result["orders"],
        total: result["total"],
        page: result["page"],
        limit: result["limit"],
        totalPages: result["total_pages"]
      })
    end

    def api_order_detail
      shop = require_shop
      order_id = URI.decode_www_form_component(@request.path.split("/").last)
      order = @store.order(shop["shop_domain"], order_id)
      if order
        respond_json(order)
      else
        respond_json({ error: "Order not found" }, status: 404)
      end
    end

    def api_sync
      shop = require_shop
      payload = request_payload
      type = payload["type"].to_s
      if type == "first_time"
        respond_json(@sync_engine.trigger_first_time(shop: shop))
      else
        respond_json(@sync_engine.trigger(shop: shop, type: type == "full" ? "full" : "incremental"))
      end
    end

    def api_bulk_sync
      shop = require_shop
      payload = request_payload
      type = payload["type"].to_s == "incremental" ? "incremental" : "full"
      respond_json(@sync_engine.trigger_bulk(shop: shop, type: type))
    end

    def api_bulk_sync_status
      shop = require_shop
      respond_json(@sync_engine.bulk_status(shop["shop_domain"]))
    end

    def api_sync_all
      authorize_sync_secret!
      payload = request_payload
      type = payload["type"].to_s == "full" ? "full" : "incremental"
      respond_json({
        startedAt: Time.now.utc.iso8601,
        type: type,
        shops: @sync_engine.trigger_all(type: type, skip_rate_limit: true)
      })
    end

    def api_sync_status
      shop = require_shop
      respond_json(@sync_engine.status(shop["shop_domain"]))
    end

    def api_batch_sync_status
      shop = require_shop
      respond_json(@sync_engine.batch_status(shop["shop_domain"]))
    end

    def api_async_requests
      shop = require_admin_shop_for_current_shop
      statuses = requested_async_request_statuses
      requests = @store.async_job_requests(
        shop_domain: shop["shop_domain"],
        statuses: statuses,
        limit: requested_async_request_limit
      )

      respond_json({
        requests: requests.map { |request| serialize_async_job_request(request) },
        statuses: statuses
      })
    end

    def api_retry_async_request
      require_admin_shop_for_current_shop
      request = shop_async_job_request_from_path
      return respond_json({ error: "Async job request not found" }, status: 404) unless request

      retried = @store.retry_failed_async_job_request(request["id"])
      unless retried
        respond_json({ error: "Only failed async job requests can be retried" }, status: 409)
        return
      end

      respond_json({
        retried: true,
        request: serialize_async_job_request(retried)
      })
    end

    def api_retry_latest_failed_async_request
      shop = require_admin_shop_for_current_shop
      retried = @store.retry_latest_failed_async_job_request(shop_domain: shop["shop_domain"])
      return respond_json({ error: "No failed async job requests found" }, status: 404) unless retried

      respond_json({
        retried: true,
        request: serialize_async_job_request(retried)
      })
    end

    def api_retry_all_failed_async_requests
      shop = require_admin_shop_for_current_shop
      retried_count = @store.retry_all_failed_async_job_requests(shop_domain: shop["shop_domain"])
      return respond_json({ error: "No failed async job requests found" }, status: 404) if retried_count.zero?

      respond_json({
        retried: true,
        retriedCount: retried_count
      })
    end

    def api_delete_async_request
      require_admin_shop_for_current_shop
      request = shop_async_job_request_from_path
      return respond_json({ error: "Async job request not found" }, status: 404) unless request

      deleted = @store.delete_async_job_request(request["id"], allowed_statuses: %w[failed completed])
      unless deleted
        respond_json({ error: "Only failed or completed async job requests can be deleted" }, status: 409)
        return
      end

      respond_json({
        deleted: true,
        requestId: request["id"]
      })
    end

    def handle_bulk_operations_finish_webhook
      raw_body = @request.body.to_s
      hmac = header_value("x-shopify-hmac-sha256")
      raise UnauthorizedError, "Invalid webhook signature" unless @shopify_client.verify_webhook_hmac(raw_body, hmac)

      topic = header_value("x-shopify-topic").to_s
      raise UnauthorizedError, "Unexpected webhook topic" unless topic == "bulk_operations/finish"

      shop_domain = header_value("x-shopify-shop-domain").to_s
      raise UnauthorizedError, "Invalid webhook shop domain" unless @shopify_client.valid_shop_domain?(shop_domain)

      shop = @store.shop(shop_domain)
      raise UnauthorizedError, "Unknown webhook shop" unless shop

      payload = JSON.parse(raw_body)
      operation_id = payload["admin_graphql_api_id"].to_s
      raise UnauthorizedError, "Missing bulk operation ID" if operation_id.empty?

      accepted = @sync_engine.handle_bulk_finish(shop: shop, operation_id: operation_id)
      respond_json({ received: true, accepted: accepted })
    rescue JSON::ParserError
      respond_json({ error: "Invalid webhook payload" }, status: 400)
    end

    def handle_app_uninstalled_webhook
      raw_body = @request.body.to_s
      hmac = header_value("x-shopify-hmac-sha256")
      raise UnauthorizedError, "Invalid webhook signature" unless @shopify_client.verify_webhook_hmac(raw_body, hmac)

      topic = header_value("x-shopify-topic").to_s
      raise UnauthorizedError, "Unexpected webhook topic" unless topic == "app/uninstalled"

      shop_domain = header_value("x-shopify-shop-domain").to_s
      raise UnauthorizedError, "Invalid webhook shop domain" unless @shopify_client.valid_shop_domain?(shop_domain)

      shop = @sync_engine.mark_shop_uninstalled(shop_domain)
      respond_json({
        received: true,
        scheduledForDeletionAt: shop && shop["scheduled_for_deletion_at"]
      })
    end

    def handle_orders_changed_webhook
      raw_body = @request.body.to_s
      hmac = header_value("x-shopify-hmac-sha256")
      raise UnauthorizedError, "Invalid webhook signature" unless @shopify_client.verify_webhook_hmac(raw_body, hmac)

      topic = header_value("x-shopify-topic").to_s
      allowed_topics = ["orders/create", "orders/updated", "orders/edited"]
      raise UnauthorizedError, "Unexpected webhook topic" unless allowed_topics.include?(topic)

      shop_domain = header_value("x-shopify-shop-domain").to_s
      raise UnauthorizedError, "Invalid webhook shop domain" unless @shopify_client.valid_shop_domain?(shop_domain)

      shop = @store.shop(shop_domain)
      raise UnauthorizedError, "Unknown webhook shop" unless shop

      result = @sync_engine.trigger(shop: shop, type: "incremental", skip_rate_limit: true)
      respond_json({
        received: true,
        accepted: result["started"],
        topic: topic
      })
    end

    def register_shop_webhooks(shop_domain, access_token)
      @shopify_client.ensure_webhook_subscription(
        shop_domain,
        access_token,
        topic: "BULK_OPERATIONS_FINISH",
        uri: @config.bulk_finish_webhook_uri
      )
      @shopify_client.ensure_webhook_subscription(
        shop_domain,
        access_token,
        topic: "APP_UNINSTALLED",
        uri: @config.app_uninstalled_webhook_uri
      )
      @shopify_client.ensure_webhook_subscription(
        shop_domain,
        access_token,
        topic: "ORDERS_CREATE",
        uri: @config.orders_changed_webhook_uri
      )
      @shopify_client.ensure_webhook_subscription(
        shop_domain,
        access_token,
        topic: "ORDERS_UPDATED",
        uri: @config.orders_changed_webhook_uri
      )
      @shopify_client.ensure_webhook_subscription(
        shop_domain,
        access_token,
        topic: "ORDERS_EDITED",
        uri: @config.orders_changed_webhook_uri
      )
    rescue StandardError => e
      warn "[send-invoice] webhook registration failed for #{shop_domain}: #{e.class}: #{e.message}"
    end

    def render_page(page, locals, status: 200, layout: "application")
      page_template = File.join(@config.views_path, "#{page}.erb")
      render_locals = base_locals.merge(locals)
      render_locals[:queue_ops_admin] = queue_ops_admin?(render_locals[:shop])
      content = ERB.new(File.read(page_template)).result(TemplateContext.new(self, render_locals).binding_context)
      layout_template = File.join(@config.views_path, "layouts", "#{layout}.erb")
      context = TemplateContext.new(
        self,
        render_locals.merge(
          content: content,
          nav_items: NAV_ITEMS,
          admin_nav_items: queue_ops_admin?(render_locals[:shop]) ? ADMIN_NAV_ITEMS : [],
          flash: consume_flash
        )
      )
      @response.status = status
      @response["Content-Type"] = "text/html; charset=utf-8"
      @response.body = ERB.new(File.read(layout_template)).result(context.binding_context)
    end

    def respond_json(payload, status: 200)
      @response.status = status
      @response["Content-Type"] = "application/json; charset=utf-8"
      @response.body = JSON.generate(payload)
    end

    def redirect_to(path)
      @response.status = 302
      @response["Location"] = path
      @response.body = ""
    end

    def current_shop(optional: false)
      requested_shop = @session["shop_domain"] || single_value(params["shop"]) || header_value("x-shop-domain")

      if @config.mock_mode?
        shop_domain = @shopify_client.valid_shop_domain?(requested_shop.to_s) ? requested_shop : MockData::DEMO_SHOP_DOMAIN
        @session["shop_domain"] = shop_domain
        return @store.ensure_shop(shop_domain, "shop_name" => MockData::DEMO_SHOP_NAME)
      end

      return nil if optional && requested_shop.to_s.empty?
      raise UnauthorizedError, "Unauthorized: missing or invalid shop domain" unless @shopify_client.valid_shop_domain?(requested_shop.to_s)

      shop = @store.shop(requested_shop)
      if shop && shop["uninstalled_at"]
        return nil if optional

        raise UnauthorizedError, "Unauthorized: shop uninstalled. Please reinstall the app."
      end
      return shop if shop
      return nil if optional

      raise UnauthorizedError, "Unauthorized: shop not found. Please reinstall the app."
    end

    def current_admin_shop(optional: false)
      admin_shop_domain = @session["admin_shop_domain"].to_s
      return nil if optional && admin_shop_domain.empty?
      raise UnauthorizedError, "Unauthorized: missing admin app session" if admin_shop_domain.empty?
      raise UnauthorizedError, "Unauthorized: invalid admin shop domain" unless @shopify_client.valid_shop_domain?(admin_shop_domain)

      shop = @store.shop(admin_shop_domain)
      if shop && shop["uninstalled_at"]
        return nil if optional

        raise UnauthorizedError, "Unauthorized: admin shop uninstalled. Please reinstall the app."
      end
      return shop if shop
      return nil if optional

      raise UnauthorizedError, "Unauthorized: admin shop not found. Please reinstall the app."
    end

    def require_shop
      current_shop(optional: false)
    end

    def require_onboarded_shop
      shop = require_shop
      return shop if shop["onboarded"]

      raise UnauthorizedError, "Complete onboarding before accessing the app."
    end

    def require_onboarded_ready_shop
      shop = require_shop
      status = @sync_engine.status(shop["shop_domain"])
      raise UnauthorizedError, "Initial sync is not complete yet." unless status["status"] == "completed"

      shop
    end

    def require_admin_shop_for_current_shop
      shop = require_onboarded_shop
      admin_shop = current_admin_shop(optional: false)
      return shop if admin_shop["shop_domain"] == shop["shop_domain"]

      raise UnauthorizedError, "Queue Ops is only available to app admins for the installed shop."
    end

    def current_sync_status(optional: false)
      shop = current_shop(optional: optional)
      return @sync_engine.send(:idle_status) unless shop

      @sync_engine.status(shop["shop_domain"])
    end

    def ensure_shop_for_onboarding
      if @config.mock_mode?
        current_shop(optional: false)
      else
        current_shop(optional: false)
      end
    end

    def current_shop_name(shop_domain)
      existing = @store.shop(shop_domain)
      return existing["shop_name"] if existing && existing["shop_name"]

      shop_domain.split(".").first.split("-").map(&:capitalize).join(" ")
    end

    def last_30_day_revenue(orders)
      cutoff = Time.now - (29 * 86_400)
      daily = Hash.new(0.0)
      orders.each do |order|
        timestamp = Time.parse(order["created_at"])
        next if timestamp < cutoff

        key = timestamp.strftime("%Y-%m-%d")
        daily[key] += order["total_price_amount"]
      end

      (0..29).map do |offset|
        day = (Time.now - ((29 - offset) * 86_400)).strftime("%Y-%m-%d")
        { "date" => day, "revenue" => daily.fetch(day, 0.0).round(2) }
      end
    end

    def vendor_summaries(shop, orders)
      edits = shop["vendor_edits"]
      grouped = orders.each_with_object(Hash.new { |hash, key| hash[key] = { "orders" => 0, "revenue" => 0.0 } }) do |order, memo|
        order["line_items"].each do |line_item|
          vendor = line_item["vendor"] || "Unknown Vendor"
          memo[vendor]["orders"] += 1
          memo[vendor]["revenue"] += line_item["totalAmount"].to_f
        end
      end

      grouped.map do |vendor_name, values|
        edit = edits[vendor_name] || {}
        rate = (edit["rate"] || 12).to_f
        deductions = (edit["deductions"] || seeded_vendor_deduction(vendor_name)).to_f
        commission = (values["revenue"] * rate / 100.0).round(2)
        {
          "name" => vendor_name,
          "total_orders" => values["orders"],
          "total_revenue" => values["revenue"].round(2),
          "commission_rate" => rate,
          "total_commission" => commission,
          "custom_deductions" => deductions.round(2),
          "net_payable" => (commission - deductions).round(2)
        }
      end.sort_by { |vendor| vendor["name"] }
    end

    def seeded_vendor_deduction(name)
      seed = name.to_s.length
      (((Math.sin(seed) * 10_000) - (Math.sin(seed) * 10_000).floor) * 200 * 100).round / 100.0
    end

    def merged_invoice_config(shop)
      deep_merge(MockData::DEFAULT_INVOICE_TEMPLATE_CONFIG, shop["invoice_template_config"] || {})
    end

    def merged_notification_config(shop)
      deep_merge(MockData::DEFAULT_NOTIFICATION_CONFIG, shop["notification_config"] || {})
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

    def plan_definitions
      [
        { "id" => "basic", "name" => "Basic", "price" => "$9", "period" => "/mo", "tagline" => "For Shopify Basic stores", "features" => ["Basic invoice templates", "Email and SMS notifications", "Up to 100 orders per month"] },
        { "id" => "growth", "name" => "Growth", "price" => "$29", "period" => "/mo", "tagline" => "For growing stores", "popular" => true, "features" => ["Everything in Basic", "Customizable invoice templates", "Advanced notifications", "Analytics and tracking"] },
        { "id" => "pro", "name" => "Pro", "price" => "$79", "period" => "/mo", "tagline" => "For Shopify Advanced stores", "features" => ["Everything in Growth", "Multi-currency invoices", "Detailed reporting", "Priority support"] },
        { "id" => "enterprise", "name" => "Enterprise", "price" => "Custom", "period" => "", "tagline" => "For Shopify Plus", "features" => ["Everything in Pro", "Dedicated account manager", "Custom ERP and CRM integrations", "Subscription invoices"] }
      ]
    end

    def faq_items
      [
        { "question" => "How do I connect my Shopify store?", "answer" => "Start from the OAuth install URL or use mock mode locally." },
        { "question" => "Can I customize invoice templates?", "answer" => "Yes. Update the template settings and use the print view to export a browser PDF." },
        { "question" => "Which notification channels are supported?", "answer" => "Email, WhatsApp, Slack, and Basecamp are all configurable." },
        { "question" => "How is vendor commission calculated?", "answer" => "The vendor page uses each line item's vendor, applies the commission rate, then subtracts custom deductions." },
        { "question" => "What happens after my trial expires?", "answer" => "You can switch to a paid plan from the plans page." }
      ]
    end

    def load_session
      cookie = @request.cookies.find { |item| item.name == @config.session_cookie_name }
      @session_id = cookie ? cookie.value : SecureRandom.hex(24)
      @session = @store.load_session(@session_id)
      return if cookie

      @response.cookies << WEBrick::Cookie.new(@config.session_cookie_name, @session_id)
    end

    def persist_session
      return unless @session_id

      @store.save_session(@session_id, @session["shop_domain"], @session || {})
    end

    def consume_flash
      flash = @session["flash"]
      @session.delete("flash")
      flash
    end

    def flash!(type, message)
      @session["flash"] = { "type" => type, "message" => message }
    end

    def base_locals
      { current_year: Time.now.year }
    end

    def queue_ops_admin?(shop)
      return false unless shop

      admin_shop = current_admin_shop(optional: true)
      admin_shop && admin_shop["shop_domain"] == shop["shop_domain"]
    end

    def back_path(fallback)
      referer = header_value("referer")
      return fallback unless referer

      uri = URI.parse(referer)
      return fallback unless uri.path

      path = uri.path
      path += "?#{uri.query}" if uri.query
      path
    rescue URI::InvalidURIError
      fallback
    end

    def params
      @request.query
    end

    def stringified_params
      params.each_with_object({}) do |(key, value), memo|
        memo[key] = single_value(value)
      end
    end

    def request_payload
      return stringified_params unless @request["Content-Type"].to_s.include?("application/json")
      return {} if @request.body.to_s.strip.empty?

      JSON.parse(@request.body)
    rescue JSON::ParserError
      {}
    end

    def authorize_sync_secret!
      return true if @config.mock_mode?

      secret = @config.sync_api_secret.to_s
      provided = header_value("x-sync-secret").to_s
      raise UnauthorizedError, "SYNC_API_SECRET is required for automated sync" if secret.empty?
      raise UnauthorizedError, "Invalid sync secret" unless secure_compare(provided, secret)

      true
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      left_bytes = left.unpack("C*")
      result = 0
      right.each_byte.with_index { |byte, index| result |= byte ^ left_bytes[index] }
      result.zero?
    end

    def single_value(value)
      value.is_a?(Array) ? value.first : value
    end

    def requested_async_request_statuses(default: ["failed"])
      raw_statuses = single_value(params["status"]).to_s.strip
      return Array(default) if raw_statuses.empty?
      return ASYNC_REQUEST_STATUSES if raw_statuses == "all"

      statuses = raw_statuses.split(",").map(&:strip).reject(&:empty?).uniq
      invalid = statuses - ASYNC_REQUEST_STATUSES
      raise UnauthorizedError, "Invalid async request status filter" unless invalid.empty?

      statuses
    end

    def requested_async_request_limit(default: 20)
      limit = single_value(params["limit"]).to_i
      limit = default if limit <= 0
      [limit, 100].min
    end

    def requested_async_request_page
      page = single_value(params["page"]).to_i
      page <= 0 ? 1 : page
    end

    def shop_async_job_request_from_path
      request_id = async_job_request_id_from_path
      request = @store.async_job_request(request_id)
      return nil unless request
      return request if request["shop_domain"] == require_shop["shop_domain"]

      nil
    end

    def shop_batch_log_from_path
      batch_id = batch_log_id_from_path
      batch = @store.batch_log(batch_id)
      return nil unless batch
      return batch if batch["shop_domain"] == require_shop["shop_domain"]

      nil
    end

    def async_job_request_id_from_path
      path = @request.path.to_s
      if path.end_with?("/retry") || path.end_with?("/delete")
        File.basename(File.dirname(path))
      else
        File.basename(path)
      end
    end

    def batch_log_id_from_path
      File.basename(File.dirname(@request.path.to_s))
    end

    def serialize_async_job_request(request)
      retry_in_seconds = nil
      if request["status"] == "queued" && request["error_message"] && request["available_at"]
        begin
          retry_in_seconds = [Time.iso8601(request["available_at"]).to_i - Time.now.utc.to_i, 0].max
        rescue ArgumentError
          retry_in_seconds = nil
        end
      end

      {
        id: request["id"],
        shopDomain: request["shop_domain"],
        requestType: request["request_type"],
        queueName: request["queue_name"],
        status: request["status"],
        attempts: request["attempts"],
        claimedBy: request["claimed_by"],
        claimedAt: request["claimed_at"],
        availableAt: request["available_at"],
        dispatchedAt: request["dispatched_at"],
        errorMessage: request["error_message"],
        createdAt: request["created_at"],
        updatedAt: request["updated_at"],
        payload: request["payload"],
        retryInSeconds: retry_in_seconds,
        canRetry: request["status"] == "failed",
        canDelete: %w[failed completed].include?(request["status"])
      }
    end

    def header_value(name)
      Array(@request.header[name.to_s.downcase]).first
    end

    def api_request?
      @request.path.start_with?("/api/")
    end

    def webhook_request?
      @request&.path.to_s.start_with?("/webhooks/")
    end

    def queue_ops_path(shop_domain)
      query_path("/queue-ops", { "shop" => shop_domain })
    end
  end
end
