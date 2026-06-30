# frozen_string_literal: true

require "pg"

module SendInvoice
  # Wraps a PG::Connection with the same surface the Store/Migrator use against
  # SQLite (execute / get_first_row / get_first_value / execute_batch / changes),
  # translating the few SQLite-isms in our SQL to Postgres:
  #   * `?` positional binds      -> `$1, $2, ...`
  #   * `INSERT OR IGNORE`        -> `INSERT ... ON CONFLICT DO NOTHING`
  #   * `rowid` (ORDER BY tie)    -> `ctid`
  #   * `PRAGMA ...`              -> no-op
  # Results come back as string-keyed hashes (like SQLite's results_as_hash),
  # and callers already coerce with to_i/to_f/normalize_text.
  class PgConnection
    def initialize(url)
      @url = url
      @last_changes = 0
      connect
    end

    def connect
      @conn = PG.connect(@url)
    end

    def healthy?
      !@conn.nil? && !@conn.finished? && @conn.status == PG::CONNECTION_OK
    rescue StandardError
      false
    end

    def ensure_healthy!
      connect unless healthy?
    end

    def execute(sql, binds = [])
      translated = translate(sql)
      return [] if translated.nil? # PRAGMA / no-op

      result = @conn.exec_params(translated, Array(binds).map { |bind| pg_bind(bind) })
      @last_changes = result.cmd_tuples.to_i
      result.to_a
    end

    def get_first_row(sql, binds = [])
      execute(sql, binds).first
    end

    def get_first_value(sql, binds = [])
      row = get_first_row(sql, binds)
      row && row.values.first
    end

    # Multi-statement DDL (schema). No bound params; only translate dialect bits.
    def execute_batch(sql)
      @conn.exec(rewrite_dialect(sql.to_s))
      nil
    end

    def changes
      @last_changes
    end

    def close
      @conn&.close
    rescue StandardError
      nil
    end

    private

    def translate(sql)
      text = sql.to_s
      return nil if text.strip.upcase.start_with?("PRAGMA")

      number_placeholders(rewrite_dialect(text))
    end

    def rewrite_dialect(sql)
      out = rewrite_insert_or_ignore(sql)
      out.gsub(/\browid\b/i, "ctid")
    end

    def rewrite_insert_or_ignore(sql)
      return sql unless sql.match?(/INSERT\s+OR\s+IGNORE/i)

      sql.sub(/INSERT\s+OR\s+IGNORE/i, "INSERT").rstrip.sub(/;?\s*\z/, "") + " ON CONFLICT DO NOTHING"
    end

    def number_placeholders(sql)
      index = 0
      sql.gsub("?") do
        index += 1
        "$#{index}"
      end
    end

    def pg_bind(value)
      case value
      when true then "t"
      when false then "f"
      else value
      end
    end
  end
end
