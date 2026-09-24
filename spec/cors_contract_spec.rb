# frozen_string_literal: true
#
# CORS - the runner for cors_contract.json (ADR-0018, ADR-0048, ADR-0066).
#
# tina4-documentation/plan/v3/fixtures/cors_contract.json names these cases; the
# Python, PHP and Node suites carry the same names.
#
#   * deny by default: no policy grants nobody; an allow-list grants only its own;
#   * a same-origin request (Origin equals the request's own scheme + host) is
#     neither warned about nor granted anything - with or without a policy;
#   * the warning for a refused origin names it, says how to add THAT origin
#     and never advises '*';
#   * refusals are remembered by REASON, never by origin (bounded diagnostics).
#
# NO MOCKS: a REAL Tina4::WebServer, REAL HTTP requests, the REAL log file
# (spec/support/real_log_capture.rb) and the real warn-once ledger, emptied
# between cases with CorsMiddleware.reset! (the policy is re-read with it).

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "support/real_log_capture"

RSpec.describe "CORS contract (cors_contract.json)" do
  include RealLogCapture

  let(:allowed_origin) { "https://allowed.example" }
  let(:other_origin) { "https://other.example" }
  let(:cors_reasons) { %w[unconfigured denied wildcard_credentials] }

  def contract_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def own_origin
    "http://127.0.0.1:#{@port}"
  end

  # POST as origin; returns [status, headers-with-lowercase-names].
  def cors_post(origin)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      request = Net::HTTP::Post.new("/cors-contract/save")
      request["Origin"] = origin
      request["Content-Type"] = "application/json"
      request.body = "{}"
      response = http.request(request)
      [response.code.to_i, response.each_header.to_h]
    end
  end

  # Run the block under a fresh ledger and the given policy; returns [value, CORS log lines].
  def under_policy(origins)
    origins.nil? ? ENV.delete("TINA4_CORS_ORIGINS") : ENV["TINA4_CORS_ORIGINS"] = origins
    Tina4::CorsMiddleware.reset!
    result = nil
    log = capture_real_log(level: "DEBUG") { result = yield }
    [result, log.lines.grep(/CORS:/)]
  end

  def access_control(headers)
    headers.keys.select { |name| name.start_with?("access-control-") }
  end

  before(:all) do
    @saved_env = %w[TINA4_CORS_ORIGINS TINA4_CORS_CREDENTIALS TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT].to_h { |k| [k, ENV[k]] }
    ENV.delete("TINA4_CORS_CREDENTIALS")
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @dir = Dir.mktmpdir("tina4-cors-contract")
    @port = contract_free_port
    @server = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: @dir), host: "127.0.0.1", port: @port)
    @thread = Thread.new { @server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", @port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up" if Time.now > deadline

      sleep 0.05
      retry
    end
  end

  after(:all) do
    @server&.stop
    @thread&.join(5)
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Tina4::CorsMiddleware.reset!
  end

  before(:each) do
    Tina4::Router.post("/cors-contract/save") { |_request, response| response.json({ "saved" => true }) }.no_auth
  end

  it "a cross origin request is denied by default" do
    (status, headers), = under_policy(nil) { cors_post(other_origin) }
    expect(status).to eq(200)
    expect(headers).not_to have_key("access-control-allow-origin")
  end

  it "only a listed origin is granted" do
    (listed, unlisted), = under_policy(allowed_origin) { [cors_post(allowed_origin)[1], cors_post(other_origin)[1]] }
    expect(listed["access-control-allow-origin"]).to eq(allowed_origin)
    expect(unlisted).not_to have_key("access-control-allow-origin")
  end

  it "a same origin request is neither warned about nor granted" do
    [nil, allowed_origin].each do |policy|
      (status, headers), warnings = under_policy(policy) { cors_post(own_origin) }
      expect(status).to eq(200)
      expect(access_control(headers)).to eq([]), "policy=#{policy.inspect}: granted #{access_control(headers)}"
      expect(warnings).to eq([]), "policy=#{policy.inspect}: a same-origin request was warned about"
    end
  end

  it "a different port or scheme is cross origin" do
    _, port_warnings = under_policy(nil) { cors_post("http://127.0.0.1:#{@port + 1}") }
    _, scheme_warnings = under_policy(nil) { cors_post("https://127.0.0.1:#{@port}") }
    expect(port_warnings.length).to eq(1), "an Origin on another port is cross-origin"
    expect(scheme_warnings.length).to eq(1), "an Origin with another scheme is cross-origin"
  end

  it "a refused origin warning names the origin and never advises a wildcard" do
    [nil, allowed_origin].each do |policy|
      _, warnings = under_policy(policy) { cors_post(other_origin) }
      expect(warnings.length).to eq(1), "policy=#{policy.inspect}: #{warnings.inspect}"
      expect(warnings.first).to include(other_origin)
      expect(warnings.first).to include("TINA4_CORS_ORIGINS")
      expect(warnings.first).not_to include("*")
    end
  end

  it "many refused origins produce one warning per reason and no per origin ledger" do
    [nil, allowed_origin].each do |policy|
      _, warnings = under_policy(policy) { 30.times { |number| cors_post("https://probe#{number}.attacker.example") } }
      expect(warnings.length).to eq(1), "policy=#{policy.inspect}: 30 refused origins logged #{warnings.length} warnings"
      expect(Tina4::CorsMiddleware.warned_reasons - cors_reasons).to eq([])
    end
  end
end
