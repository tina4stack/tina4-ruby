# frozen_string_literal: true

# Feature 130 -- dynamic framework version (single resolver + version
# User-Agent). See tina4-documentation/plan/v3/features/130-dynamic-version.md
# and OWNER-DECISIONS.md (Batch 5, VERSION-DEC-01/02/03). Shared fixture:
# tina4-documentation/plan/v3/fixtures/version_contract.json.
#
# Ruby is the reference resolver (Tina4::VERSION const in lib/tina4/version.rb;
# the gemspec `require`s it so the gem and the runtime cannot diverge) and is
# UNCHANGED here.
#
# A REAL bug was found and fixed while grounding this feature (not previously
# catalogued, not something the "Ruby is the reference" framing predicted):
# Tina4._default_mcp_server built McpServer.new("/__dev/mcp", name: "Tina4 Dev
# Tools") with NO version: kwarg, so the built-in dev MCP server's
# serverInfo.version was stuck on the constructor's generic "1.0.0" default --
# the exact same class of bug PHP was audited for. Fixed by passing
# Tina4::VERSION explicitly at that one call site (lib/tina4/mcp.rb). The
# resolver itself was not touched.
#
# Ruby has no ASCII-art startup banner tied to server boot (unlike
# Python/PHP/Node) -- WebServer#start only logs "Development server: WEBrick".
# Its closest real analog to a human-facing "here is my version" surface is
# the separate `tina4ruby version` CLI subcommand (cmd_version, distinct code
# path from `commands --json`'s cmd_commands), so that is what this suite
# treats as the "banner" leg of every_reporting_surface_agrees.
#
# Case names (shared with Python/PHP/Node):
#   - runtime_version_equals_the_package_manifest
#   - every_reporting_surface_agrees
#   - no_surface_reports_a_placeholder_version
#   - the_outbound_http_client_sends_a_tina4_version_user_agent
#
# NO MOCKS: a real spawned `ruby app.rb` process (Tina4::WebServer/RackApp --
# the same path `tina4ruby start` takes) queried over real sockets (health,
# dashboard, a real JSON-RPC POST to the MCP endpoint), real `exe/tina4ruby`
# subprocesses for `version` and `commands --json`, and a real local TCP
# capture server the framework's own API client makes a real outbound request
# against.

require "spec_helper"
require "socket"
require "net/http"
require "timeout"
require "json"
require "open3"
require_relative "support/shutdown_probe"

