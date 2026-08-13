# frozen_string_literal: true

# Real-bug audit (3.13.99): the built-in server's FIRST-TIME session cookie.
#
# CONFIRMED BROKEN in PHP: Tina4\Server (the raw-socket engine `tina4 serve`
# boots) never triggers PHP's headers_sent() -- a raw socket engages no real
# PHP SAPI header-sending mechanism at all -- so Router::emitSessionCookie()
# took the native setcookie() branch, which writes into a void nothing reads
# back under that engine. A first-time session login under `tina4 serve`
# emitted NO Set-Cookie at all: session auth was silently broken on the
# framework's own recommended dev/prod server. Fixed in PHP by giving
# Response a rawSocket flag Tina4\Server sets, read by emitSessionCookie().
#
# CROSS-CHECKED HERE: Ruby's Tina4::WebServer is WEBrick (Ruby stdlib), not a
# bespoke raw socket engine the way PHP's Tina4\Server is -- WEBrick IS a real
# HTTP server with its own native header/cookie mechanism, always. Ruby's
# dispatch_pipeline.rb writes `headers["set-cookie"] = sess.cookie_header`
# into a plain headers Hash that WebServer copies onto webrick_res.cookies
# uniformly for every request -- there is no PHP-style CGI-heritage split
# between "a real SAPI" and "a raw socket". CODE WINS: this spec is a real,
# no-mock proof (not merely read from source) that a REAL spawned
# `ruby app.rb` process -- Tina4::WebServer, the exact path
# Tina4.run!/`tina4ruby serve` take -- emits a first-time Set-Cookie and that
# replaying it resumes the session, mirroring spec/dual_port_contract_spec.rb's
# established real-child-server pattern (spec/support/shutdown_probe.rb).
#
# Same case name in all four (tina4-documentation/plan/v3/fixtures/session_contract.json):
#   - first_time_session_cookie_is_emitted_and_a_replay_resumes_it

require "spec_helper"
require "socket"
require "timeout"
require_relative "support/shutdown_probe"

module SessionBuiltinServerCookieProbe
  module_function

  # A REAL Tina4::WebServer child: POST /login (noauth) writes to the
  # session, so the framework must emit a first-time Set-Cookie; GET /whoami
  # reads it back.
  def write_app(dir)
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      #{ShutdownProbe.load_guard(lib)}

      Tina4::Router.post("/login") do |request, response|
        request.session.set("token", "abc")
        response.json({ ok: true })
      end.no_auth

      Tina4::Router.get("/whoami") do |request, response|
        response.json({ token: request.session.get("token") })
      end

      Tina4.initialize!(#{dir.inspect})
      application = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(application, host: "127.0.0.1",
                                        port: Integer(ENV.fetch("PROBE_PORT"))).start
    RUBY
    app_path
  end

  def boot
    dir = SpecTmpdir.create("tina4-session-builtin-cookie")
    port = ShutdownProbe.free_port
    app_path = write_app(dir)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env("TINA4_OVERRIDE_CLIENT" => "true", "PROBE_PORT" => port.to_s)
    pid = spawn(child_env, RbConfig.ruby, app_path,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/whoami")
  end

  # Raw socket POST/GET so the FULL response (status line + every header,
  # including Set-Cookie) is visible -- ShutdownProbe::Server#get discards
  # headers, which is exactly what this case needs to inspect.
  def raw_request(port, method, path, headers: {}, body: nil, timeout: 5)
    socket = Socket.tcp("127.0.0.1", port, connect_timeout: timeout)
    lines = ["#{method} #{path} HTTP/1.1", "Host: 127.0.0.1:#{port}", "Connection: close"]
    headers.each { |k, v| lines << "#{k}: #{v}" }
    if body
      lines << "Content-Type: application/json"
      lines << "Content-Length: #{body.bytesize}"
    end
    request = lines.join("\r\n") + "\r\n\r\n" + (body || "")
    socket.write(request)

    raw = +""
    begin
      Timeout.timeout(timeout) { loop { raw << socket.readpartial(4096) } }
    rescue EOFError, Timeout::Error, Errno::ECONNRESET
      # whatever we got is the answer
    end
    socket.close

    head, _sep, response_body = raw.partition("\r\n\r\n")
    header_lines = head.split("\r\n")
    status = header_lines.first.to_s[/\A\S+\s+(\d+)/, 1].to_i
    set_cookies = header_lines.select { |l| l =~ /\Aset-cookie:/i }
                              .map { |l| l.split(":", 2)[1].to_s.strip }
    { status: status, body: response_body, set_cookies: set_cookies }
  end
end

RSpec.describe "Session contract - built-in server first-time cookie (real-bug audit 3.13.99)" do
  after(:each) { @server&.destroy! }

  it "first_time_session_cookie_is_emitted_and_a_replay_resumes_it" do
    @server = SessionBuiltinServerCookieProbe.boot

    login = SessionBuiltinServerCookieProbe.raw_request(@server.port, "POST", "/login", body: "{}")
    expect(login[:status]).to eq(200), "login must succeed\n--- server log ---\n#{@server.log}"
    expect(login[:set_cookies]).not_to be_empty,
      "a first-time session write over the REAL Tina4::WebServer must emit a Set-Cookie - " \
      "this is the exact defect confirmed in PHP's Tina4\\Server\n--- server log ---\n#{@server.log}"

    tina4_cookie = login[:set_cookies].find { |c| c.start_with?("tina4_session=") }
    expect(tina4_cookie).not_to be_nil, "no tina4_session cookie among: #{login[:set_cookies]}"
    cookie_value = tina4_cookie.split(";", 2).first

    whoami = SessionBuiltinServerCookieProbe.raw_request(
      @server.port, "GET", "/whoami", headers: { "Cookie" => cookie_value }
    )
    expect(whoami[:status]).to eq(200)
    expect(whoami[:body]).to match(/"token"\s*:\s*"abc"/),
      "replaying the first-time cookie must RESUME the session (token=abc); got #{whoami[:body].inspect}"
  end
end
