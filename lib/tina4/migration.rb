# frozen_string_literal: true
require "fileutils"

module Tina4
  class Migration
    TRACKING_TABLE = "tina4_migrations"

    def initialize(db, migrations_dir: nil)
      @db = db
      @migrations_dir = migrations_dir || File.join(Dir.pwd, "migrations")
      ensure_tracking_table
    end

    def run
      pending = pending_migrations
      if pending.empty?
        Tina4::Debug.info("No pending migrations")
        return []
      end

      results = []
      pending.each do |file|
        result = run_migration(file)
        results << result
      end
      results
    end

    def rollback(steps = 1)
      completed = completed_migrations.last(steps)
      completed.reverse.each do |name|
        down_file = File.join(@migrations_dir, name.sub(".sql", ".down.sql"))
        if File.exist?(down_file)
          execute_sql_file(down_file)
          remove_migration_record(name)
          Tina4::Debug.info("Rolled back: #{name}")
        else
          Tina4::Debug.warning("No rollback file for: #{name}")
        end
      end
    end

    def status
      {
        completed: completed_migrations,
        pending: pending_migrations.map { |f| File.basename(f) }
      }
    end

    def create(name)
      FileUtils.mkdir_p(@migrations_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      filename = "#{timestamp}_#{name.gsub(/\s+/, '_')}.sql"
      filepath = File.join(@migrations_dir, filename)
      File.write(filepath, "-- Migration: #{name}\n-- Created: #{Time.now}\n\n")

      down_filepath = filepath.sub(".sql", ".down.sql")
      File.write(down_filepath, "-- Rollback: #{name}\n-- Created: #{Time.now}\n\n")

      Tina4::Debug.info("Created migration: #{filename}")
      filepath
    end

    private

    def ensure_tracking_table
      unless @db.table_exists?(TRACKING_TABLE)
        @db.execute(<<~SQL)
          CREATE TABLE #{TRACKING_TABLE} (
            id INTEGER PRIMARY KEY,
            migration_name VARCHAR(255) NOT NULL,
            executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )
        SQL
        Tina4::Debug.info("Created migrations tracking table")
      end
    end

    def completed_migrations
      result = @db.fetch("SELECT migration_name FROM #{TRACKING_TABLE} ORDER BY id")
      result.map { |r| r[:migration_name] }
    end

    def pending_migrations
      return [] unless Dir.exist?(@migrations_dir)

      completed = completed_migrations
      Dir.glob(File.join(@migrations_dir, "*.sql"))
         .reject { |f| f.end_with?(".down.sql") }
         .sort
         .reject { |f| completed.include?(File.basename(f)) }
    end

    def run_migration(file)
      name = File.basename(file)
      Tina4::Debug.info("Running migration: #{name}")
      begin
        execute_sql_file(file)
        record_migration(name)
        { name: name, status: "success" }
      rescue => e
        Tina4::Debug.error("Migration failed: #{name} - #{e.message}")
        { name: name, status: "failed", error: e.message }
      end
    end

    def execute_sql_file(file)
      sql = File.read(file)
      statements = sql.split(";").map(&:strip).reject(&:empty?)
      statements.each do |stmt|
        next if stmt.start_with?("--")
        @db.execute(stmt)
      end
    end

    def record_migration(name)
      @db.insert(TRACKING_TABLE, { migration_name: name })
    end

    def remove_migration_record(name)
      @db.delete(TRACKING_TABLE, { migration_name: name })
    end
  end
end