module VersionContractProbe
  Server = ShutdownProbe::Server
  PLACEHOLDER_VERSIONS = %w[0.0.0 1.0.0].freeze
  module_function

  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"

      loaded_from = $LOADED_FEATURES.find { |feature| feature.end_with?("/tina4.rb") }
      unless loaded_from.to_s.start_with?(#{lib.inspect})
        abort("loaded the WRONG tina4: \#{loaded_from} (expected #{lib})")
      end

      Tina4.initialize!(#{dir.inspect})
      application = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot
    dir = SpecTmpdir.create("tina4-version-contract")
    port = ShutdownProbe.free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env(
      "TINA4_DEBUG" => "true",
      "TINA4_OVERRIDE_CLIENT" => "true",
      "TINA4_NO_AI_PORT" => "true",
      "PROBE_PORT" => port.to_s
    )

    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    Server.new(pid, port, dir, log_path).wait_until_serving!("/health")
  end

  # Real JSON-RPC 'initialize' POST to the mounted MCP endpoint.
  def mcp_initialize_version(port, timeout: 5)
    uri = URI("http://127.0.0.1:#{port}/__dev/mcp")
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "version-contract-test", version: "1.0" }
      }
    }.to_json

    response = Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
      http.post(uri.path, body, { "Content-Type" => "application/json" })
    end
    raise "MCP initialize -> HTTP #{response.code}: #{response.body}" unless response.code.to_i == 200

    JSON.parse(response.body).dig("result", "serverInfo", "version")
  end

  # Real subprocess running the actual exe/tina4ruby CLI.
  #
  # RUBYOPT="-W0" silences Ruby warnings entirely for the child. Ruby normally
  # writes warnings to stderr (which we redirect into the combined output
  # buffer with err: [:child, :out]), but a stray `puts` in a broken
  # ~/.irbrc, a gem's `require` warning routed to $stdout, or any misconfigured
  # startup file can put noise on STDOUT ahead of the JSON manifest. The
  # payload is parsed via parse_cli_manifest (below), which is robust to
  # leading noise, but silencing warnings at the source is the belt to that
  # suspenders. Same defect class as the 3.13.115 PHP local-env failure where
  # a warning printed to stdout before the JSON killed JSON.parse.
  def cli_run(*args)
    env = { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => "-W0", "BUNDLER_SETUP" => nil }
    cmd = [RUBY_BIN, EXE, *args]
    out = nil
    status = nil
    block = lambda do
      out = IO.popen(env, cmd, err: [:child, :out], &:read)
      status = $?.exitstatus
    end
    if defined?(Bundler)
      Bundler.with_unbundled_env(&block)
    else
      block.call
    end
    [status, out]
  end

  # Locate the first `{` in the child's stdout and JSON.parse from there. A
  # bare JSON.parse(cli_out) raises an opaque ParserError with no clue what
  # the child actually printed -- exactly the failure mode that hit 3.13.115
  # in PHP when a startup warning leaked onto stdout ahead of the manifest.
  # This helper isolates the leading noise (raising RuntimeError with a
  # 400-byte stdout slice so the operator can see WHAT preceded the payload)
  # and calls JSON.parse only on the substring starting at the first brace.
  def parse_cli_manifest(stdout, context = "")
    brace = stdout.index("{")
    if brace.nil?
      raise "No JSON manifest found in stdout (context=#{context}); " \
            "first 400 bytes: #{stdout[0, 400].inspect}"
    end
    begin
      JSON.parse(stdout[brace..])
    rescue JSON::ParserError => e
      raise "Failed to parse CLI manifest JSON (context=#{context}, err=#{e.message}); " \
            "first 400 bytes: #{stdout[0, 400].inspect}"
    end
  end
  module_function :parse_cli_manifest
end

