# frozen_string_literal: true
#
# ADR-0063: `tina4ruby migrate:create` and `tina4ruby generate migration`
# must produce the SAME migration file with the SAME `generate_v1_1` envelope.
# `cmd_migrate_create` was rewritten in 3.13.121 to delegate to the shared
# resolution-aware generator that backs `generate migration`, threading
# `emit_test: false` (so `migrate:create` still emits "just a migration, no
# test") and `description:` (so the raw human prose survives in the file
# HEADER even though the FILENAME uses the slugified NAME).
#
# Every case runs the REAL `exe/tina4ruby` in a fresh temp cwd via
# `Open3.capture3`. NO mocks: real generator, real edit-hints sandbox, real
# subprocess, real filesystem. Ruby mirror of the parity contract the other
# three Tina4 frameworks will each port when their turn comes.

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "migrate:create / generate migration — envelope parity (ADR-0063)" do
  around(:each) do |ex|
    Dir.mktmpdir("tina4_migrate_parity") do |dir|
      @project_root = dir
      ex.run
    end
  end

  # Spawn the REAL CLI in @project_root and return [stdout, stderr, status].
  def run_cli(*args)
    Open3.capture3(RUBY_BIN, EXE, *args, chdir: @project_root)
  end

  # Replace the 14-digit timestamp segment of any embedded migration path
  # with a fixed sentinel so two envelopes generated a second apart still
  # compare cleanly. Only touches timestamps that PREFIX a `migrations/`
  # basename — nothing else in the payload would legitimately be 14 digits.
  def normalize_ts(value)
    case value
    when String
      value.gsub(%r{migrations/\d{14}_}, "migrations/TS_")
    when Array
      value.map { |v| normalize_ts(v) }
    when Hash
      value.each_with_object({}) { |(k, v), out| out[k] = normalize_ts(v) }
    else
      value
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 1. Positive parity — --json --dry-run envelopes match byte-for-byte after
  # ts normalisation. Same edit_hints[], same next[], same target, same shape.
  # ─────────────────────────────────────────────────────────────────────────
  describe "1. --json --dry-run envelopes match" do
    # Use a snake_case description so `migrate:create`'s slugifier is a
    # no-op — the two paths then produce byte-for-byte identical envelopes
    # (modulo timestamp), which is the strictest possible parity check.
    it "both paths return a valid generate_v1_1 envelope with the same shape + content" do
      mc_out, mc_err, mc_status = run_cli("migrate:create", "add_users", "--json", "--dry-run")
      gm_out, gm_err, gm_status = run_cli("generate", "migration", "add_users", "--json", "--dry-run")

      expect(mc_status.exitstatus).to eq(0), "migrate:create stderr: #{mc_err}"
      expect(gm_status.exitstatus).to eq(0), "generate migration stderr: #{gm_err}"

      mc_env = JSON.parse(mc_out)
      gm_env = JSON.parse(gm_out)

      # Shape: every generate_v1_1 top-level key present on BOTH envelopes.
      %w[command target input resolution actions_taken dry_run].each do |key|
        expect(mc_env).to have_key(key), "migrate:create envelope missing #{key.inspect}"
        expect(gm_env).to have_key(key), "generate migration envelope missing #{key.inspect}"
      end

      # verb (task-vocab) = target — both are "migration".
      expect(mc_env["target"]).to eq("migration")
      expect(gm_env["target"]).to eq("migration")

      # command = "generate" — the delegated migrate:create IS a generate call.
      expect(mc_env["command"]).to eq("generate")
      expect(gm_env["command"]).to eq("generate")

      expect(mc_env["dry_run"]).to be true
      expect(gm_env["dry_run"]).to be true

      # actions_taken always [] in dry-run — no files were written.
      expect(mc_env["actions_taken"]).to eq([])
      expect(gm_env["actions_taken"]).to eq([])

      # Resolution shape: every v1 + v1.1 key present on BOTH envelopes.
      %w[class_name table_name file_path migration_path
         transformations routes test_paths next edit_hints].each do |key|
        expect(mc_env["resolution"]).to have_key(key),
                                        "migrate:create resolution missing #{key.inspect}"
        expect(gm_env["resolution"]).to have_key(key),
                                        "generate migration resolution missing #{key.inspect}"
      end

      # edit_hints[] labels — same rows, same order, same labels. The file:line
      # fields ride the same generator so match too, once the timestamp
      # segment is normalised.
      mc_hints = normalize_ts(mc_env["resolution"]["edit_hints"])
      gm_hints = normalize_ts(gm_env["resolution"]["edit_hints"])
      expect(mc_hints).not_to be_empty
      expect(mc_hints).to eq(gm_hints)

      # Every hint carries the ADR-0063 `# tina4:edit` / `-- tina4:edit` label.
      mc_labels = mc_env["resolution"]["edit_hints"].map { |h| h["label"] }
      expect(mc_labels).to eq(["write your DOWN rollback SQL here",
                               "write your UP migration SQL here"])

      # next[] — curated per-verb list; identical for both paths after ts
      # normalisation (both use the same NAME + the same generate_timestamp).
      expect(normalize_ts(mc_env["resolution"]["next"]))
        .to eq(normalize_ts(gm_env["resolution"]["next"]))

      # Full-envelope deep-equal after ts normalisation is the strongest
      # possible parity: any drift in any field lights up here.
      expect(normalize_ts(mc_env)).to eq(normalize_ts(gm_env))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 2. commands --json manifest advertises `generate_v1_1` — one contract,
  # both callers. (The per-envelope JSON carries no `envelope` field of its
  # own; the contract name lives in the CLI's self-describing manifest, which
  # applies uniformly to whichever caller ran the generator.)
  # ─────────────────────────────────────────────────────────────────────────
  describe "2. commands --json declares the shared contract" do
    it "reports resolution_contract { version: '1.1', envelope: 'generate_v1_1' }" do
      stdout, stderr, status = run_cli("commands", "--json")
      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      manifest = JSON.parse(stdout)
      expect(manifest["resolution_contract"]).to eq(
        "version"  => "1.1",
        "envelope" => "generate_v1_1"
      )
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 3. File-shape parity — real (non-dry-run) invocations land the same
  # {timestamp}_{name}.sql + .down.sql pair with UP + DOWN + tina4:edit
  # markers, functionally equivalent after ts + rollback-block normalisation.
  # ─────────────────────────────────────────────────────────────────────────
  describe "3. real invocations write functionally equivalent files" do
    it "both paths produce {ts}_{name}.sql + .down.sql with UP/DOWN + tina4:edit markers" do
      # Two different names so the files can co-exist in the same tmpdir.
      mc_out, mc_err, mc_status = run_cli("migrate:create", "add_customers")
      gm_out, gm_err, gm_status = run_cli("generate", "migration", "add_products")

      expect(mc_status.exitstatus).to eq(0), "migrate:create stderr: #{mc_err}"
      expect(gm_status.exitstatus).to eq(0), "generate migration stderr: #{gm_err}"

      mc_up = Dir.glob(File.join(@project_root, "migrations", "*_add_customers.sql"))
                 .reject { |f| f.end_with?(".down.sql") }
      mc_down = Dir.glob(File.join(@project_root, "migrations", "*_add_customers.down.sql"))
      gm_up = Dir.glob(File.join(@project_root, "migrations", "*_add_products.sql"))
                 .reject { |f| f.end_with?(".down.sql") }
      gm_down = Dir.glob(File.join(@project_root, "migrations", "*_add_products.down.sql"))

      expect(mc_up.length).to eq(1)
      expect(mc_down.length).to eq(1)
      expect(gm_up.length).to eq(1)
      expect(gm_down.length).to eq(1)

      # Timestamps of the 14-digit shape.
      [mc_up.first, mc_down.first, gm_up.first, gm_down.first].each do |path|
        expect(File.basename(path)).to match(/\A\d{14}_add_(customers|products)\.(down\.)?sql\z/)
      end

      # ADR-0063: both paths carry the `-- tina4:edit` marker in BOTH files.
      [mc_up.first, mc_down.first, gm_up.first, gm_down.first].each do |path|
        expect(File.read(path)).to include("-- tina4:edit"),
                                    "no tina4:edit marker in #{path}"
      end

      # Functional equivalence after normalising:
      #   * the 14-digit timestamp header,
      #   * the description-vs-name divergence in `-- Migration:` /
      #     `-- Rollback:` headers (that IS the intended one place the two
      #     paths differ — migrate:create carries the raw human prose,
      #     generate migration carries the snake_case name),
      #   * the migration NAME embedded in the placeholder ALTER example, AND
      #   * the DERIVED table name (`add_customers` → `customers`, `add_products`
      #     → `products`) that also lands in the ALTER example.
      def normalize_body(content, expected_name, expected_table)
        content
          .gsub(/-- Created: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, "-- Created: TIMESTAMP")
          .gsub(/-- (Migration|Rollback): .+/, '-- \1: HEADER')
          # Order matters: substitute the name FIRST (longer / includes the
          # table as a suffix) so a shorter table-name substitute doesn't
          # corrupt the still-present name.
          .gsub(expected_name, "MIGRATION_NAME")
          .gsub(expected_table, "TABLE")
      end

      expect(normalize_body(File.read(mc_up.first),   "add_customers", "customers"))
        .to eq(normalize_body(File.read(gm_up.first), "add_products",  "products"))
      expect(normalize_body(File.read(mc_down.first),   "add_customers", "customers"))
        .to eq(normalize_body(File.read(gm_down.first), "add_products",  "products"))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 4. Test-emission — migrate:create must NOT co-emit a test file, even for
  # a `create_X` name (which is what triggers the co-emit under `generate
  # migration`). generate migration MAY (and does) co-emit one. This is the
  # ONE intentional behavioural difference between the two paths.
  # ─────────────────────────────────────────────────────────────────────────
  describe "4. migrate:create suppresses the co-emitted spec" do
    it "migrate:create on a create_X name never writes spec/*.rb" do
      # `create_widgets` triggers the co-emit branch inside generate_migration
      # (`emit_test && is_create`); the delegation passes emit_test: false, so
      # no spec is written. The migration files themselves land normally.
      _out, _err, status = run_cli("migrate:create", "create_widgets")
      expect(status.exitstatus).to eq(0)

      migrations = Dir.glob(File.join(@project_root, "migrations", "*")).sort
      expect(migrations.length).to eq(2), "expected .sql + .down.sql, got #{migrations.inspect}"

      specs = Dir.glob(File.join(@project_root, "spec", "*"))
      expect(specs).to eq([]), "migrate:create leaked a co-emitted spec: #{specs.inspect}"
    end

    it "generate migration on the same create_X name DOES co-emit a spec" do
      _out, _err, status = run_cli("generate", "migration", "create_widgets", "--fields", "name:string")
      expect(status.exitstatus).to eq(0)
      # The spec name is `spec/{table}_migration_spec.rb` (widgets_migration
      # if the current template plural-fies; widget_migration otherwise).
      # Assert SOMETHING landed in spec/ — the exact filename is not the point
      # of this parity contract; the point is that `generate` co-emits AT ALL
      # while `migrate:create` does NOT.
      specs = Dir.glob(File.join(@project_root, "spec", "*_spec.rb"))
      expect(specs).not_to be_empty, "generate migration failed to co-emit a spec"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 5. Error paths — both callers exit non-zero with a helpful Usage: line
  # when the required description / name is missing.
  # ─────────────────────────────────────────────────────────────────────────
  describe "5. missing args → non-zero + Usage: line on both paths" do
    it "migrate:create with no args exits 1 with Usage:" do
      stdout, _stderr, status = run_cli("migrate:create")
      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("Usage: tina4ruby migrate:create <description>")
      # Nothing written.
      expect(Dir.glob(File.join(@project_root, "migrations", "*"))).to eq([])
    end

    it "generate migration with no name exits 1 with Usage:" do
      stdout, _stderr, status = run_cli("generate", "migration")
      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("Usage: tina4ruby generate migration")
      expect(Dir.glob(File.join(@project_root, "migrations", "*"))).to eq([])
    end
  end
end
