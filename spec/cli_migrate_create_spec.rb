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
#
# 3.13.121: `migrate:create` now delegates to the same resolution-aware
# generator that backs `tina4ruby generate migration` (see
# `spec/migrate_create_envelope_parity_spec.rb` for the parity contract).
# The generator prints `  Created <path>` (two-space prefix, no colon), and
# the file body carries `-- tina4:edit` markers as well as the header lines.
# The essential invariants — filename shape, `-- Migration:` header preserving
# the raw human description, DB-free — are unchanged.

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

  # Run the CLI in-process, capturing stdout, stderr, and any SystemExit
  # status. The delegated path emits its human resolution block to STDERR and
  # the "Created <path>" lines to STDOUT — capturing both keeps every existing
  # assertion + the new envelope-aware behaviour testable in-process.
  def run_cli(args)
    out = +""
    err = +""
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    begin
      cli.run(args)
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      err = $stderr.string
      $stdout = orig_out
      $stderr = orig_err
    end
    [out, err, status]
  end

  it "writes a real UP .sql and matching .down.sql, no database" do
    out, _err, status = run_cli(["migrate:create", "add", "users", "table"])
    expect(status).to eq(0)
    # Delegated to `generate migration`: the generator prints "  Created <path>"
    # to STDOUT (no colon suffix). The essential contract is that the two files
    # were logged as created.
    expect(out).to match(/Created\s+migrations\/\d{14}_add_users_table\.sql/)
    expect(out).to match(/Created\s+migrations\/\d{14}_add_users_table\.down\.sql/)

    up = Dir.glob(File.join(@tmp_dir, "migrations", "*_add_users_table.sql"))
             .reject { |f| f.end_with?(".down.sql") }
    down = Dir.glob(File.join(@tmp_dir, "migrations", "*_add_users_table.down.sql"))

    expect(up.length).to eq(1), "expected one UP migration, got #{up.inspect}"
    expect(down.length).to eq(1), "expected one DOWN migration, got #{down.inspect}"

    # Timestamp prefix: 14 digits (YYYYMMDDHHMMSS), shared across frameworks.
    expect(File.basename(up.first)).to match(/\A\d{14}_add_users_table\.sql\z/)
    expect(File.basename(down.first)).to match(/\A\d{14}_add_users_table\.down\.sql\z/)

    # Headers keep the raw human description (delegation passes `description:`
    # through to `generate_migration`, so the readable prose still lands in
    # the file even though the FILENAME uses the slugified name).
    expect(File.read(up.first)).to include("-- Migration: add users table")
    expect(File.read(down.first)).to include("-- Rollback: add users table")

    # ADR-0063: the generator emits `-- tina4:edit` markers so the delegated
    # path carries the same self-documenting scaffolding as `generate
    # migration`. Regression guard against a silent revert to the bare
    # header-only file this command used to write pre-3.13.121.
    expect(File.read(up.first)).to include("-- tina4:edit")
    expect(File.read(down.first)).to include("-- tina4:edit")

    # DB-free: nothing opened a database (no *.db file created anywhere).
    dbs = Dir.glob(File.join(@tmp_dir, "**", "*.db"), File::FNM_DOTMATCH)
    expect(dbs).to eq([]), "migrate:create opened a database: #{dbs.inspect}"
  end

  it "slugifies the description (lowercase, non-alnum -> _)" do
    out, _err, _status = run_cli(["migrate:create", "Add Orders & Items!"])
    expect(out).to match(/Created\s+migrations\//)
    created = Dir.glob(File.join(@tmp_dir, "migrations", "*.sql"))
                 .reject { |f| f.end_with?(".down.sql") }
    expect(created.length).to eq(1)
    expect(File.basename(created.first)).to match(/\A\d{14}_add_orders_items\.sql\z/)
  end

  it "requires a description — prints usage and exits 1 when none given" do
    out, _err, status = run_cli(["migrate:create"])
    expect(status).to eq(1)
    expect(out).to include("Usage: tina4ruby migrate:create <description>")
    expect(Dir.glob(File.join(@tmp_dir, "migrations", "*"))).to eq([])
  end
end
