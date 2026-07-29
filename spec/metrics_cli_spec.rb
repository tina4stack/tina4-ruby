# frozen_string_literal: true

# Lock-in tests for `tina4ruby metrics` — the offenders() analyzer and the CLI
# handler (cmd_metrics). Engine/CLI-agnostic: builds throwaway projects on disk,
# runs the real analyzer + the real CLI handler, and asserts on the structured
# offenders list, the --json shape, --top truncation, the "clean" path, every
# --fail-on exit-code branch, AND the precise test-detection fix (a file with no
# dedicated test reports untested; a file a spec really requires reports tested).
#
# These guard against silent drift in the scoring rules, the exit-code contract,
# and the has_tests precision.

require "spec_helper"
require "tina4/cli"
require "tina4/metrics"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "tina4ruby metrics" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      Dir.chdir(dir) { example.run }
    end
  end

  # full_analysis caches for 60s keyed on file mtimes; tmp dirs are fresh per
  # test so the hash differs, but reset explicitly to be safe (mirrors the
  # Python autouse fixture).
  before do
    Tina4::Metrics.instance_variable_set(:@full_cache_hash, "")
    Tina4::Metrics.instance_variable_set(:@full_cache_data, nil)
    Tina4::Metrics.instance_variable_set(:@full_cache_time, 0)
    Tina4::Metrics.instance_variable_set(:@last_scan_root, "")
  end

  def write(path, content = "")
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  # A function whose cyclomatic complexity exceeds 20 (an 'error' offender).
  # CC = 1 + one decision point per `if`. 25 ifs → CC 26.
  def bad_function_source(name = "messy", branches = 25)
    lines = ["def #{name}(x)"]
    branches.times { |i| lines << "  return #{i} if x == #{i}" }
    lines << "  -1"
    lines << "end"
    lines.join("\n") + "\n"
  end

  # A file with > 500 lines of code (a 'large_file' warn offender).
  def huge_file_source(loc = 600)
    (0...loc).map { |i| "a#{i} = #{i}" }.join("\n") + "\n"
  end

  # Lay down a src/ tree with a deliberately bad, untested module.
  def write_bad_project
    bad = bad_function_source + "\n" + huge_file_source
    write("src/bad.rb", bad)
  end

  # A tiny, simple, tested src/ tree → zero offenders.
  def write_clean_project
    write("src/clean.rb", "def add(a, b)\n  a + b\nend\n")
    # A precise referencing spec so has_tests is true (not 'untested').
    write("spec/clean_spec.rb", "require_relative \"../src/clean\"\n\nRSpec.describe \"add\" do; end\n")
  end

  # Run cmd_metrics, capturing stdout and the SystemExit status.
  def run_metrics(args)
    cli = Tina4::CLI.new
    out = +""
    status = nil
    orig = $stdout
    $stdout = StringIO.new
    begin
      cli.run(["metrics", *args])
      status = 0
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      $stdout = orig
    end
    [out, status]
  end

  # ── offenders() — positive ────────────────────────────────────────────

  describe ".offenders (positive)" do
    it "surfaces each offender kind for a bad project" do
      write_bad_project
      offenders = Tina4::Metrics.offenders("src", 50)["offenders"]
      kinds = offenders.map { |o| o["kind"] }.uniq

      expect(kinds).to include("complexity"), "over-20 CC function must be flagged"
      expect(kinds).to include("large_file"), ">500 LOC file must be flagged"
      expect(kinds).to include("untested"), "module with no referencing test must be flagged"

      complexity = offenders.find { |o| o["kind"] == "complexity" }
      expect(complexity["severity"]).to eq("error")
      expect(complexity["score"]).to be > 20
      expect(complexity["detail"].downcase).to include("complexity")

      large = offenders.find { |o| o["kind"] == "large_file" }
      expect(large["severity"]).to eq("warn")
      expect(large["detail"]).to include("LOC")

      untested = offenders.find { |o| o["kind"] == "untested" }
      expect(untested["severity"]).to eq("info")
    end

    it "gives each offender the required keys" do
      write_bad_project
      Tina4::Metrics.offenders("src", 50)["offenders"].each do |o|
        expect(o.keys).to include("file", "line", "kind", "severity", "score", "detail")
      end
    end

    it "ranks error before warn before info" do
      write_bad_project
      offenders = Tina4::Metrics.offenders("src", 50)["offenders"]
      # The rank lives in the engine now; state it here so the ordering contract
      # is asserted against a value this spec owns, not one it imports.
      rank = { "error" => 2, "warn" => 1, "info" => 0 }
      ranks = offenders.map { |o| rank.fetch(o["severity"]) }
      expect(ranks).to eq(ranks.sort.reverse), "must be severity-descending"
      expect(offenders.first["severity"]).to eq("error")
    end

    it "surfaces a low_maintainability offender when MI is low" do
      # The bad project's huge+complex file drives maintainability well under 40.
      write_bad_project
      offenders = Tina4::Metrics.offenders("src", 50)["offenders"]
      low = offenders.find { |o| o["kind"] == "low_maintainability" }
      expect(low).not_to be_nil
      expect(%w[warn error]).to include(low["severity"])
      expect(low["detail"]).to include("maintainability index")
    end

    it "surfaces a too_many_functions offender for a file with > 20 functions" do
      body = (0...25).map { |i| "def f#{i}\n  #{i}\nend\n" }.join("\n")
      write("src/many.rb", body)
      offenders = Tina4::Metrics.offenders("src", 50)["offenders"]
      tmf = offenders.find { |o| o["kind"] == "too_many_functions" }
      expect(tmf).not_to be_nil
      expect(tmf["severity"]).to eq("warn")
      expect(tmf["score"]).to eq(25 / 4.0)
    end

    it "carries the headline numbers in summary" do
      write_bad_project
      summary = Tina4::Metrics.offenders("src", 5)["summary"]
      expect(summary["files_analyzed"]).to be >= 1
      expect(summary["total_offenders"]).to be >= 3
      expect(summary).to have_key("avg_complexity")
      expect(summary).to have_key("avg_maintainability")
      expect(%w[project framework]).to include(summary["scan_mode"])
    end

    it "truncates to the top N" do
      write_bad_project
      expect(Tina4::Metrics.offenders("src", 1)["offenders"].length).to eq(1)
    end
  end

  # ── offenders() — negative ─────────────────────────────────────────────

  describe ".offenders (negative)" do
    it "reports no offenders for a clean, tested project" do
      write_clean_project
      result = Tina4::Metrics.offenders("src", 20)
      expect(result["offenders"]).to eq([])
      expect(result["summary"]["total_offenders"]).to eq(0)
    end

    it "falls back to a framework scan for a missing directory" do
      # Matches the Python master and PHP: a missing target scans the framework
      # package rather than erroring, and scan_mode says so. The engine raises
      # only when it genuinely cannot run (see the MetricsEngineError specs).
      result = Tina4::Metrics.offenders("does_not_exist", 20)
      expect(result["summary"]["scan_mode"]).to eq("framework")
      expect(result["summary"]["engine"]).to eq("tina4-cli")
    end
  end

  # ── detection fix — has_tests precision ────────────────────────────────

  describe "precise has_tests detection" do
    it "reports UNTESTED for a file with no dedicated test (only a bare-word parent-dir mention)" do
      write("src/database/sqlite_adapter.rb", "class SqliteAdapter\n  def connect; end\nend\n")
      # A blanket parent-dir spec that merely mentions the word loosely — the
      # OLD heuristic marked this tested via parent-dir blanket + bare-word match.
      write("spec/database_spec.rb",
            "# database layer tests, mentions sqlite_adapter loosely\nRSpec.describe \"db\" do; end\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].find { |f| f["path"] == "database/sqlite_adapter.rb" }
      expect(fm["has_tests"]).to eq(false)
    end

    it "reports TESTED for a file a spec actually requires + references its class" do
      write("src/database/mysql_adapter.rb", "class MysqlAdapter\n  def connect; end\nend\n")
      write("spec/mysql_spec.rb",
            "require_relative \"../src/database/mysql_adapter\"\nRSpec.describe MysqlAdapter do; end\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].find { |f| f["path"] == "database/mysql_adapter.rb" }
      expect(fm["has_tests"]).to eq(true)
    end

    it "reports TESTED on a dedicated <module>_spec.rb file (filename match)" do
      write("src/widget.rb", "class Widget\nend\n")
      write("spec/widget_spec.rb", "RSpec.describe \"Widget\" do; end\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].find { |f| f["path"] == "widget.rb" }
      expect(fm["has_tests"]).to eq(true)
    end

    it "does NOT mark a sibling tested just because the parent-dir test names another sibling" do
      write("src/database/sqlite_adapter.rb", "class SqliteAdapter\nend\n")
      write("src/database/mysql_adapter.rb", "class MysqlAdapter\nend\n")
      # Only mysql is genuinely required; sqlite must stay untested.
      write("spec/mysql_spec.rb",
            "require_relative \"../src/database/mysql_adapter\"\nRSpec.describe MysqlAdapter do; end\n")
      result = Tina4::Metrics.full_analysis("src")
      sqlite = result["file_metrics"].find { |f| f["path"] == "database/sqlite_adapter.rb" }
      mysql = result["file_metrics"].find { |f| f["path"] == "database/mysql_adapter.rb" }
      expect(sqlite["has_tests"]).to eq(false)
      expect(mysql["has_tests"]).to eq(true)
    end
  end

  # ── CLI handler — JSON output ──────────────────────────────────────────

  describe "metrics --json" do
    it "prints valid JSON with summary and offenders and only JSON" do
      write_bad_project
      out, status = run_metrics(["--json"])
      expect(status).to eq(0) # default --fail-on absent → exit 0
      parsed = JSON.parse(out) # must be the ONLY thing printed
      expect(parsed).to have_key("summary")
      expect(parsed).to have_key("offenders")
      expect(parsed["summary"]["total_offenders"]).to be >= 3
      expect(parsed["offenders"].length).to be >= 3
    end

    it "honours --top in JSON mode" do
      write_bad_project
      out, = run_metrics(["--json", "--top", "1"])
      parsed = JSON.parse(out)
      expect(parsed["offenders"].length).to eq(1)
    end
  end

  # ── CLI handler — human output ─────────────────────────────────────────

  describe "metrics human report" do
    it "prints a friendly clean line and exits zero for a clean project" do
      write_clean_project
      out, status = run_metrics([])
      expect(status).to eq(0)
      expect(out).to include("no offenders")
    end

    it "lists offenders with header columns" do
      write_bad_project
      out, status = run_metrics([])
      expect(status).to eq(0)
      expect(out).to include("Tina4 Metrics")
      expect(out).to include("SEVERITY")
      expect(out).to include("complexity")
    end
  end

  # ── CLI handler — exit codes (--fail-on) ───────────────────────────────

  describe "metrics --fail-on" do
    it "exits 0 by default even with offenders present" do
      write_bad_project
      _, status = run_metrics(["--json"])
      expect(status).to eq(0)
    end

    it "exits 1 on --fail-on error when an error offender is present" do
      write_bad_project # has an error-severity complexity offender
      _, status = run_metrics(["--json", "--fail-on", "error"])
      expect(status).to eq(1)
    end

    it "exits 1 on --fail-on warn when offenders are present" do
      write_bad_project
      _, status = run_metrics(["--json", "--fail-on", "warn"])
      expect(status).to eq(1)
    end

    it "exits 0 on --fail-on error when only warn/info offenders exist" do
      # 25 trivial functions, untested: offenders are warn (too_many_functions)
      # + info (untested), and small enough that maintainability stays healthy,
      # so NO error offender.
      body = (0...25).map { |i| "def f#{i}\n  #{i}\nend\n" }.join("\n")
      write("src/many.rb", body)
      out, status = run_metrics(["--json", "--fail-on", "error"])
      parsed = JSON.parse(out)
      severities = parsed["offenders"].map { |o| o["severity"] }.uniq
      expect(severities).not_to include("error"), "fixture must produce no error offenders"
      expect(severities & %w[warn info]).not_to be_empty, "fixture must produce warn/info offenders"
      expect(status).to eq(0), "--fail-on error must ignore warn/info"
    end

    it "exits 1 on --fail-on warn when only warn offenders exist" do
      body = (0...25).map { |i| "def f#{i}\n  #{i}\nend\n" }.join("\n")
      write("src/many.rb", body)
      _, status = run_metrics(["--json", "--fail-on", "warn"])
      expect(status).to eq(1)
    end

    it "exits 0 on --fail-on warn for a clean project" do
      write_clean_project
      _, status = run_metrics(["--json", "--fail-on", "warn"])
      expect(status).to eq(0)
    end

    it "exits 2 on an invalid --fail-on value" do
      write_bad_project
      out, status = run_metrics(["--fail-on", "bogus"])
      expect(status).to eq(2)
      expect(out).to include("invalid --fail-on")
    end
  end
end
