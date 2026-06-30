# frozen_string_literal: true

require "fileutils"
require "sqlite3"

module SendInvoice
  # Dual-engine database access. Uses PostgreSQL when DATABASE_URL is set
  # (production), otherwise SQLite (local/dev/test). Both engines expose the
  # same connection surface via `with_connection` so the Store/Migrator stay
  # engine-agnostic.
  class Database
    def initialize(config)
      @config = config
      @url = ENV["DATABASE_URL"].to_s
      @postgres = @url.start_with?("postgres://", "postgresql://")

      if @postgres
        require "send_invoice/pg_connection"
        @pool = Queue.new
        @pool_size = [Integer(ENV.fetch("DB_POOL", "5"), 10), 1].max
        @pool_mutex = Mutex.new
        @created = 0
      else
        FileUtils.mkdir_p(File.dirname(@config.database_path))
      end
    end

    def postgres?
      @postgres
    end

    def with_connection(&block)
      @postgres ? with_pg_connection(&block) : with_sqlite_connection(&block)
    end

    private

    def with_sqlite_connection
      db = SQLite3::Database.new(@config.database_path)
      db.results_as_hash = true
      db.busy_timeout = 5_000
      db.execute("PRAGMA foreign_keys = ON")
      yield db
    ensure
      db&.close
    end

    def with_pg_connection
      conn = checkout_pg
      conn.ensure_healthy!
      yield conn
    ensure
      @pool.push(conn) if conn
    end

    # Lazily grow the pool up to @pool_size, then block for an available conn.
    def checkout_pg
      @pool_mutex.synchronize do
        if @pool.empty? && @created < @pool_size
          @created += 1
          return PgConnection.new(@url)
        end
      end
      @pool.pop
    end
  end
end
