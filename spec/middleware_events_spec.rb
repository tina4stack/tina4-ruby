# frozen_string_literal: true

require "spec_helper"
require_relative "support/real_log_capture"

# Lock-in regression guards for E1 + M1 + M2 (visible-but-resilient
# middleware + events). Mirrors tina4-python/tests/test_middleware_events.py
# so behaviour stays byte-identical across Python / PHP / Ruby / Node.
#
#   E1 — a throwing event listener must NOT abort the rest of emit().
#   M1 — middleware run in DEFINITION / REGISTRATION order, not alphabetical.
#   M2 — a throwing middleware → logged clean 500; after_* run on 4xx short-circuit.

# ---------------------------------------------------------------------------
# E1 — Event listener isolation
# ---------------------------------------------------------------------------
RSpec.describe "TestEventListenerIsolation (E1)" do
  before(:each) { Tina4::Events.clear }
  after(:each)  { Tina4::Events.clear }

  it "middle listener throws — first and third still run, no raise, surviving results returned" do
    ran = []
    Tina4::Events.on("evt", priority: 30) { ran << "first"; "r1" }
    Tina4::Events.on("evt", priority: 20) { ran << "boom"; raise "kaboom" }
    Tina4::Events.on("evt", priority: 10) { ran << "third"; "r3" }

    results = nil
    expect { results = Tina4::Events.emit("evt") }.not_to raise_error

    # 1st and 3rd STILL ran in priority order despite the middle throw.
    expect(ran).to eq(%w[first boom third])
    # N listeners always yield N results in priority order; failed slot is nil.
    expect(results).to eq(["r1", nil, "r3"])
  end

  it "error is logged — never silent" do
    # NO double. The REAL Tina4::Log writes through its real formatter to a real
    # file; we assert on the real bytes an operator would grep. A message
    # expectation here would REPLACE Log.warning, so a regression that formats
    # the line wrongly, filters it out by level, or never reaches a sink would
    # still pass.
    text = capture_real_log do
      Tina4::Events.on("evt") { raise "kaboom" }
      Tina4::Events.emit("evt")
    end

    expect(text).to include("evt")          # the event name
    expect(text).to include("RuntimeError") # the error class
    expect(text).to include("kaboom")       # the error message
    expect(text).to match(/WARNING/i)       # emitted at WARNING, really
  end

  it "strict: true re-raises on the first error and stops" do
    ran = []
    Tina4::Events.on("evt", priority: 30) { ran << "boom"; raise "kaboom" }
    Tina4::Events.on("evt", priority: 10) { ran << "third"; "r3" }

    expect { Tina4::Events.emit("evt", strict: true) }.to raise_error(RuntimeError, /kaboom/)
    # Later listeners do NOT run under strict.
    expect(ran).to eq(%w[boom])
  end

  it "non-throwing listeners are unchanged" do
    Tina4::Events.on("calc") { 1 }
    Tina4::Events.on("calc") { 2 }
    expect(Tina4::Events.emit("calc")).to eq([1, 2])
  end

  it "emit_async isolates each listener (one rejection does not abort the others)" do
    ran = Queue.new
    Tina4::Events.on("async", priority: 30) { ran << "a1"; "a1" }
    Tina4::Events.on("async", priority: 20) { ran << "boom"; raise "kaboom" }
    Tina4::Events.on("async", priority: 10) { ran << "a3"; "a3" }

    threads = nil
    expect { threads = Tina4::Events.emit_async("async") }.not_to raise_error
    threads.each(&:join)

    drained = []
    drained << ran.pop until ran.empty?
    expect(drained).to contain_exactly("a1", "boom", "a3")
  end

  it "emit_async strict: true re-raises the listener error on join" do
    Tina4::Events.on("async") { raise "kaboom" }
    threads = Tina4::Events.emit_async("async", strict: true)
    expect { threads.each(&:join) }.to raise_error(RuntimeError, /kaboom/)
  end
end

# ---------------------------------------------------------------------------
# M1 — Middleware definition / registration order
# ---------------------------------------------------------------------------
RSpec.describe "TestMiddlewareDefinitionOrder (M1)" do
  before(:each) { Tina4::Middleware.clear! }
  after(:each)  { Tina4::Middleware.clear! }

  # before_zulu / before_mike / before_alpha defined in THAT order — discovery
  # must return them in definition order, which is provably != alphabetical.
  let(:ordered_class) do
    Class.new do
      class << self
        def before_zulu(req, resp);  [req, resp]; end
        def before_mike(req, resp);  [req, resp]; end
        def before_alpha(req, resp); [req, resp]; end

        def after_zulu(req, resp);  [req, resp]; end
        def after_mike(req, resp);  [req, resp]; end
        def after_alpha(req, resp); [req, resp]; end
      end
    end
  end

  it "within-class before_* discovery is definition order, not alphabetical" do
    names = Tina4::Middleware.send(:before_methods_for, ordered_class).map(&:to_s)
    expect(names).to eq(%w[before_zulu before_mike before_alpha])
    expect(names).not_to eq(names.sort) # provably NOT alphabetical
  end

  it "within-class after_* discovery is also definition order" do
    names = Tina4::Middleware.send(:after_methods_for, ordered_class).map(&:to_s)
    expect(names).to eq(%w[after_zulu after_mike after_alpha])
    expect(names).not_to eq(names.sort)
  end

  it "dispatch runs before_* in definition order (end-to-end via run_before)" do
    order = []
    klass = Class.new do
      define_singleton_method(:order_sink) { order }
      class << self
        def before_zulu(req, resp);  order_sink << :zulu;  [req, resp]; end
        def before_mike(req, resp);  order_sink << :mike;  [req, resp]; end
        def before_alpha(req, resp); order_sink << :alpha; [req, resp]; end
      end
    end

    req  = make_request("GET", "/api/order")
    resp = Tina4::Response.new
    Tina4::Middleware.run_before([klass], req, resp)

    expect(order).to eq(%i[zulu mike alpha])
  end

  def make_request(method, path)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new(""),
    }
    Tina4::Request.new(env)
  end
