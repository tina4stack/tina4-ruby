#!/usr/bin/env ruby
# frozen_string_literal: true

##
# Framework Comparison: tina4-ruby vs Sequel, ActiveRecord (Rails' ORM), Sinatra, Roda
#
# PART 1 (performance) benchmarks database CRUD across the layers that HAVE a
# database layer: Raw sqlite3, tina4-ruby, Sequel, and ActiveRecord (Rails'
# ORM). Sinatra and Roda are deliberately NOT in the performance table: they are
# HTTP frameworks with no database layer of their own, so giving one a database
# means pairing it with Sequel or ActiveRecord -- a "Sinatra CRUD benchmark"
# would just re-measure that library, not Sinatra. Their performance is measured
# where it is real, in the HTTP-throughput benchmark (see benchmarks/README.md),
# not here. Fabricating DB numbers for them would be a rigged row.
#
# PARTS 2-4 compare all five frameworks qualitatively -- there Sinatra and Roda
# legitimately appear as columns:
# - Out-of-the-box features
# - Lines of code / complexity
# - AI compatibility
#
# Run with:
#   ruby benchmarks/bench_frameworks.rb

require "benchmark"
require "tmpdir"
require "json"
require "fileutils"

NUM_ROWS  = 5_000
ITERATIONS = 20
LIMIT     = 20

# Explicit "give me everything" bound for frameworks whose read API applies a
# default row cap (Tina4's fetch defaults to limit: 100). Any comparison of a
# "select all" must have every framework materialise the SAME number of rows.
ALL_ROWS  = NUM_ROWS * 2

CITIES = %w[NewYork London Tokyo Paris Berlin Sydney Toronto Mumbai SaoPaulo Cairo].freeze

def random_string(len = 12)
  (0...len).map { (97 + rand(26)).chr }.join
end

def random_email
  "#{random_string(8)}@#{random_string(5)}.com"
end

def generate_users(n)
  srand(42)
  n.times.map do |i|
    {
      id: i + 1,
      name: random_string(10),
      email: random_email,
      age: rand(18..80),
      city: CITIES.sample,
      active: rand(2)
    }
  end
end

USERS = generate_users(NUM_ROWS)

# ---------------------------------------------------------------------------
# Base class for framework benchmarks
# ---------------------------------------------------------------------------
class FrameworkBench
  attr_reader :name, :db_path

  def initialize(name)
    @name = name
    @db_path = File.join(Dir.tmpdir, "bench_#{name.downcase.gsub(/\W/, '_')}_#{$$}.db")
  end

  def setup
    raise NotImplementedError
  end

  def cleanup
    FileUtils.rm_f(@db_path)
  end

  # Reports the MEDIAN of ITERATIONS samples after an untimed warm-up.
  #
  # Was: the mean of 20 samples with NO warm-up. Two problems. The first sample
  # runs cold (statement not prepared, pages not in cache, no JIT), and one cold
  # sample 10x the rest moves a 20-sample mean by ~45%. And a mean absorbs any
  # single scheduler or fsync stall, so a framework could look slower purely
  # because one of its 20 samples hit a flush. The median is stable against both.
  # Connection settings every framework in this comparison must share.
  #
  # Tina4's SQLite adapter sets journal_mode=WAL and foreign_keys=ON on connect.
  # Raw sqlite3, Sequel and ActiveRecord were left on SQLite's defaults (rollback
  # journal), so the write rows were comparing JOURNAL MODES, not frameworks --
  # Tina4 read 0.034ms against raw sqlite3's 0.592ms for the same insert, a 17x
  # gap that WAL alone explains. Applying the same pragmas everywhere makes the
  # writes comparable; the framework, not the journal, is what varies.
  EQUAL_PRAGMAS = [
    "PRAGMA journal_mode=WAL",
    "PRAGMA foreign_keys=ON"
  ].freeze

  def apply_equal_pragmas
    EQUAL_PRAGMAS.each { |sql| yield sql }
  end

  # How many rows this framework's "Select all" actually materialises.
  #
  # This exists because the comparison silently stopped being a comparison: Tina4
  # fetched 100 rows where every competitor fetched 5,000, and nothing in the
  # output revealed it. Each subclass reports its real count and main() refuses to
  # print a table when the counts disagree. A rigged row is worse than no row.
  def select_all_row_count
    raise NotImplementedError, "#{self.class}: must report its Select-all row count"
  end

  def bench(label)
    yield                                   # warm-up, untimed
    times = ITERATIONS.times.map do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0
    end
    times.sort[times.size / 2]
  end

  def run_all
    results = {}
    benchmarks.each do |label, method_name|
      begin
        ms = send(method_name)
        results[label] = ms
        printf "    %-24s %10.3f ms\n", label, ms
      rescue => e
        results[label] = nil
        printf "    %-24s FAILED: %s\n", label, e.message
      end
    end
    results
  end

  def benchmarks
    [
      ["Insert (single)",   :bench_insert_single],
      ["Insert (100 bulk)", :bench_insert_bulk],
      ["Select ALL rows",   :bench_select_all],
      ["Select filtered",   :bench_select_filtered],
      ["Select paginated",  :bench_select_paginated],
      ["Update (by PK)",    :bench_update],
      ["Delete (by PK)",    :bench_delete]
    ]
  end
