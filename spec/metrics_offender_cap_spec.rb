# frozen_string_literal: true

# Regression: the metrics offenders list must NOT be capped to the top-15
# most-complex functions.
#
# Latent bug (fixed): full_analysis returned most_complex_functions.first(15) and
# offenders() sourced the complexity offenders from that capped list, so the 16th+
# function over the complexity threshold was silently dropped from the offenders
# list, the total_offenders count, AND the --fail-on gate — a genuinely
# too-complex function escaped the build gate. offenders() now reads the full
# "all_functions" list; most_complex_functions.first(15) stays for the display
# report only.
#
# No mocks: writes a real .rb file and runs the real analyzer over it. Mirrors
# the Python master regression tests/test_metrics_offender_cap.py.

require "spec_helper"
require "tina4/metrics"
require "tmpdir"
require "fileutils"

RSpec.describe "Tina4::Metrics offenders complexity cap" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  # full_analysis caches for 60s keyed on file mtimes; reset so a fresh temp
  # dir is always re-analyzed (mirrors the Python autouse cache-reset fixture).
  before do
    Tina4::Metrics.instance_variable_set(:@full_cache_hash, "")
    Tina4::Metrics.instance_variable_set(:@full_cache_data, nil)
    Tina4::Metrics.instance_variable_set(:@full_cache_time, 0)
    Tina4::Metrics.instance_variable_set(:@last_scan_root, "")
  end

  # `decisions` independent `if` statements -> cyclomatic complexity = 1 + decisions.
  # 22 -> CC 23 (> 20 => "error" severity).
  def high_cc_function(name, decisions = 22)
    body = (0...decisions).map { |j| "  if #{j} == #{j}\n    x = #{j}\n  end" }.join("\n")
    "def #{name}\n#{body}\nend\n"
  end

  def write_big_module(count)
    src = (0...count).map { |i| high_cc_function("fn#{i}") }.join("\n")
    File.write(File.join(@root, "bigmod.rb"), src)
  end

  it "surfaces every over-threshold function, not just the top 15" do
    n = 18 # > 15, so the old first(15) cap would silently drop fn15..fn17
    write_big_module(n)

    result = Tina4::Metrics.offenders(@root, 100)
    complexity = result["offenders"].select { |o| o["kind"] == "complexity" }

    # All 18 over-threshold functions must surface (old code: exactly 15).
    expect(complexity.length).to eq(n)
    # They are error-severity (CC 23 > 20) and therefore MUST reach --fail-on error.
    expect(complexity).to all(include("severity" => "error"))
    expect(result["summary"]["total_offenders"]).to be >= n
  end

  it "still caps the display-only most_complex_functions report at 15" do
    write_big_module(18)

    analysis = Tina4::Metrics.full_analysis(@root)
    expect(analysis["most_complex_functions"].length).to eq(15) # display cap intact
    expect(analysis).not_to have_key("all_functions")            # the engine owns the ranking now
      # total_offenders is the honest proof nothing was lost at the display cap.
      uncapped = Tina4::Metrics.offenders(@root, 2**31)
      expect(uncapped["summary"]["total_offenders"]).to be >= 18
      expect(uncapped["offenders"].length).to be >= 18
  end
end
