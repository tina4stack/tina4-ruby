# frozen_string_literal: true
#
# ADR-0063 (3.13.121): the MCP tool `migration_create` in `lib/tina4/mcp.rb`
# used to call `Tina4::Migration.new(nil).create(description)` and return
# `{created: filename}` only — no `generate_v1_1` envelope, no `edit_hints[]`,
# no `next[]`, no `-- tina4:edit` markers in the emitted UP+DOWN files. The
# rewrite delegates to the SAME resolution-aware helper the CLI (`generate
# migration` + `migrate:create`) uses since 1f09a31, so a coding agent driving
# MCP gets the same envelope as a human on the CLI.
#
# Every case runs the REAL MCP handler + the REAL CLI in a fresh temp cwd
# via `Open3.capture3` — NO mocks, NO stubs, NO test doubles. The MCP handler
# invocation goes through the same `register_tool` lambda the JSON-RPC dispatch
# does; the CLI parity comparison shells out to `exe/tina4ruby`. Both write
# real files under `migrations/` on real disk.
#
# Ports of the parity contract other frameworks' MCP conformance tests
# already carry (tina4-python `test_mcp_dev_tools_conformance.py`, tina4-php
# `McpDevToolsConformanceTest.php`).

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "MCP migration_create — ADR-0063 envelope + duplicate guard" do
  # Fresh tmpdir per example so migrations from a previous case cannot trigger
  # the duplicate-slug guard here.
  around(:each) do |ex|
    Dir.mktmpdir("tina4_mcp_migration_create") do |dir|
      # The MCP handler resolves migrations/ from Dir.pwd, so run each example
      # from inside the tmpdir the same way the CLI parity case does.
      original_cwd = Dir.pwd
      begin
        Dir.chdir(dir)
        @project_root = dir
        ex.run
      ensure
        Dir.chdir(original_cwd)
      end
    end
  end

  # Invoke the REAL MCP handler lambda that dev_admin registers under
  # migration_create. NO mocks: fresh McpServer + real McpDevTools.register
  # attach the same lambda body the JSON-RPC dispatch would drive.
  def call_migration_create(description)
    server = Tina4::McpServer.new("/__dev/mcp")
    Tina4::McpDevTools.register(server)
    tool = server.tools["migration_create"]
    raise "migration_create not registered on server" if tool.nil?
    tool["handler"].call(description: description)
  end

  # Same normaliser the CLI parity spec uses — pins the embedded 14-digit
  # timestamp to a sentinel so two runs a second apart compare cleanly.
  def normalize_ts(value)
    case value
    when String then value.gsub(%r{migrations/\d{14}_}, "migrations/TS_")
    when Array  then value.map { |v| normalize_ts(v) }
    when Hash   then value.each_with_object({}) { |(k, v), out| out[k] = normalize_ts(v) }
    else value
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 1. Positive envelope — the handler returns {ok:true, created, resolution,
  #    actions_taken}, where resolution carries EVERY ADR-0063 v1.1 key with
  #    real content (not empty arrays), and the migration files really landed
  #    on disk with the `-- tina4:edit` markers.
  # ─────────────────────────────────────────────────────────────────────────
  describe "1. positive — full envelope + files on disk" do
    it "returns a generate_v1_1 resolution with populated edit_hints[] and next[]" do
      result = call_migration_create("add users table")

      expect(result[:ok] || result["ok"]).to be true
      created = result[:created] || result["created"]
      expect(created).to match(%r{\Amigrations/\d{14}_add_users_table\.sql\z})

      resolution = result[:resolution] || result["resolution"]
      expect(resolution).not_to be_nil, "MCP handler must return `resolution` (envelope block)"

      # Every v1 + v1.1 key present.
      %w[class_name table_name file_path migration_path
         transformations routes test_paths next edit_hints].each do |key|
        expect(resolution).to have_key(key), "resolution missing #{key.inspect}"
      end

      # edit_hints[] populated with the two `-- tina4:edit` labels baked into
      # the UP + DOWN SQL — the whole point of the envelope for a coding agent.
      hints = resolution["edit_hints"]
      expect(hints).not_to be_empty, "edit_hints[] must not be empty"
      labels = hints.map { |h| h["label"] }
      expect(labels).to include("write your UP migration SQL here",
                                "write your DOWN rollback SQL here")

      # next[] populated with the curated per-verb steps.
      expect(resolution["next"]).not_to be_empty, "next[] must not be empty"

      # Files really landed on disk with the tina4:edit marker.
      up_paths = Dir.glob(File.join(@project_root, "migrations", "*_add_users_table.sql"))
                    .reject { |f| f.end_with?(".down.sql") }
      down_paths = Dir.glob(File.join(@project_root, "migrations", "*_add_users_table.down.sql"))
      expect(up_paths.length).to eq(1), "expected exactly one UP file"
      expect(down_paths.length).to eq(1), "expected exactly one DOWN file"
      expect(File.read(up_paths.first)).to include("-- tina4:edit")
      expect(File.read(down_paths.first)).to include("-- tina4:edit")
    end

    it "produces a 14-digit timestamp prefix on the created filename" do
      result = call_migration_create("create widgets")
      created = result[:created] || result["created"]
      expect(File.basename(created)).to match(/\A\d{14}_create_widgets\.sql\z/)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 2. CLI parity — the MCP envelope's resolution shape matches what
  #    `tina4ruby migrate:create <desc> --json --dry-run` prints. Both go
  #    through run_resolution_aware_generator, so the shape MUST agree.
  # ─────────────────────────────────────────────────────────────────────────
  describe "2. parity with the CLI's --json envelope" do
    it "resolution shape matches migrate:create --json --dry-run" do
      # MCP side — writes files (dry_run: false) but structure is identical.
      mcp = call_migration_create("add customers")
      mcp_resolution = mcp[:resolution] || mcp["resolution"]

      # CLI side — dry-run so no files, in a SEPARATE tmpdir so this run's
      # own MCP-written files can't collide with the CLI's own tracking.
      cli_out = Dir.mktmpdir("tina4_mcp_cli_parity") do |cli_dir|
        stdout, stderr, status = Open3.capture3(
          RUBY_BIN, EXE, "migrate:create", "add_customers", "--json", "--dry-run",
          chdir: cli_dir
        )
        expect(status.exitstatus).to eq(0), "CLI stderr: #{stderr}"
        JSON.parse(stdout)
      end
      cli_resolution = cli_out["resolution"]

      # Same set of top-level resolution keys.
      expect(mcp_resolution.keys.sort).to eq(cli_resolution.keys.sort)

      # Same edit_hints[] LABELS (file:line ride the timestamp so we normalise).
      mcp_labels = mcp_resolution["edit_hints"].map { |h| h["label"] }
      cli_labels = cli_resolution["edit_hints"].map { |h| h["label"] }
      expect(mcp_labels).to eq(cli_labels)

      # Same next[] steps after timestamp normalisation.
      expect(normalize_ts(mcp_resolution["next"])).to eq(normalize_ts(cli_resolution["next"]))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 3. Duplicate-slug guard — a second call with the same (or clearly
  #    equivalent) description refuses with {ok:false, error, existing} and
  #    does NOT create a second file. Parity with PHP + Python MCPs.
  # ─────────────────────────────────────────────────────────────────────────
  describe "3. duplicate-slug guard" do
    it "refuses a duplicate description with {ok:false, existing:[...]}" do
      first = call_migration_create("create orders table")
      expect(first[:ok] || first["ok"]).to be true

      before_files = Dir.glob(File.join(@project_root, "migrations", "*")).length

      dup = call_migration_create("create orders table")
      expect(dup[:ok] || dup["ok"]).to be false
      error = dup[:error] || dup["error"]
      expect(error).to match(/already exists/i)
      existing = dup[:existing] || dup["existing"]
      expect(existing).to be_a(Array)
      expect(existing).not_to be_empty

      after_files = Dir.glob(File.join(@project_root, "migrations", "*")).length
      expect(after_files).to eq(before_files), "duplicate call must not write files"
    end

    it "treats 'create orders' and 'create orders table' as equivalent slugs" do
      first = call_migration_create("create orders")
      expect(first[:ok] || first["ok"]).to be true

      dup = call_migration_create("create orders table")
      expect(dup[:ok] || dup["ok"]).to be false
      existing = dup[:existing] || dup["existing"]
      expect(existing).not_to be_empty
    end
  end
end
