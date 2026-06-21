# frozen_string_literal: true

require "spec_helper"

# Mirrors tina4-python tests/test_auto_migrate_startup.py — the startup
# auto-migration hook (Tina4.auto_migrate_on_startup!): applies-on-startup,
# disabled-by-env, no-folder no-op, and failure-is-non-breaking.
RSpec.describe "Startup auto-migration" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_auto_mig") }
  let(:db_path) { File.join(tmp_dir, "app.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }
  let(:mig_dir) { File.join(tmp_dir, "migrations") }

  before(:each) do
    @saved_db = Tina4.database
    @saved_env = ENV["TINA4_AUTO_MIGRATE"]
    Tina4.bind_database(db)
  end

  after(:each) do
    Tina4.bind_database(@saved_db) unless @saved_db.nil?
    Tina4.instance_variable_set(:@database, @saved_db) if @saved_db.nil?
    if @saved_env.nil?
      ENV.delete("TINA4_AUTO_MIGRATE")
    else
      ENV["TINA4_AUTO_MIGRATE"] = @saved_env
    end
    db.close rescue nil
    FileUtils.rm_rf(tmp_dir)
  end

  def write_migration(name, sql)
    FileUtils.mkdir_p(mig_dir)
    File.write(File.join(mig_dir, name), sql)
  end

  it "applies pending migrations on startup (default on)" do
    ENV.delete("TINA4_AUTO_MIGRATE") # default => enabled
    write_migration("000001_create_widgets.sql",
                    "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")

    Tina4.auto_migrate_on_startup!(tmp_dir)

    expect(db.table_exists?("widgets")).to be true
  end

  it "is disabled by TINA4_AUTO_MIGRATE=false" do
    ENV["TINA4_AUTO_MIGRATE"] = "false"
    write_migration("000001_create_widgets.sql",
                    "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")

    Tina4.auto_migrate_on_startup!(tmp_dir)

    expect(db.table_exists?("widgets")).to be false
  end

  it "is a no-op when no migrations/ folder exists (or it has no .sql)" do
    # No migrations dir at all — must not raise, must not create the tracking table.
    expect { Tina4.auto_migrate_on_startup!(tmp_dir) }.not_to raise_error
    expect(db.table_exists?("tina4_migration")).to be false

    # An empty migrations dir (no .sql) is also a no-op.
    FileUtils.mkdir_p(mig_dir)
    expect { Tina4.auto_migrate_on_startup!(tmp_dir) }.not_to raise_error
    expect(db.table_exists?("tina4_migration")).to be false
  end

  it "is NON-BREAKING when a migration fails (does not propagate, boot continues)" do
    ENV.delete("TINA4_AUTO_MIGRATE")
    write_migration("000001_bad.sql", "THIS IS NOT VALID SQL;")

    # The bad migration must NOT raise out of the startup hook.
    expect { Tina4.auto_migrate_on_startup!(tmp_dir) }.not_to raise_error
    # The bad table was never created.
    expect(db.table_exists?("widgets")).to be false
  end
end
