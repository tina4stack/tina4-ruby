# frozen_string_literal: true
require "fileutils"

module Tina4
  class Migration
    TRACKING_TABLE = "tina4_migration"

    attr_reader :db, :migrations_dir

    def initialize(db, migrations_dir: nil)
      @db = db
      @migrations_dir = migrations_dir || resolve_migrations_dir
      ensure_tracking_table
    end

    # Run all pending migrations
    def migrate
      pending = pending_migrations
      if pending.empty?
        Tina4::Log.info("No pending migrations")
        return []
      end

      batch = next_batch_number
      results = []
      pending.each do |file|
        result = run_migration(file, batch)
        results << result
        # Stop on failure
        break if result[:status] == "failed"
      end
      results
    end

    alias run migrate

    # Rollback last batch (or N steps)
    def rollback(steps = 1)
      completed = completed_migrations_with_batch
      return [] if completed.empty?

      # Get the last N unique batches
      batches = completed.map { |m| m[:batch] }.uniq.sort.reverse
      batches_to_rollback = batches.first(steps)

      results = []
      completed.select { |m| batches_to_rollback.include?(m[:batch]) }
               .sort_by { |m| -m[:id] }
               .each do |migration|
        result = rollback_migration(migration[:migration_name])
        results << result
      end
      results
    end

    def status
      {
        completed: completed_migrations,
        pending: pending_migrations.map { |f| File.basename(f) }
      }
    end

    # Create a new migration file
    #
    # kind="ruby"   — creates {timestamp}_{description}.rb with MigrationBase subclass (default)
    # kind="sql"    — creates {timestamp}_{description}.sql + .down.sql
    # kind="python" — alias for "ruby" (class-based scaffold for cross-framework parity)
    def create(description, kind = "sql")
      FileUtils.mkdir_p(@migrations_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      created_at = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
      safe_name = description.gsub(/[^a-z0-9]+/i, "_").downcase.gsub(/^_|_$/, "")

      if kind == "ruby" || kind == "python"
        filename = "#{timestamp}_#{safe_name}.rb"
        filepath = File.join(@migrations_dir, filename)

        File.write(filepath, <<~RUBY)
          # frozen_string_literal: true
          # Migration: #{description}
          # Created: #{created_at}

          class #{classify(description)} < Tina4::MigrationBase
            def up(db = nil)
              # db.execute("CREATE TABLE ...")
            end

            def down(db = nil)
              # db.execute("DROP TABLE IF EXISTS ...")
            end
          end
        RUBY

        Tina4::Log.info("Created migration: #{filename}")
        return filepath
      end

      # Default: SQL
      up_filename = "#{timestamp}_#{safe_name}.sql"
      down_filename = "#{timestamp}_#{safe_name}.down.sql"
      up_path = File.join(@migrations_dir, up_filename)
      down_path = File.join(@migrations_dir, down_filename)

      File.write(up_path, "-- Migration: #{description}\n-- Created: #{created_at}\n\n")
      File.write(down_path, "-- Rollback: #{description}\n-- Created: #{created_at}\n\n")

      Tina4::Log.info("Created migration: #{up_filename}")
      up_path
    end

    # Insert a record into the migration tracking table.
    #
    # @param name  [String]  Migration filename (e.g. "20240101000000_create_users.sql")
    # @param batch [Integer] Batch number this migration belongs to
    # @param passed [Integer] 1 if successful (default), 0 if failed
    def record_migration(name, batch, passed: 1)
      _record_migration(name, batch, passed: passed)
    end

    # Delete a migration record from the tracking table by filename.
    #
    # @param name [String] Migration filename to remove
    def remove_migration_record(name)
      _remove_migration_record(name)
    end

    # Create a migration file — static helper for parity with Python/Node.
    # @param description [String] Human-readable migration name
    # @param migrations_dir [String] Directory for migration files (default: 'migrations')
    # @param kind [String] File kind: 'sql' or 'ruby' (default: 'sql')
    def self.create_migration(description, migrations_dir: "migrations", kind: "sql")
      new(nil, migrations_dir: migrations_dir).create(description, kind)
    end

    # Get list of applied migration records (public alias for completed_migrations)
    def get_applied
      completed_migrations
    end

    # Alias for get_applied — parity with PHP/Node
    def get_applied_migrations
      get_applied
    end

    # Get list of pending migration filenames (public alias for pending_migrations)
    def get_pending
      pending_migrations.map { |f| File.basename(f) }
    end

    # Get all migration files on disk, excluding .down files
    def get_files
      migration_files = Dir.glob(File.join(@migrations_dir, "*.sql")).reject { |f| f.end_with?(".down.sql") }
      migration_files += Dir.glob(File.join(@migrations_dir, "*.rb"))
      migration_files.map { |f| File.basename(f) }.sort
    end

    private

    # Resolve migrations directory: prefer src/migrations, fall back to migrations/
    def resolve_migrations_dir
      # Canonical location is migrations/ (project root) — matches the Python reference, the CLI,
      # and auto-migrate. A legacy src/migrations/ is honoured only as a fallback.
      root_dir = File.join(Dir.pwd, "migrations")
      return root_dir if Dir.exist?(root_dir)

      src_dir = File.join(Dir.pwd, "src", "migrations")
      return src_dir if Dir.exist?(src_dir)

      # Neither exists yet -> default to the canonical migrations/ (created when needed)
      root_dir
    end

    def ensure_tracking_table
      return unless @db
      unless @db.table_exists?(TRACKING_TABLE)
        if firebird?
          # Firebird: no AUTOINCREMENT, no TEXT type, use generator for IDs
          begin
            @db.execute("CREATE GENERATOR GEN_TINA4_MIGRATION_ID")
            @db.execute("COMMIT") rescue nil
          rescue
            # Generator may already exist
          end
          # migration_name is UNIQUE: a migration is "applied" iff a success row
          # exists, so a re-applied name must never duplicate a tracking row.
          @db.execute(<<~SQL)
            CREATE TABLE #{TRACKING_TABLE} (
              id INTEGER NOT NULL PRIMARY KEY,
              migration_name VARCHAR(500) NOT NULL UNIQUE,
              description VARCHAR(500),
              batch INTEGER NOT NULL DEFAULT 1,
              executed_at VARCHAR(50) NOT NULL,
              passed INTEGER NOT NULL DEFAULT 1
            )
          SQL
        else
          # Engine-aware bookkeeping DDL. Each engine spells an auto-increment
          # integer PK differently (SQLite AUTOINCREMENT, PostgreSQL SERIAL,
          # MySQL AUTO_INCREMENT, MSSQL IDENTITY); MSSQL also reserves TIMESTAMP
          # for rowversion, so a real timestamp column must be DATETIME. The
          # migration_name UNIQUE column is VARCHAR (not TEXT) — a TEXT column
          # cannot carry a UNIQUE index on MySQL, and SQLite gives VARCHAR TEXT
          # affinity so SQLite behaviour stays identical. Mirrors the
          # engine-aware DDL in ORM.create_table; without it `migrate()` died
          # with "syntax error at AUTOINCREMENT" on PostgreSQL/MySQL/MSSQL.
          #
          # migration_name is UNIQUE: a migration is "applied" iff a success row
          # exists, so a re-applied name must never duplicate a tracking row.
          engine = (@db.respond_to?(:get_database_type) ? @db.get_database_type : "").to_s.downcase
          id_column = case engine
                      when "postgres", "postgresql" then "id SERIAL PRIMARY KEY"
                      when "mysql" then "id INTEGER PRIMARY KEY AUTO_INCREMENT"
                      when "mssql", "sqlserver" then "id INTEGER IDENTITY(1,1) PRIMARY KEY"
                      else "id INTEGER PRIMARY KEY AUTOINCREMENT" # sqlite (default)
                      end
          # Canonical executed_at is a written VARCHAR(50) string (no
          # CURRENT_TIMESTAMP default — a timestamp default on a VARCHAR is
          # rejected by PostgreSQL/MySQL). recordMigration writes it explicitly.
          @db.execute(<<~SQL)
            CREATE TABLE #{TRACKING_TABLE} (
              #{id_column},
              migration_name VARCHAR(500) NOT NULL UNIQUE,
              description VARCHAR(500),
              batch INTEGER NOT NULL DEFAULT 1,
              executed_at VARCHAR(50) NOT NULL,
              passed INTEGER NOT NULL DEFAULT 1
            )
          SQL
        end
        Tina4::Log.info("Created migrations tracking table")
      end
    end

    # Return a result row keyed by lower-case symbols. Firebird returns rows keyed
    # by UPPERCASE string column names while SQLite/others return lower-case symbol
    # keys, so the tracking-table reads below are normalised to one shape. Without
    # this, `row[:migration_name]` is nil on Firebird and every applied migration
    # is treated as pending and re-run.
    def normalize_row(row)
      return {} if row.nil?

      source = row.respond_to?(:to_h) ? row.to_h : row
      source.each_with_object({}) { |(k, v), h| h[k.to_s.downcase.to_sym] = v }
    end

    def completed_migrations
      result = @db.fetch("SELECT migration_name FROM #{TRACKING_TABLE} WHERE passed = 1 ORDER BY id")
      result.map { |r| normalize_row(r)[:migration_name] }
    end

    def completed_migrations_with_batch
      result = @db.fetch("SELECT id, migration_name, batch FROM #{TRACKING_TABLE} WHERE passed = 1 ORDER BY id")
      result.map do |r|
        row = normalize_row(r)
        { id: row[:id], migration_name: row[:migration_name], batch: row[:batch] }
      end
    end

    def next_batch_number
      result = normalize_row(@db.fetch_one("SELECT MAX(batch) as max_batch FROM #{TRACKING_TABLE} WHERE passed = 1"))
      (result[:max_batch] ? result[:max_batch].to_i : 0) + 1
    end

    def pending_migrations
      return [] unless Dir.exist?(@migrations_dir)

      completed = completed_migrations
      # Support both .rb and .sql migration files. Accept both 000001_name.sql
      # (sequential) and YYYYMMDDHHMMSS_name.sql (timestamp) patterns. Sort by a
      # leading numeric/timestamp prefix (numeric-aware) so `9_*` applies before
      # `10_*` — a plain lexical sort misorders unpadded prefixes ("10" < "9").
      # Files with no numeric prefix sort after the numbered ones, lexically.
      files = Dir.glob(File.join(@migrations_dir, "*.{rb,sql}"))
                 .reject { |f| f.end_with?(".down.sql") }
                 .sort_by { |f| migration_sort_key(File.basename(f)) }

      # Warn about filenames without a recognized NNNNNN_/timestamp prefix —
      # their ordering relative to numbered migrations is undefined, a silent
      # out-of-order-apply footgun.
      unprefixed = files.map { |f| File.basename(f) }.reject { |n| n =~ /\A\d+[_-]/ }
      unless unprefixed.empty?
        Tina4::Log.warning(
          "Migration file(s) without a numeric/timestamp prefix may apply out of order: " +
          unprefixed.join(", ")
        )
      end

      files.reject { |f| completed.include?(File.basename(f)) }
    end

    # Numeric-aware sort key so `9_name.sql` sorts before `10_name.sql` (plain
    # lexical sort puts "10" before "9"). Files with a leading numeric/timestamp
    # prefix sort first by that number; the rest sort after, lexically.
    def migration_sort_key(filename)
      if filename =~ /\A(\d+)/
        [0, $1.to_i, filename]
      else
        [1, 0, filename]
      end
    end

    def run_migration(file, batch)
      name = File.basename(file)
      Tina4::Log.info("Running migration: #{name}")
      begin
        # Wrap each migration FILE in its own transaction so a multi-statement
        # file that fails midway rolls back as a unit. Truly atomic only on
        # engines with transactional DDL (PostgreSQL); MySQL/Firebird/SQLite
        # auto-commit DDL, so earlier statements may persist there — keep one
        # logical change per file.
        @db.start_transaction
        if file.end_with?(".rb")
          execute_ruby_migration(file, :up)
        else
          execute_sql_file(file)
        end
        # A migration is "applied" iff a passed=1 row exists. On success,
        # _record_migration deletes any existing row for this migration_name
        # (superseding a leftover passed=0) and writes the fresh passed=1 row, so
        # a previously-failed migration re-applies cleanly instead of colliding
        # on the UNIQUE migration_name. On a FAILURE the file rolls back and NO
        # row is written (failures are never recorded) - fix the bad file and
        # re-run.
        _record_migration(name, batch, passed: 1)
        @db.commit
        { name: name, status: "success" }
      rescue => e
        @db.rollback rescue nil
        Tina4::Log.error("Migration failed: #{name} - #{e.message}")
        { name: name, status: "failed", error: e.message }
      end
    end

    def rollback_migration(name)
      Tina4::Log.info("Rolling back: #{name}")
      begin
        file = File.join(@migrations_dir, name)
        if name.end_with?(".rb") && File.exist?(file)
          execute_ruby_migration(file, :down)
        elsif name.end_with?(".sql")
          down_file = File.join(@migrations_dir, name.sub(".sql", ".down.sql"))
          if File.exist?(down_file)
            execute_sql_file(down_file)
          else
            Tina4::Log.warning("No rollback file for: #{name}")
          end
        end
        _remove_migration_record(name)
        { name: name, status: "rolled_back" }
      rescue => e
        Tina4::Log.error("Rollback failed: #{name} - #{e.message}")
        { name: name, status: "failed", error: e.message }
      end
    end

    def execute_ruby_migration(file, direction)
      # Load the migration class
      content = File.read(file)
      # Evaluate in a clean binding
      eval(content, TOPLEVEL_BINDING, file)

      # Find the migration class (last class defined that inherits from MigrationBase)
      class_name = extract_class_name(content)
      klass = Object.const_get(class_name)
      migration = klass.new
      migration.__send__(direction, @db)
    end

    # Smart/curly quotes — editors, word processors, docs and chat apps silently
    # convert a straight " to “ ” and a straight ' to ‘ ’ (plus primes ′ ″). Those
    # characters are NOT valid SQL string/identifier delimiters, so a pasted-in
    # migration fails to run ("syntax error near …"). Map them back to straight
    # ASCII quotes. (Real string CONTENTS are unaffected by intent — we only swap
    # the lookalike code points for their ASCII equivalents.)
    SMART_QUOTES = {
      "“" => '"', "”" => '"', "„" => '"', "‟" => '"', "″" => '"', # “ ” „ ‟ ″
      "‘" => "'", "’" => "'", "‚" => "'", "‛" => "'", "′" => "'"  # ‘ ’ ‚ ‛ ′
    }.freeze
    SMART_QUOTE_RE = Regexp.union(SMART_QUOTES.keys)

    # Replace smart/curly quotes with straight ASCII quotes so migration SQL
    # authored or pasted from an editor/doc actually runs (those code points are
    # not valid SQL delimiters). Already-straight quotes and ordinary content are
    # returned byte-for-byte unchanged.
    def normalize_quotes(sql)
      sql.gsub(SMART_QUOTE_RE, SMART_QUOTES)
    end

    # Split SQL into individual statements with a single-pass, quote- and
    # comment-aware scanner. The split decision is made character by character so
    # the delimiter only ever fires in real statement position.
    #
    # This is the fix for issue #54: the old implementation split on +delimiter+
    # BEFORE stripping +-- …+ line comments, so a +;+ inside a line comment
    # fragmented one statement into several broken pieces. A scanner that knows
    # where it is (code / comment / string) cannot make that mistake.
    #
    # Handled, in priority order, only when NOT already inside a stored-proc block:
    # - $$ … $$ and // … // stored-proc blocks are kept intact (inner ; never
    #   splits). A // preceded by ':' is a URL scheme (https://…), not a delimiter.
    # - /* … */ block comments are stripped.
    # - -- … line comments are stripped to end of line (the newline is kept).
    # - '…' single-quoted strings and "…" double-quoted identifiers are copied
    #   verbatim, honouring the SQL doubled-quote escape ('' / ""); a ;, -- or /*
    #   inside a literal is data, not a delimiter or comment.
    # Mirrors the tina4-python _split_statements / tina4-php scanner (parity).
    def split_sql_statements(sql, delimiter = ";")
      # Normalize smart/curly quotes to straight ASCII first, so SQL pasted from
      # an editor/doc (which converts " → “ ” and ' → ‘ ’) actually runs.
      sql = normalize_quotes(sql)

      statements = []
      current = +""
      n = sql.length
      dlen = delimiter.length
      i = 0
      in_dollar_block = false
      in_slash_block = false

      while i < n
        ch = sql[i]

        # $$ … $$ stored-proc block (toggle).
        if !in_slash_block && ch == "$" && i + 1 < n && sql[i + 1] == "$"
          current << "$$"
          i += 2
          in_dollar_block = !in_dollar_block
          next
        end

        # // … // stored-proc block (toggle) — but NOT a `://` URL scheme.
        if !in_dollar_block && ch == "/" && i + 1 < n && sql[i + 1] == "/" &&
           !(i.positive? && sql[i - 1] == ":")
          current << "//"
          i += 2
          in_slash_block = !in_slash_block
          next
        end

        # Inside a stored-proc block: consume verbatim (inner ; never splits).
        if in_dollar_block || in_slash_block
          current << ch
          i += 1
          next
        end

        # Block comment /* … */ — stripped.
        if ch == "/" && i + 1 < n && sql[i + 1] == "*"
          endpos = sql.index("*/", i + 2)
          i = endpos ? endpos + 2 : n
          next
        end

        # Line comment -- … — stripped to end of line; the newline is left for the
        # next iteration so line structure (and NEXT-line boundaries) survive.
        if ch == "-" && i + 1 < n && sql[i + 1] == "-"
          endpos = sql.index("\n", i + 2)
          i = endpos || n
          next
        end

        # Single-quoted string literal — '' escapes a quote. Copied verbatim.
        if ch == "'"
          current << "'"
          i += 1
          while i < n
            if sql[i] == "'" && i + 1 < n && sql[i + 1] == "'"
              current << "''"
              i += 2
            elsif sql[i] == "'"
              current << "'"
              i += 1
              break
            else
              current << sql[i]
              i += 1
            end
          end
          next
        end

        # Double-quoted identifier — "" escapes a quote. Same verbatim handling.
        if ch == '"'
          current << '"'
          i += 1
          while i < n
            if sql[i] == '"' && i + 1 < n && sql[i + 1] == '"'
              current << '""'
              i += 2
            elsif sql[i] == '"'
              current << '"'
              i += 1
              break
            else
              current << sql[i]
              i += 1
            end
          end
          next
        end

        # Statement delimiter — only reached outside blocks/comments/strings. A
        # SET TERM directive switches the active terminator and is consumed
        # (never emitted); any other completed statement is collected.
        if !delimiter.empty? && sql[i, dlen] == delimiter
          i += dlen
          stmt = current.strip
          current = +""
          unless stmt.empty?
            new_term = parse_set_term(stmt)
            if new_term
              delimiter = new_term
              dlen = delimiter.length
            else
              statements << stmt
            end
          end
          next
        end

        current << ch
        i += 1
      end

      # Trailing statement (may not end with a delimiter). A trailing SET TERM
      # directive is a no-op — consume it, don't emit it.
      stmt = current.strip
      statements << stmt unless stmt.empty? || parse_set_term(stmt)
      statements
    end

    # Return the new terminator from a `SET TERM <new> <current>` directive, or
    # nil when +statement+ is not a SET TERM directive.
    #
    # SET TERM is a script-level directive (recognised by isql and other
    # InterBase/Firebird tooling, not run by the engine) that changes the
    # terminator separating statements. Recognising it lets a statement whose own
    # body contains the default ";" terminator — a trigger, stored procedure or
    # EXECUTE BLOCK — be kept intact rather than split on those inner ";". The
    # terminator may be more than one character (e.g. "!!").
    #
    # @param statement [String] a single, already-stripped statement
    # @return [String, nil] the new terminator, or nil when not a SET TERM directive
    def parse_set_term(statement)
      m = statement.strip.match(/\ASET\s+TERM\s+(\S+)\z/i)
      m && m[1]
    end

    def execute_sql_file(file)
      sql = File.read(file)
      statements = split_sql_statements(sql)
      statements.each do |stmt|
        # Idempotency on engines lacking IF NOT EXISTS: Firebird ALTER-TABLE-ADD
        # (pre-check the system catalogue for a duplicate column), and CREATE
        # TABLE on Firebird/MSSQL (pre-check the table exists). Only a genuine
        # already-exists is skipped — every other error still raises.
        skip_reason = should_skip_for_firebird(stmt) || should_skip_create_table(stmt)
        if skip_reason
          Tina4::Log.info("Migration #{File.basename(file)}: #{skip_reason}")
          next
        end
        # db.execute() now RAISES on a SQL error (it no longer returns false),
        # so a bad statement throws straight up to run_migration's rescue, which
        # records the migration as failed and surfaces the error. The old
        # "if result == false: raise" check is dead — a plain execute carries
        # the same failure semantics.
        @db.execute(stmt)
      end
    end

    # Regex to match ALTER TABLE <table> ADD <column> ...
    ALTER_ADD_RE = /\A\s*ALTER\s+TABLE\s+(?:"([^"]+)"|(\S+))\s+ADD\s+(?:"([^"]+)"|(\S+))/i

    def firebird?
      @db.driver_name == "firebird"
    end

    # Check if a column already exists in a Firebird table via RDB$RELATION_FIELDS.
    # Firebird stores unquoted identifiers in upper-case.
    def firebird_column_exists?(table, column)
      row = @db.fetch_one(
        "SELECT 1 FROM RDB\$RELATION_FIELDS WHERE RDB\$RELATION_NAME = ? AND TRIM(RDB\$FIELD_NAME) = ?",
        [table.upcase, column.upcase]
      )
      !row.nil?
    end

    # If stmt is an ALTER TABLE ... ADD on Firebird and the column already exists,
    # returns a skip reason. Returns nil if the statement should execute normally.
    def should_skip_for_firebird(stmt)
      return nil unless firebird?

      m = stmt.match(ALTER_ADD_RE)
      return nil unless m

      table = m[1] || m[2]
      column = m[3] || m[4]

      if firebird_column_exists?(table, column)
        "Column #{column} already exists in #{table}, skipping"
      end
    end

    # CREATE TABLE <name> — name may be quoted ("x"), bracketed ([x] MSSQL), or bare.
    CREATE_TABLE_RE = /\A\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"([^"]+)"|\[([^\]]+)\]|(\w+))/i

    # Make CREATE TABLE idempotent on engines lacking IF NOT EXISTS.
    #
    # Firebird and MSSQL do not support `CREATE TABLE IF NOT EXISTS`, so a raw
    # CREATE in a re-run migration raises "object already exists". When the
    # target table already exists on those engines, returns a skip reason so the
    # statement is skipped (mirrors the Firebird ALTER-TABLE-ADD idempotency
    # guard). SQLite/MySQL/PostgreSQL support IF NOT EXISTS and are left to the
    # engine. Only a genuine already-exists is skipped — every other error still
    # raises. Returns nil if the statement should execute normally.
    def should_skip_create_table(stmt)
      engine = @db.get_database_type rescue nil
      return nil unless %w[firebird mssql].include?(engine)

      m = stmt.match(CREATE_TABLE_RE)
      return nil unless m

      table = m[1] || m[2] || m[3]
      begin
        return "Table #{table} already exists, skipping CREATE TABLE" if @db.table_exists?(table)
      rescue
        return nil
      end
      nil
    end

    def _record_migration(name, batch, passed: 1)
      # Extract description from filename (strip numeric prefix and extension)
      stem = File.basename(name, File.extname(name))
      desc = stem.sub(/\A\d+_/, "").tr("_", " ")
      # executed_at is a written VARCHAR(50) string (canonical shape has no
      # CURRENT_TIMESTAMP default), ISO-8601 UTC. strftime avoids a require "time".
      executed_at = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      # Delete-before-insert: supersede any existing row for this migration_name
      # first, so a leftover passed=0 row (a public record_migration(passed: 0)
      # call, or a state carried in from elsewhere) does NOT collide on the
      # UNIQUE migration_name when the fresh row is inserted - the migration
      # re-applies cleanly instead of wedging on the constraint. DELETE+INSERT is
      # portable across every engine (no UPSERT dialect variance). Invariant: the
      # bookkeeping table holds AT MOST ONE row per migration_name, latest state
      # wins. Within run_migration's transaction the delete is part of the same
      # unit (autocommit is a no-op while a transaction is pinned); on the public
      # record_migration path it is a standalone write, mirroring the Python
      # master's two-statement delete-then-insert.
      _remove_migration_record(name)

      # Build the column list from the columns that ACTUALLY exist on the table,
      # so a legacy column left behind by an in-place upgrade is populated rather
      # than defaulted to NULL. Ruby never created a `migration_id` column, but a
      # Ruby app can be pointed at a database whose tina4_migration table was
      # created by tina4-python v3 <= 3.13.54 - there `migration_id` is NOT NULL,
      # and an insert that omits it fails, wedging every migration on that
      # database (tina4-python#93). Mirrors the PHP + Python masters.
      cols = _tracking_columns
      insert_cols = %w[migration_name description batch executed_at passed]
      values = [name, desc, batch, executed_at, passed]

      if cols.include?("migration_id")
        insert_cols << "migration_id"
        values << name
      end

      if firebird?
        # Firebird: generate ID from sequence
        row = @db.fetch_one(
          "SELECT GEN_ID(GEN_TINA4_MIGRATION_ID, 1) AS NEXT_ID FROM RDB\$DATABASE"
        )
        next_id = row ? (row[:NEXT_ID] || row[:next_id] || 1).to_i : 1
        insert_cols.unshift("id")
        values.unshift(next_id)
      end

      placeholders = Array.new(insert_cols.length, "?").join(", ")
      @db.execute(
        "INSERT INTO #{TRACKING_TABLE} (#{insert_cols.join(', ')}) VALUES (#{placeholders})",
        values
      )
    end

    # Lowercased column names on the tracking table; empty on any failure so a
    # missing/unreadable table falls through to the canonical column list.
    def _tracking_columns
      (@db.columns(TRACKING_TABLE) || []).map do |c|
        (c.is_a?(Hash) ? (c[:name] || c["name"]) : c).to_s.downcase
      end
    rescue StandardError
      []
    end

    def _remove_migration_record(name)
      @db.delete(TRACKING_TABLE, { migration_name: name })
    end

    def classify(name)
      name.gsub(/[^a-zA-Z0-9_]/, "_")
          .split("_")
          .map(&:capitalize)
          .join
    end

    def extract_class_name(content)
      if content =~ /class\s+(\w+)\s*<\s*Tina4::MigrationBase/
        $1
      else
        raise "No migration class found inheriting from Tina4::MigrationBase"
      end
    end
  end

  # Base class for Ruby migrations
  class MigrationBase
    def up(db = nil)
      raise NotImplementedError, "Implement #up in your migration"
    end

    def down(db = nil)
      raise NotImplementedError, "Implement #down in your migration"
    end
  end
end