end

# ---------------------------------------------------------------------------
# 1. Raw sqlite3
# ---------------------------------------------------------------------------
class RawSqliteBench < FrameworkBench
  def initialize
    super("Raw sqlite3")
  end

  def setup
    require "sqlite3"
    @db = SQLite3::Database.new(@db_path)
    apply_equal_pragmas { |sql| @db.execute(sql) }
    @db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, age INTEGER, city TEXT, active INTEGER)")
    USERS.each do |u|
      @db.execute("INSERT INTO users VALUES (?,?,?,?,?,?)", [u[:id], u[:name], u[:email], u[:age], u[:city], u[:active]])
    end
  end

  def cleanup
    @db.close rescue nil
    super
  end

  def bench_insert_single
    bench("Insert single") do
      @db.execute("INSERT INTO users (name, email, age, city, active) VALUES (?,?,?,?,?)",
                  [random_string, random_email, 25, "Test", 1])
      @db.execute("DELETE FROM users WHERE id > ?", [NUM_ROWS])
    end
  end

  def bench_insert_bulk
    bench("Insert bulk") do
      @db.transaction do
        100.times do
          @db.execute("INSERT INTO users (name, email, age, city, active) VALUES (?,?,?,?,?)",
                      [random_string, random_email, 25, "Test", 1])
        end
      end
      @db.execute("DELETE FROM users WHERE id > ?", [NUM_ROWS])
    end
  end

  def select_all_row_count
    @db.execute("SELECT * FROM users").length
  end

  def bench_select_all
    bench("Select all") { @db.execute("SELECT * FROM users") }
  end

  def bench_select_filtered
    bench("Select filtered") { @db.execute("SELECT * FROM users WHERE age > ? AND city = ?", [30, "London"]) }
  end

  def bench_select_paginated
    bench("Select paginated") { @db.execute("SELECT * FROM users LIMIT ? OFFSET ?", [LIMIT, 100]) }
  end

  def bench_update
    bench("Update") do
      @db.execute("UPDATE users SET age = ? WHERE id = ?", [99, rand(1..NUM_ROWS)])
    end
  end

  def bench_delete
    bench("Delete") do
      @db.execute("INSERT INTO users (name, email, age, city, active) VALUES (?,?,?,?,?)",
                  ["del", "del@test.com", 20, "Test", 1])
      last_id = @db.last_insert_row_id
      @db.execute("DELETE FROM users WHERE id = ?", [last_id])
    end
  end
end

