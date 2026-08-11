# frozen_string_literal: true

# Feature 43 - request-id / correlation-id.
#
# Real request-pipeline tests: every case drives the REAL front controller
# (Tina4::RackApp#call, via Tina4::TestClient) - NO mocks. The logger case reads
# the REAL tina4.log file the framework wrote.
#
# Proves the four cross-framework invariants:
#   1. a well-formed inbound X-Request-ID is honoured and echoed on the response;
#   2. an absent id yields a generated id echoed on the response;
#   3. a CR/LF-bearing OR over-long OR illegal-charset inbound id is sanitized so
#      it never reflects raw into the response header or a log line (no injection);
#   4. a log line written during the request carries the id (log correlation).
#
# Plus the Ruby-specific correctness property (RID-DORMANT-RUBY-NODE + porting
# capsule): the id is stored THREAD-LOCAL, so two requests in flight on different
# Puma worker threads keep DISTINCT ids.

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Feature 43 - request id / correlation id" do
  let(:tmpdir) { Dir.mktmpdir }

  # A method, NOT a bare constant: a constant declared inside an RSpec block
  # lands on Object and leaks across the whole suite.
  def well_formed?(rid)
    !rid.nil? && rid.match?(/\A[A-Za-z0-9._-]{1,128}\z/)
  end

  # The log file is written only in dev (TINA4_DEBUG truthy); pin it so the
  # correlation case can read a REAL file the framework wrote.
  around do |example|
    saved = ENV.key?("TINA4_DEBUG") ? ENV["TINA4_DEBUG"] : :__unset__
    ENV["TINA4_DEBUG"] = "true"
    example.run
  ensure
    saved == :__unset__ ? ENV.delete("TINA4_DEBUG") : (ENV["TINA4_DEBUG"] = saved)
  end

  before do
    Tina4::Router.clear!
    Tina4::Log.configure(File.join(tmpdir, "logs"))

    Tina4::Router.get("/rid-echo") do |_request, response|
      # Return the id the framework threaded into the request context, so the
      # test can assert the handler and the wire agree.
      response.call({ rid: Tina4::Log.get_request_id }, 200)
    end
    Tina4::Router.get("/rid-log") do |_request, response|
      Tina4::Log.info("rid-log-marker")
      response.call({ rid: Tina4::Log.get_request_id }, 200)
    end
    Tina4::Router.get("/rid-slow") do |_request, response|
      sleep(0.05) # force two concurrent requests to interleave
      response.call({ rid: Tina4::Log.get_request_id }, 200)
    end
  end

  after do
    Tina4::Router.clear!
    Tina4::Log.clear_request_id
    FileUtils.rm_rf(tmpdir)
  end

  # 1. honour a valid inbound id ---------------------------------------------
  it "inbound id is honoured and echoed" do
    res = Tina4::TestClient.new.get("/rid-echo", headers: { "X-Request-ID" => "trace-abc_123.4" })
    expect(res.headers["x-request-id"]).to eq("trace-abc_123.4")
    expect(res.json["rid"]).to eq("trace-abc_123.4")
  end

  # 2. generate when absent ---------------------------------------------------
  it "absent id is generated and echoed" do
    res = Tina4::TestClient.new.get("/rid-echo")
    rid = res.headers["x-request-id"]
    expect(well_formed?(rid)).to be(true), "generated id not well-formed: #{rid.inspect}"
    expect(res.json["rid"]).to eq(rid) # same id in the handler and on the wire
  end

  # 3. sanitize a hostile inbound id (CR/LF) ----------------------------------
  it "crlf id is sanitized" do
    hostile = "abc\r\nSet-Cookie: pwned=1"
    res = Tina4::TestClient.new.get("/rid-echo", headers: { "X-Request-ID" => hostile })
    rid = res.headers["x-request-id"]
    expect(rid).not_to include("\r")
    expect(rid).not_to include("\n")
    expect(rid).not_to eq(hostile)
    expect(well_formed?(rid)).to be(true)
    res.headers.each_value { |v| expect(v.to_s).not_to include("pwned") }
    expect(res.json["rid"]).to eq(rid)
  end

  # 3. sanitize a hostile inbound id (over-long) ------------------------------
  it "overlong id is sanitized" do
    hostile = "a" * 500
    res = Tina4::TestClient.new.get("/rid-echo", headers: { "X-Request-ID" => hostile })
    rid = res.headers["x-request-id"]
    expect(rid).not_to eq(hostile)
    expect(rid.length).to be <= 128
    expect(well_formed?(rid)).to be(true)
  end

  # 3. sanitize a hostile inbound id (illegal charset) ------------------------
  it "illegal charset id is sanitized" do
    hostile = "no spaces or *stars*"
    res = Tina4::TestClient.new.get("/rid-echo", headers: { "X-Request-ID" => hostile })
    rid = res.headers["x-request-id"]
    expect(rid).not_to eq(hostile)
    expect(well_formed?(rid)).to be(true)
  end

  # RID-DORMANT-RUBY-NODE + thread-local: concurrent requests keep DISTINCT ids
  it "keeps distinct ids for two concurrent requests (thread isolation)" do
    client = Tina4::TestClient.new
    client.app # force the shared app to build once, before threading
    results = {}
    %w[aaa-111 bbb-222].map do |inbound|
      Thread.new do
        res = client.get("/rid-slow", headers: { "X-Request-ID" => inbound })
        results[inbound] = res.json["rid"]
      end
    end.each(&:join)
    # A shared class-ivar (the old storage) would let the first request read the
    # second's id after its sleep; thread-local storage isolates them.
    expect(results["aaa-111"]).to eq("aaa-111"), "first request saw #{results['aaa-111'].inspect} - id isolation broken"
    expect(results["bbb-222"]).to eq("bbb-222"), "second request saw #{results['bbb-222'].inspect} - id isolation broken"
  end

  # 4. a log line carries the id ----------------------------------------------
  it "log line carries the request id" do
    res = Tina4::TestClient.new.get("/rid-log", headers: { "X-Request-ID" => "corr-9f8e7d" })
    expect(res.headers["x-request-id"]).to eq("corr-9f8e7d")

    log_text = File.read(File.join(tmpdir, "logs", "tina4.log"))
    marker_lines = log_text.each_line.select { |line| line.include?("rid-log-marker") }
    expect(marker_lines).not_to be_empty, "the handler log line was never written to the file"
    expect(marker_lines.any? { |line| line.include?("[corr-9f8e7d]") }).to be(true),
           "the log line does not carry the request id: #{marker_lines.inspect}"
  end

  # Direct, no-dependency unit checks of the sanitizer (a pure function). The
  # tight mutation target: drop the disallowed-char test and every hostile case
  # reflects raw; drop the length cap and the over-long case reflects.
  it "sanitizer honours well-formed ids" do
    ["abc123", "trace-id_9.8", "A" * 128, "0", "x.y-z_1"].each do |good|
      expect(Tina4::Log.sanitize_request_id(good)).to eq(good), "should honour #{good.inspect}"
    end
  end

  it "sanitizer rejects hostile or malformed ids" do
    [
      "abc\r\nSet-Cookie: x=1", # CRLF header injection
      "abc\rinject",           # bare CR
      "abc\ninject",           # bare LF
      "has space",             # space not allowed
      "semi;colon",            # ; not allowed
      "curl|bash",             # pipe not allowed
      "<script>",              # angle brackets not allowed
      "a" * 129,               # over the length cap
      "",                      # empty
      nil                      # absent
    ].each do |bad|
      expect(Tina4::Log.sanitize_request_id(bad)).to be_nil, "should reject #{bad.inspect}"
    end
  end
end
