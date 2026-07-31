# frozen_string_literal: true

require "spec_helper"
require "json"

# The dispatch pipeline's COMPLEXITY gate (feature 6, group B).
#
# Split out of spec/dispatch_pipeline_spec.rb, which keeps the assertions that
# need nothing but the source: the stage lists, that every listed stage exists
# and is private, and that no stage calls another.
#
# These two need the tina4 Rust CLI on PATH. Metrics is measured by the NATIVE
# engine (ADR-0002) with no in-framework fallback, so CI cannot run them - the
# workflow excludes `**/metrics*_spec.rb`, which is why this file is named that
# way. The engine is tested where it lives, tina4stack/tina4 src/metrics.rs,
# exercised by `cargo test` in its own pipeline.
#
# They run locally for anyone with the CLI installed, which is where a refactor
# that regrows a god-function gets caught.
RSpec.describe "Dispatch pipeline complexity gate" do
  # ── The complexity gate — the thing that keeps this fixed ────────

  it "no dispatch function exceeds complexity ten" do
    # Asserted from `tina4 metrics`, the same tool the CI gate uses, so this
    # cannot rot into a stale hand-written number.
    report = metrics_for("lib/tina4/dispatch_pipeline.rb")
    over = report["offenders"].select { |o| o["kind"] == "complexity" }

    expect(over).to be_empty,
                    "dispatch stages over the complexity ceiling: " \
                    "#{over.map { |o| o['detail'] }.join('; ')}"
  end

  it "the god function does not come back" do
    # #call and #handle_route were 53 and 24. They live in rack_app.rb, so this
    # asserts against THAT file - the extraction is only real while they stay
    # small.
    report = metrics_for("lib/tina4/rack_app.rb")
    regrown = report["offenders"].select do |o|
      o["kind"] == "complexity" && o["detail"].match?(/\.(call|handle_route) /)
    end

    expect(regrown).to be_empty,
                       "a dispatch god-function regrew: #{regrown.map { |o| o['detail'] }.join('; ')}"
  end

  # Shell out to the SAME `tina4 metrics` the CI gate uses, so the ceiling
  # asserted here cannot drift from the one that gates a release.
  #
  # It must run OUTSIDE bundler. Under `bundle exec`, bundler intercepts the
  # `tina4` name, tries to resolve it as a binstub of the tina4ruby gem, and
  # dies with "can't find executable tina4 for gem tina4ruby". With stderr
  # discarded that looked exactly like "not installed", so both complexity
  # gates silently went pending and asserted nothing - a skip is not
  # verification.
  def metrics_for(relative_path)
    command = "tina4 metrics --json --path #{relative_path}"
    output = if defined?(Bundler)
               Bundler.with_unbundled_env { `#{command} 2>&1` }
             else
               `#{command} 2>&1`
             end

    unless output.lstrip.start_with?("{")
      raise "tina4 metrics did not return JSON - the complexity gate cannot be " \
            "asserted. Install the tina4 CLI. Got: #{output.lines.first&.strip}"
    end
    JSON.parse(output)
  end

end
