# frozen_string_literal: true
#
# ADR-0063 (3.13.121): the dev-admin endpoint `POST /__dev/api/scaffold/run`
# in `lib/tina4/dev_admin.rb` used to inline `File.write` for four verbs
# (route / model / migration / middleware) — no envelope, no `-- tina4:edit` /
# `# tina4:edit` markers, no `edit_hints[]`, no `next[]`. The rewrite shells
# out to `exe/tina4ruby generate <kind> <name>` — mirroring PHP
# (`Tina4/DevAdmin.php:2506-2520`, `shell_exec 'php bin/tina4php generate ...'`)
# and Node (`packages/core/src/devAdmin.ts:handleScaffoldRun`, `execFileSync
# 'npx tina4nodejs generate ...'`) — so the CLI's envelope-emitting resolution
# block reaches the dev-admin caller as `output`.
#
# Every case invokes the REAL `scaffold_run` handler in a fresh temp cwd, which
# in turn `Open3.capture3`s the REAL `exe/tina4ruby generate ...` CLI. NO mocks,
# NO stubs — real subprocess, real filesystem, real generator.

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "dev-admin scaffold_run — ADR-0063 envelope + validation" do
  around(:each) do |ex|
    Dir.mktmpdir("tina4_scaffold_run") do |dir|
      original_cwd = Dir.pwd
      begin
        Dir.chdir(dir)
        @project_root = dir
        # scaffold_run shells to <Dir.pwd>/exe/tina4ruby, so symlink the real
        # exe into the tmpdir. The exe uses require_relative "../lib/tina4/cli"
        # so we need lib/ too — a symlink to REPO_ROOT is the cheapest way.
        FileUtils.mkdir_p(File.join(dir, "exe"))
        File.symlink(EXE, File.join(dir, "exe", "tina4ruby"))
        File.symlink(File.join(REPO_ROOT, "lib"), File.join(dir, "lib"))
        ex.run
      ensure
        Dir.chdir(original_cwd)
      end
    end
  end

  # Call the REAL scaffold_run handler — same code path POST /__dev/api/scaffold/run
  # takes when the router hands it a decoded JSON body. `scaffold_run` is
  # private-by-declaration on the DevAdmin module (dispatch is the intended
  # public entry point); #send is the deliberate re-use path for a spec that
  # exercises the handler body directly rather than mounting the full router.
  def scaffold_run(kind:, name:)
    Tina4::DevAdmin.send(:scaffold_run, "kind" => kind, "name" => name)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 1. Per-verb positive envelope — the CLI subprocess's stderr resolution
  #    block reaches the endpoint as `output`. The generator's own human
  #    "Edit these lines:" section is the on-the-wire signal that the ADR-0063
  #    envelope actually fired (`generate migration` uses `-- tina4:edit`,
  #    the others use `# tina4:edit`; both surface in the same block).
  # ─────────────────────────────────────────────────────────────────────────
  describe "1. positive envelope per verb (real CLI subprocess)" do
    it "route emits the resolution block in `output` and writes the file" do
      result = scaffold_run(kind: "route", name: "widgets")
      expect(result[:ok]).to be true
      expect(result[:kind]).to eq("route")
      expect(result[:name]).to eq("widgets")
      expect(result[:output]).to include("Edit these lines:")
      expect(File).to exist(File.join(@project_root, "src", "routes", "widgets.rb"))
    end

    it "model emits the resolution block AND writes the co-emitted migration" do
      result = scaffold_run(kind: "model", name: "Product")
      expect(result[:ok]).to be true
      expect(result[:output]).to include("Edit these lines:")
      # The model generator co-emits a migration for the table (singular table
      # name by convention: Product -> product; see cli.rb's to_table_name).
      expect(File).to exist(File.join(@project_root, "src", "orm", "product.rb"))
      migrations = Dir.glob(File.join(@project_root, "migrations", "*_create_product.sql"))
                      .reject { |f| f.end_with?(".down.sql") }
      expect(migrations.length).to eq(1), "model must co-emit a create_product migration"
    end

    it "migration emits the resolution block AND writes UP+DOWN .sql files" do
      result = scaffold_run(kind: "migration", name: "add_users")
      expect(result[:ok]).to be true
      expect(result[:output]).to include("Edit these lines:")
      up = Dir.glob(File.join(@project_root, "migrations", "*_add_users.sql"))
              .reject { |f| f.end_with?(".down.sql") }
      down = Dir.glob(File.join(@project_root, "migrations", "*_add_users.down.sql"))
      expect(up.length).to eq(1)
      expect(down.length).to eq(1)
      expect(File.read(up.first)).to include("-- tina4:edit")
      expect(File.read(down.first)).to include("-- tina4:edit")
    end

    it "middleware emits the resolution block and writes the file" do
      result = scaffold_run(kind: "middleware", name: "AuditLog")
      expect(result[:ok]).to be true
      expect(result[:output]).to include("Edit these lines:")
      # The middleware generator writes to src/middleware/ (see cli.rb),
      # so assert something landed there OR under src/app/ (older tree).
      expect(
        Dir.glob(File.join(@project_root, "src", "**", "*audit_log*.rb")) +
        Dir.glob(File.join(@project_root, "src", "**", "*AuditLog*.rb"))
      ).not_to be_empty
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # 2. Validation — the endpoint refuses garbage input BEFORE spawning any
  #    subprocess. Mirrors PHP's regex + Node's regex.
  # ─────────────────────────────────────────────────────────────────────────
  describe "2. validation" do
    it "rejects a name starting with a digit" do
      result = scaffold_run(kind: "route", name: "1bad")
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/name must match/i)
      # Nothing written.
      expect(Dir.glob(File.join(@project_root, "src", "**", "*"))).to be_empty
    end

    it "rejects an unknown kind" do
      result = scaffold_run(kind: "widget", name: "thing")
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/unknown kind/i)
    end

    it "rejects missing kind + name" do
      result = scaffold_run(kind: "", name: "")
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/required/i)
    end

    it "rejects a name with shell metacharacters" do
      result = scaffold_run(kind: "route", name: "widget;rm -rf /")
      expect(result[:ok]).to be false
      expect(result[:error]).to match(/name must match/i)
      expect(Dir.glob(File.join(@project_root, "src", "**", "*"))).to be_empty
    end
  end
end
