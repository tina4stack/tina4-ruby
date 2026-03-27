# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Tina4::CsrfMiddleware do
  let(:tmp_dir) { Dir.mktmpdir("tina4_csrf_test") }

  before(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
  end

  after(:each) do
    Tina4::Router.clear!
    Tina4::Middleware.clear!
    FileUtils.rm_rf(tmp_dir)
  end

  # ── Helpers ────────────────────────────────────────────────────

  # Build a mock request for unit-level middleware tests
  def mock_request(method:, headers: {}, body: {}, query: {}, handler: nil, session: nil)
    req = double("request")
    allow(req).to receive(:method).and_return(method)

    # respond_to? checks used by the middleware
    allow(req).to receive(:respond_to?).with(:handler).and_return(!handler.nil?)
    allow(req).to receive(:respond_to?).with(:headers).and_return(true)
    allow(req).to receive(:respond_to?).with(:body).and_return(true)
    allow(req).to receive(:respond_to?).with(:params).and_return(false)
    allow(req).to receive(:respond_to?).with(:query).and_return(true)
    allow(req).to receive(:respond_to?).with(:session).and_return(!session.nil?)

    allow(req).to receive(:headers).and_return(headers)
    allow(req).to receive(:body).and_return(body)
    allow(req).to receive(:query).and_return(query)
    allow(req).to receive(:handler).and_return(handler) if handler
    allow(req).to receive(:session).and_return(session) if session

    req
  end

  def new_response
    Tina4::Response.new
  end

  # ── 1. Skips GET requests ──────────────────────────────────────

  it "skips GET requests" do
    request = mock_request(method: "GET")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 2. Skips HEAD requests ─────────────────────────────────────

  it "skips HEAD requests" do
    request = mock_request(method: "HEAD")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 3. Skips OPTIONS requests ──────────────────────────────────

  it "skips OPTIONS requests" do
    request = mock_request(method: "OPTIONS")
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 4. Blocks POST without token — returns 403 ────────────────

  it "blocks POST without token and returns 403" do
    request = mock_request(method: "POST", headers: {}, body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 5. Accepts formToken in body ───────────────────────────────

  it "accepts formToken in body" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "POST", body: { "formToken" => token }, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 6. Accepts X-Form-Token header ────────────────────────────

  it "accepts X-Form-Token header" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "POST", headers: { "X-Form-Token" => token }, body: {}, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 7. Rejects formToken in query params — returns 403 ────────

  it "rejects formToken in query params with 403" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "POST", query: { "formToken" => token }, body: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    # Verify JSON body contains the right error
    body_json = JSON.parse(response.to_rack[2].first)
    expect(body_json["error"]).to eq("CSRF_INVALID")
    expect(body_json["message"]).to include("query string")
  end

  # ── 8. Rejects invalid/expired token — returns 403 ────────────

  it "rejects an invalid token with 403" do
    request = mock_request(method: "POST", body: { "formToken" => "invalid.token.here" }, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  it "rejects an expired token with 403" do
    token = Tina4::Auth.get_token({ "type" => "form" }, expires_in: -10)
    request = mock_request(method: "POST", body: { "formToken" => token }, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 9. Skips no_auth routes ────────────────────────────────────

  it "skips routes marked no_auth" do
    handler = double("handler", no_auth: true)
    request = mock_request(method: "POST", handler: handler)
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 10. Skips Bearer auth requests ─────────────────────────────

  it "skips requests with a valid Bearer token" do
    bearer = Tina4::Auth.get_token({ "user_id" => 1 })
    request = mock_request(
      method: "POST",
      headers: { "authorization" => "Bearer #{bearer}" },
      body: {},
      query: {},
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 11. Rejects token with wrong session_id — returns 403 ─────

  it "rejects token with wrong session_id" do
    token = Tina4::Auth.get_token({ "type" => "form", "session_id" => "session-abc" })
    session = { "session_id" => "session-xyz" }
    request = mock_request(
      method: "POST",
      body: { "formToken" => token },
      query: {},
      session: session,
    )
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 12. Accepts token with matching session_id ─────────────────

  it "accepts token with matching session_id" do
    token = Tina4::Auth.get_token({ "type" => "form", "session_id" => "session-abc" })
    session = { "session_id" => "session-abc" }
    request = mock_request(
      method: "POST",
      body: { "formToken" => token },
      query: {},
      session: session,
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end
end
