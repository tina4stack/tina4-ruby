# An oversized body is the CLIENT's error, so it must answer 413.
#
# Tina4::Request raises PayloadTooLarge when Content-Length exceeds
# TINA4_MAX_UPLOAD_SIZE, and nothing rescued it. It fell into RackApp's generic
# `rescue => e` and came back as 500 Internal Server Error - which tells the
# caller to retry the exact request that will fail again.
#
# Measured on a real Puma server with TINA4_MAX_UPLOAD_SIZE=1MB:
#
#                                    before      after
#     1_500_000 bytes                500         413
#     3_000_000 bytes                500         413
#     8_388_608 bytes                500         413
#     8MB chunked, no Content-Length 500         413
#
# Unlike Node and Python, Ruby's MEMORY was never the problem: RSS stayed flat
# at 5.4MB throughout, because Puma bounds the read before the app sees it, and
# it populates Content-Length after de-chunking so the check fires on a chunked
# body too. Only the status code was wrong. This is the parity half of the
# tina4-nodejs and tina4-python body-cap fixes.
#
# No mocks: the real RackApp, the real Request, the real dispatch pipeline.

require "spec_helper"
require "json"

RSpec.describe "request body cap" do
  # A private constant name so this cannot clobber another spec file - a bare
  # constant inside RSpec.describe is GLOBAL in Ruby.
  body_limit = Tina4::Request::TINA4_MAX_UPLOAD_SIZE

  before do
    Tina4::Router.clear!
    Tina4::Router.post("/upload") do |_request, response|
      response.json({ ok: true }, 200)
    end.no_auth
  end

  after { Tina4::Router.clear! }

  def post_with_length(path, bytes)
    app = Tina4::RackApp.new
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "CONTENT_TYPE" => "application/octet-stream",
      "CONTENT_LENGTH" => bytes.to_s,
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.input" => StringIO.new("a" * [bytes, 4096].min)
    }
    app.call(env)
  end

  it "answers 413, not 500, when the body is over the limit" do
    status, headers, body = post_with_length("/upload", body_limit + 1)

    expect(status).to eq(413)
    expect(headers["content-type"]).to include("application/json")
    parsed = JSON.parse(body.join)
    expect(parsed["error"]).to include("TINA4_MAX_UPLOAD_SIZE")
  end

  it "names the actual size and the limit, so the caller can act on it" do
    oversize = body_limit + 12_345
    _status, _headers, body = post_with_length("/upload", oversize)

    message = JSON.parse(body.join)["error"]
    expect(message).to include(oversize.to_s)
    expect(message).to include(body_limit.to_s)
  end

  it "still serves a body under the limit" do
    status, _headers, _body = post_with_length("/upload", 1024)
    expect(status).to eq(200)
  end

  it "does not turn every error into a 413" do
    # The generic 500 path must survive: a route that genuinely blows up is not
    # a payload problem, and a rescue placed too broadly would swallow it.
    Tina4::Router.clear!
    Tina4::Router.post("/boom") do |_request, _response|
      raise "a real failure"
    end.no_auth

    status, _headers, _body = post_with_length("/boom", 512)
    expect(status).to eq(500)
  end
end
