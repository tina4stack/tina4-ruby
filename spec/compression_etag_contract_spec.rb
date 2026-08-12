# frozen_string_literal: true

require "spec_helper"
require "json"
require "net/http"
require "zlib"
require "stringio"
require "tmpdir"
require "fileutils"

# Shared contract suite for feature 40 -- HTTP compression + ETag.
#
# Fixture: tina4-documentation/plan/v3/fixtures/compression_etag_contract.json
# Decisions: CE-DEC-01 (parity -- gzip + dynamic ETag + conditional-GET are a
# real four-language feature, ported from Python to PHP/Ruby/Node) + CE-DEC-02
# (one pinned weak static ETag format `W/"<size>-<mtime>"` across the four;
# Python's 304 now preserves ETag/Last-Modified; If-None-Match matching
# unified on RFC-7232 weak comparison -- Ruby's was already correct and is
# reused, not reimplemented, by the new dynamic conditional-GET path).
#
# NO MOCKS. A REAL Tina4::WebServer (WEBrick/Puma) is booted on a REAL TCP
# port (the same boot_server pattern server_parity_spec.rb uses) and driven
# with genuine Net::HTTP requests -- real Accept-Encoding / If-None-Match /
# If-Modified-Since headers, and a real Zlib::GzipReader decode of the wire
# body.
RSpec.describe "Compression + ETag contract" do
  STATIC_MTIME = 1_700_000_000 # a round epoch second -- avoids rounding ambiguity

  before(:all) do
    @static_dir = Dir.mktmpdir("tina4-ce-contract")
    @static_file = File.join(@static_dir, "asset.css")
    File.write(@static_file, ".contract-etag-fixture { color: red; }\n" + ("/* pad */\n" * 80))
    File.utime(STATIC_MTIME, STATIC_MTIME, @static_file)
    @static_size = File.size(@static_file)
    ENV["TINA4_PUBLIC_DIR"] = @static_dir

    app = Tina4::RackApp.new(root_dir: Dir.pwd)
    @port = free_port
    @server, @thread = boot_server(app, @port)
  end

  after(:all) do
    @server.stop
    @thread.join(5)
    ENV.delete("TINA4_PUBLIC_DIR")
    FileUtils.remove_entry(@static_dir) if @static_dir && Dir.exist?(@static_dir)
  end

  # spec_helper.rb's global `prepend_before(:each)` runs Router.clear! ahead of
  # EVERY example (isolation for the rest of the suite), which would also wipe
  # the routes registered once in before(:all) above -- so routes are
  # re-declared fresh for each example instead, after that global clear runs.
  before(:each) do
    Tina4::Router.get "/big" do |_request, response|
      # ~2010 bytes serialized, all-'x' repeats -> compresses hard, a strong
      # positive gzip signal when the decompressed body is checked byte-exact.
      response.call({ "data" => "x" * 2000 }, 200)
    end

    Tina4::Router.get "/small" do |_request, response|
      response.call({ "ok" => true }, 200)
    end

    Tina4::Router.get "/binary" do |_request, response|
      # >1KB, highly-compressible BYTES, but a non-compressible declared
      # content-type -- proves the content-type gate, not just a size gate.
      response.call("x" * 2000, 200, "application/octet-stream")
    end
  end

  # ── Harness ────────────────────────────────────────────────────────

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  # Boot the REAL Tina4::WebServer in a background thread, block until it
  # actually accepts a TCP connection. Mirrors server_parity_spec.rb's helper.
  def boot_server(app, port)
    srv = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)
    prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
    prev_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    thread = Thread.new { srv.start }
    thread.abort_on_exception = false

    deadline = Time.now + 10
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        break
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "server never came up on port #{port}" if Time.now > deadline

        sleep 0.05
      end
    end

    [srv, thread]
  ensure
    if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
    if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
  end

  # A REAL HTTP round trip over Net::HTTP -- no in-process shortcut. Never
  # auto-decompresses (Net::HTTP does not send Accept-Encoding unless asked),
  # so a gzip body can be decoded for real.
  def request(path, headers = {})
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 5) do |http|
      res = http.get(path, headers)
      lowered = {}
      res.each_header { |k, v| lowered[k.downcase] = v }
      [res.code.to_i, lowered, res.body || ""]
    end
  end

  def gunzip(bytes)
    Zlib::GzipReader.new(StringIO.new(bytes)).read
  end

  # ── 1. compressible_body_over_1kb_gzips_with_vary ────────────────────

  it "compressible_body_over_1kb_gzips_with_vary" do
    status, headers, body = request("/big", { "Accept-Encoding" => "gzip" })
    expect(status).to eq(200)
    expect(headers["content-encoding"]).to eq("gzip")
    expect(headers["vary"]).to eq("Accept-Encoding")
    expect(JSON.parse(gunzip(body))).to eq({ "data" => "x" * 2000 })

    # Negative: WITHOUT the header -> identity.
    status2, headers2, body2 = request("/big")
    expect(status2).to eq(200)
    expect(headers2).not_to have_key("content-encoding")
    expect(JSON.parse(body2)).to eq({ "data" => "x" * 2000 })
  end

  # ── 2. small_or_incompressible_body_not_gzipped ───────────────────────

  it "small_or_incompressible_body_not_gzipped" do
    status, headers, body = request("/small", { "Accept-Encoding" => "gzip" })
    expect(status).to eq(200)
    expect(headers).not_to have_key("content-encoding")
    expect(JSON.parse(body)).to eq({ "ok" => true })

    status2, headers2, body2 = request("/binary", { "Accept-Encoding" => "gzip" })
    expect(status2).to eq(200)
    expect(headers2).not_to have_key("content-encoding")
    expect(body2).to eq("x" * 2000)
  end

  # ── 3. cacheable_response_carries_an_etag ─────────────────────────────

  it "cacheable_response_carries_an_etag" do
    status, headers, = request("/small")
    expect(status).to eq(200)
    expect(headers["etag"]).not_to be_nil
    expect(headers["etag"]).not_to be_empty
  end

  # ── 4. matching_if_none_match_returns_304_preserving_validators ──────

  it "matching_if_none_match_returns_304_preserving_validators" do
    # Dynamic response: strong ETag only.
    _status, headers, = request("/small")
    etag = headers["etag"]
    status2, headers2, body2 = request("/small", { "If-None-Match" => etag })
    expect(status2).to eq(304)
    expect(body2).to eq("")
    expect(headers2["etag"]).to eq(etag)

    # Static response: weak ETag AND Last-Modified -- the 304 must preserve BOTH.
    _status, sheaders, = request("/asset.css")
    setag = sheaders["etag"]
    slast_modified = sheaders["last-modified"]
    status3, headers3, body3 = request("/asset.css", { "If-None-Match" => setag })
    expect(status3).to eq(304)
    expect(body3).to eq("")
    expect(headers3["etag"]).to eq(setag)
    expect(headers3["last-modified"]).to eq(slast_modified)
  end

  # ── 5. rfc7232_weak_list_star_inm_matches ─────────────────────────────

  it "rfc7232_weak_list_star_inm_matches" do
    _status, headers, = request("/small")
    etag = headers["etag"] # a STRONG tag, e.g. "a1b2c3d4e5f60718"
    weak_form = "W/#{etag}"

    status_w, = request("/small", { "If-None-Match" => weak_form })
    expect(status_w).to eq(304)

    status_list, = request("/small", { "If-None-Match" => %("not-it", #{weak_form}) })
    expect(status_list).to eq(304)

    status_star, = request("/small", { "If-None-Match" => "*" })
    expect(status_star).to eq(304)

    status_miss, = request("/small", { "If-None-Match" => '"totally-different"' })
    expect(status_miss).to eq(200)
  end

  # ── 6. static_etag_format_identical_across_the_four ───────────────────

  it "static_etag_format_identical_across_the_four" do
    status, headers, = request("/asset.css")
    expect(status).to eq(200)
    expected = %(W/"#{@static_size}-#{STATIC_MTIME}")
    expect(headers["etag"]).to eq(expected)
  end
end
