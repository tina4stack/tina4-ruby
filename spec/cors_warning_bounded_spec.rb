# frozen_string_literal: true
#
# ADR-0048: CORS denial diagnostics are BOUNDED - "no per-origin ledger and no
# per-origin warning". Ruby's warn_once keyed the :denied warning by
# "denied:#{origin}", so every new attacker-chosen Origin header added a
# @warned entry that was never freed AND another log line: an unbounded
# ledger and an unbounded log. Every CORS warning is now keyed by REASON only
# (as PHP does); the message still names the origin that triggered it the
# first time per reason per process.
#
# NO MOCKS: a REAL Tina4::WebServer, 50 REAL cross-origin HTTP requests per
# policy, and the REAL log file (spec/support/real_log_capture.rb).

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "support/real_log_capture"

RSpec.describe "CORS warnings are bounded: one per reason, never one per origin (ADR-0048)" do
  include RealLogCapture

  def bounded_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def bounded_post(origin)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      req = Net::HTTP::Post.new("/cors48/save")
      req["Origin"] = origin
      req["Content-Type"] = "application/json"
      req.body = "{}"
      http.request(req).code.to_i
    end
  end

  # 50 DISTINCT cross-origin requests under one policy; returns the CORS lines
  # the real logger wrote and the size of the warning ledger afterwards.
  def fifty_origins(origins_policy)
    origins_policy.nil? ? ENV.delete("TINA4_CORS_ORIGINS") : ENV["TINA4_CORS_ORIGINS"] = origins_policy
    Tina4::CorsMiddleware.reset!
    statuses = []
    log = capture_real_log(level: "DEBUG") do
      50.times { |i| statuses << bounded_post("https://attacker-#{i}.example") }
    end
    expect(statuses.uniq).to eq([200])
    [log.lines.grep(/CORS/), (Tina4::CorsMiddleware.instance_variable_get(:@warned) || {}).size]
  end

  before(:all) do
    @saved_env = %w[TINA4_CORS_ORIGINS TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT].to_h { |k| [k, ENV[k]] }
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    @dir = Dir.mktmpdir("tina4-cors48")
    @port = bounded_free_port
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
    Tina4::Router.post("/cors48/save") { |_request, response| response.json({ "saved" => true }) }.no_auth
  end

  it "no policy: 50 distinct origins log exactly ONE warning and keep one ledger entry" do
    warnings, ledger = fifty_origins(nil)
    expect(warnings.length).to eq(1), "#{warnings.length} CORS warnings for 50 origins"
    expect(warnings.first).to include("https://attacker-0.example")
    expect(ledger).to eq(1)
  end

  it "an allow-list excluding them: exactly ONE denied warning and one ledger entry" do
    warnings, ledger = fifty_origins("https://partner.example.com")
    expect(warnings.length).to eq(1), "#{warnings.length} CORS warnings for 50 origins"
    expect(warnings.first).to include("https://attacker-0.example")
    expect(ledger).to eq(1)
  end
end
