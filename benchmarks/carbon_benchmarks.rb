#!/usr/bin/env ruby
# frozen_string_literal: true

# Tina4 v3 Carbon Benchmarks - 9 workload categories.
#
# Run all:      ruby benchmarks/carbon_benchmarks.rb
# Run one:      ruby benchmarks/carbon_benchmarks.rb json
# Startup cost: ruby benchmarks/carbon_benchmarks.rb --startup
# Carbon (SCI): ruby benchmarks/carbon_benchmarks.rb --carbon
# Categories:   json, db_single, db_multi, template, json_large,
#               plaintext, crud, paginated, startup
#
# By default this reports WALL-CLOCK time and throughput. `--carbon` shells out
# to the real Carbonah CLI for Software Carbon Intensity; `--startup` spawns
# fresh interpreters to measure per-process require cost, which no in-process
# loop can see (Ruby caches in $LOADED_FEATURES, so a repeated require is a
# hash lookup).
#
# Ruby was the only one of the four frameworks without this runner; the other
# three had it and Ruby did not, so its numbers were simply absent from every
# cross-language table. This closes that gap with the same methodology as the
# Python master, including the measurement fixes described in run_benchmark.

# Silence framework logging BEFORE anything loads: the Database connect logs at
# INFO and would interleave with the results table.
ENV["TINA4_LOG_LEVEL"] ||= "none"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tina4"
require "tmpdir"
require "fileutils"
require "json"

# Nominal count, still used by --single (carbonah needs a fixed amount of work,
# not a fixed duration).
ITERATIONS = 1000

# Timed runs continue until this much wall-clock has elapsed...
MIN_SECONDS = 0.25

# ...but never fewer than this many iterations, however fast the operation.
MIN_ITERATIONS = 200

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# 1,234,567 - Ruby has no built-in thousands separator.
def commafy(num)
  num.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

def bench_db(dir)
  Tina4::Database.new("sqlite://#{dir}/bench.db")
end

# ── 1. JSON serialization - raw overhead ───────────────────────

def bench_json
  payload = { message: "Hello, World!", status: "ok" }
  [-> { Tina4::Response.new.json(payload) }, nil]
end

# ── 2. Single database query ───────────────────────────────────

def bench_db_single
  dir = Dir.mktmpdir
  db = bench_db(dir)
  db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")
  db.execute("INSERT INTO users VALUES (1, 'Alice', 'alice@test.com')")
  db.commit

  teardown = lambda do
    db.close
    FileUtils.remove_entry(dir, true)
  end

  [-> { db.fetch_one("SELECT * FROM users WHERE id = ?", [1]) }, teardown]
end

# ── 3. Multiple database queries ───────────────────────────────

def bench_db_multi
  dir = Dir.mktmpdir
  db = bench_db(dir)
  db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, price REAL)")
  100.times { |i| db.execute("INSERT INTO items VALUES (?, ?, ?)", [i, "Item #{i}", i * 1.5]) }
  db.commit

  op = lambda do
    db.fetch("SELECT * FROM items WHERE price > ?", [50.0], limit: 20)
    db.fetch_one("SELECT COUNT(*) as cnt FROM items")
    db.fetch("SELECT * FROM items ORDER BY price DESC", [], limit: 5)
  end

  teardown = lambda do
    db.close
    FileUtils.remove_entry(dir, true)
  end

  [op, teardown]
end

# ── 4. Template rendering ──────────────────────────────────────

def bench_template
  dir = Dir.mktmpdir
  engine = Tina4::Frond.new(template_dir: dir)
  tpl = <<~TPL
    <!DOCTYPE html>
    <html>
    <head><title>{{ title }}</title></head>
    <body>
    <h1>{{ heading }}</h1>
    <ul>
    {% for item in items %}
    <li class="{{ loop.even ? 'even' : 'odd' }}">{{ loop.index }}. {{ item.name | upper }} - ${{ item.price | number_format(2) }}</li>
    {% endfor %}
    </ul>
    {% if show_footer %}
    <footer>{{ footer_text | truncate(50) }}</footer>
    {% endif %}
    </body>
    </html>
  TPL
  data = {
    "title" => "Benchmark Page",
    "heading" => "Product List",
    "items" => (0...20).map { |i| { "name" => "Product #{i}", "price" => i * 9.99 } },
    "show_footer" => true,
    "footer_text" => "This is a footer with some text that may be truncated for display purposes."
  }
  # render() from a FILE, not render_string(). render_string recompiles on every
  # call (Frond has no compiled-template cache), so timing it measured
  # compile+render while every other framework's template benchmark measures
  # render alone. render("bench.twig") is the per-request call a real app makes.
  File.write(File.join(dir, "bench.twig"), tpl)

  [-> { engine.render("bench.twig", data) }, -> { FileUtils.remove_entry(dir, true) }]
