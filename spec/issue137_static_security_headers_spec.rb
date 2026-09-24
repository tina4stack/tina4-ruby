# frozen_string_literal: true
#
# Issue #137 parity (tina4-python #137): responses served by the static file
# handler (public/, src/public/) skipped the security-headers middleware even
# when it was attached. The same HTML carried CSP, X-Content-Type-Options and
# X-Frame-Options from a route and none of them as a static file - and because
# "/" resolves to index.html, a single-page app's front door was served with no
# CSP and frameable (clickjacking).
#
# In Ruby the static branch answers from the not-found fallback with
# bypass_response_stages set, and SecurityHeadersMiddleware is post-match
# global middleware, which only a MATCHED route ever runs.
#
# NO MOCKS: a REAL Tina4::WebServer on a REAL port, a REAL file on disk, REAL
# HTTP round trips via Net::HTTP.

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe "Issue #137: static files carry the same security headers as routes" do
  def issue137_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def issue137_boot(app, port)
    server = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)
    thread = Thread.new { server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up on port #{port}" if Time.now > deadline

      sleep 0.05
      retry
    end
    [server, thread]
  end

  def issue137_get(path, headers = {})
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      res = http.get(path, headers)
      lowered = {}
      res.each_header { |key, value| lowered[key.downcase] = value }
      [res.code.to_i, lowered, res.body.to_s]
    end
  end

  # A method, not a constant: a constant in a describe block lands on Object.
  def issue137_security_headers
    %w[content-security-policy x-content-type-options x-frame-options]
  end

  before(:all) do
    @saved_env = %w[TINA4_PUBLIC_DIR TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT TINA4_CSP].to_h { |k| [k, ENV[k]] }
    @public_dir = Dir.mktmpdir("tina4-issue137")
    File.write(File.join(@public_dir, "index.html"), "<!doctype html><title>spa</title><div id=app></div>")
    File.write(File.join(@public_dir, "app.js"), "console.log('spa');")
    ENV["TINA4_PUBLIC_DIR"] = @public_dir
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    ENV["TINA4_CSP"] = "default-src 'self'"

    @port = issue137_free_port
    @server, @thread = issue137_boot(Tina4::RackApp.new(root_dir: @public_dir), @port)
  end

  after(:all) do
    @server&.stop
    @thread&.join(5)
    FileUtils.remove_entry(@public_dir) if @public_dir && Dir.exist?(@public_dir)
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # spec_helper clears Router + Middleware before every example, so the route
  # and the boot-time attach (Tina4.initialize! does exactly this) are redone.
  before(:each) do
    Tina4::SecurityHeadersMiddleware.attach
    Tina4::Router.get("/issue137/page") do |_request, response|
      response.html("<!doctype html><title>route</title><p>hello</p>")
    end
  end

  after(:each) { Tina4::Middleware.clear! }

  it "a route response carries CSP, nosniff and frame options (control)" do
    status, headers, = issue137_get("/issue137/page")
    expect(status).to eq(200)
    issue137_security_headers.each { |name| expect(headers).to have_key(name), "route is missing #{name}" }
  end

  it "a static HTML file carries CSP, nosniff and frame options" do
    status, headers, body = issue137_get("/index.html")
    expect(status).to eq(200)
    expect(body).to include("<title>spa</title>")
    issue137_security_headers.each { |name| expect(headers).to have_key(name), "static /index.html is missing #{name}" }
    expect(headers["x-frame-options"]).to eq("SAMEORIGIN")
    expect(headers["content-security-policy"]).to eq("default-src 'self'")
  end

  it "the SPA front door ('/' -> index.html) is not frameable and has a CSP" do
    status, headers, body = issue137_get("/")
    expect(status).to eq(200)
    expect(body).to include("<title>spa</title>")
    issue137_security_headers.each { |name| expect(headers).to have_key(name), "static / is missing #{name}" }
  end

  it "a static asset (JS) gets nosniff too, and the file's own headers are kept" do
    status, headers, = issue137_get("/app.js")
    expect(status).to eq(200)
    expect(headers["x-content-type-options"]).to eq("nosniff")
    expect(headers["etag"]).to start_with("W/")
    expect(headers["cache-control"]).to eq("no-cache, must-revalidate")
  end

  it "static files get NO security headers when the middleware is not attached (opt-out is honoured)" do
    Tina4::Middleware.clear!
    status, headers, = issue137_get("/index.html")
    expect(status).to eq(200)
    issue137_security_headers.each { |name| expect(headers).not_to have_key(name) }
  end
end
