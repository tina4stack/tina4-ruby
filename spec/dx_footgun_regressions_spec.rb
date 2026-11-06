# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Regressions for the LLM DX footguns fixed at parity with the Python master:
#   #270 — a generated route spec must stay GREEN when the handler is filled in.
#   #297 — `migrate:create create_*_view` scaffolds a VIEW, not a runnable table.
#   #288 — an empty, unedited scaffold migration is kept pending, not applied.
#
# No mocks: real `tina4ruby generate ...` subprocess, real rspec run of the
# emitted spec, real SQLite through Tina4::Migration.
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "DX footgun regressions" do
  TINA4_EXE_DX = File.join(REPO_ROOT, "exe", "tina4ruby")

  around(:each) do |example|
    Dir.mktmpdir("tina4_dxfootgun") do |dir|
      @project = dir
      example.run
    end
  end

  def run_cli(*args)
    out = IO.popen([RbConfig.ruby, TINA4_EXE_DX, *args], chdir: @project, err: [:child, :out], &:read)
    expect($?.exitstatus).to eq(0), "`tina4ruby #{args.join(' ')}` failed:\n#{out}"
    out
  end

  def write_spec_helper
    FileUtils.mkdir_p(File.join(@project, "spec"))
    File.write(File.join(@project, "spec", "spec_helper.rb"), <<~RUBY)
      $LOAD_PATH.unshift #{REPO_LIB.inspect}
      require "tina4"
      RSpec.configure do |c|
        c.after(:each) { Tina4::Router.clear! if defined?(Tina4::Router) }
      end
    RUBY
  end

  def run_rspec(spec_rel)
    cmd = ["bundle", "exec", "rspec", "-Ispec", spec_rel]
    env = { "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile") }
    out = nil
    status = nil
    block = lambda do
      out = IO.popen(env, cmd, chdir: @project, err: [:child, :out], &:read)
      status = $?.exitstatus
    end
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : block.call
    [status, out]
  end

  # ── #270: the generated route spec stays green when the handler is filled ──

  it "keeps the generated route spec green after the handler is filled in (#270)" do
    write_spec_helper
    run_cli("generate", "route", "complaints")

    status, out = run_rspec("spec/complaints_spec.rb")
    expect(status).to eq(0), "route spec should be green as a stub:\n#{out}"

    # Fill the list handler with a real response, remove the raise.
    route = File.join(@project, "src", "routes", "complaints.rb")
    src = File.read(route, encoding: "UTF-8")
    src = src.sub(/raise NotImplementedError.*$/, 'response.json({ "records" => [] })')
    File.write(route, src)

    status, out = run_rspec("spec/complaints_spec.rb")
    expect(status).to eq(0), "filling the handler in turned the suite red (#270):\n#{out}"
  end

  it "the generated route spec has no self-defeating raise assertion (#270)" do
    run_cli("generate", "route", "complaints")
    spec = File.read(File.join(@project, "spec", "complaints_spec.rb"))
    expect(spec).not_to include("raise_error(NotImplementedError)")
    expect(spec).not_to include("is a live stub")
    expect(spec).to include("is wired")
  end

  # ── #297: a *_view migration scaffolds a VIEW, not a runnable table ──

  it "scaffolds a VIEW, not a runnable table, for a *_view name (#297)" do
    run_cli("generate", "migration", "create_open_tickets_view")
    up = Dir.glob(File.join(@project, "migrations", "*create_open_tickets_view.sql"))
            .reject { |f| f.end_with?(".down.sql") }.first
    sql = File.read(up)
    expect(sql).not_to include("CREATE TABLE")
    expect(sql).to include("CREATE VIEW")      # commented guidance
    sql.each_line do |line|
      expect(line.strip).to start_with("--") if line.include?("CREATE VIEW")
    end
    expect(Dir.glob(File.join(@project, "spec", "*open_tickets_view*"))).to be_empty
  end

  # ── #288: an empty scaffold migration is kept pending; real DDL applies ──

  it "keeps a comment-only migration pending, then applies it once written (#288)" do
    db = Tina4::Database.new("sqlite:///#{@project}/app.db")
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY)")
    mdir = File.join(@project, "m")
    FileUtils.mkdir_p(mdir)
    file = File.join(mdir, "000001_add_note.sql")
    File.write(file, "-- Migration: add_note\n-- tina4:edit  write the UP migration SQL\n")

    Tina4::Migration.new(db, migrations_dir: mdir).migrate
    expect(Tina4::Migration.new(db, migrations_dir: mdir).get_pending).to eq(["000001_add_note.sql"])

    File.write(file, "ALTER TABLE widget ADD COLUMN note TEXT;\n")
    Tina4::Migration.new(db, migrations_dir: mdir).migrate
    cols = db.get_columns("widget").map { |c| c["name"] || c[:name] }
    expect(cols).to include("note")
  end

  it "still applies a scaffolded CREATE TABLE migration (#288 does not over-skip)" do
    db = Tina4::Database.new("sqlite:///#{@project}/app2.db")
    mdir = File.join(@project, "m2")
    FileUtils.mkdir_p(mdir)
    File.write(File.join(mdir, "000001_create_gizmo.sql"),
               "CREATE TABLE IF NOT EXISTS gizmo (\n" \
               "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n" \
               "  created_at TIMESTAMP\n" \
               "  -- tina4:edit  add columns beyond id + created_at\n);\n")
    Tina4::Migration.new(db, migrations_dir: mdir).migrate
    expect(db.table_exists?("gizmo")).to be(true)
  end
end
