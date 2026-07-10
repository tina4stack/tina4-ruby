# frozen_string_literal: true
#
# Real tests for the top-level `migrate:create` CLI command (Phase 3, self-
# describing CLI epic — Ruby mirror of the Python master's migrate:create).
#
# NO mocks. Drives the ACTUAL CLI dispatch (Tina4::CLI#run) in a clean temp
# project dir and asserts it writes REAL migration files on disk with the shape
# + naming shared across the four frameworks: a {timestamp}_{slug}.sql and a
# matching {timestamp}_{slug}.down.sql, with the `-- Migration:` / `-- Rollback:`
# headers. It must NOT need a database (cheap, DB-free, like the Python master).

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "tina4ruby migrate:create" do
  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4_migrate_create") do |dir|
      @tmp_dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  # Run the CLI in-process, capturing stdout and any SystemExit status.
  def run_cli(args)
    out = +""
    status = 0
    orig = $stdout
    $stdout = StringIO.new
    begin
      cli.run(args)
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      $stdout = orig
    end
    [out, status]
  end

  it "writes a real UP .sql and matching .down.sql, no database" do
    out, status = run_cli(["migrate:create", "add", "users", "table"])
    expect(status).to eq(0)
    expect(out).to include("Created:")

    up = Dir.glob(File.join(@tmp_dir, "migrations", "*_add_users_table.sql"))
             .reject { |f| f.end_with?(".down.sql") }
    down = Dir.glob(File.join(@tmp_dir, "migrations", "*_add_users_table.down.sql"))

    expect(up.length).to eq(1), "expected one UP migration, got #{up.inspect}"
    expect(down.length).to eq(1), "expected one DOWN migration, got #{down.inspect}"

    # Timestamp prefix: 14 digits (YYYYMMDDHHMMSS), shared across frameworks.
    expect(File.basename(up.first)).to match(/\A\d{14}_add_users_table\.sql\z/)
    expect(File.basename(down.first)).to match(/\A\d{14}_add_users_table\.down\.sql\z/)

    expect(File.read(up.first)).to include("-- Migration: add users table")
    expect(File.read(down.first)).to include("-- Rollback: add users table")

    # DB-free: nothing opened a database (no *.db file created anywhere).
    dbs = Dir.glob(File.join(@tmp_dir, "**", "*.db"), File::FNM_DOTMATCH)
    expect(dbs).to eq([]), "migrate:create opened a database: #{dbs.inspect}"
  end

  it "slugifies the description (lowercase, non-alnum -> _)" do
    out, _ = run_cli(["migrate:create", "Add Orders & Items!"])
    expect(out).to include("Created:")
    created = Dir.glob(File.join(@tmp_dir, "migrations", "*.sql"))
                 .reject { |f| f.end_with?(".down.sql") }
    expect(created.length).to eq(1)
    expect(File.basename(created.first)).to match(/\A\d{14}_add_orders_items\.sql\z/)
  end

  it "requires a description — prints usage and exits 1 when none given" do
    out, status = run_cli(["migrate:create"])
    expect(status).to eq(1)
    expect(out).to include("Usage: tina4ruby migrate:create <description>")
    expect(Dir.glob(File.join(@tmp_dir, "migrations", "*"))).to eq([])
  end
end
