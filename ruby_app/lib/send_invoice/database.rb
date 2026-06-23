# frozen_string_literal: true

require "fileutils"
require "sqlite3"

module SendInvoice
  class Database
    def initialize(config)
      @config = config
      FileUtils.mkdir_p(File.dirname(@config.database_path))
    end

    def with_connection
      db = SQLite3::Database.new(@config.database_path)
      db.results_as_hash = true
      db.busy_timeout = 5_000
      db.execute("PRAGMA foreign_keys = ON")
      yield db
    ensure
      db&.close
    end
  end
end
