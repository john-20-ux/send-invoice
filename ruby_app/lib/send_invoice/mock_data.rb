# frozen_string_literal: true

require "json"
require "time"

module SendInvoice
  module MockData
    DEMO_SHOP_DOMAIN = "demo-store.myshopify.com"
    DEMO_SHOP_NAME = "Demo Store"
    DEFAULT_CURRENCY = "USD"

    FIRST_NAMES = %w[
      Sarah James Priya Marcus Emily David Aisha Lucas Mei Oliver Fatima Ryan
      Chloe Tomas Nina Hassan Eva Raj Isabelle Kenji Sophia Liam Amara Noah
    ].freeze

    LAST_NAMES = %w[
      Mitchell Rodriguez Sharma Chen Watson Okafor Patel Fernandez Lin Hughes
      Alrashid Kowalski Bernard Garcia Johansson Malik Muller Krishnan Dupont Tanaka
    ].freeze

    PRODUCTS = [
      { "title" => "Wireless Earbuds Pro", "sku" => "WEP-001", "variant" => "Black", "vendor" => "TechStyle Co", "price" => 79.99 },
      { "title" => "Organic Matcha Set", "sku" => "OMS-042", "variant" => "Premium", "vendor" => "GreenLeaf Organics", "price" => 34.99 },
      { "title" => "Denim Jacket Classic", "sku" => "DJC-108", "variant" => "Medium / Blue", "vendor" => "UrbanWear Studio", "price" => 89.99 },
      { "title" => "Ceramic Vase Duo", "sku" => "CVD-220", "variant" => "White", "vendor" => "HomeBliss Decor", "price" => 45.0 },
      { "title" => "Premium Dog Harness", "sku" => "PDH-055", "variant" => "Large / Red", "vendor" => "PetPalace", "price" => 29.99 },
      { "title" => "Yoga Mat Elite", "sku" => "YME-301", "variant" => "6mm / Sage", "vendor" => "FitGear Pro", "price" => 54.99 },
      { "title" => "Sourdough Starter Kit", "sku" => "SSK-015", "variant" => "Standard", "vendor" => "Artisan Bakes", "price" => 24.99 },
      { "title" => "Scandi Table Lamp", "sku" => "STL-190", "variant" => "Oak", "vendor" => "Nordic Living", "price" => 119.0 },
      { "title" => "Smart Watch Band", "sku" => "SWB-077", "variant" => "42mm / Navy", "vendor" => "TechStyle Co", "price" => 19.99 },
      { "title" => "Herbal Tea Collection", "sku" => "HTC-063", "variant" => "12-Pack", "vendor" => "GreenLeaf Organics", "price" => 28.5 },
      { "title" => "Canvas Sneakers", "sku" => "CSN-445", "variant" => "US 10 / White", "vendor" => "UrbanWear Studio", "price" => 64.99 },
      { "title" => "Linen Throw Pillow", "sku" => "LTP-332", "variant" => "Oatmeal", "vendor" => "HomeBliss Decor", "price" => 38.0 },
      { "title" => "Cat Climbing Tower", "sku" => "CCT-088", "variant" => "Tall", "vendor" => "PetPalace", "price" => 149.99 },
      { "title" => "Resistance Band Set", "sku" => "RBS-210", "variant" => "5-Pack", "vendor" => "FitGear Pro", "price" => 22.99 },
      { "title" => "Artisan Bread Knife", "sku" => "ABK-007", "variant" => "Walnut Handle", "vendor" => "Artisan Bakes", "price" => 42.0 },
      { "title" => "Wool Blanket", "sku" => "WBL-156", "variant" => "King / Grey", "vendor" => "Nordic Living", "price" => 135.0 },
      { "title" => "Phone Stand Walnut", "sku" => "PSW-092", "variant" => "Universal", "vendor" => "TechStyle Co", "price" => 32.0 },
      { "title" => "Face Serum Trio", "sku" => "FST-501", "variant" => "Sensitive", "vendor" => "GreenLeaf Organics", "price" => 58.0 }
    ].freeze

    CITIES = [
      ["San Francisco", "CA"],
      ["Austin", "TX"],
      ["Seattle", "WA"],
      ["Chicago", "IL"],
      ["Miami", "FL"],
      ["Denver", "CO"],
      ["Brooklyn", "NY"]
    ].freeze

    FINANCIAL_STATUSES = %w[PAID PAID PAID PARTIALLY_PAID PENDING REFUNDED PARTIALLY_REFUNDED].freeze
    FULFILLMENT_STATUSES = ["FULFILLED", "FULFILLED", "FULFILLED", "UNFULFILLED", "PARTIALLY_FULFILLED", "IN_PROGRESS", nil].freeze

    DEFAULT_NOTIFICATION_CONFIG = {
      "email" => { "enabled" => true, "subject" => "Your Invoice from {{company}}", "body" => "Hi {{name}},\n\nPlease find your invoice attached.\n\nThank you!" },
      "whatsapp" => { "enabled" => false, "phone" => "", "message" => 'Hi {{name}}, your invoice #{{invoice_number}} is ready.' },
      "slack" => { "enabled" => false, "channel" => "#invoices" },
      "basecamp" => { "enabled" => false, "project" => "" }
    }.freeze

    DEFAULT_INVOICE_TEMPLATE_CONFIG = {
      "template" => "classic",
      "currency_symbol" => "$",
      "accent_color" => "#147c64",
      "surface_tone" => "paper",
      "font_family" => "\"IBM Plex Sans\", \"Aptos\", \"Segoe UI\", sans-serif",
      "density" => "comfortable",
      "header_align" => "split",
      "logo_text" => "AS",
      "company_name" => "Acme Store",
      "tagline" => "Quality products delivered",
      "address" => "123 Commerce St, Suite 4",
      "phone" => "+1 (555) 123-4567",
      "email" => "billing@acmestore.com",
      "website" => "www.acmestore.com",
      "gst" => "GST1234567890",
      "bill_to" => "Sarah Mitchell",
      "client_address" => "456 Oak Ave",
      "client_email" => "sarah@email.com",
      "invoice_number" => "INV-1001",
      "invoice_date" => "Mar 21, 2026",
      "due_date" => "Apr 20, 2026",
      "payment_terms" => "Net 30",
      "notes" => "Thank you for your business!",
      "bank_details" => "Bank of Commerce, Acct: 12345678",
      "terms" => "Payment due within 30 days.",
      "visible_fields" => {
        "website" => false,
        "terms" => false,
        "gst" => true,
        "notes" => true,
        "bank_details" => true
      },
      "line_items" => [
        { "desc" => "Wireless Earbuds Pro", "qty" => 2, "rate" => 89.99, "discount" => 0.0, "tax" => 10.0 },
        { "desc" => "Premium Dog Harness", "qty" => 1, "rate" => 45.0, "discount" => 5.0, "tax" => 10.0 },
        { "desc" => "Support and handling", "qty" => 1, "rate" => 18.0, "discount" => 0.0, "tax" => 0.0 }
      ]
    }.freeze

    module_function

    def orders
      @orders ||= generate_orders
    end

    def seeded_random(seed)
      value = Math.sin(seed) * 10_000
      value - value.floor
    end

    def generate_orders
      now = Time.now
      Array.new(150) do |index|
        seed = index + 42
        days_ago = (seeded_random(seed) * 120).floor
        created_at = now - (days_ago * 86_400)
        created_at -= created_at.min * 60
        created_at += (((seeded_random(seed + 1) * 14).floor + 8) * 3_600)
        created_at += ((seeded_random(seed + 2) * 60).floor * 60)

        first_name = FIRST_NAMES[(seeded_random(seed + 3) * FIRST_NAMES.length).floor]
        last_name = LAST_NAMES[(seeded_random(seed + 4) * LAST_NAMES.length).floor]
        financial_status = FINANCIAL_STATUSES[(seeded_random(seed + 5) * FINANCIAL_STATUSES.length).floor]
        fulfillment_status = FULFILLMENT_STATUSES[(seeded_random(seed + 6) * FULFILLMENT_STATUSES.length).floor]
        item_count = (seeded_random(seed + 7) * 4).floor + 1

        line_items = []
        subtotal = 0.0

        item_count.times do |item_index|
          product = PRODUCTS[(seeded_random(seed + 10 + item_index) * PRODUCTS.length).floor]
          quantity = (seeded_random(seed + 20 + item_index) * 3).floor + 1
          total = round_money(quantity * product["price"])
          subtotal += total

          line_items << {
            "id" => "gid://shopify/LineItem/#{1000 + (index * 10) + item_index}",
            "sku" => product["sku"],
            "title" => product["title"],
            "variantTitle" => product["variant"],
            "vendor" => product["vendor"],
            "quantity" => quantity,
            "currentQuantity" => financial_status == "REFUNDED" ? 0 : quantity,
            "totalAmount" => total,
            "totalCurrency" => DEFAULT_CURRENCY
          }
        end

        discounts = round_money(seeded_random(seed + 30) * subtotal * 0.15)
        shipping = round_money((seeded_random(seed + 31) * 15) + 5)
        tax = round_money((subtotal - discounts) * 0.08)
        tip = seeded_random(seed + 32) > 0.8 ? round_money(seeded_random(seed + 33) * 10) : 0.0
        total_price = round_money(subtotal - discounts + shipping + tax + tip)
        refunded = if financial_status == "REFUNDED"
                     total_price
                   elsif financial_status == "PARTIALLY_REFUNDED"
                     round_money(total_price * 0.3)
                   else
                     0.0
                   end

        transactions = [{ "amount" => total_price, "currency" => DEFAULT_CURRENCY }]
        transactions << { "amount" => -refunded, "currency" => DEFAULT_CURRENCY } if refunded.positive?
        city, province = CITIES[(seeded_random(seed + 43) * CITIES.length).floor]
        address1 = "#{120 + index} Market Street"
        address2 = seeded_random(seed + 44) > 0.65 ? "Suite #{100 + index}" : nil
        zip = format("%05d", 10000 + ((seeded_random(seed + 45) * 89999).floor))
        shipping_name = "#{first_name} #{last_name}"
        order_tags = []
        order_tags << "vip" if total_price >= 250
        order_tags << "gift" if seeded_random(seed + 46) > 0.78
        note = seeded_random(seed + 47) > 0.7 ? "Leave package at the front desk if nobody answers." : nil
        transaction_rows = [
          {
            "kind" => "SALE",
            "status" => financial_status == "PENDING" ? "PENDING" : "SUCCESS",
            "gateway" => "Shopify Payments",
            "processedAt" => created_at.utc.iso8601,
            "amountSet" => money_set(total_price)
          }
        ]
        if refunded.positive?
          transaction_rows << {
            "kind" => "REFUND",
            "status" => "SUCCESS",
            "gateway" => "Shopify Payments",
            "processedAt" => (created_at + 3600).utc.iso8601,
            "amountSet" => money_set(refunded)
          }
        end

        normalized_last_name = last_name.downcase.gsub(/[^a-z]/, "")
        {
          "id" => "gid://shopify/Order/#{4000 + index}",
          "shop_domain" => DEMO_SHOP_DOMAIN,
          "name" => "##{1001 + index}",
          "created_at" => created_at.utc.iso8601,
          "fully_paid" => financial_status == "PAID",
          "financial_status" => financial_status,
          "fulfillment_status" => fulfillment_status,
          "total_price_amount" => total_price,
          "total_price_currency" => DEFAULT_CURRENCY,
          "total_discounts_amount" => discounts,
          "total_refunded_amount" => refunded,
          "total_shipping_amount" => shipping,
          "total_tax_amount" => tax,
          "total_tip_amount" => tip,
          "total_weight" => (seeded_random(seed + 34) * 5000 + 200).round,
          "customer_id" => "gid://shopify/Customer/#{2000 + (seeded_random(seed + 40) * 50).floor}",
          "customer_first_name" => first_name,
          "customer_last_name" => last_name,
          "customer_email" => "#{first_name.downcase}.#{normalized_last_name}@example.com",
          "customer_phone" => seeded_random(seed + 41) > 0.5 ? "+1#{(seeded_random(seed + 42) * 9_000_000_000 + 1_000_000_000).floor}" : nil,
          "line_items" => line_items,
          "transactions" => transactions,
          "raw_data" => {
            "id" => "gid://shopify/Order/#{4000 + index}",
            "name" => "##{1001 + index}",
            "createdAt" => created_at.utc.iso8601,
            "updatedAt" => (created_at + 1800).utc.iso8601,
            "fullyPaid" => financial_status == "PAID",
            "displayFinancialStatus" => financial_status,
            "displayFulfillmentStatus" => fulfillment_status,
            "customer" => {
              "id" => "gid://shopify/Customer/#{2000 + (seeded_random(seed + 40) * 50).floor}",
              "firstName" => first_name,
              "lastName" => last_name,
              "email" => "#{first_name.downcase}.#{normalized_last_name}@example.com",
              "phone" => seeded_random(seed + 41) > 0.5 ? "+1#{(seeded_random(seed + 42) * 9_000_000_000 + 1_000_000_000).floor}" : nil
            },
            "shippingAddress" => {
              "name" => shipping_name,
              "address1" => address1,
              "address2" => address2,
              "city" => city,
              "province" => province,
              "zip" => zip,
              "country" => "United States",
              "phone" => seeded_random(seed + 41) > 0.5 ? "+1#{(seeded_random(seed + 42) * 9_000_000_000 + 1_000_000_000).floor}" : nil
            },
            "billingAddress" => {
              "name" => shipping_name,
              "address1" => address1,
              "address2" => address2,
              "city" => city,
              "province" => province,
              "zip" => zip,
              "country" => "United States"
            },
            "note" => note,
            "tags" => order_tags,
            "transactions" => transaction_rows
          },
          "synced_at" => Time.now.utc.iso8601
        }
      end.sort_by { |order| order["created_at"] }.reverse
    end

    def round_money(value)
      (value * 100).round / 100.0
    end

    def money_set(amount)
      {
        "shopMoney" => {
          "amount" => format("%.2f", amount),
          "currencyCode" => DEFAULT_CURRENCY
        }
      }
    end
  end
end
