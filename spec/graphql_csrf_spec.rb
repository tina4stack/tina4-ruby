# frozen_string_literal: true

# Medium security finding F4 — the built-in GraphQL route must be CSRF-safe.
#
# Two holes on current v3:
#   * GET /graphql ran mutations — a cross-site GET (an <img>/<script> src or a
#     pre-rendered link) carries the victim's cookies and would trigger a state
#     change.
#   * POST /graphql accepted a JSON body sent as text/plain — a cross-site HTML
#     form can send text/plain without a CORS preflight, so it could drive a
#     mutation.
#
# Fix: no mutations over GET, and POST requires an application/json content-type
# (which forces a CORS preflight for any cross-site caller). Case names match
# tina4-php/tests/GraphQLCsrfTest.php.
#
# Real Tina4::RackApp front controller via TestClient. No mocks.
require "spec_helper"
require "cgi"

RSpec.describe "GraphQL CSRF safety (F4)" do
  let(:client) { Tina4::TestClient.new }
  # A valid bearer so the POST requests clear the write-route auth gate and the
  # test isolates the content-type control (the F4 fix), not authentication.
  let(:auth) { { "Authorization" => "Bearer #{Tina4::Auth.get_token({ 'sub' => 'test' })}" } }

  before do
    ENV["TINA4_SECRET"] ||= "test-secret-for-graphql-csrf-spec"
    Tina4::Router.clear!
    gql = Tina4::GraphQL.new
    gql.schema.add_query("ping", {}, "String") { |_r, _a, _c| "pong" }
    gql.schema.add_mutation("bump", {}, "String") { |_r, _a, _c| "bumped" }
    gql.register_route("/graphql")
  end

  after { Tina4::Router.clear! }

  def body_of(resp)
    Tina4.parse_json(resp.body)
  rescue StandardError
    {}
  end

  it "refuses a mutation over GET" do
    resp = client.get("/graphql?query=#{CGI.escape('mutation { bump }')}")
    messages = (body_of(resp)["errors"] || []).map { |e| e["message"] }.join(" ")
    expect(messages).to include("Mutations are not allowed over GET"),
                         "GET ran a mutation (CSRF). errors=#{messages.inspect}"
  end

  it "runs an ordinary query over GET" do
    # Positive twin: read-only GET still works.
    resp = client.get("/graphql?query=#{CGI.escape('{ ping }')}")
    expect(body_of(resp).dig("data", "ping")).to eq("pong")
  end

  it "rejects a POST whose body is sent as text/plain" do
    resp = client.post("/graphql",
                       body: JSON.generate({ query: "mutation { bump }" }),
                       headers: auth.merge("Content-Type" => "text/plain"))
    expect(resp.status).to eq(415),
                           "text/plain POST was accepted (CSRF). status=#{resp.status}"
  end

  it "accepts a POST with an application/json content-type" do
    # Positive twin: a same-origin XHR / server client sets application/json.
    resp = client.post("/graphql", json: { query: "mutation { bump }" }, headers: auth)
    expect(resp.status).to eq(200)
    expect(body_of(resp).dig("data", "bump")).to eq("bumped")
  end
end
