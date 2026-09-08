# frozen_string_literal: true

# The dev-admin version check must not report "up to date" for a check it never
# made.
#
# It used to answer latest == current whenever the call to RubyGems failed, and
# the toolbar renders that as a green "Latest: vX — You are up to date!". A
# developer several releases behind, on a machine with no route out, was told
# the opposite of the truth — and the toolbar's own "Could not check for
# updates" branch could never fire, because the failure arrived as a success.
#
# No mocks. A REAL local HTTP server (a bare TCPServer accept thread) stands in
# for RubyGems where the body has to be controlled, and a REAL closed port
# stands in for "no route out". The registry URL is chosen with
# TINA4_VERSION_CHECK_URL — the same seam an operator points at a mirror with.

require "spec_helper"
require "socket"
require "json"

RSpec.describe "dev-admin version check" do
  # Run the REAL version_check_payload with the registry pointed at `url`, and
  # put TINA4_VERSION_CHECK_URL back exactly as it was so nothing leaks into a
  # later example.
  def payload_for(url)
    previous = ENV.key?("TINA4_VERSION_CHECK_URL") ? ENV["TINA4_VERSION_CHECK_URL"] : :unset
    ENV["TINA4_VERSION_CHECK_URL"] = url
    Tina4::DevAdmin.send(:version_check_payload)
  ensure
    if previous == :unset
      ENV.delete("TINA4_VERSION_CHECK_URL")
    else
      ENV["TINA4_VERSION_CHECK_URL"] = previous
    end
  end

  # A real address with nothing listening: bind then close to free the port, so
  # the connect is refused for real rather than simulated.
  def closed_port_url
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    "http://127.0.0.1:#{port}/"
  end

  # Start a REAL local HTTP server that answers every request with `status` and
  # `body`. Returns [url, server]; close the server to stop it. The accept loop
  # runs http:// (not https), which is exactly why version_check_payload has to
  # honour the URL scheme instead of forcing SSL.
  def serve(body, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    Thread.new do
      loop do
        client = server.accept
        # Drain the request line + headers; a GET carries no body.
        while (line = client.gets) && line != "\r\n"; end
        client.write("HTTP/1.1 #{status}\r\n" \
                     "Content-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\n" \
                     "Connection: close\r\n" \
                     "\r\n#{body}")
        client.close
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        break # server closed, or the client hung up — stop serving
      end
    end
    ["http://127.0.0.1:#{port}/", server]
  end

  it "does not answer with the current version when the registry is unreachable" do
    result = payload_for(closed_port_url)

    expect(result[:latest]).to be_nil,
                                "a check that did not happen must not answer with a version"
    expect(result[:latest]).not_to eq(result[:current]),
                                    "the toolbar reads latest == current as 'you are up to date'"
    expect(result[:error].to_s).not_to be_empty, "the reason has to reach the client"
    expect(result[:current]).to eq(Tina4::VERSION)
  end

  it "does not treat a non-success response as up to date" do
    # A body WITH a version behind a 503 is still not an answer we may trust.
    url, server = serve(JSON.generate({ "version" => "3.13.200" }), status: "503 Service Unavailable")
    begin
      result = payload_for(url)
    ensure
      server.close
    end

    expect(result[:latest]).to be_nil
    expect(result[:error].to_s).to include("503")
  end

  it "does not invent a version from an answer that carries none" do
    # Reaching RubyGems is not the same as learning the version.
    url, server = serve(JSON.generate({ "name" => "tina4ruby" }))
    begin
      result = payload_for(url)
    ensure
      server.close
    end

    expect(result[:latest]).to be_nil
    expect(result[:error].to_s).not_to be_empty
  end

  it "reports the published version when the registry answers" do
    url, server = serve(JSON.generate({ "version" => "3.13.200" }))
    begin
      result = payload_for(url)
    ensure
      server.close
    end

    expect(result[:latest]).to eq("3.13.200")
    expect(result).not_to have_key(:error)
  end

  it "has a toolbar that acts on a missing latest before comparing versions" do
    js = Tina4::RackApp.toolbar_js

    expect(js).to include("couldNotCheck"),
                  "no branch for a check that did not happen"
    expect(js).to include("if (!latest) { couldNotCheck")
    expect(js.index("if (!latest)")).to be < js.index("if (latest === current)"),
                                          "the up-to-date branch must not run first — a null would fall into it"
  end
end
