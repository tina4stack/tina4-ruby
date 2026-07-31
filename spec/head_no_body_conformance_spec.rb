# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# RFC 9110 s9.3.2: a HEAD response MUST NOT carry content. On EVERY path.
#
# REGRESSION. Ruby stripped the body for a routed response, a 404 and a 405,
# but NOT for a static asset: the static and swagger branches return early out
# of #call and so skipped the strip entirely. `HEAD /style.css` shipped the
# whole file. Measured 2026-07-31: Ruby returned 15 bytes where PHP, Python and
# Node all returned 0 - a 3-1 outlier, and a spec violation rather than a
# missing optimisation.
#
# The strip now lives in ALWAYS_STAGES, which runs whatever produced the
# response, instead of RESPONSE_STAGES, which the early returns bypass.
#
# Why it matters beyond conformance: HEAD is what link checkers, monitoring
# probes and cache validators use precisely to AVOID transferring the body. A
# HEAD that returns the body makes every one of those checks cost a full
# download, silently.
#
# NO MOCKS: a real RackApp over a real temp directory, real files on disk.
#
# Same case names in all four frameworks.
RSpec.describe "HEAD carries no body, on every path" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_head_conformance") }
  let(:app) { Tina4::RackApp.new(root_dir: tmp_dir) }

  before(:each) do
    Tina4::Router.clear!
    FileUtils.mkdir_p(File.join(tmp_dir, "src", "public"))
    File.write(File.join(tmp_dir, "src", "public", "asset.css"), "body { color: red; }")
    Tina4::Router.get("/routed") { |_q, s| s.call("hello from the route", Tina4::HTTP_OK) }
    Tina4::Router.get("/only-get") { |_q, s| s.call("ok", Tina4::HTTP_OK) }
  end

  after(:each) do
    Tina4::Router.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  def head(path)
    env = {
      "REQUEST_METHOD" => "HEAD", "PATH_INFO" => path, "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147", "rack.input" => StringIO.new("")
    }
    status, headers, body = app.call(env)
    [status, Array(body).join, headers]
  end

  it "a head on a static asset carries no body" do
    # THE regression. A GET of the same path must still return the bytes.
    status, body, = head("/asset.css")
    expect(status).to eq(200), "the static asset was not served at all"
    expect(body.bytesize).to eq(0),
                             "HEAD returned #{body.bytesize} bytes of the file - RFC 9110 " \
                             "s9.3.2 forbids content in a HEAD response, and every link " \
                             "checker and monitoring probe now pays for a full download"
  end

  it "a head on a routed response carries no body" do
    status, body, = head("/routed")
    expect(status).to eq(200)
    expect(body.bytesize).to eq(0)
  end

  it "a head on a 404 carries no body" do
    status, body, = head("/definitely/not/a/route")
    expect(status).to eq(404)
    expect(body.bytesize).to eq(0)
  end

  it "a head still reports the content length the get would have sent" do
    # s9.3.2 SHOULD: the same headers as the equivalent GET. That is the whole
    # point of a HEAD probe - a size estimate without the transfer. Stripping
    # the body while dropping Content-Length would make the response useless.
    _status, _body, headers = head("/asset.css")
    length = headers.find { |k, _| k.to_s.downcase == "content-length" }&.last

    expect(length).not_to be_nil, "HEAD dropped Content-Length, so the probe learns nothing"
    expect(length.to_i).to eq(File.size(File.join(tmp_dir, "src", "public", "asset.css")))
  end

  # NEGATIVE: stripping HEAD must not have broken GET.
  it "a get on a static asset still returns the body" do
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/asset.css", "QUERY_STRING" => "",
      "HTTP_HOST" => "localhost", "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "7147", "rack.input" => StringIO.new("")
    }
    status, _h, body = app.call(env)
    expect(status).to eq(200)
    expect(Array(body).join).to include("color: red"),
                                "the HEAD fix stripped the body from GET as well"
  end
end
