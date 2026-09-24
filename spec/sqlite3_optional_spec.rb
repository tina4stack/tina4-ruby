# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# sqlite3 is an APPLICATION dependency, not a framework one (ADR-0067): the
# scaffold's Gemfile declares it, tina4ruby does not. A project without it must
# get an actionable message naming the fix, never a bare
# "cannot load such file -- sqlite3".
#
# The reproduction is a real Ruby process that genuinely cannot load sqlite3:
# plain `ruby` (no Bundler), RubyGems pointed at an empty gem home, and a load
# path holding every gem this suite activated EXCEPT sqlite3. Nothing is
# stubbed; `require "sqlite3"` really fails inside tina4.
RSpec.describe "SQLite without the sqlite3 gem" do
  def run_without_sqlite3(script)
    lib = File.expand_path("../lib", __dir__)
    load_paths = Gem.loaded_specs.values
                    .reject { |spec| spec.name == "sqlite3" }
                    .flat_map(&:full_require_paths)
    Dir.mktmpdir("tina4-no-sqlite3") do |gem_home|
      env = {
        "GEM_HOME" => gem_home, "GEM_PATH" => gem_home,
        "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
        "TINA4_DATABASE_URL" => nil
      }
      args = [RbConfig.ruby, "-I", lib] + load_paths.flat_map { |path| ["-I", path] }
      Open3.capture2e(env, *args, "-e", script, chdir: gem_home)
    end
  end

  it "the reproduction really cannot load sqlite3 (guards the guard)" do
    out, _status = run_without_sqlite3('begin; require "sqlite3"; print "LOADED"; rescue LoadError; print "MISSING"; end')
    expect(out).to eq("MISSING")
  end

  it "Tina4::Database.new with a sqlite URL raises the actionable LoadError" do
    out, _status = run_without_sqlite3(<<~RUBY)
      require "tina4"
      begin
        Tina4::Database.new("sqlite::memory:")
        print "CONNECTED"
      rescue LoadError => e
        print e.message
      end
    RUBY
    expect(out).to include(%(The 'sqlite3' gem is required for SQLite connections.))
    expect(out).to include(%(gem "sqlite3"))
    expect(out).to include("bundle add sqlite3")
    expect(out).not_to include("CONNECTED")
  end

  it "the legacy Sqlite3Adapter and the DocStore raise the same message" do
    out, _status = run_without_sqlite3(<<~RUBY)
      require "tina4"
      messages = []
      begin
        Tina4::Adapters::Sqlite3Adapter.new("sqlite::memory:")
      rescue LoadError => e
        messages << e.message
      end
      begin
        Tina4::DocStore::SqliteDatabase.new(":memory:")
      rescue LoadError => e
        messages << e.message
      end
      print messages.map { |m| m.include?("bundle add sqlite3") }.inspect
    RUBY
    expect(out).to eq("[true, true]")
  end

  it "boots without sqlite3 when no SQLite database is configured" do
    out, status = run_without_sqlite3(<<~RUBY)
      require "tina4"
      print Tina4::Context.fts5_available? ? "FTS5" : "NO-FTS5"
    RUBY
    expect(status.success?).to be(true), out
    expect(out).to end_with("NO-FTS5")
  end
end
