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
      src_dir = File.join(Dir.pwd, "src", "migrations")
      return src_dir if Dir.exist?(src_dir)

      root_dir = File.join(Dir.pwd, "migrations")
      return root_dir if Dir.exist?(root_dir)

      # Default to src/migrations (will be created when needed)
      src_dir
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
          @db.execute(<<~SQL)
            CREATE TABLE #{TRACKING_TABLE} (
              id INTEGER NOT NULL PRIMARY KEY,
              migration_name VARCHAR(500) NOT NULL,
              description VARCHAR(500) DEFAULT '',
              batch INTEGER NOT NULL DEFAULT 1,
              executed_at VARCHAR(50) DEFAULT CURRENT_TIMESTAMP,
              passed INTEGER NOT NULL DEFAULT 1
            )
          SQL
        else
          @db.execute(<<~SQL)
            CREATE TABLE #{TRACKING_TABLE} (
              id INTEGER PRIMARY KEY,
              migration_name VARCHAR(255) NOT NULL,
              description VARCHAR(255) DEFAULT '',
              batch INTEGER NOT NULL DEFAULT 1,
              executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
              passed INTEGER NOT NULL DEFAULT 1
            )
          SQL
        end
        Tina4::Log.info("Created migrations tracking table")
      end
    end

    def completed_migrations
      result = @db.fetch("SELECT migration_name FROM #{TRACKING_TABLE} WHERE passed = 1 ORDER BY id")
      result.map { |r| r[:migration_name] }
    end

    def completed_migrations_with_batch
      result = @db.fetch("SELECT id, migration_name, batch FROM #{TRACKING_TABLE} WHERE passed = 1 ORDER BY id")
      result.map { |r| { id: r[:id], migration_name: r[:migration_name], batch: r[:batch] } }
    end

    def next_batch_number
      result = @db.fetch_one("SELECT MAX(batch) as max_batch FROM #{TRACKING_TABLE} WHERE passed = 1")
      (result && result[:max_batch] ? result[:max_batch].to_i : 0) + 1
    end

    def pending_migrations
      return [] unless Dir.exist?(@migrations_dir)

      completed = completed_migrations
      # Support both .rb and .sql migration files
      # Accept both 000001_name.sql (sequential) and YYYYMMDDHHMMSS_name.sql (timestamp) patterns
      Dir.glob(File.join(@migrations_dir, "*.{rb,sql}"))
         .reject { |f| f.end_with?(".down.sql") }
         .sort_by { |f| migration_sort_key(File.basename(f)) }
         .reject { |f| completed.include?(File.basename(f)) }
    end

    # Sort key that handles both 000001_name.sql and 20240315120000_name.sql patterns.
    # Both are zero-padded numeric prefixes so alphabetical sorting works, but we
    # extract the prefix explicitly to guarantee correct ordering when mixed.
    def migration_sort_key(filename)
      if filename =~ /\A(\d+)/
        [$1.to_i, filename]
      else
        [0, filename]
      end
    end

    def run_migration(file, batch)
      name = File.basename(file)
      Tina4::Log.info("Running migration: #{name}")
      begin
        if file.end_with?(".rb")
          execute_ruby_migration(file, :up)
        else
          execute_sql_file(file)
        end
        _record_migration(name, batch, passed: 1)
        { name: name, status: "success" }
      rescue => e
        Tina4::Log.error("Migration failed: #{name} - #{e.message}")
        _record_migration(name, batch, passed: 0)
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

    # Split SQL into individual statements, handling:
    # - $$ delimited stored procedure blocks
    # - // delimited blocks
    # - Block comments /* ... */
    # - Line comments -- ...
    # Matches the Python/Node.js approach: extract blocks first, split on ;, restore blocks.
    def split_sql_statements(sql, delimiter = ";")
      blocks = []

      # Extract $$ ... $$ blocks (stored procedures, triggers, etc.)
      processed = sql.gsub(/\$\$(.*?)\$\$/m) do
        blocks << $~.to_s
        "__BLOCK_#{blocks.length - 1}__"
      end

      # Extract // ... // blocks
      processed = processed.gsub(/\/\/(.*?)\/\//m) do
        blocks << $~.to_s
        "__BLOCK_#{blocks.length - 1}__"
      end

      # Remove block comments (/* ... */) but not inside stored proc blocks (already extracted)
      clean = processed.gsub(/\/\*.*?\*\//m, "")

      statements = []
      clean.split(delimiter).each do |stmt|
        lines = []
        stmt.split("\n").each do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("--")
          # Remove inline comments (-- after SQL)
          comment_pos = line.index("--")
          line = line[0...comment_pos] if comment_pos && comment_pos >= 0
          lines << line
        end
        cleaned = lines.join("\n").strip

        # Restore block placeholders
        blocks.each_with_index do |block, i|
          cleaned = cleaned.gsub("__BLOCK_#{i}__", block)
        end

        statements << cleaned unless cleaned.empty?
      end

      statements
    end

    def execute_sql_file(file)
      sql = File.read(file)
      statements = split_sql_statements(sql)
      statements.each do |stmt|
        # Firebird lacks IF NOT EXISTS for ALTER TABLE ADD.
        # Pre-check the system catalogue so duplicate columns are
        # silently skipped instead of raising an error.
        skip_reason = should_skip_for_firebird(stmt)
        if skip_reason
          Tina4::Log.info("Migration #{File.basename(file)}: #{skip_reason}")
          next
        end
        result = @db.execute(stmt)
        if result == false
          raise RuntimeError, @db.get_error || "SQL execution failed: #{stmt}"
        end
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

    def _record_migration(name, batch, passed: 1)
      # Extract description from filename (strip numeric prefix and extension)
      stem = File.basename(name, File.extname(name))
      desc = stem.sub(/\A\d+_/, "").tr("_", " ")
      if firebird?
        # Firebird: generate ID from sequence
        row = @db.fetch_one(
          "SELECT GEN_ID(GEN_TINA4_MIGRATION_ID, 1) AS NEXT_ID FROM RDB\$DATABASE"
        )
        next_id = row ? (row[:NEXT_ID] || row[:next_id] || 1).to_i : 1
        @db.execute(
          "INSERT INTO #{TRACKING_TABLE} (id, migration_name, description, batch, passed) VALUES (?, ?, ?, ?, ?)",
          [next_id, name, desc, batch, passed]
        )
      else
        @db.execute(
          "INSERT INTO #{TRACKING_TABLE} (migration_name, description, batch, passed) VALUES (?, ?, ?, ?)",
          [name, desc, batch, passed]
        )
      end
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