end

# ── 5. Large JSON payload ──────────────────────────────────────

def bench_json_large
  payload = {
    "users" => (0...100).map do |i|
      {
        "id" => i, "name" => "User #{i}", "email" => "user#{i}@test.com",
        "active" => i.even?, "score" => i * 1.5,
        "tags" => %w[tag1 tag2 tag3],
        "address" => { "street" => "#{i} Main St", "city" => "TestCity", "zip" => (10_000 + i).to_s }
      }
    end,
    "meta" => { "total" => 100, "page" => 1, "per_page" => 100 }
  }
  [-> { Tina4::Response.new.json(payload) }, nil]
end

# ── 6. Plaintext response ──────────────────────────────────────

def bench_plaintext
  [-> { Tina4::Response.new.html("Hello, World!") }, nil]
end

# ── 7. Full CRUD cycle ─────────────────────────────────────────

def bench_crud
  dir = Dir.mktmpdir
  db = bench_db(dir)
  db.execute("CREATE TABLE tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, done INTEGER DEFAULT 0)")
  db.commit

  # ONE measured op is ONE full create/read/update/delete cycle -- not a batch of
  # them divided by a nominal count, which is how the other three runners each
  # reported CRUD 10x too high before being fixed.
  op = lambda do
    db.insert("tasks", { title: "Benchmark task", done: 0 })
    task_id = db.get_last_id
    db.fetch_one("SELECT * FROM tasks WHERE id = ?", [task_id])
    db.update("tasks", { done: 1 }, "id = ?", [task_id])
    db.delete("tasks", "id = ?", [task_id])
    db.commit
  end

  teardown = lambda do
    db.close
    FileUtils.remove_entry(dir, true)
  end

  [op, teardown]
end

# ── 8. Paginated query with count ──────────────────────────────

def bench_paginated
  dir = Dir.mktmpdir
  db = bench_db(dir)
  db.execute("CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, category TEXT, price REAL)")
  500.times do |i|
    db.execute("INSERT INTO products VALUES (?, ?, ?, ?)",
               [i, "Product #{i}", "Cat #{i % 10}", i * 2.5])
  end
  db.commit

  op = lambda do
    result = db.fetch("SELECT * FROM products WHERE category = ?", ["Cat 3"], limit: 20, offset: 0)
    result.to_paginate(page: 1, per_page: 20)
  end

  teardown = lambda do
    db.close
    FileUtils.remove_entry(dir, true)
  end

  [op, teardown]
end

# ── 9. Framework startup ───────────────────────────────────────

def bench_startup
  op = lambda do
    # Construct what an app boot touches. The require itself already happened at
    # the top of this file, and Ruby caches it in $LOADED_FEATURES, so a repeated
    # require here would be a hash lookup rather than a load. The honest
    # per-process number comes from `--startup`, which spawns fresh interpreters.
    Tina4::Router
    Tina4::Auth
    Tina4::Session   # constant only: Session#initialize needs a live Rack env
    Tina4::Swagger
    Tina4::GraphQL
    Tina4::Frond.new(template_dir: Dir.tmpdir)
    Tina4::Container
    Tina4::Events
  end
  [op, nil]
end

BENCHMARKS = {
  "json" => ["JSON Hello World", method(:bench_json)],
  "db_single" => ["Single DB Query", method(:bench_db_single)],
  "db_multi" => ["Multiple DB Queries", method(:bench_db_multi)],
  "template" => ["Template Rendering", method(:bench_template)],
  "json_large" => ["Large JSON Payload", method(:bench_json_large)],
  "plaintext" => ["Plaintext Response", method(:bench_plaintext)],
  "crud" => ["CRUD Cycle", method(:bench_crud)],
  "paginated" => ["Paginated Query", method(:bench_paginated)],
  "startup" => ["Framework Startup", method(:bench_startup)]
}.freeze

