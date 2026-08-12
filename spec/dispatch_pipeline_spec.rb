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
                Tina4::DispatchPipeline::ALWAYS_STAGES +
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
    # head_strip is in ALWAYS_STAGES, not RESPONSE_STAGES: RFC 9110 s9.3.2 is
    # not conditional, so it must also cover the swagger and static branches
    # that return early. Moving it back would silently reintroduce a HEAD
    # response carrying a body.
    # apply_cors joined head_strip here (ADR-0018): CORS policy headers must
    # survive a short-circuited 401/403 and the early-returning swagger/static
    # branches, exactly like the HEAD strip. Ruby previously stamped CORS
    # headers on the PREFLIGHT only, so the real response carried none and the
    # browser blocked it.
    # compress_and_tag and conditional_get (feature 40, CE-DEC-01/02) run
    # FIRST - before head_strip - so a HEAD response's preserved
    # Content-Length reflects the (possibly compressed) body the equivalent
    # GET would have sent.
    expect(Tina4::DispatchPipeline::ALWAYS_STAGES).to eq(%i[compress_and_tag conditional_get head_strip apply_cors])
    expect(Tina4::DispatchPipeline::RESPONSE_STAGES).to eq(%i[
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
    (Tina4::DispatchPipeline::ALWAYS_STAGES +
     Tina4::DispatchPipeline::RESPONSE_STAGES).each do |stage|
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
end
