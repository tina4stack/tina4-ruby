# frozen_string_literal: true

# Swagger / OpenAPI CONTRACT suite (Feature 47, ADR-0004) for tina4-ruby.
#
# This is the Ruby half of the shared fixture
#   tina4-documentation/plan/v3/fixtures/swagger_contract.json
# whose ten invariants were written from a measured four-way audit: one
# identical app per framework, real servers, the document fetched over a real
# socket from /swagger/openapi.json and checked with a real OpenAPI validator.
# TWO OF FOUR SHIPPED A STRUCTURALLY INVALID DOCUMENT; the fixture is "owed"
# rather than proven until a NAMED suite exists in every framework it names.
# This file is that suite for Ruby: exactly one example per invariant, its
# description carrying the invariant's stem so the shared auditor can match it.
#
# NO MOCKS. Every example drives the REAL Router, the REAL Tina4::Swagger
# generator, and (where the rule is about what a client receives) the REAL
# Tina4::RackApp over the in-process Tina4::TestClient, which dispatches through
# the same front controller a live HTTP request goes through. Invariant #1
# validates the fetched document with a REAL OpenAPI 3.0 validator
# (openapi3_parser, a TEST-ONLY development dependency — the framework core
# stays zero-dependency). Swagger generation is pure over the route registry and
# a model's field definitions, so no example needs a live database; the "real
# thing" here is the generator, the dispatcher and the validator, and all three
# are exercised for real.

require "spec_helper"
require "openapi3_parser"

# ORM model for invariants #1 and #5. Declared at TOP LEVEL, uniquely named, so
# it can never clobber a constant in another spec file — a bare constant inside
# an RSpec.describe lands on Object and is global (see spec_helper's notes). A
# NOT NULL column (`name`) is what makes `required` non-empty; the auto-increment
# PK is what makes `readOnly` true. No table is created: model_schema introspects
# the class-level field definitions, not the database.
class SwaggerContractModel < Tina4::ORM
  table_name "swagger_contract_models"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, nullable: false
  integer_field :quantity, default: 0
end

