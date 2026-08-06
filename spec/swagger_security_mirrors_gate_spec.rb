# The document must say what the server enforces.
#
# MEASURED 2026-08-06, all four frameworks, same app, real servers:
#
#     POST /api/items with no Authorization header
#       python  runtime 401   spec security [{"bearerAuth": []}]
#       php     runtime 401   spec security [{"bearerAuth": []}]
#       ruby    runtime 401   spec security ABSENT      <-- enforced, undocumented
#       node    runtime 401   spec security [{"bearerAuth": []}]
#
# Ruby carries TWO flags and Swagger read the wrong one:
#
#   router.rb  @auth_required = %w[POST PUT PATCH DELETE].include?(@method)
#              This is what dispatch enforces. `.secure` / `.no_auth` change
#              only this.
#   swagger.rb return ... if route.auth_handler
#              `auth_handler:` defaults to nil and is set only by the
#              `auth:` keyword or the secure_* helpers.
#
# So EVERY write route registered the ordinary way was enforced-secured and
# documented-public, and `.secure` on a GET never reached the document at all.
# Systemic rather than DSL-specific: AutoCrud's generated writes did the same.
#
# A published API document that says a write endpoint is public, on a server
# that answers 401, sends every consumer down a debugging path that ends at
# "the docs are wrong".
#
# No mocks: the real Router, the real Swagger generator, the real flags.

require "spec_helper"

RSpec.describe "swagger security mirrors the runtime gate" do
  before do
    Tina4::Router.clear!
    Tina4::Swagger.reset_registry if Tina4::Swagger.respond_to?(:reset_registry)
  end

  after { Tina4::Router.clear! }

  def operation(spec, path, verb)
    (spec["paths"] || spec[:paths] || {}).dig(path, verb) || {}
  end

  it "documents security on a write route registered the ordinary way" do
    Tina4::Router.post("/api/items") { |_req, res| res.json({ ok: true }, 200) }

    route = Tina4::Router.routes.find { |r| r.path == "/api/items" && r.method == "POST" }
    # The premise: dispatch WILL enforce this. If that ever stops being true the
    # test is asserting the wrong thing, so pin it rather than assume it.
    expect(route.auth_required).to be(true), "premise broken: POST is no longer secure by default"

    op = operation(Tina4::Swagger.generate, "/api/items", "post")
    expect(op["security"]).to eq([{ "bearerAuth" => [] }]),
      "a route the server answers 401 for is documented as public: #{op['security'].inspect}"
  end

  it "documents security on a GET explicitly marked secure" do
    Tina4::Router.get("/api/private") { |_req, res| res.json({ ok: true }, 200) }.secure

    op = operation(Tina4::Swagger.generate, "/api/private", "get")
    expect(op["security"]).to eq([{ "bearerAuth" => [] }]),
      ".secure on a GET is enforced but never reached the document"
  end

  it "omits security on a write route explicitly opened with no_auth" do
    # The negative half. A rule that stamped security on every write would pass
    # the two cases above and be just as wrong the other way.
    Tina4::Router.post("/api/public").tap { |r| r.no_auth }
    Tina4::Router.routes.find { |r| r.path == "/api/public" }&.instance_variable_set(:@handler, proc { |_q, s| s })

    route = Tina4::Router.routes.find { |r| r.path == "/api/public" && r.method == "POST" }
    expect(route.auth_required).to be(false), "premise broken: no_auth no longer opens a write route"

    op = operation(Tina4::Swagger.generate, "/api/public", "post")
    expect(op["security"]).to be_nil,
      "a public write route is documented as requiring auth: #{op['security'].inspect}"
  end
end
