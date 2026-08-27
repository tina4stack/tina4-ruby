# frozen_string_literal: true
#
# `tina4ruby generate` — resolution transparency (Feature B).
#
# Real subprocess only (Open3.capture3 + the real exe/tina4ruby), inside a
# Dir.mktmpdir so every scaffold lands somewhere disposable. NO mocks. Every
# case boots a fresh CLI process, cds into a temp project root, and asserts on
# the real stdout/stderr/exit-status.
#
# The five things this suite proves:
#
#   1. `--json` prints a valid generate_v1 envelope for a reserved-word class
#      name (Order -> orders) with the reserved_word_pluralize transformation.
#   2. `--dry-run` writes NO files, `actions_taken: []`, `dry_run: true`.
#   3. Bare `generate model Order` emits the human resolution block to STDERR
#      BEFORE the file writes hit STDOUT.
#   4. `commands --json` carries the `resolution_contract` key with the
#      generate_v1 envelope declaration.
#   5. A bare-name `generate model User` (User is a SQL reserved word too)
#      still pluralizes: User -> users, proving `to_table_name` routes every
#      generator through `SQL_RESERVED_TABLE_NAMES`.

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "tina4ruby generate — resolution transparency" do
  # Spawn the real exe in a fresh temp project root, so every scaffold lands
  # somewhere disposable. Returns [stdout, stderr, status].
  def run_generate(*args)
    Open3.capture3(RUBY_BIN, EXE, "generate", *args, chdir: @project_root)
  end

  around(:each) do |ex|
    Dir.mktmpdir("tina4_generate_resolution") do |dir|
      @project_root = dir
      ex.run
    end
  end

  describe "--json emits the generate_v1 envelope for a reserved word (Order)" do
    it "returns a valid JSON envelope with the reserved_word_pluralize transformation" do
      stdout, stderr, status = run_generate("model", "Order", "--json")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      expect(envelope["command"]).to eq("generate")
      expect(envelope["target"]).to eq("model")
      expect(envelope["input"]).to eq({ "name" => "Order", "fields" => nil })
      expect(envelope["dry_run"]).to be false

      resolution = envelope["resolution"]
      expect(resolution["class_name"]).to eq("Order")
      expect(resolution["table_name"]).to eq("orders")
      expect(resolution["file_path"]).to eq("src/orm/order.rb")
      expect(resolution["migration_path"]).to match(%r{\Amigrations/\d{14}_create_orders\.sql\z})
      expect(resolution["routes"]).to eq(["/orders", "/orders/{id}"])
      expect(resolution["test_paths"]).to include("spec/order_spec.rb")

      # The reserved_word_pluralize transformation MUST carry the four keys
      # a machine caller needs: kind, from, to, reason (+ an override hint).
      pluralize = resolution["transformations"].find { |t| t["kind"] == "reserved_word_pluralize" }
      expect(pluralize).not_to be_nil
      expect(pluralize["from"]).to eq("order")
      expect(pluralize["to"]).to eq("orders")
      expect(pluralize["reason"]).to include("SQL reserved word 'order'")
      expect(pluralize["override"]).to include("--table order --quote")

      # actions_taken lists files actually written (this is NOT a --dry-run).
      expect(envelope["actions_taken"]).to include(a_string_matching(/wrote src\/orm\/order\.rb/))
      expect(File.exist?(File.join(@project_root, "src", "orm", "order.rb"))).to be true

      # Nothing except the JSON envelope on stdout — a machine caller can pipe
      # it to `jq` without stripping banner text.
      expect { JSON.parse(stdout) }.not_to raise_error
    end
  end

  describe "--dry-run writes nothing and reports dry_run: true" do
    it "leaves the working tree untouched and returns actions_taken: []" do
      stdout, stderr, status = run_generate("model", "Order", "--json", "--dry-run")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      expect(envelope["dry_run"]).to be true
      expect(envelope["actions_taken"]).to eq([])

      # Prove the working tree really was untouched: no src/, no migrations/.
      expect(Dir.exist?(File.join(@project_root, "src"))).to be false
      expect(Dir.exist?(File.join(@project_root, "migrations"))).to be false
      expect(Dir.exist?(File.join(@project_root, "spec"))).to be false

      # The resolution still names WHERE the files WOULD land, so a caller
      # can plan a scaffold without touching the tree.
      resolution = envelope["resolution"]
      expect(resolution["file_path"]).to eq("src/orm/order.rb")
      expect(resolution["table_name"]).to eq("orders")
    end
  end

  describe "bare `generate model` prints the human resolution block to STDERR" do
    it "shows the pluralize note on STDERR and creates the file on STDOUT" do
      stdout, stderr, status = run_generate("model", "Order")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      # Human resolution block goes to STDERR — a machine parser reading
      # STDOUT-only sees only the generator's "Created" log lines.
      expect(stderr).to include("Generated model Order")
      expect(stderr).to include("class      Order  (in src/orm/order.rb)")
      expect(stderr).to include("table      orders")
      expect(stderr).to include("auto-pluralized: 'order' is a SQL reserved word")
      expect(stderr).to include("routes     /orders, /orders/{id}")
      expect(stderr).to include("To keep the raw name 'order' as the table:")
      expect(stderr).to include("tina4ruby generate model Order --table order --quote")

      # STDOUT keeps the generator's existing "Created" log, unchanged.
      expect(stdout).to include("Created src/orm/order.rb")

      # And the files really landed on disk.
      expect(File.exist?(File.join(@project_root, "src", "orm", "order.rb"))).to be true
      migrations = Dir.glob(File.join(@project_root, "migrations", "*create_orders*.sql"))
      expect(migrations).not_to be_empty
    end

    it "does NOT print the reserved-word note for a non-reserved class" do
      stdout, stderr, status = run_generate("model", "Widget")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      expect(stderr).to include("Generated model Widget")
      expect(stderr).to include("table      widget")
      # No pluralize suggestion — `widget` is a normal name.
      expect(stderr).not_to include("auto-pluralized")
      expect(stderr).not_to include("To keep the raw name")
    end
  end

  describe "commands --json manifest carries the resolution_contract" do
    # ADR-0063 bumped the contract from v1 -> v1.1 (additive: edit_hints[] and
    # next[] joined the resolution shape; every v1 key is preserved). See
    # spec/generate_envelope_v1_1_spec.rb for the v1.1 contract's own coverage.
    it "declares { version: '1.1', envelope: 'generate_v1_1' } (ADR-0063)" do
      stdout, _stderr, status = Open3.capture3(RUBY_BIN, EXE, "commands", "--json")
      expect(status.exitstatus).to eq(0)

      manifest = JSON.parse(stdout)
      expect(manifest).to have_key("resolution_contract")
      expect(manifest["resolution_contract"]).to eq(
        "version"  => "1.1",
        "envelope" => "generate_v1_1"
      )
    end
  end

  describe "reserved-word pluralize is wired into every generator, not just --json" do
    # `User` is in SQL_RESERVED_TABLE_NAMES too. If the reserved-word logic
    # lives ONLY inside build_model_resolution (not in to_table_name), the
    # migration file will be `create_user.sql` even though the JSON envelope
    # says `users`. This case proves the migration path and the ORM
    # table_name agree, on a second reserved word.
    it "pluralizes `User` -> `users` in the actual generated files" do
      _stdout, _stderr, status = run_generate("model", "User", "--json")
      expect(status.exitstatus).to eq(0)

      model_path = File.join(@project_root, "src", "orm", "user.rb")
      expect(File.exist?(model_path)).to be true
      expect(File.read(model_path)).to include('table_name "users"')

      migrations = Dir.glob(File.join(@project_root, "migrations", "*create_users*.sql"))
      expect(migrations).not_to be_empty
    end
  end
end