# ── Runner ─────────────────────────────────────────────────────

def run_benchmark(name)
  label, fn = BENCHMARKS[name]
  op, teardown = fn.call

  # Startup is one-shot: looping it would time already-resolved constant lookups
  # rather than boot work.
  if name == "startup"
    start = now
    op.call
    elapsed = now - start
    teardown&.call
    puts format("  %-25s %13s %13s   1 run, in-process (%.3fs)", label, "-", "-", elapsed)
    return elapsed
  end

  # Warm-up doubles as batch-size calibration. It must be a LOOP, and it runs
  # TWICE keeping the second pass: one pass still pays the cold costs (first-call
  # requires, lazily-built caches). In the PHP twin a single 64-op pass read JSON
  # Hello World at ~50us/op against a real ~375ns, inflating the estimate 130x
  # and collapsing the batch back to 1.
  calibration_ops = 64
  one = 1e-9
  2.times do
    c0 = now
    calibration_ops.times { op.call }
    one = [(now - c0) / calibration_ops, 1e-9].max
  end

  # Sample in BATCHES sized so a batch costs >= ~50us. Two reasons:
  #  1. A mean alone hides a fat tail. Measured in the Python master, the CRUD
  #     cycle has a ~108us median but ONE op per run costs ~711ms (a SQLite
  #     flush), dragging mean throughput from ~9,300 to ~1,350 ops/sec -- a
  #     mean-only line understates CRUD 7x.
  #  2. Timing every single op distorts the fastest benchmarks, where the clock
  #     reads cost the same order as the work. Batching amortises them away.
  batch = [[(5e-5 / one).to_i, 1].max, 10_000].min

  batches = []
  iterations = 0
  start = now
  loop do
    b0 = now
    batch.times { op.call }
    batches << (now - b0) / batch
    iterations += batch
    break if iterations >= MIN_ITERATIONS && (now - start) >= MIN_SECONDS
  end
  elapsed = now - start

  teardown&.call

  # p50 is the HEADLINE, mean is secondary. Across repeat runs on one host the
  # mean for JSON Hello World swung 215k -> 630k ops/sec (3x) in the Python
  # master while p50 held at 774k-792k: the mean absorbs scheduler/GC/flush
  # stalls, p50 does not. A figure that moves 3x run-to-run cannot support a
  # comparative claim, so the stable statistic leads and the gap to the mean
  # shows the tail.
  p50 = [batches.sort[batches.length / 2], 1e-9].max
  puts format("  %-25s %13s %13s   %sx%d", label,
              commafy(1 / p50), commafy(iterations / elapsed),
              commafy(iterations), batch)
  elapsed
end

# ── Real startup cost ──────────────────────────────────────────
#
# Require cost is per-PROCESS, so it can only be measured by spawning fresh
# interpreters. This is where Ruby's Module#autoload laziness shows up;
# per-request throughput is unaffected by it.

LIB = File.expand_path("../lib", __dir__)

STARTUP_SNIPPETS = {
  "bare ruby" => "nil",
  "require tina4" => 'require "tina4"',
  "core surface used" => 'require "tina4"; Tina4::Router; Tina4::HTTP_OK; Tina4::RackApp',
  "+ one lazy feature" => 'require "tina4"; Tina4::Queue',
  # Every autoloaded constant -- the worst case, equivalent to an eager barrel.
  # Read from Module#autoload? itself so the list cannot drift from the code.
  "+ every lazy feature" =>
    'require "tina4"; Tina4.constants.select { |c| Tina4.autoload?(c) }.each { |c| Tina4.const_get(c) }'
}.freeze

