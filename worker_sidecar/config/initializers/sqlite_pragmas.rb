# frozen_string_literal: true

return unless Rails.env.development?

Rails.application.config.after_initialize do
  apply_pragmas = lambda do |connection, label|
    connection.execute("PRAGMA busy_timeout = 30000")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA synchronous = NORMAL")
  rescue StandardError => e
    warn "[send-invoice-worker] failed to apply SQLite pragmas for #{label}: #{e.class}: #{e.message}"
  end

  apply_pragmas.call(ActiveRecord::Base.connection, "primary")
  apply_pragmas.call(SolidQueue::Record.connection, "queue") if defined?(SolidQueue::Record)
end
