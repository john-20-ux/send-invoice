# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "solid_queue"

module SendInvoiceWorker
  class Application < Rails::Application
    config.load_defaults 7.1
    config.api_only = true
    config.eager_load = ENV.fetch("RAILS_ENV", "development") == "production"
    config.autoload_paths << root.join("lib")
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }
    config.logger = ActiveSupport::Logger.new($stdout)
  end
end
