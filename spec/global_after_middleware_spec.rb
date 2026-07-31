# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# A global middleware's after_* hooks MUST run, for BOTH phases.
#
# Ruby already behaved correctly; this LOCKS IT IN, because Node and Python did
# not. There the after pass covered only the POST-match group, so a pre-match
# middleware's after_* never ran on a successful request - measured 0 runs in 5
# requests. An acquire/release pair leaked one slot per request, unbounded.
#
# It also inverted: the pre-match after_* DID run when the pre-match pass
# short-circuited, so it fired on the error path and not the happy one.
#
# Splitting the BEFORE pass by dependency (ADR-0012) says nothing about the
# after pass: an after hook adds headers or logging and needs no route metadata
# either way.
#
# NO MOCKS: a real RackApp over a real temp directory, real routes.
#
# Same case names in all four frameworks.
RSpec.describe "Global after-hook coverage" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_after_hooks") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.instance_variable_set(:@global_middleware, [])
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    Tina4::Router.get("/hello") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.instance_variable_set(:@global_middleware, [])
    FileUtils.rm_rf(tmp_dir)
  end

  def call(method, path)
    env = {
      "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147", "rack.input" => StringIO.new("")
    }
    app.call(env)
  end

  # Acquire in before, release in after - the pair that leaked elsewhere.
  def tracking_middleware(pre_match:, counters:)
    Class.new do
      define_singleton_method(:pre_match?) { pre_match }
      define_singleton_method(:before_acquire) do |req, res|
        counters[:in_flight] += 1
        [req, res]
      end
      define_singleton_method(:after_release) do |req, res|
        counters[:in_flight] -= 1
        counters[:runs] += 1
        [req, res]
      end
    end
  end

  it "a global after hook runs on a matched route" do
    counters = { in_flight: 0, runs: 0 }
    Tina4::Middleware.use(tracking_middleware(pre_match: false, counters: counters))

    status, _h, _b = call("GET", "/hello")
    expect(status).to eq(200)
    expect(counters[:runs]).to eq(1)
  end

  it "a pre match middlewares after hook also runs" do
    counters = { in_flight: 0, runs: 0 }
    Tina4::Middleware.use(tracking_middleware(pre_match: true, counters: counters))

    call("GET", "/hello")
    expect(counters[:runs]).to eq(1),
                              "a pre-match middleware was excluded from the after pass - " \
                              "the ADR-0012 split applies to the BEFORE pass only"
  end

  it "an acquire release pair stays balanced" do
    # The implication, asserted directly. This is what made the bug serious
    # rather than cosmetic elsewhere: the imbalance grew by one per request,
    # without bound, and nothing errored.
    counters = { in_flight: 0, runs: 0 }
    Tina4::Middleware.use(tracking_middleware(pre_match: true, counters: counters))

    5.times { call("GET", "/hello") }

    expect(counters[:runs]).to eq(5)
    expect(counters[:in_flight]).to eq(0),
                                   "acquire/release leaked #{counters[:in_flight]} slots over 5 requests"
  end

  it "a global after hook does not run on an unmatched path" do
    counters = { in_flight: 0, runs: 0 }
    Tina4::Middleware.use(tracking_middleware(pre_match: false, counters: counters))

    status, _h, _b = call("GET", "/no/such/route")
    expect(status).to eq(404)
    expect(counters[:runs]).to eq(0)
  end
end