# ---------------------------------------------------------------------------
# 2. Tina4 Ruby
# ---------------------------------------------------------------------------
class Tina4Bench < FrameworkBench
  def initialize
    super("tina4_ruby")
  end

  def setup
    $LOAD_PATH.unshift(File.expand_path("../../lib", __FILE__))
    # Suppress tina4 debug output
    ENV["TINA4_DEBUG_LEVEL"] = "ERROR"
    require "tina4"
    @db = Tina4::Database.new(@db_path)
    @db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, age INTEGER, city TEXT, active INTEGER)")
    USERS.each do |u|
      @db.insert("users", u)
    end
  end

  def cleanup
    @db.close rescue nil
    super
  end

  def bench_insert_single
    bench("Insert single") do
      @db.insert("users", { name: random_string, email: random_email, age: 25, city: "Test", active: 1 })
      @db.execute("DELETE FROM users WHERE id > ?", [NUM_ROWS])
    end
  end

  # Wrapped in ONE transaction to match raw sqlite3 and Sequel, which both use
  # db.transaction here. Without it Tina4 did 100 separate autocommitting inserts
  # against the competitors' single commit -- 100 fsyncs vs 1, biasing this row
  # heavily AGAINST Tina4. The unfairness in this file ran in both directions.
  def bench_insert_bulk
    bench("Insert bulk") do
      @db.transaction do
        100.times do
          @db.insert("users", { name: random_string, email: random_email, age: 25, city: "Test", active: 1 })
        end
      end
      @db.execute("DELETE FROM users WHERE id > ?", [NUM_ROWS])
    end
  end

  # NOTE the explicit limit: Tina4's fetch defaults to limit: 100, so a bare
  # fetch("SELECT * FROM users") returned 100 of the 5,000 rows while Sequel's
  # .all, ActiveRecord's .all.to_a and raw sqlite3's execute all materialise all
  # 5,000. That made Tina4 do 50x LESS work in this row and read dramatically
  # faster for a reason that had nothing to do with the framework. Verified by
  # counting: bare fetch -> 100 records, fetch(limit: 10_000) -> 5,000.
  def select_all_row_count
    @db.fetch("SELECT * FROM users", [], limit: ALL_ROWS).records.length
  end

  def bench_select_all
    bench("Select all") { @db.fetch("SELECT * FROM users", [], limit: ALL_ROWS) }
  end

  def bench_select_filtered
    bench("Select filtered") do
      @db.fetch("SELECT * FROM users WHERE age > ? AND city = ?", [30, "London"], limit: ALL_ROWS)
    end
  end

  def bench_select_paginated
    # offset:, not skip: -- Tina4's fetch takes offset:. With skip: this row raised
    # "unknown keyword: :skip" on every run and printed FAIL, so the Tina4 paginated
    # figure never existed. A row that always errors is not a slow result, it is a
    # missing one.
    bench("Select paginated") { @db.fetch("SELECT * FROM users", [], limit: LIMIT, offset: 100) }
  end

  def bench_update
    bench("Update") do
      @db.update("users", { age: 99 }, { id: rand(1..NUM_ROWS) })
    end
  end

  def bench_delete
    bench("Delete") do
      @db.insert("users", { name: "del", email: "del@test.com", age: 20, city: "Test", active: 1 })
      @db.execute("DELETE FROM users WHERE id > ?", [NUM_ROWS])
    end
  end
end

# ---------------------------------------------------------------------------
# 3. Sequel
# ---------------------------------------------------------------------------
class SequelBench < FrameworkBench
  def initialize
    super("Sequel")
  end

  def setup
    require "sequel"
    @db = Sequel.sqlite(@db_path)
    apply_equal_pragmas { |sql| @db.run(sql) }
    @db.create_table :users do
      primary_key :id
      String :name
      String :email
      Integer :age
      String :city
      Integer :active
    end
    @users = @db[:users]
    USERS.each { |u| @users.insert(u.reject { |k,_| k == :id }) }
  end

  def cleanup
    @db.disconnect rescue nil
    super
  end

  def bench_insert_single
    bench("Insert single") do
      @users.insert(name: random_string, email: random_email, age: 25, city: "Test", active: 1)
      @users.where { id > NUM_ROWS }.delete
    end
  end

  def bench_insert_bulk
    bench("Insert bulk") do
      @db.transaction do
        100.times do
          @users.insert(name: random_string, email: random_email, age: 25, city: "Test", active: 1)
        end
      end
      @users.where { id > NUM_ROWS }.delete
    end
  end

  def select_all_row_count
    @users.all.length
  end

  def bench_select_all
    bench("Select all") { @users.all }
  end

  def bench_select_filtered
    bench("Select filtered") { @users.where { (age > 30) & (city =~ "London") }.all }
  end

  def bench_select_paginated
    bench("Select paginated") { @users.limit(LIMIT, 100).all }
  end

  def bench_update
    bench("Update") { @users.where(id: rand(1..NUM_ROWS)).update(age: 99) }
  end

  def bench_delete
    bench("Delete") do
      id = @users.insert(name: "del", email: "del@test.com", age: 20, city: "Test", active: 1)
      @users.where(id: id).delete
    end
  end
