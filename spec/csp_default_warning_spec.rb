# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Default-CSP warn-once - the visible half of the secure-by-default CSP.
#
# Issue tina4-nodejs#61. `default-src 'self'` stays the secure default, but when
# TINA4_CSP is unset the framework says so ONCE per process, so a cross-origin app
# (runtime inline styles, CDN fonts/scripts, a separate API/LiveKit WebSocket) is
# not silently broken with the failure only visible in the browser at runtime.
#
# Driven through the REAL Rack app (Tina4::RackApp#call) with real Rack envs,
# capturing the REAL log via the file sink (output: file). NO MOCKS.
#
# Three rules:
#  1. TINA4_CSP unset -> the warning is emitted exactly ONCE across many requests.
#  2. TINA4_CSP set   -> NO warning (the app opted in).
#  3. Behaviour is UNCHANGED: the CSP header is still `default-src 'self'` when unset.
#
# Mutation-proved: drop the warn_csp_default_once call and rule 1 goes RED; warn on
# every request (remove the ledger guard) and "exactly once" goes RED.
#
# Same case names in all four:
#   tina4-python/tests/test_csp_default_warning.py
#   tina4-php/tests/CspDefaultWarningTest.php
#   tina4-nodejs/test/cspDefaultWarning.test.ts
RSpec.describe "Default-CSP warn-once" do
  MARK = "TINA4_CSP is not set"

  let(:tmp_dir) { Dir.mktmpdir("tina4_csp_warn") }
  let(:log_dir) { File.join(tmp_dir, "logs") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    ENV.delete("TINA4_CSP")
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    FileUtils.mkdir_p(log_dir)
    Tina4::Log.configure(log_dir: log_dir, level: "warning", output: "file")
    reset_ledger
    Tina4::Router.get("/csp-probe") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
    Tina4::SecurityHeadersMiddleware.attach
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    ENV.delete("TINA4_CSP")
    reset_ledger
    Tina4::Log.reset if Tina4::Log.respond_to?(:reset)
    FileUtils.rm_rf(tmp_dir)
  end

  # Reset the per-process warn-once ledger - real state, no mock.
  def reset_ledger
    Tina4::SecurityHeadersMiddleware.instance_variable_set(:@csp_default_warned, false)
  end

  def request
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/csp-probe", "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "rack.input" => StringIO.new(""), "rack.url_scheme" => "http"
    }
    _status, headers, _body = app.call(env)
    headers.transform_keys { |k| k.to_s.downcase }
  end

  def mark_count
    path = File.join(log_dir, "tina4.log")
    return 0 unless File.file?(path)

    File.read(path).lines.count { |line| line.include?(MARK) }
  end

  it "default csp warns exactly once" do
    headers = request
    request
    request
    expect(mark_count).to eq(1), "the default-CSP warning must fire exactly once"
    # Behaviour unchanged: the header is still the secure default.
    expect(headers["content-security-policy"]).to eq("default-src 'self'")
  end

  it "set csp does not warn" do
    ENV["TINA4_CSP"] = "default-src 'self' https://api.example"
    reset_ledger
    headers = request
    expect(mark_count).to eq(0), "setting TINA4_CSP is an opt-in and must not warn"
    expect(headers["content-security-policy"]).to eq("default-src 'self' https://api.example")
  end
end