RSpec.describe "Dynamic framework version (feature 130)" do
  # ── runtime_version_equals_the_package_manifest ─────────────────────────

  it "runtime version equals the package manifest" do
    gemspec_path = File.join(REPO_ROOT, "tina4ruby.gemspec")
    spec = Gem::Specification.load(gemspec_path)
    expect(spec).not_to be_nil, "could not load #{gemspec_path}"
    expect(spec.version.to_s).to eq(Tina4::VERSION)
  end

  # ── every_reporting_surface_agrees / no_surface_reports_a_placeholder_version ──

  describe "live surfaces" do
    before(:context) do
      @server = VersionContractProbe.boot
    end

    after(:context) do
      @server&.destroy!
    end

    def surfaces
      resolved = Tina4::VERSION

      health_code, health_body = @server.get("/health")
      raise "GET /health -> #{health_code}" unless health_code == 200
      health_version = JSON.parse(health_body)["version"]

      dash_code, dash_body = @server.get("/__dev/api/status")
      raise "GET /__dev/api/status -> #{dash_code}: #{dash_body}" unless dash_code == 200
      dashboard_version = JSON.parse(dash_body)["version"]

      mcp_version = VersionContractProbe.mcp_initialize_version(@server.port)

      banner_status, banner_out = VersionContractProbe.cli_run("version")
      raise "tina4ruby version exited #{banner_status}: #{banner_out}" unless banner_status.zero?

      cli_status, cli_out = VersionContractProbe.cli_run("commands", "--json")
      raise "tina4ruby commands --json exited #{cli_status}: #{cli_out}" unless cli_status.zero?
      cli_version = VersionContractProbe.parse_cli_manifest(cli_out, "cli_run(commands --json)")["version"]

      {
        resolved: resolved,
        health: health_version,
        dashboard: dashboard_version,
        mcp: mcp_version,
        banner: banner_out,
        cli: cli_version
      }
    end

    it "every reporting surface agrees" do
      s = surfaces
      expected_banner = "Tina4 Ruby v#{s[:resolved]}"
      expect(s[:banner]).to include(expected_banner), "banner missing #{expected_banner.inspect}; got: #{s[:banner].inspect}"
      expect(s[:health]).to eq(s[:resolved]), "health #{s[:health].inspect} != runtime #{s[:resolved].inspect}"
      expect(s[:dashboard]).to eq(s[:resolved]), "dashboard #{s[:dashboard].inspect} != runtime #{s[:resolved].inspect}"
      expect(s[:mcp]).to eq(s[:resolved]), "MCP serverInfo #{s[:mcp].inspect} != runtime #{s[:resolved].inspect}"
      expect(s[:cli]).to eq(s[:resolved]), "CLI manifest #{s[:cli].inspect} != runtime #{s[:resolved].inspect}"
    end

    it "no surface reports a placeholder version" do
      s = surfaces
      %i[health dashboard mcp cli].each do |name|
        expect(VersionContractProbe::PLACEHOLDER_VERSIONS).not_to include(s[name]), "#{name} reported a placeholder version: #{s[name].inspect}"
      end
    end
  end

  # ── the_outbound_http_client_sends_a_tina4_version_user_agent ───────────

  it "the outbound http client sends a tina4 version user agent" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = { user_agent: nil }
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.strip.downcase] = value.strip if name && value
        end
        captured[:user_agent] = headers["user-agent"]
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        client.close
      end
    rescue IOError, Errno::EBADF
      # server closed -- thread exits cleanly
    end

    begin
      base_url = "http://127.0.0.1:#{port}"

      # Default: no caller-supplied User-Agent.
      api = Tina4::API.new(base_url)
      response = api.get("/probe")
      expect(response.error).to be_nil, "request failed: #{response.error}"
      deadline1 = Time.now + 5
      sleep 0.05 while captured[:user_agent].nil? && Time.now < deadline1
      expected = "Tina4/#{Tina4::VERSION}"
      expect(captured[:user_agent]).to eq(expected), "default User-Agent was #{captured[:user_agent].inspect}, expected #{expected.inspect}"

      # Caller-supplied User-Agent must be preserved, not clobbered.
      captured[:user_agent] = nil
      api_custom = Tina4::API.new(base_url, headers: { "User-Agent" => "MyApp/9.9" })
      response2 = api_custom.get("/probe")
      expect(response2.error).to be_nil, "request failed: #{response2.error}"
      deadline = Time.now + 5
      sleep 0.05 while captured[:user_agent].nil? && Time.now < deadline
      expect(captured[:user_agent]).to eq("MyApp/9.9"), "caller-supplied User-Agent was clobbered: #{captured[:user_agent].inspect}"
    ensure
      thread.kill
      server.close
    end
  end
end

# ── CLI manifest parser resilience (feature 130) ────────────────────────────
#
# Named regression tests for the JSON.parse hardening in
# VersionContractProbe.parse_cli_manifest. Same defect class as the 3.13.115
# PHP local-env failure: a warning printed to stdout ahead of the JSON payload
# killed the bare JSON.parse. The parser now locates the first `{` in stdout
# before parsing, and raises a diagnostic RuntimeError (with a 400-byte stdout
# slice) when no JSON payload is present, so the operator can see what the
# child actually printed.
RSpec.describe "CLI manifest parser resilience" do
  it "parses a JSON payload even when stdout has leading warning noise (positive gate)" do
    polluted = "Warning: something loud\n" \
               "DEBUG: whatever\n" \
               "{\"framework\":\"ruby\",\"version\":\"3.13.115\",\"commands\":[]}"
    manifest = VersionContractProbe.parse_cli_manifest(polluted, "test-fixture")
    expect(manifest["version"]).to eq("3.13.115")
    expect(manifest["framework"]).to eq("ruby")

    clean = "{\"framework\":\"ruby\",\"version\":\"3.13.115\",\"commands\":[]}"
    expect(VersionContractProbe.parse_cli_manifest(clean, "clean")["version"]).to eq("3.13.115")
  end

  it "raises a diagnostic RuntimeError when stdout contains no JSON (negative gate)" do
    expect {
      VersionContractProbe.parse_cli_manifest("Traceback: exploded, no JSON here", "test-negative")
    }.to raise_error(RuntimeError, /no.*json|manifest/i)
  end
end