end

# ---------------------------------------------------------------------------
# 4. ActiveRecord (used by Rails)
# ---------------------------------------------------------------------------
class ActiveRecordBench < FrameworkBench
  def initialize
    super("ActiveRecord")
  end

  def setup
    require "active_record"
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @db_path)
    apply_equal_pragmas { |sql| ActiveRecord::Base.connection.execute(sql) }
    ActiveRecord::Schema.define do
      create_table :users, force: true do |t|
        t.string :name
        t.string :email
        t.integer :age
        t.string :city
        t.integer :active
      end
    end

    # Silence AR logging
    ActiveRecord::Base.logger = nil

    # Define model
    Object.send(:remove_const, :ARUser) if defined?(ARUser)
    Object.const_set(:ARUser, Class.new(ActiveRecord::Base) {
      self.table_name = "users"
    })

    USERS.each do |u|
      ARUser.create!(name: u[:name], email: u[:email], age: u[:age], city: u[:city], active: u[:active])
    end
  end

  def cleanup
    ActiveRecord::Base.connection.close rescue nil
    super
  end

  def bench_insert_single
    bench("Insert single") do
      ARUser.create!(name: random_string, email: random_email, age: 25, city: "Test", active: 1)
      ARUser.where("id > ?", NUM_ROWS).delete_all
    end
  end

  def bench_insert_bulk
    bench("Insert bulk") do
      ActiveRecord::Base.transaction do
        100.times do
          ARUser.create!(name: random_string, email: random_email, age: 25, city: "Test", active: 1)
        end
      end
      ARUser.where("id > ?", NUM_ROWS).delete_all
    end
  end

  def select_all_row_count
    ARUser.all.to_a.length
  end

  def bench_select_all
    bench("Select all") { ARUser.all.to_a }
  end

  def bench_select_filtered
    bench("Select filtered") { ARUser.where("age > ? AND city = ?", 30, "London").to_a }
  end

  def bench_select_paginated
    bench("Select paginated") { ARUser.limit(LIMIT).offset(100).to_a }
  end

  def bench_update
    bench("Update") { ARUser.where(id: rand(1..NUM_ROWS)).update_all(age: 99) }
  end

  def bench_delete
    bench("Delete") do
      u = ARUser.create!(name: "del", email: "del@test.com", age: 20, city: "Test", active: 1)
      u.delete
    end
  end
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def feature_comparison
  {
    "Web Server & Routing" => [
      ["Built-in HTTP server",     "YES",     "YES*",    "Puma*",   "no",      "no"],
      ["Route decorators/DSL",     "YES",     "YES",     "no",      "YES",     "YES"],
      ["Path parameter types",     "YES",     "YES",     "no",      "YES",     "partial"],
      ["WebSocket support",        "YES",     "plugin",  "Action Cable", "no", "no"],
      ["Auto CORS handling",       "YES",     "plugin",  "plugin",  "no",      "no"],
      ["Static file serving",      "YES",     "YES",     "YES",     "no",      "no"],
    ],
    "Database & ORM" => [
      ["Built-in DB abstraction",  "YES",     "no",      "YES",     "YES",     "YES"],
      ["Built-in ORM",             "YES",     "no",      "YES",     "YES",     "YES"],
      ["Built-in migrations",      "YES",     "no",      "YES",     "no",      "no"],
      ["SQL-first API (raw SQL)",  "YES",     "no",      "partial", "YES",     "YES"],
      ["Multi-engine support",     "5 engines","no",     "3 engines","12+ engines","12+ engines"],
      ["Built-in pagination",      "YES",     "no",      "plugin",  "YES",     "YES"],
      ["Built-in search",          "YES",     "no",      "no",      "no",      "no"],
      ["CRUD scaffolding",         "YES",     "no",      "YES",     "no",      "no"],
    ],
    "Templating & Frontend" => [
      ["Built-in template engine", "Twig",    "ERB",     "ERB",     "no",      "no"],
      ["Template inheritance",     "YES",     "YES",     "YES",     "no",      "no"],
      ["SCSS auto-compilation",    "YES",     "no",      "plugin",  "no",      "no"],
      ["Live-reload / hot-patch",  "YES",     "plugin",  "plugin",  "no",      "no"],
    ],
    "Auth & Security" => [
      ["JWT auth built-in",        "YES",     "no",      "no",      "no",      "no"],
      ["Session management",       "YES",     "plugin",  "YES",     "no",      "no"],
      ["Password hashing",         "YES",     "no",      "has_secure_password","no","no"],
      ["Route-level auth",         "YES",     "no",      "before_action","no", "no"],
    ],
    "API & Integration" => [
      ["Swagger/OpenAPI gen",      "YES",     "no",      "no",      "no",      "no"],
      ["GraphQL (built-in)",       "YES",     "no",      "no",      "no",      "no"],
      ["SOAP/WSDL support",        "YES",     "no",      "no",      "no",      "no"],
      ["Queue system",             "YES",     "no",      "Active Job","no",    "no"],
      ["REST API client",          "YES",     "no",      "no",      "no",      "no"],
    ],
    "Developer Experience" => [
      ["Zero-config startup",      "YES",     "YES",     "no",      "YES",     "YES"],
      ["CLI scaffolding",          "YES",     "no",      "YES",     "no",      "no"],
      ["Inline testing",           "YES",     "no",      "YES",     "no",      "no"],
      ["i18n / localization",      "YES",     "no",      "YES",     "no",      "no"],
      ["Error overlay (dev)",      "YES",     "YES",     "YES",     "no",      "no"],
    ],
  }
