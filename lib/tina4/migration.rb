# frozen_string_literal: true
require "fileutils"

module Tina4
  class Migration
    TRACKING_TABLE = "tina4_migrations"

    attr_reader :db, :migrations_dir

    def initialize(db, migrations_dir: nil)
      @db = db
      @migrations_dir = migrations_dir || File.join(Dir.pwd, "src", "migrations")
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
    def create(name)
      FileUtils.mkdir_p(@migrations_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      filename = "#{timestamp}_#{name.gsub(/\s+/, '_')}.rb"
      filepath = File.join(@migrations_dir, filename)

      File.write(filepath, <<~RUBY)
        # frozen_string_literal: true
        # Migration: #{name}
        # Created: #{Time.now}

        class #{classify(name)} < Tina4::MigrationBase
          def up(db)
            # db.exec("CREATE TABLE ...")
          end

          def down(db)
            # db.exec("DROP TABLE IF EXISTS ...")
          end
        end
      RUBY

      Tina4::Log.info("Created migration: #{filename}")
      filepath
    end

    private

    def ensure_tracking_table
      unless @db.table_exists?(TRACKING_TABLE)
        @db.execute(<<~SQL)
          CREATE TABLE #{TRACKING_TABLE} (
            id INTEGER PRIMARY KEY,
            migration_name VARCHAR(255) NOT NULL,
            batch INTEGER NOT NULL DEFAULT 1,
            executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )
        SQL
        Tina4::Log.info("Created migrations tracking table")
      end
    end

    def completed_migrations
      result = @db.fetch("SELECT migration_name FROM #{TRACKING_TABLE} ORDER BY id")
      result.map { |r| r[:migration_name] }
    end

    def completed_migrations_with_batch
      result = @db.fetch("SELECT id, migration_name, batch FROM #{TRACKING_TABLE} ORDER BY id")
      result.map { |r| { id: r[:id], migration_name: r[:migration_name], batch: r[:batch] } }
    end

    def next_batch_number
      result = @db.fetch_one("SELECT MAX(batch) as max_batch FROM #{TRACKING_TABLE}")
      (result && result[:max_batch] ? result[:max_batch].to_i : 0) + 1
    end

    def pending_migrations
      return [] unless Dir.exist?(@migrations_dir)

      completed = completed_migrations
      # Support both .rb and .sql migration files
      Dir.glob(File.join(@migrations_dir, "*.{rb,sql}"))
         .reject { |f| f.end_with?(".down.sql") }
         .sort
         .reject { |f| completed.include?(File.basename(f)) }
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
        record_migration(name, batch)
        { name: name, status: "success" }
      rescue => e
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
        remove_migration_record(name)
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

    def execute_sql_file(file)
      sql = File.read(file)
      statements = sql.split(";").map(&:strip).reject(&:empty?)
      statements.each do |stmt|
        next if stmt.start_with?("--")
        @db.execute(stmt)
      end
    end

    def record_migration(name, batch)
      @db.insert(TRACKING_TABLE, { migration_name: name, batch: batch })
    end

    def remove_migration_record(name)
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
    def up(db)
      raise NotImplementedError, "Implement #up in your migration"
    end

    def down(db)
      raise NotImplementedError, "Implement #down in your migration"
    end
  end
end
