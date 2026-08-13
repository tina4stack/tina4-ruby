# frozen_string_literal: true

require "spec_helper"

# Feature 29 - HTTP request model - shared cross-language contract (3.13.99).
#
# Four named cases, identical across Python/PHP/Ruby/Node
# (plan/v3/fixtures/request_contract.json), each driven through the REAL
# front controller (Tina4::TestClient -> Tina4::RackApp#call) — no mocks, no
# hand-invoked handlers.
#
#   route_param_not_shadowed_by_query  - REQ-PARAM-POLLUTION (security):
#       params is route-only; a client ?id= can never shadow the route {id}.
#   malformed_json_body_agreed_result  - REQ-BODY-DIVERGE: malformed JSON ->
#       the raw string, in all four (was {} here).
#   auth_middleware_sets_request_user  - the secure-by-default auth gate
#       stashes the verified payload on request.user (already correct in
#       Ruby; locked in here under the shared fixture name).
#   ip_honours_xff_only_from_trusted_proxy - DO NOT REGRESS: remote_ip is
#       always the raw peer; ip honours X-Forwarded-For ONLY from a
#       TINA4_TRUSTED_PROXIES peer (see spec/trusted_proxy_spec.rb for the
#       deeper suite — this locks the existing algorithm, doesn't change it).
RSpec.describe "Request contract (feature 29, 3.13.99)" do
  before(:each) do
    Tina4::Router.clear!
    ENV["TINA4_SECRET"] = "request-contract-secret"

    Tina4::Router.get("/__rq29/{id}") do |request, response|
      response.json({ params: request.params.to_h, query: request.query.to_h })
    end

    Tina4::Router.post("/__rq29/body") do |request, response|
      response.json({ body: request.body })
    end.no_auth

    Tina4::Router.post("/__rq29/whoami") do |request, response|
      response.json({ user: request.user })
    end

    Tina4::Router.get("/__rq29ip/probe") do |request, response|
      response.json({ ip: request.ip, remote_ip: request.remote_ip })
    end
  end

  after(:each) do
    ENV.delete("TINA4_SECRET")
    ENV.delete("TINA4_TRUSTED_PROXIES")
  end

  let(:client) { Tina4::TestClient.new }

  it "route_param_not_shadowed_by_query" do
    # A route `/{id}` hit with `?id=other` -> params["id"] is the ROUTE
    # value; the client value is only ever in query. Also asserts an
    # UNRELATED query key (`extra`) never leaks into params — a same-name
    # collision alone doesn't distinguish old vs new (route already won a
    # name collision in the old merge, applied last); the pollution was any
    # OTHER client-controlled key riding along in `params`.
    r = client.get("/__rq29/1?id=other&extra=leak")
    expect(r.status).to eq(200)
    body = r.json
    expect(body["params"]["id"]).to eq("1")
    expect(body["query"]["id"]).to eq("other")
    expect(body["params"]).not_to have_key("extra")
    expect(body["query"]["extra"]).to eq("leak")
  end

  it "malformed_json_body_agreed_result" do
    malformed = "{not valid json"
    r = client.post("/__rq29/body", body: malformed, headers: { "Content-Type" => "application/json" })
    expect(r.status).to eq(200)
    expect(r.json["body"]).to eq(malformed)
  end

  it "auth_middleware_sets_request_user" do
    token = Tina4::Auth.get_token({ "sub" => "contract-user", "role" => "tester" })
    r = client.post("/__rq29/whoami", headers: { "Authorization" => "Bearer #{token}" })
    expect(r.status).to eq(200)
    user = r.json["user"]
    expect(user).not_to be_nil
    expect(user["sub"]).to eq("contract-user")
    expect(user["role"]).to eq("tester")
  end

  it "ip_honours_xff_only_from_trusted_proxy" do
    # TestClient hardcodes REMOTE_ADDR to 127.0.0.1, so a controlled peer
    # needs a Rack env built directly here — dispatched through the SAME
    # real front controller (Tina4::RackApp#call) TestClient itself calls.
    trusted_peer = "203.0.113.9"
    untrusted_peer = "198.51.100.7"
    spoofed = "1.2.3.4"

    dispatch_probe = lambda do |peer_ip, xff|
      env = {
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/__rq29ip/probe",
        "QUERY_STRING" => "",
        "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "7147",
        "HTTP_HOST" => "localhost:7147",
        "REMOTE_ADDR" => peer_ip,
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "rack.input" => StringIO.new(""),
        "rack.errors" => $stderr,
        "rack.url_scheme" => "http"
      }
      env["HTTP_X_FORWARDED_FOR"] = xff if xff
      app = Tina4::RackApp.current || Tina4::RackApp.new
      Tina4::TestResponse.new(app.call(env))
    end

    # Trusted peer: X-Forwarded-For IS honoured.
    ENV["TINA4_TRUSTED_PROXIES"] = trusted_peer
    r = dispatch_probe.call(trusted_peer, spoofed)
    expect(r.json["remote_ip"]).to eq(trusted_peer)
    expect(r.json["ip"]).to eq(spoofed)

    # Untrusted peer: X-Forwarded-For is ignored — the raw peer wins.
    ENV["TINA4_TRUSTED_PROXIES"] = trusted_peer
    r = dispatch_probe.call(untrusted_peer, spoofed)
    expect(r.json["remote_ip"]).to eq(untrusted_peer)
    expect(r.json["ip"]).to eq(untrusted_peer)
  end
end