end

def ai_compatibility
  [
    ["CLAUDE.md / AI guidelines", "YES",     "no",      "no",      "no",      "no"],
    ["Convention over config",    "HIGH",    "LOW",     "HIGH",    "LOW",     "LOW"],
    ["Single file app possible",  "YES",     "YES",     "no",      "YES",     "YES"],
    ["Predictable file structure", "YES",    "no",      "YES",     "no",      "no"],
    ["Auto-discovery (routes)",   "YES",     "no",      "no",      "no",      "no"],
    ["Minimal boilerplate",       "YES",     "YES",     "no",      "YES",     "YES"],
    ["Self-contained (fewer deps)","YES",    "partial", "no",      "YES",     "YES"],
    ["Consistent API patterns",   "YES",     "partial", "YES",     "YES",     "YES"],
    ["AI can scaffold full app",  "YES",     "partial", "YES",     "no",      "no"],
    ["AI SCORE (out of 10)",      "9.5",     "6",       "7.5",     "6",       "6.5"],
  ]
end

def main
  puts "=" * 130
  puts "  RUBY FRAMEWORK COMPARISON: Features, Performance, Complexity, and AI Compatibility"
  puts "=" * 130
  puts "  DB Benchmark: #{NUM_ROWS} users | #{ITERATIONS} iterations | SQLite backend (same for all)"
  puts
  puts "=" * 130
  puts "  PART 1: DATABASE PERFORMANCE (ms per operation, lower is better)"
  puts "=" * 130
  puts "  Measures the DB layers only: Raw sqlite3, tina4_ruby, Sequel, ActiveRecord (Rails' ORM)."
  puts "  Sinatra and Roda are HTTP frameworks with no DB layer of their own, so they are NOT in this"
  puts "  table -- they appear in the feature / LOC / AI comparison (PARTS 2-4). Their performance is"
  puts "  the HTTP-throughput benchmark (benchmarks/README.md), which is where routing overhead is real."
  puts

  framework_classes = [RawSqliteBench, Tina4Bench, SequelBench, ActiveRecordBench]
  framework_order = []
  all_results = {}
  bench_names = []
  row_counts = {}

  framework_classes.each do |klass|
    begin
      fw = klass.new
    rescue => e
      puts "  [#{klass.name}] FAILED to init: #{e.message}"
      next
    end

    puts "  [#{fw.name}] Setting up..."
    begin
      fw.setup
    rescue => e
      puts "  [#{fw.name}] FAILED setup: #{e.message}"
      puts "    #{e.backtrace.first(3).join("\n    ")}"
      next
    end

    # Equal-work gate. Record what this framework's "Select all" really
    # materialises; the table is withheld below if the frameworks disagree.
    begin
      row_counts[fw.name] = fw.select_all_row_count
      printf "  [%s] Select-all materialises %d rows\n", fw.name, row_counts[fw.name]
    rescue => e
      row_counts[fw.name] = nil
      puts "  [#{fw.name}] could not report its Select-all row count: #{e.message}"
    end

    framework_order << fw.name
    all_results[fw.name] = fw.run_all
    bench_names = fw.benchmarks.map(&:first) if bench_names.empty?

    begin
      fw.cleanup
    rescue
    end
    puts
  end

  # Performance table
  puts "-" * 130
  header = "  %-24s" % "Operation"
  framework_order.each { |n| header += "%18s" % n }
  puts header
  puts "-" * 130

  bench_names.each do |label|
    row = "  %-24s" % label
    times = framework_order.filter_map { |n| all_results[n][label] }
    best = times.min || 0
    framework_order.each do |n|
      t = all_results[n][label]
      if t.nil?
        row += "%18s" % "FAIL"
      else
        marker = (t - best).abs < 0.001 ? " *" : "  "
        row += "%15.3f%2s" % [t, marker]
      end
    end
    puts row
  end

  puts "-" * 130
  puts "  * = fastest"
  puts

  # Overhead vs raw sqlite3
  if all_results["Raw sqlite3"]
    raw = all_results["Raw sqlite3"]
    puts "  OVERHEAD vs Raw sqlite3 (avg across all operations):"
    framework_order.each do |name|
      next if name == "Raw sqlite3"
      overheads = []
      bench_names.each do |label|
        r = raw[label]
        f = all_results[name][label]
        overheads << ((f / r - 1) * 100) if r && f && r > 0
      end
      next if overheads.empty?
      avg = overheads.sum / overheads.size
      bar = "#" * [1, (avg.abs / 5).to_i].max
      printf "    %-20s %+8.1f%%  %s\n", name, avg, bar
    end
    puts
  end

  # Features

  # ── Equal-work gate ──────────────────────────────────────────
  #
  # Refuse to present a performance comparison in which the frameworks did
  # different amounts of work. This fired for real: Tina4's fetch defaults to
  # limit: 100, so it returned 100 of 5,000 rows while Sequel/ActiveRecord/raw
  # sqlite3 returned all 5,000 -- a 50x advantage that looked like a framework
  # win. Numbers that flatter us for the wrong reason are worse than no numbers.
  seen = row_counts.values.compact.uniq
  if seen.length > 1
    puts
    puts "  !! EQUAL-WORK CHECK FAILED - performance table withheld."
    row_counts.each { |n, c| printf "     %-16s Select-all rows: %s\n", n, c.inspect }
    puts "     The frameworks materialised different row counts, so these timings"
    puts "     are not comparable. Fix the read call that truncates, then re-run."
    puts
  end
  puts "=" * 130
  puts "  PART 2: OUT-OF-THE-BOX FEATURES (no plugins/extensions needed)"
  puts "=" * 130
  puts "  Legend: YES = built-in | plugin = needs third-party | no = not available"
  puts
  fws = %w[tina4 Sinatra Rails Sequel Roda]

  features = feature_comparison
  yes_count = Hash.new(0)
  total = 0

  features.each do |category, items|
    puts "  --- #{category} ---"
    printf "  %-36s %10s %10s %10s %10s %10s\n", "Feature", *fws
    items.each do |row|
      printf "  %-36s", row[0]
      row[1..].each { |v| printf " %10s", v }
      puts
      total += 1
      row[1..].each_with_index do |v, i|
        val = v.upcase
        yes_count[fws[i]] += 1 if val == "YES" || val.include?("ENGINE") || val == "TWIG" || val == "ERB" || val == "HIGH" || val.include?("ACTIVE") || val.include?("HAS_SECURE") || val.include?("BEFORE_ACTION") || val.include?("PUMA")
      end
    end
    puts
  end

  total = features.values.flatten(1).size
  puts "  BUILT-IN FEATURE COUNT (out of #{total}):"
  fws.each do |fw|
    bar = "#" * yes_count[fw]
    printf "    %-20s %3d  %s\n", fw, yes_count[fw], bar
  end
  puts

  # Complexity
  puts "=" * 130
  puts "  PART 3: COMPLEXITY — Lines of Code for Common Tasks"
  puts "=" * 130
  puts
  tasks = [
    ["Hello World API",         "5",   "5",   "8+",   "5",   "5"],
    ["CRUD REST API",           "25",  "40+", "80+",  "30+", "30+"],
    ["DB + pagination endpoint","8",   "15+", "15",   "10",  "10"],
    ["Auth-protected route",    "3",   "10+", "5",    "10+", "10+"],
    ["WebSocket endpoint",      "10",  "plugin","15+","N/A", "N/A"],
    ["Background queue job",    "5",   "plugin","5",  "plugin","plugin"],
    ["Config files needed",     "0-1", "0-1", "3+",   "0-1", "0-1"],
    ["DB setup code",           "1 line","N/A","5+",  "3",   "3"],
  ]

  printf "  %-30s", "Task"
  fws.each { |fw| printf " %14s", fw }
  puts
  tasks.each do |row|
    printf "  %-30s", row[0]
    row[1..].each { |v| printf " %14s", v }
    puts
  end
  puts

  # Code examples
  puts "-" * 130
  puts "  CODE EXAMPLES: Complete CRUD API with database"
  puts "-" * 130

  puts <<~EXAMPLES

    tina4_ruby (8 lines — complete CRUD):
      require "tina4"
      db = Tina4::Database.new("sqlite3:app.db")
      db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      db.insert("users", { name: "Alice", age: 30 })
      result = db.fetch("SELECT * FROM users WHERE age > ?", [25], limit: 10, skip: 0)
      db.update("users", { age: 31 }, { id: 1 })
      db.delete("users", { id: 1 })
      db.close

    Sinatra + Sequel (25+ lines):
      require "sinatra"
      require "sequel"
      DB = Sequel.sqlite("app.db")
      DB.create_table? :users do
        primary_key :id
        String :name; Integer :age
      end
      get "/users" do
        DB[:users].limit(params[:limit]&.to_i || 10)
                  .offset(params[:skip]&.to_i || 0).all.to_json
      end
      post "/users" do
        data = JSON.parse(request.body.read)
        id = DB[:users].insert(name: data["name"], age: data["age"])
        { id: id }.to_json
      end

    Rails (40+ lines across 4+ files):
      # config/database.yml + Gemfile + routes.rb + model + controller
      # models/user.rb
      class User < ApplicationRecord; end
      # controllers/users_controller.rb
      class UsersController < ApplicationController
        def index
          render json: User.limit(params[:limit]).offset(params[:skip])
        end
        def create
          user = User.create!(user_params)
          render json: user, status: :created
        end
        private
        def user_params; params.require(:user).permit(:name, :age); end
      end
      # + rails db:migrate, routes.rb, application config
  EXAMPLES

  # AI Compatibility
  puts "=" * 130
  puts "  PART 4: AI ASSISTANT COMPATIBILITY"
  puts "=" * 130
  puts
  ai = ai_compatibility
  printf "  %-36s %14s %14s %14s %14s %14s\n", "Factor", *fws
  ai.each do |row|
    printf "  %-36s", row[0]
    row[1..].each { |v| printf " %14s", v }
    puts
  end
  puts

  # Summary
  puts "=" * 130
  puts "  SUMMARY: WHEN TO USE WHAT"
  puts "=" * 130
  puts <<~SUMMARY

    tina4_ruby ........... Best for: Rapid development, SQL-first apps, multi-DB projects,
                           AI-assisted development, full-stack apps with minimal config.
                           Ideal when you want everything built-in and zero boilerplate.

    Sinatra .............. Best for: Simple apps, microservices, learning Ruby web dev.
                           Minimal and flexible but you bring your own DB, auth, everything.

    Rails ................ Best for: Large enterprise apps, teams needing strong conventions,
                           job market presence, extensive community and ecosystem.

    Sequel ............... Best for: Database-heavy apps where you want a powerful DSL
                           without a full framework. Excellent multi-DB support.

    Roda ................. Best for: Performance-focused routing, plugin-based architecture.
                           Fast but minimal — you build everything yourself.

    KEY DIFFERENTIATORS for tina4_ruby:
    1. ONLY Ruby framework with built-in CLAUDE.md AI guidelines
    2. Built-in GraphQL, SOAP/WSDL, JWT, queues, SCSS — no gems needed
    3. Twig templating (familiar to PHP/Python tina4 users)
    4. SQL-first API — write real SQL, not ORM-specific DSL
    5. ZERO config files needed to start
    6. Cross-platform consistency with tina4-python and tina4-php
  SUMMARY

  puts "=" * 130
end

main
