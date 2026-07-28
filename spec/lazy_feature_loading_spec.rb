# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

TINA4_LAZY_LIB_DIR = File.expand_path("../lib", __dir__)

# Subsystems that must NOT load until an app actually references them.
TINA4_LAZY_SUBSYSTEMS = %w[queue messenger docstore graphql wsdl mqtt swagger crud
                           webserver testing validator scss_compiler].freeze

# Lock-in: a never-referenced subsystem is never loaded.
#
# `require "tina4"` used to pull in a queue backend, an SMTP/IMAP client and a
# JSON1 document store even in an app that talks to none of them. Queue,
# Messenger and DocStore now sit behind `Module#autoload` alongside the DB
# drivers, session handlers, GraphQL, WSDL, Mqtt and Swagger, so the boot pays
# only for the core.
#
# Measured on this change (macOS, Ruby 3.4): the three cost 22.5ms and 29 extra
# files (net/smtp, sqlite3, ...) on every single boot.
#
# Every reference to the three across the framework is inside a method body
# (CLI queue commands, dev-admin handlers, MCP tools), which is why autoload is
# safe here. `defined?(Tina4::Queue)` answers "constant" against an autoload
# entry WITHOUT triggering the load, so the `if defined?(Tina4::Queue)` guards
# in dev_admin keep working and stay lazy -- that is asserted below, because if
# Ruby ever changed it those guards would start silently skipping.
#
# Each example boots a FRESH ruby process: this spec file has already loaded
# half the framework, so checking $LOADED_FEATURES in-process would prove
# nothing. No doubles -- the real gem, the real loader.
#
# Parity: Python tests/test_lazy_feature_loading.py (PEP 562 module
# __getattr__), PHP tests/LazyFeatureLoadingTest.php (PSR-4 is lazy natively),
# Node test/lazyFeatureLoading.test.ts (static ESM re-exports are eager by
# spec, so Node gets granularity from its package split instead).
RSpec.describe "lazy feature loading" do
  # Runs a snippet in a fresh ruby process and returns its stdout.
  def in_fresh_ruby(code)
    script = File.join(Dir.tmpdir, "tina4_lazy_#{Process.pid}_#{rand(1 << 30)}.rb")
    File.write(script,
               "# encoding: utf-8\n" \
               "$LOAD_PATH.unshift #{TINA4_LAZY_LIB_DIR.inspect}\n#{code}\n")
    out = `ruby #{script} 2>&1`
    raise "snippet failed: #{out}" unless $?.success?

    out.strip
  ensure
    File.unlink(script) if script && File.exist?(script)
  end

  # Which lib/tina4/*.rb files a bare `require "tina4"` actually loaded.
  def loaded_after_bare_require
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      puts $LOADED_FEATURES.grep(%r{/lib/tina4/}).map { |f| File.basename(f, ".rb") }.sort.join(",")
    RUBY
    out.split(",")
  end

  it "does not load any optional subsystem on a bare require" do
    loaded = loaded_after_bare_require
    leaked = TINA4_LAZY_SUBSYSTEMS & loaded
    expect(leaked).to eq([]),
                      "these optional subsystems loaded on a bare `require \"tina4\"`: " \
                      "#{leaked.join(', ')}. Either a require_relative crept back into " \
                      "lib/tina4.rb, or something on the eager path references the " \
                      "constant at LOAD time (move that reference into a method body)."
  end

  it "still resolves a lazy constant on first reference" do
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      before = $LOADED_FEATURES.any? { |f| f.end_with?("/lib/tina4/queue.rb") }
      klass  = Tina4::Queue
      after  = $LOADED_FEATURES.any? { |f| f.end_with?("/lib/tina4/queue.rb") }
      puts [before, after, klass.name].join("|")
    RUBY
    before, after, name = out.split("|")
    expect(before).to eq("false"), "queue.rb was already loaded -- laziness is broken"
    expect(after).to eq("true"), "referencing Tina4::Queue did not load queue.rb"
    expect(name).to eq("Tina4::Queue")
  end

  it "resolves every constant the three newly-lazy files define" do
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      names = %i[Queue Job Messenger MessengerError MessengerConnectionError
                 IMAP_CONNECTION_ERRORS DocStore]
      missing = names.reject { |n| Tina4.const_get(n) rescue false }
      puts missing.empty? ? "all ok" : "MISSING: \#{missing.join(', ')}"
    RUBY
    expect(out).to eq("all ok"),
                   "an autoload entry points at a file that does not define the constant"
  end

  # THE GATE THAT WAS MISSING. A `require` registers every constant in a file
  # implicitly; an autoload table names them one at a time, so a file defining
  # two constants needs two entries. queue.rb defines Job as well as Queue, and
  # omitting Job turned `Tina4::Job` into a NameError that took the whole spec
  # suite to "0 examples, 2 errors occurred outside of examples".
  #
  # Rather than trusting a hand-kept list, load each lazy file in a fresh
  # process and assert it introduces NO constant that was not already visible --
  # an autoload entry makes its name appear in Tina4.constants immediately, so
  # anything NEW after the require is a name with no entry.
  it "has an autoload entry for every constant each lazy file defines" do
    %w[queue messenger docstore].each do |mod|
      out = in_fresh_ruby(<<~RUBY)
        require "tina4"
        before = Tina4.constants
        require File.expand_path("tina4/#{mod}", #{TINA4_LAZY_LIB_DIR.inspect})
        added = Tina4.constants - before
        puts added.empty? ? "none" : added.sort.join(",")
      RUBY
      expect(out).to eq("none"),
                     "lib/tina4/#{mod}.rb defines #{out} with no autoload entry in " \
                     "lib/tina4.rb, so referencing #{out.split(',').first} after a " \
                     "clean `require \"tina4\"` raises NameError. Add " \
                     "`autoload :#{out.split(',').first}, ...tina4/#{mod}...`."
    end
  end

  it "answers defined? without triggering the load, so the dev_admin guards stay lazy" do
    # dev_admin.rb does `queue = Tina4::Queue.new(...) if defined?(Tina4::Queue)`.
    # If defined? ever stopped seeing autoload entries, that guard would go
    # false and the dev dashboard would silently stop creating queues.
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      seen   = defined?(Tina4::Queue)
      loaded = $LOADED_FEATURES.any? { |f| f.end_with?("/lib/tina4/queue.rb") }
      puts [seen.inspect, loaded].join("|")
    RUBY
    seen, loaded = out.split("|")
    expect(seen).to eq('"constant"'), "defined? no longer sees the autoload entry"
    expect(loaded).to eq("false"), "defined? triggered the load -- the guard is no longer free"
  end

  it "keeps the core surface eagerly available" do
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      %i[Router Request Response ORM Database Frond Auth Session Events].each do |c|
        Tina4.const_get(c)
      end
      puts "core ok"
    RUBY
    expect(out).to eq("core ok")
  end

  it "raises NameError for a constant that genuinely does not exist" do
    # The autoload table must not turn a typo into something truthy.
    out = in_fresh_ruby(<<~RUBY)
      require "tina4"
      begin
        Tina4::NoSuchFeature
        puts "NO RAISE"
      rescue NameError
        puts "raised"
      end
    RUBY
    expect(out).to eq("raised")
  end
end