end

# ---------------------------------------------------------------------------
# M1 — Registration order (Node index-skip parity guard): N middleware all run
# exactly once, in registration order — none skipped.
# ---------------------------------------------------------------------------
RSpec.describe "TestMiddlewareRegistrationOrder (M1)" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end
  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  it "N=5 function-style middleware all run exactly once, in order (no skip)" do
    trace = []
    order = %i[m0 m1 m2 m3 m4]
    mws = order.map do |tag|
      lambda do |req, resp, nxt|
        trace << tag
        nxt.call(req, resp)
      end
    end

    route = Tina4::Router.get("/api/chain") { |_req, resp| resp.json({ ok: true }) }
    route.middleware(*mws)

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => "/api/chain",
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new(""),
    }
    status, = Tina4::RackApp.new.call(env)

    expect(status).to eq(200)
    expect(trace).to eq(order)                 # exact registration order
    expect(trace.length).to eq(trace.uniq.length) # each runs exactly once (none skipped)
  end
end

# ---------------------------------------------------------------------------
# M2 — Middleware throw → clean 500 (logged); after_* on 4xx short-circuit
# ---------------------------------------------------------------------------
RSpec.describe "TestMiddlewareThrow (M2)" do
  before(:each) { Tina4::Middleware.clear! }
  after(:each)  { Tina4::Middleware.clear! }

  def make_request(method = "GET", path = "/api/x")
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO"      => path,
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new(""),
    }
    Tina4::Request.new(env)
  end

  it "before_* throw yields a clean 500, skips the handler, and is logged" do
    boom = Class.new do
      class << self
        def before_boom(_req, _resp); raise "kaboom"; end
      end
    end
    # Give the anonymous class a stable name for the log label.
    Object.const_set(:BoomMw, boom) unless defined?(BoomMw)

    req  = make_request
    resp = Tina4::Response.new
    halted = nil

    # NO double: the REAL logger writes to a real file through its real
    # formatter, and we grep the real bytes.
    text = capture_real_log do
      halted = Tina4::Middleware.run_before([BoomMw], req, resp)
    end

    expect(text).to include("before_boom")  # the method label
    expect(text).to include("RuntimeError") # the error class
    expect(text).to include("kaboom")       # the error message

    expect(halted).to be false # handler skipped
    expect(resp.status_code).to eq(500)
    expect(resp.body).to include("Internal Server Error")
    expect(JSON.parse(resp.body)).to eq({ "error" => "Internal Server Error", "status" => 500 })
  ensure
    Object.send(:remove_const, :BoomMw) if defined?(BoomMw)
  end

  it "after_* throw yields a clean 500 but the remaining after_* still run" do
    ran = []

    klass = Class.new do
      define_singleton_method(:trace) { ran }
      class << self
        def after_boom(_req, _resp); trace << :boom; raise "kaboom"; end
        def after_log(req, resp);    trace << :log; [req, resp]; end
      end
    end

    req  = make_request
    resp = Tina4::Response.new
    logged = capture_real_log do
      expect { Tina4::Middleware.run_after([klass], req, resp) }.not_to raise_error
    end

    # The throwing after_* did NOT abort the pass — BOTH after_* still ran
    # (one throws, the rest continue). Within-class definition order itself is
    # locked separately by TestMiddlewareDefinitionOrder; here we only assert
    # M2's contract: throw is isolated + logged + clean 500.
    expect(ran).to contain_exactly(:boom, :log)
    expect(logged).to include("RuntimeError") # the throw was logged, never silent (real file)
    expect(resp.status_code).to eq(500)            # clean 500 from the throwing after_*
    expect(JSON.parse(resp.body)).to eq({ "error" => "Internal Server Error", "status" => 500 })
  end
end

# ---------------------------------------------------------------------------
# M2 — AFTER-ON-4xx rule: after_* run even when before_* short-circuits 4xx
# ---------------------------------------------------------------------------
RSpec.describe "TestAfterOn4xxRule (M2)" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end
  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
  end

  it "after_* runs (adds a header) even when a before_* short-circuits with 403" do
    gate = Class.new do
      class << self
        # before_gate forbids the request (handler skipped).
        def before_gate(req, resp)
          resp.json({ error: "forbidden" }, 403)
          [req, resp]
        end

        # after_headers must still run on the 4xx short-circuit path.
        def after_headers(req, resp)
          resp.add_header("x-audited", "yes")
          [req, resp]
        end
      end
    end

    Tina4::Router.use(gate)
    Tina4::Router.get("/api/gated") { |_req, resp| resp.json({ ok: true }) }

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO"      => "/api/gated",
      "QUERY_STRING"   => "",
      "HTTP_HOST"      => "localhost",
      "rack.input"     => StringIO.new(""),
    }
    status, headers, _body = Tina4::RackApp.new.call(env)

    expect(status).to eq(403)               # before_gate short-circuited
    expect(headers["x-audited"]).to eq("yes") # after_headers STILL ran
  end
end
