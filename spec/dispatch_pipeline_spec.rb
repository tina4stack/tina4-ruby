# frozen_string_literal: true

require "spec_helper"
require "json"

# The dispatch pipeline CONTRACT (feature 6, group B).
#
# The characterisation suite proves the extraction changed no behaviour. This
# suite proves the extraction STAYS extracted. A refactor with no gate regrows:
# the next person to inline a stage should get a red test, not a slightly worse
# number in a report nobody reads.
#
# Every assertion here is derived from the code or from `tina4 metrics`, never
# from a hand-maintained copy of the answer - a list duplicated into a test
# drifts from the list it is meant to guard.
RSpec.describe "Dispatch pipeline contract" do
  let(:app) { Tina4::RackApp.new(root_dir: Dir.pwd) }

  ALL_STAGES = (Tina4::DispatchPipeline::REQUEST_STAGES +
                Tina4::DispatchPipeline::RESPONSE_STAGES +
                Tina4::DispatchPipeline::ROUTE_STAGES).freeze

  # ── The stage list is DATA ───────────────────────────────────────

  it "the pipeline declares its stages in order" do
    expect(Tina4::DispatchPipeline::REQUEST_STAGES).to eq(%i[
      reset_request_caches
      cors_preflight
      websocket_upgrade
      dev_routes
      feedback_routes
      global_middleware_pre
      match_route
      method_not_allowed
      not_found
    ])
    expect(Tina4::DispatchPipeline::RESPONSE_STAGES).to eq(%i[
      head_strip
      dev_inspector_capture
      request_log
      dev_toolbar_inject
      feedback_inject
      session_save
    ])
    expect(Tina4::DispatchPipeline::ROUTE_STAGES).to eq(%i[
      prepare_route_request
      global_middleware_post
      route_auth_handler
      route_auth_gate
      route_middleware
    ])
  end

  # NEGATIVE: a name in the list with no method behind it, or a stage
  # quietly deleted, must fail here rather than at 3am on a real request.
  it "has no unnamed stage" do
    ALL_STAGES.each do |stage|
      expect(app.respond_to?(stage, true)).to be(true),
                                              "stage #{stage} is listed but not defined"
    end
  end

  it "keeps every stage private" do
    # A stage is an internal step, not public API. If one leaks into the public
    # surface it becomes something callers depend on and the list stops being
    # the only thing that decides ordering.
    ALL_STAGES.each do |stage|
      expect(app.respond_to?(stage)).to be(false),
                                        "stage #{stage} is PUBLIC - stages are internals"
    end
  end

  # ── Isolation: a stage takes a context, not #call's locals ───────

  it "each stage is callable on its own" do
    # The whole point of the context struct: a stage needs a context and
    # nothing else. Arity proves it - a stage reaching for another local would
    # need another parameter.
    Tina4::DispatchPipeline::REQUEST_STAGES.each do |stage|
      expect(app.method(stage).arity).to eq(1), "#{stage} should take (ctx)"
    end
    Tina4::DispatchPipeline::RESPONSE_STAGES.each do |stage|
      expect(app.method(stage).arity).to eq(2), "#{stage} should take (ctx, response)"
    end
    Tina4::DispatchPipeline::ROUTE_STAGES.each do |stage|
      expect(app.method(stage).arity).to eq(1), "#{stage} should take (ctx)"
    end
  end

  # NEGATIVE: ordering lives in the lists. A stage calling another stage
  # directly hides an edge the list does not show, which is exactly the
  # coupling the extraction removed (the 404 chain used to be nested calls
  # inside match_route).
  it "a stage does not reach into another stage" do
    source = File.read(File.join(__dir__, "..", "lib", "tina4", "dispatch_pipeline.rb"),
                       encoding: "UTF-8")
    bodies = source.split(/^    def /)[1..] || []

    offenders = bodies.flat_map do |body|
      name = body[/\A(\w+)/, 1]&.to_sym
      next [] unless ALL_STAGES.include?(name)

      (ALL_STAGES - [name]).select { |other| body.match?(/(?<![.\w:])#{other}\(/) }
                           .map { |other| "#{name} calls #{other}" }
    end

    expect(offenders).to be_empty,
                         "ordering must live in the stage lists, not in calls between stages: " \
                         "#{offenders.join(', ')}"
  end

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
