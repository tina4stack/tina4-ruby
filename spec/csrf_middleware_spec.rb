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
    ENV.delete("TINA4_CSRF")
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
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

  # ── 13. PUT without token returns 403 ─────────────────────────

  it "blocks PUT without token and returns 403" do
    request = mock_request(method: "PUT", headers: {}, body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 14. DELETE without token returns 403 ──────────────────────

  it "blocks DELETE without token and returns 403" do
    request = mock_request(method: "DELETE", headers: {}, body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 15. PUT with valid body token passes ──────────────────────

  it "accepts formToken in body for PUT" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "PUT", body: { "formToken" => token }, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 16. Header takes precedence when body is empty ────────────

  it "accepts X-Form-Token header when body has no formToken" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(
      method: "POST",
      headers: { "X-Form-Token" => token },
      body: {},
      query: {},
    )
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 17. Wrong secret token returns 403 ────────────────────────

  it "rejects a token signed with a wrong secret" do
    # Generate a token with a different key pair (separate tmp dir)
    wrong_dir = Dir.mktmpdir("tina4_csrf_wrong")
    begin
      # Save current Auth state
      orig_priv = Tina4::Auth.instance_variable_get(:@private_key)
      orig_pub  = Tina4::Auth.instance_variable_get(:@public_key)
      orig_dir  = Tina4::Auth.instance_variable_get(:@keys_dir)

      Tina4::Auth.instance_variable_set(:@private_key, nil)
      Tina4::Auth.instance_variable_set(:@public_key, nil)
      Tina4::Auth.instance_variable_set(:@keys_dir, nil)
      Tina4::Auth.setup(wrong_dir)
      wrong_token = Tina4::Auth.get_token({ "type" => "form" })

      # Restore original Auth state
      Tina4::Auth.instance_variable_set(:@private_key, orig_priv)
      Tina4::Auth.instance_variable_set(:@public_key, orig_pub)
      Tina4::Auth.instance_variable_set(:@keys_dir, orig_dir)

      request = mock_request(method: "POST", body: { "formToken" => wrong_token }, query: {})
      response = new_response

      Tina4::CsrfMiddleware.before_csrf(request, response)
      expect(response.status_code).to eq(403)
    ensure
      FileUtils.rm_rf(wrong_dir)
    end
  end

  # ── 18. Handler without noauth requires CSRF ──────────────────

  it "requires CSRF when handler has no_auth false" do
    handler = double("handler", no_auth: false)
    request = mock_request(method: "POST", handler: handler, body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 19. Invalid Bearer does not skip CSRF ─────────────────────

  it "does not skip CSRF for an invalid Bearer token" do
    request = mock_request(
      method: "POST",
      headers: { "authorization" => "Bearer invalid-token-here" },
      body: {},
      query: {},
    )
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 20. Token without session_id passes ───────────────────────

  it "accepts token without session_id claim (skips session binding)" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "POST", body: { "formToken" => token }, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 21. CSRF disabled via env false ───────────────────────────

  it "skips CSRF when TINA4_CSRF=false" do
    ENV["TINA4_CSRF"] = "false"
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 22. CSRF default on without env ───────────────────────────

  it "enforces CSRF by default when TINA4_CSRF is not set" do
    ENV.delete("TINA4_CSRF")
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    # Without a token, POST should be blocked when CSRF is active
    expect(response.status_code).to eq(403)
  end

  # ── 23. CSRF enabled via env true ─────────────────────────────

  it "enforces CSRF when TINA4_CSRF=true" do
    ENV["TINA4_CSRF"] = "true"
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end

  # ── 24. CSRF disabled via env zero ────────────────────────────

  it "skips CSRF when TINA4_CSRF=0" do
    ENV["TINA4_CSRF"] = "0"
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 25. CSRF disabled via env no ──────────────────────────────

  it "skips CSRF when TINA4_CSRF=no" do
    ENV["TINA4_CSRF"] = "no"
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    result = Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(result).to eq([request, response])
    expect(response.status_code).not_to eq(403)
  end

  # ── 26. 403 response has error envelope ───────────────────────

  it "returns error envelope with error and message fields on 403" do
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = JSON.parse(response.to_rack[2].first)
    expect(body_json["error"]).to eq("CSRF_INVALID")
    expect(body_json).to have_key("message")
  end

  # ── 27. 403 query param rejection has specific message ────────

  it "returns query string rejection message in error envelope" do
    token = Tina4::Auth.get_token({ "type" => "form" })
    request = mock_request(method: "POST", query: { "formToken" => token }, body: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)

    body_json = JSON.parse(response.to_rack[2].first)
    expect(body_json["error"]).to eq("CSRF_INVALID")
    expect(body_json["message"].downcase).to include("query string")
  end

  # ── 28. Missing token error has descriptive message ───────────

  it "returns descriptive message when no token provided" do
    request = mock_request(method: "POST", body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    body_json = JSON.parse(response.to_rack[2].first)
    expect(body_json["message"]).to include("form token")
  end

  # ── 29. PATCH without token returns 403 ───────────────────────

  it "blocks PATCH without token and returns 403" do
    request = mock_request(method: "PATCH", headers: {}, body: {}, query: {})
    response = new_response

    Tina4::CsrfMiddleware.before_csrf(request, response)
    expect(response.status_code).to eq(403)
  end
end
