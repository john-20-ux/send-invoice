# frozen_string_literal: true

Rails.application.configure do
  sql_log_enabled = ENV.fetch("SEND_INVOICE_WORKER_SQL_LOG", "0") == "1"

  config.cache_classes = false
  config.eager_load = false
  config.log_level = ENV.fetch("SEND_INVOICE_WORKER_LOG_LEVEL", "info").downcase.to_sym
  config.active_record.verbose_query_logs = false
  config.active_record.logger = sql_log_enabled ? config.logger : nil
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
end