def measure_startup(runs = 10)
  require "open3"

  puts format("\n  Startup cost - fresh interpreter, best of %d\n", runs)
  puts format("  %-24s %9s %9s", "Scenario", "Best", "Files")
  puts "  #{'-' * 45}"

  baseline = nil
  STARTUP_SNIPPETS.each do |label, snippet|
    # One untimed warm-up per scenario. Without it the FIRST row pays the
    # cold-file-cache cost for every .rb it touches and can read higher than a
    # strictly-larger scenario measured after it -- a nonsense ordering that
    # makes the whole table untrustworthy.
    Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", snippet)

    best = nil
    failed = false
    runs.times do
      start = now
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", snippet)
      elapsed = now - start
      unless status.success?
        puts format("  %-24s  FAILED: %s", label, err.to_s.strip[0, 60])
        failed = true
        break
      end
      best = best.nil? ? elapsed : [best, elapsed].min
    end
    next if failed || best.nil?

    files, = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e",
                            "#{snippet}; puts $LOADED_FEATURES.size")
    files = files.to_s.strip
    files = "?" if files.empty?

    if baseline.nil?
      baseline = best
      delta = ""
    else
      delta = format("  (+%.1fms over bare)", (best - baseline) * 1000)
    end
    puts format("  %-24s %7.1fms %9s%s", label, best * 1000, files, delta)
  end
  puts
end

# ── Carbon (SCI) via the real Carbonah CLI ─────────────────────

def measure_carbon(selected)
  require "open3"

  carbonah = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                        .map { |p| File.join(p, "carbonah") }
                        .find { |p| File.executable?(p) }
  if carbonah.nil?
    puts "\n  carbonah not on PATH - skipping SCI measurement."
    puts "  Install it (https://carbonah.dev) and re-run with --carbon.\n\n"
    return
  end

  region = ENV["CARBONAH_REGION"] || "ZA"
  puts format("\n  Software Carbon Intensity via Carbonah (region %s)\n", region)
  puts format("  %-25s %11s %7s %13s", "Benchmark", "gCO2e/run", "Grade", "Energy kWh")
  puts "  #{'-' * 60}"

  script = File.expand_path(__FILE__)
  selected.each do |name|
    next unless BENCHMARKS.key?(name)

    label = BENCHMARKS[name][0]
    out, err, = Open3.capture3(carbonah, "measure", "--format", "json", "--region", region,
                               "--", RbConfig.ruby, script, "--single", name)
    # carbonah prints a progress line before the JSON body.
    brace = out.index("{")
    if brace.nil?
      puts format("  %-25s  no JSON from carbonah: %s", label, err.to_s.strip[0, 40])
      next
    end
    begin
      d = JSON.parse(out[brace..])
    rescue JSON::ParserError
      puts format("  %-25s  unparseable carbonah output", label)
      next
    end
    measured = d["energy_measured"] ? "" : "  (modelled)"
    puts format("  %-25s %11.6f %7s %13.3e%s",
                label, d["value"], d["grade"], d["energy_kwh"], measured)
  end
  puts "\n  'modelled' means Carbonah had no hardware energy counter on this"
  puts "  platform and derived energy from duration x grid intensity. Treat"
  puts "  those as comparative, not absolute.\n\n"
end

# ── Entry point ────────────────────────────────────────────────

args = ARGV

# --single runs ONE benchmark bare, with no reporting: this is the form
# `carbonah measure` wraps, so the SCI reflects the benchmark and not the
# printing around it.
if (i = args.index("--single"))
  run_only = args[i + 1]
  # Benchmarks return [op, teardown]; carbonah needs a FIXED amount of work
  # rather than a fixed duration, so run the op ITERATIONS times.
  op, teardown = BENCHMARKS.fetch(run_only)[1].call
  if run_only == "startup"
    op.call
  else
    ITERATIONS.times { op.call }
  end
  teardown&.call
  exit 0
end

want_carbon = args.include?("--carbon")
want_startup = args.include?("--startup")
selected = args.reject { |a| a.start_with?("--") }
selected = BENCHMARKS.keys if selected.empty?

puts format("\nTina4 v3 Carbon Benchmarks (Ruby) - >=%ss / >=%d iterations per test\n\n",
            MIN_SECONDS, MIN_ITERATIONS)
puts format("  %-25s %13s %13s   %s", "Benchmark", "p50 ops/sec", "mean ops/sec", "samples")
puts "  #{'-' * 72}"

total = 0.0
selected.each do |name|
  if BENCHMARKS.key?(name)
    total += run_benchmark(name)
  else
    puts "  Unknown benchmark: #{name}"
  end
end

puts format("\n  Total: %.3fs", total)

measure_startup if want_startup
measure_carbon(selected) if want_carbon

unless want_startup || want_carbon
  puts "\n  --startup  measure real per-process require cost (fresh interpreters)"
  puts "  --carbon   measure Software Carbon Intensity via the Carbonah CLI\n\n"
end
