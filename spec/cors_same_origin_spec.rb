# frozen_string_literal: true
#
# tina4-python #139 parity: a SAME-ORIGIN request is not a CORS request.
#
# Browsers send an Origin header on every same-origin POST/PUT/PATCH/DELETE.
# CorsMiddleware treated any request carrying Origin as cross-origin, so an
# ordinary SPA served by the app itself logged, on its first save:
#
#   * with no policy - "CORS: refused cross-origin request ... (or '*' to allow
#     any origin)": nothing was refused, and the advice would open the API to
#     every website to silence a warning about the app's own page;
#   * with an allow-list for OTHER sites - "... not in TINA4_CORS_ORIGINS ...
#     the browser will block this response", also untrue for same-origin.
#
# The contract (all four frameworks): Origin equal to the request's own origin
# (scheme://host[:port], http:80 and https:443 as default ports) is same-origin:
# no warning, never refused. That ONLY suppresses the warning - it never grants
# CORS access (no Access-Control-Allow-Origin). A disallowed cross-origin
# request still warns, and no warning ever advises '*': it names the specific
# origin to add.
#
# NO MOCKS: a REAL Tina4::WebServer, REAL HTTP requests, and the REAL log
# output read back from the real log file (spec/support/real_log_capture.rb).

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "support/real_log_capture"

RSpec.describe "CORS: same-origin requests are not warned about, and no warning advises '*'" do
  include RealLogCapture

  def cors_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def cors_post(headers)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      req = Net::HTTP::Post.new("/cors139/save")
      headers.each { |key, value| req[key] = value }
      req["Content-Type"] = "application/json"
      req.body = "{}"
      res = http.request(req)
      lowered = {}
      res.each_header { |key, value| lowered[key.downcase] = value }
      [res.code.to_i, lowered]
    end
  end

  # Configure the policy for real, then run one request and return
  # [status, headers, the CORS lines the real logger wrote].
  def cors_run(origins, headers)
    origins.nil? ? ENV.delete("TINA4_CORS_ORIGINS") : ENV["TINA4_CORS_ORIGINS"] = origins
    Tina4::CorsMiddleware.reset!
    result = nil
    log = capture_real_log(level: "DEBUG") { result = cors_post(headers) }
    [*result, log.lines.grep(/CORS/)]
  end

  def own
    "http://127.0.0.1:#{@port}"
  end

  before(:all) do
    @saved_env = %w[TINA4_CORS_ORIGINS TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT].to_h { |k| [k, ENV[k]] }
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @dir = Dir.mktmpdir("tina4-cors139")
    @port = cors_free_port
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
    Tina4::Router.post("/cors139/save") { |_request, response| response.json({ "saved" => true }) }.no_auth
  end

  context "same-origin (Origin equals the request's own origin)" do
    it "logs no CORS warning with no policy configured, and is served" do
      status, headers, warnings = cors_run(nil, "Origin" => own)
      expect(status).to eq(200)
      expect(warnings).to be_empty, "a same-origin POST was warned about: #{warnings.join}"
      expect(headers).not_to have_key("access-control-allow-origin")
    end

    it "logs no CORS warning with an allow-list for other sites, and gains no CORS access" do
      status, headers, warnings = cors_run("https://partner.example.com", "Origin" => own)
      expect(status).to eq(200)
      expect(warnings).to be_empty, "a same-origin POST was warned about: #{warnings.join}"
      expect(headers).not_to have_key("access-control-allow-origin")
    end

    it "treats http:80 and https:443 as the default ports (Host without a port)" do
      _, _, warnings = cors_run(nil, "Host" => "app.example.com", "Origin" => "http://app.example.com:80")
      expect(warnings).to be_empty, warnings.join
      _, _, warnings = cors_run(nil, "Host" => "app.example.com", "X-Forwarded-Proto" => "https",
                                     "Origin" => "https://app.example.com")
      expect(warnings).to be_empty, warnings.join
    end
  end

  context "cross-origin" do
    it "a different port is NOT same-origin: it still warns (no policy), without advising '*'" do
      status, headers, warnings = cors_run(nil, "Origin" => "http://127.0.0.1:1")
      expect(status).to eq(200) # the browser, not the server, does the blocking
      expect(headers).not_to have_key("access-control-allow-origin")
      expect(warnings.length).to eq(1)
      expect(warnings.first).to include("http://127.0.0.1:1")
      expect(warnings.first).to include("TINA4_CORS_ORIGINS=http://127.0.0.1:1")
      expect(warnings.first).not_to include("*")
    end

    it "an origin missing from the allow-list warns, naming it, without advising '*'" do
      _, headers, warnings = cors_run("https://partner.example.com", "Origin" => "https://evil.example")
      expect(headers).not_to have_key("access-control-allow-origin")
      expect(warnings.length).to eq(1)
      expect(warnings.first).to include("https://evil.example")
      expect(warnings.first).to include("TINA4_CORS_ORIGINS=https://partner.example.com,https://evil.example")
      expect(warnings.first).not_to include("*")
    end

    it "an allowed origin gets the CORS headers and no warning" do
      _, headers, warnings = cors_run("https://partner.example.com", "Origin" => "https://partner.example.com")
      expect(headers["access-control-allow-origin"]).to eq("https://partner.example.com")
      expect(headers["vary"].to_s).to include("Origin")
      expect(warnings).to be_empty
    end
  end
end