RSpec.describe "Tina4 Swagger contract (3.13.96)" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::Swagger.reset_registry if Tina4::Swagger.respond_to?(:reset_registry)
  end

  after(:each) { Tina4::Router.clear! }

  # Scrub the whole swagger env so every example starts from the COMPUTED
  # defaults, not whatever the ambient shell contributes. Individual examples
  # layer their own overrides on top with #with_env. Legacy fallbacks
  # (SWAGGER_CONTACT_TEAM/_URL/SWAGGER_DEV_URL), the enable switch (TINA4_DEBUG),
  # the health path and PROJECT_NAME (which seeds info.title) are scrubbed too.
  around(:each) do |example|
    keys = ENV.keys.select { |k| k.start_with?("TINA4_SWAGGER_") } +
           %w[SWAGGER_CONTACT_TEAM SWAGGER_CONTACT_URL SWAGGER_DEV_URL
              TINA4_DEBUG TINA4_HEALTH_PATH PROJECT_NAME]
    saved = ENV.to_hash.slice(*keys)
    keys.each { |k| ENV.delete(k) }
    example.run
    keys.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # Set/restore specific env vars around a block (parity with the pattern in
  # swagger_static_gate_spec.rb). Restores to the value seen at entry — which,
  # under the around-hook scrub above, is nil.
  def with_env(pairs)
    previous = {}
    pairs.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def expected_default_security(spec)
    security = [{ "bearerAuth" => [] }]
    security << { "ssoSession" => [] } if spec.dig("components", "securitySchemes", "ssoSession")
    security
  end

  # Fetch a path through a REAL RackApp + in-process TestClient — the same front
  # controller (route match -> swagger/static branch -> gate) a live request
  # hits. A fresh RackApp per call, so the swagger gate re-reads the env each
  # example sets.
  def fetch(path)
    Tina4::TestClient.new(Tina4::RackApp.new).get(path)
  end

  # The schema fragment for a named path parameter on a GET operation.
  def get_param_schema(spec, path, name)
    params = spec.dig("paths", path, "get", "parameters") || []
    param = params.find { |p| p["name"] == name }
    param && param["schema"]
  end

  # ── #1 the-document-validates ────────────────────────────────────────────
  # The document fetched from /swagger/openapi.json passes a REAL OpenAPI
  # validator, for an app with routes, a path param, a model and a secured
  # route. This is the invariant that catches a structurally invalid document on
  # its own — the one two frameworks failed at the audit.
  it "the document validates against a real OpenAPI validator for a full app (routes, path param, model, secured route)" do
    with_env("TINA4_SWAGGER_ENABLED" => "true") do
      Tina4.get("/api/products") { |_req, res| res.json([]) }                     # a route
      Tina4.get("/api/products/{id:int}") { |_req, res| res.json({}) }            # a path param
      # a secured write (POST is secure-by-default) that also references a model
      Tina4.post("/api/products", swagger_meta: { model: SwaggerContractModel }) { |_req, res| res.json({}) }

      response = fetch("/swagger/openapi.json")
      expect(response.status).to eq(200)
      expect(response.content_type).to include("application/json")

      document = response.json
      # Non-vacuous: the app really did carry each of the four ingredients.
      expect(document["paths"]).to include("/api/products", "/api/products/{id}")
      expect(document.dig("components", "schemas")).to include("SwaggerContractModel")
      expect(document.dig("paths", "/api/products", "post", "security")).to eq(expected_default_security(document))

      parsed = Openapi3Parser.load(document)
      expect(parsed.valid?).to be(true),
        "openapi3_parser rejected the generated document:\n  " +
        parsed.errors.to_a.map { |e| "#{e.message} @ #{e.source_location&.pointer}" }.join("\n  ")
    end
  end

  # ── #2 every-template-expression-has-a-parameter ─────────────────────────
  # Every {name} in a path key has a matching in:path required:true parameter,
  # and the key itself carries no framework type token (no leaked "{id:int}").
  # Whole-document assertion, on purpose: a per-route check passes on the routes
  # you happen to write and misses the one the framework registers itself.
  it "every path template has a parameter, and the path key carries no framework type token" do
    Tina4.get("/api/users/{id:int}") { |_req, res| res.json({}) }
    Tina4.get("/api/users/{uid:uuid}/posts/{slug:slug}") { |_req, res| res.json({}) }
    Tina4.post("/api/things") { |_req, res| res.json({}) } # a path with no template at all

    spec = Tina4::Swagger.generate

    # Guard against a vacuous pass: there IS at least one templated path.
    expect(spec["paths"].keys.any? { |k| k.include?("{") }).to be(true)

    spec["paths"].each do |path_key, item|
      expect(path_key).not_to include(":"), "path key leaked a framework type token: #{path_key}"

      operations = item.values.select { |op| op.is_a?(Hash) }
      declared_path_params = operations.flat_map { |op| op["parameters"] || [] }
                                       .select { |p| p["in"] == "path" }

      # Every declared path parameter is required:true (OpenAPI mandates it).
      declared_path_params.each do |param|
        expect(param["required"]).to be(true),
          "#{path_key} declares path param #{param['name'].inspect} without required:true"
      end

      # Every {token} in the key is backed by an in:path required:true parameter.
      path_key.scan(/\{(\w+)\}/).flatten.each do |token|
        match = declared_path_params.any? { |p| p["name"] == token && p["required"] == true }
        expect(match).to be(true),
          "path template {#{token}} in #{path_key} has no matching in:path required parameter"
      end
    end
  end

  # ── #3 security-mirrors-the-runtime-gate ─────────────────────────────────
  # Security is derived from auth_required — what DISPATCH enforces — not the
  # parallel auth_handler flag Ruby used to branch on. POSITIVE: a secured write
  # documents security. NEGATIVE: a .no_auth write documents none. Mirrors the
  # assertions in swagger_security_mirrors_gate_spec.rb, with both controls in
  # one example so a rule that stamped security on every write cannot pass.
  it "security mirrors the runtime gate: secured write documents it, .no_auth write does not" do
    # POSITIVE — a write registered the ordinary way (auth_handler stays nil).
    Tina4::Router.post("/api/items") { |_req, res| res.json({}) }
    write_route = Tina4::Router.routes.find { |r| r.path == "/api/items" && r.method == "POST" }
    expect(write_route.auth_required).to be(true), "premise broken: POST is no longer secure by default"

    # POSITIVE — a GET explicitly marked secure (must reach the document).
    Tina4::Router.get("/api/private") { |_req, res| res.json({}) }.secure

    # NEGATIVE — a write explicitly opened.
    Tina4::Router.post("/api/public") { |_req, res| res.json({}) }.no_auth
    open_route = Tina4::Router.routes.find { |r| r.path == "/api/public" && r.method == "POST" }
    expect(open_route.auth_required).to be(false), "premise broken: no_auth no longer opens a write route"

    spec = Tina4::Swagger.generate
    expect(spec.dig("paths", "/api/items", "post", "security")).to eq(expected_default_security(spec))
    expect(spec.dig("paths", "/api/private", "get", "security")).to eq(expected_default_security(spec))
    # security is only emitted when non-nil, so an open write has no key at all.
    expect(spec.dig("paths", "/api/public", "post")).not_to have_key("security")
  end

  # ── #4 path-param-types-map-identically ──────────────────────────────────
  # Each typed route token maps to the same JSON Schema fragment: int/integer ->
  # integer, float/number -> number, uuid -> string+format, slug/alpha/alnum ->
  # string+pattern, bare -> string. Ruby's router REJECTS a genuinely-unknown
  # token at registration (a security feature, tina4-book#125), so the
  # "degrade to string" branch is reached by a token the router accepts but the
  # generator does not richly map — `path` — which correctly degrades to string.
  it "each typed path token maps identically to its JSON Schema fragment" do
    Tina4.get("/t/int/{v:int}") { |_req, res| res.json({}) }
    Tina4.get("/t/integer/{v:integer}") { |_req, res| res.json({}) }
    Tina4.get("/t/float/{v:float}") { |_req, res| res.json({}) }
    Tina4.get("/t/number/{v:number}") { |_req, res| res.json({}) }
    Tina4.get("/t/uuid/{v:uuid}") { |_req, res| res.json({}) }
    Tina4.get("/t/slug/{v:slug}") { |_req, res| res.json({}) }
    Tina4.get("/t/alpha/{v:alpha}") { |_req, res| res.json({}) }
    Tina4.get("/t/alnum/{v:alnum}") { |_req, res| res.json({}) }
    Tina4.get("/t/bare/{v}") { |_req, res| res.json({}) }         # bare -> string
    Tina4.get("/t/path/{v:path}") { |_req, res| res.json({}) }    # accepted-but-unmapped -> string

    spec = Tina4::Swagger.generate

    expect(get_param_schema(spec, "/t/int/{v}", "v")).to eq("type" => "integer")
    expect(get_param_schema(spec, "/t/integer/{v}", "v")).to eq("type" => "integer")
    expect(get_param_schema(spec, "/t/float/{v}", "v")).to eq("type" => "number")
    expect(get_param_schema(spec, "/t/number/{v}", "v")).to eq("type" => "number")
    expect(get_param_schema(spec, "/t/uuid/{v}", "v")).to eq("type" => "string", "format" => "uuid")
    expect(get_param_schema(spec, "/t/slug/{v}", "v")).to eq("type" => "string", "pattern" => "^[a-z0-9]+(?:-[a-z0-9]+)*$")
    expect(get_param_schema(spec, "/t/alpha/{v}", "v")).to eq("type" => "string", "pattern" => "^[A-Za-z]+$")
    expect(get_param_schema(spec, "/t/alnum/{v}", "v")).to eq("type" => "string", "pattern" => "^[A-Za-z0-9]+$")
    expect(get_param_schema(spec, "/t/bare/{v}", "v")).to eq("type" => "string")
    expect(get_param_schema(spec, "/t/path/{v}", "v")).to eq("type" => "string")
  end

  # ── #5 model-schemas-are-referenced-not-inlined ──────────────────────────
  # An ORM model becomes ONE components.schemas entry keyed by the model CLASS
  # name (not the table name), with `required` derived from nullability, and is
  # referenced by $ref rather than inlined. Ruby previously emitted NO
  # components.schemas at all — confirm that is fixed.
  it "an ORM model schema keyed by class name, has a required array, and is referenced by $ref" do
    Tina4.post("/api/widgets", swagger_meta: { model: SwaggerContractModel }) { |_req, res| res.json({}) }

    spec = Tina4::Swagger.generate

    schema = spec.dig("components", "schemas", "SwaggerContractModel")
    expect(schema).not_to be_nil, "Ruby emitted no components.schemas for the model"
    expect(schema["type"]).to eq("object")
    expect(schema["properties"]).to include("id", "name", "quantity")
    # required derived from nullability: only the NOT NULL `name`.
    expect(schema["required"]).to eq(["name"])
    # the auto-increment PK is read-only.
    expect(schema.dig("properties", "id", "readOnly")).to be(true)

    # Keyed by the CLASS name, never the table name.
    expect(spec.dig("components", "schemas")).not_to have_key("swagger_contract_models")

    # Referenced by $ref from the requestBody, not inlined as {type: object}.
    body_schema = spec.dig("paths", "/api/widgets", "post",
                           "requestBody", "content", "application/json", "schema")
    expect(body_schema).to eq("$ref" => "#/components/schemas/SwaggerContractModel")
  end

  # ── #6 info-and-servers-defaults-are-one-value ───────────────────────────
  # With no TINA4_SWAGGER_* set: info.version is 1.0.0 (NOT the framework
  # version — Ruby's old bug documented an undocumented app as API v3.13.x),
  # info.description is "", and servers[0].url is "/" (correct under any port,
  # host or proxy). The around-hook has already scrubbed the env.
  it "info and servers defaults identical with no env set: version 1.0.0, description empty, server /" do
    spec = Tina4::Swagger.generate

    expect(spec["info"]["version"]).to eq("1.0.0")
    expect(spec["info"]["version"]).not_to eq(Tina4::VERSION)
    expect(spec["info"]["description"]).to eq("")
    expect(spec["servers"]).to be_a(Array)
    expect(spec["servers"].first["url"]).to eq("/")
  end

  # ── #7 env-surface-is-identical ──────────────────────────────────────────
  # Every documented TINA4_SWAGGER_* variable is actually read. Spot-check
  # several, including CONTACT_TEAM and CONTACT_URL — the two PHP silently
  # ignored, which is the exact drift this invariant exists to catch.
  it "the swagger env surface identical: documented TINA4_SWAGGER_* vars are read (incl CONTACT_TEAM/_URL)" do
    with_env(
      "TINA4_SWAGGER_TITLE"         => "Acme API",
      "TINA4_SWAGGER_VERSION"       => "9.9.9",
      "TINA4_SWAGGER_DESCRIPTION"   => "The Acme public API",
      "TINA4_SWAGGER_CONTACT_EMAIL" => "api@acme.test",
      "TINA4_SWAGGER_CONTACT_TEAM"  => "Acme Platform Team",
      "TINA4_SWAGGER_CONTACT_URL"   => "https://acme.test/support",
      "TINA4_SWAGGER_LICENSE"       => "MIT",
      "TINA4_SWAGGER_SERVERS"       => "https://one.acme.test,https://two.acme.test",
      "TINA4_SWAGGER_BEARER_FORMAT" => "opaque"
    ) do
      spec = Tina4::Swagger.generate

      expect(spec["info"]["title"]).to eq("Acme API")
      expect(spec["info"]["version"]).to eq("9.9.9")
      expect(spec["info"]["description"]).to eq("The Acme public API")
      expect(spec.dig("info", "contact", "email")).to eq("api@acme.test")
      expect(spec.dig("info", "contact", "name")).to eq("Acme Platform Team")   # CONTACT_TEAM
      expect(spec.dig("info", "contact", "url")).to eq("https://acme.test/support") # CONTACT_URL
      expect(spec.dig("info", "license", "name")).to eq("MIT")
      expect(spec["servers"].map { |s| s["url"] }).to eq(%w[https://one.acme.test https://two.acme.test])
      expect(spec.dig("components", "securitySchemes", "bearerAuth", "bearerFormat")).to eq("opaque")
    end
  end

  # ── #8 disabled-means-nothing-is-served ──────────────────────────────────
  # TINA4_SWAGGER_ENABLED=false 404s the UI path, its trailing-slash form, the
  # spec endpoint AND the bundled UI assets — end to end through the real app.
  # A positive control (enabled -> served) proves the 404s are the GATE firing,
  # not a routing accident, so this is a real gate rather than a ghost.
  it "disabled serves nothing: UI, trailing slash, spec endpoint and bundled assets all 404" do
    gated_paths = %w[/swagger /swagger/ /swagger/openapi.json
                     /swagger/index.html /swagger/oauth2-redirect.html]

    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "false") do
      gated_paths.each do |path|
        expect(fetch(path).status).to eq(404), "#{path} was served with swagger disabled"
      end
    end

    # Positive control: the same paths DO serve when enabled.
    with_env("TINA4_SWAGGER_ENABLED" => "true") do
      expect(fetch("/swagger").status).to eq(200)
      expect(fetch("/swagger/openapi.json").status).to eq(200)
      expect(fetch("/swagger/index.html").status).to eq(200)
    end
  end

  # ── #9 only-the-application-is-documented ────────────────────────────────
  # Framework-internal routes are excluded by ONE shared rule — the /swagger and
  # /__dev prefixes — not a per-framework list. (The audit found PHP the
  # divergent over-publisher; Ruby, like the Python reference, excludes exactly
  # these prefixes. The health endpoints /__health and /health are documented in
  # all four by design and are deliberately NOT part of this exclusion.)
  it "only the application is documented: framework-internal /swagger and /__dev routes excluded" do
    Tina4.get("/api/orders") { |_req, res| res.json([]) }              # application route -> documented
    Tina4::Router.get("/__dev/api/secret") { |_req, res| res.json({}) } # internal -> excluded
    Tina4::Router.get("/swagger/custom") { |_req, res| res.json({}) }   # internal -> excluded

    spec = Tina4::Swagger.generate

    expect(spec["paths"]).to have_key("/api/orders")
    expect(spec["paths"].keys).not_to include("/__dev/api/secret", "/swagger/custom")
    leaked = spec["paths"].keys.select do |p|
      p == "/__dev" || p.start_with?("/__dev/") || p == "/swagger" || p.start_with?("/swagger/")
    end
    expect(leaked).to be_empty, "framework-internal routes leaked into the document: #{leaked.inspect}"
  end

  # ── #10 operation-ids-are-stable-and-distinct ────────────────────────────
  # Two distinct paths never collapse to one operationId. /__health and /health
  # stay distinct because the leading underscores are PRESERVED — Ruby used to
  # collapse both to get_health and suffix _2 onto whichever registered second
  # (order-dependent, so a consumer's SDK method name depended on registration
  # order).
  it "operation ids stable and distinct: /__health and /health never collapse (underscores preserved)" do
    Tina4.get("/__health") { |_req, res| res.json({}) }
    Tina4.get("/health") { |_req, res| res.json({}) }
    Tina4.get("/api/users") { |_req, res| res.json({}) }
    Tina4.get("/api/items") { |_req, res| res.json({}) }

    spec = Tina4::Swagger.generate

    internal_id = spec.dig("paths", "/__health", "get", "operationId")
    public_id   = spec.dig("paths", "/health", "get", "operationId")
    expect(internal_id).to eq("get___health")
    expect(public_id).to eq("get_health")
    expect(internal_id).not_to eq(public_id)

    # No two operations anywhere share an operationId.
    ids = spec["paths"].values.flat_map do |item|
      item.values.select { |op| op.is_a?(Hash) }.map { |op| op["operationId"] }
    end.compact
    duplicates = ids.tally.select { |_id, count| count > 1 }.keys
    expect(duplicates).to be_empty, "duplicate operationIds: #{duplicates.inspect}"
  end

  # ── #11 spec-reflects-a-route-added-after-boot ───────────────────────────
  # The document reflects a route registered AFTER an earlier fetch — the spec
  # must re-read the LIVE route table every time, never a snapshot frozen at
  # server boot. Node's generator closed over a boot-time `router.getRoutes()`
  # capture (SWAG-NODE-BOOT-SNAPSHOT); Ruby's Swagger.generate already reads
  # Tina4::Router.routes live on every call, and this pins that.
  it "spec reflects a route added after boot: a route registered after an earlier fetch is documented" do
    with_env("TINA4_SWAGGER_ENABLED" => "true") do
      Tina4.get("/contract/before-boot") { |_req, res| res.json({}) }

      before_doc = fetch("/swagger/openapi.json").json
      expect(before_doc["paths"]).to have_key("/contract/before-boot")
      expect(before_doc["paths"]).not_to have_key("/contract/late-added"),
        "premise broken: the late route must not exist before it is registered"

      # Simulate a hot-reload registering a NEW route after the first fetch —
      # exactly what DevReload does mid-process.
      Tina4.get("/contract/late-added") { |_req, res| res.json({}) }

      after_doc = fetch("/swagger/openapi.json").json
      expect(after_doc["paths"]).to have_key("/contract/late-added"),
        "the document must reflect a route registered after an earlier fetch, not a frozen boot snapshot"
      expect(after_doc["paths"]).to have_key("/contract/before-boot")
    end
  end

  # ── #12 internal-feedback-route-is-never-in-the-spec ─────────────────────
  # /__feedback/* is excluded by the SAME shared internal-prefix rule as
  # /swagger and /__dev, regardless of how or when it was registered. Node's
  # /__feedback/* was kept out of the spec only by BOOT ORDERING (swagger
  # snapshotted routes before DevAdmin registered the feedback routes), not by
  # its exclusion list — a reorder would have published
  # `POST /__feedback/api/turn` as a secured route (SWAG-NODE-FEEDBACK-LEAK).
  # Ruby dispatches /__feedback outside Tina4::Router in production (like
  # Python), so this registers it directly through the real public Router API
  # (the same synthetic-internal-route pattern invariant #9 already uses for
  # /__dev and /swagger) to prove the RULE catches it, not registration luck.
  it "internal feedback route is never in the spec: /__feedback excluded regardless of registration" do
    Tina4.get("/contract/app-route") { |_req, res| res.json([]) }
    Tina4::Router.get("/__feedback/widget.js") { |_req, res| res.json({}) }
    Tina4::Router.post("/__feedback/api/turn") { |_req, res| res.json({}) }

    spec = Tina4::Swagger.generate

    expect(spec["paths"]).to have_key("/contract/app-route")
    expect(spec["paths"].keys).not_to include("/__feedback/widget.js", "/__feedback/api/turn")
    leaked = spec["paths"].keys.select { |p| p.start_with?("/__feedback") }
    expect(leaked).to be_empty, "framework-internal /__feedback routes leaked into the document: #{leaked.inspect}"
  end

  # ── #13 secured-op-per-op-shape-is-identical ──────────────────────────────
  # A secured operation's security + 401 + summary/tags shape is
  # byte-identical across all four frameworks (SWAG-401-SHAPE +
  # SWAG-SHAPE-DRIFT). Ruby always populated summary/tags (unlike Python) but
  # also always stamped a fabricated `description: ""` on every undecorated
  # operation, the one shape drift where Ruby (not Python) was the odd one
  # out. The negative control proves summary/tags populate regardless of
  # security, and that no description is fabricated either way.
  it "secured op per-op shape is identical: security + 401 + summary/tags converge across all four" do
    Tina4::Router.post("/contract/shape-item") { |_req, res| res.json({}) }        # secured by default, undecorated
    Tina4::Router.post("/contract/shape-public") { |_req, res| res.json({}) }.no_auth

    spec = Tina4::Swagger.generate

    secured = spec.dig("paths", "/contract/shape-item", "post")
    expect(secured["security"]).to eq(expected_default_security(spec))
    expect(secured["responses"]["401"]).to eq("description" => "Unauthorized")
    expect(secured["summary"]).to eq("POST /contract/shape-item")
    expect(secured["tags"]).to eq(["contract"])
    expect(secured).not_to have_key("description"), "an undecorated operation must not fabricate a description"

    public_op = spec.dig("paths", "/contract/shape-public", "post")
    expect(public_op).not_to have_key("security")
    expect(public_op["responses"]).not_to have_key("401")
    expect(public_op["summary"]).to eq("POST /contract/shape-public"), "summary populates regardless of security"
    expect(public_op["tags"]).to eq(["contract"]), "tags populate regardless of security"
    expect(public_op).not_to have_key("description")
  end
end
