# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ORM model for the S2 AutoCrud -> components.schemas mirror. Top-level, uniquely
# named so it cannot clobber a constant in another spec file (Ruby constants are
# global; a bare constant in an RSpec.describe would leak onto Object).
class SwaggerCrudModel < Tina4::ORM
  table_name "swagger_crud_models"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title, nullable: false
  integer_field :qty, default: 0
end

# 3.13.96 Swagger parity contract (decisions doc S2/S3/S5/S6). Every assertion
# here mirrors the settled cross-framework shape; Python is the reference.
RSpec.describe "Tina4::Swagger 3.13.96 parity" do
  before(:each) do
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
  end

  # Scrub the swagger env so defaults are the COMPUTED defaults, not ambient.
  around(:each) do |example|
    keys = %w[TINA4_SWAGGER_VERSION TINA4_SWAGGER_DESCRIPTION TINA4_SWAGGER_SERVERS
              TINA4_SWAGGER_INCLUDE TINA4_SWAGGER_EXCLUDE]
    saved = ENV.to_hash.slice(*keys)
    keys.each { |k| ENV.delete(k) }
    example.run
    keys.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # ── S3: info.version defaults to 1.0.0, description to "" ────────────────
  describe "S3 info defaults" do
    it "defaults info.version to 1.0.0 (the APP version, not the framework version)" do
      spec = Tina4::Swagger.generate
      expect(spec["info"]["version"]).to eq("1.0.0")
      # Guard the intent: it must NOT be the framework version.
      expect(spec["info"]["version"]).not_to eq(Tina4::VERSION)
    end

    it "still honours TINA4_SWAGGER_VERSION as an override" do
      ENV["TINA4_SWAGGER_VERSION"] = "2.5.0"
      spec = Tina4::Swagger.generate
      expect(spec["info"]["version"]).to eq("2.5.0")
    ensure
      ENV.delete("TINA4_SWAGGER_VERSION")
    end

    it "defaults info.description to the empty string" do
      spec = Tina4::Swagger.generate
      expect(spec["info"]["description"]).to eq("")
    end
  end

  # ── S5: one response set on an undecorated route ─────────────────────────
  describe "S5 response codes" do
    it "emits ONLY 200 on an undecorated public GET (no invented 400/401/404/500)" do
      Tina4.get("/api/public_thing") { |_req, res| res.json({}) }
      responses = Tina4::Swagger.generate["paths"]["/api/public_thing"]["get"]["responses"]
      expect(responses.keys).to eq(["200"])
    end

    it "adds 401 on a secured write, and nothing else beyond 200" do
      Tina4.post("/api/secure_thing") { |_req, res| res.json({}) } # POST is secure-by-default
      responses = Tina4::Swagger.generate["paths"]["/api/secure_thing"]["post"]["responses"]
      expect(responses.keys).to contain_exactly("200", "401")
      expect(responses["401"]["description"]).to eq("Unauthorized")
    end

    it "does NOT add 401 to a genuinely public write (no auth_required, no handler)" do
      # Router.post carries no default auth_handler, so .no_auth genuinely opens
      # the route (this is exactly the AutoCrud public-model path). resolve_security
      # then returns nil -> no security -> no 401.
      Tina4::Router.post("/api/open_thing") { |_req, res| res.json({}) }.no_auth
      responses = Tina4::Swagger.generate["paths"]["/api/open_thing"]["post"]["responses"]
      expect(responses.keys).to eq(["200"])
    end
  end

  # ── S6: operationId preserves leading underscores (no collision) ─────────
  describe "S6 operationId collisions" do
    it "gives /__health and /health distinct ids by preserving underscores" do
      Tina4.get("/__health") { |_req, res| res.json({}) }
      Tina4.get("/health") { |_req, res| res.json({}) }
      spec = Tina4::Swagger.generate
      health_internal = spec["paths"]["/__health"]["get"]["operationId"]
      health_public   = spec["paths"]["/health"]["get"]["operationId"]
      expect(health_internal).to eq("get___health")
      expect(health_public).to eq("get_health")
      expect(health_internal).not_to eq(health_public)
    end
  end

  # ── S2: AutoCrud populates components.schemas keyed by model CLASS name ───
  describe "S2 AutoCrud components.schemas" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_swagger_s2") }
    let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "s2.db")) }

    before(:each) do
      Tina4.bind_database(db)
      db.execute("CREATE TABLE IF NOT EXISTS swagger_crud_models (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, qty INTEGER DEFAULT 0)")
      Tina4::AutoCrud.register(SwaggerCrudModel)
      Tina4::AutoCrud.generate_routes
    end

    after(:each) do
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    it "emits components.schemas keyed by the model CLASS name with a required array" do
      spec = Tina4::Swagger.generate
      schema = spec.dig("components", "schemas", "SwaggerCrudModel")
      expect(schema).not_to be_nil, "AutoCrud did not populate components.schemas"
      expect(schema["properties"]).to include("id", "title", "qty")
      expect(schema["properties"]["title"]["type"]).to eq("string")
      expect(schema["properties"]["id"]["readOnly"]).to be(true)
      # required is derived from nullability: only the non-nullable `title`.
      expect(schema["required"]).to eq(["title"])
    end

    it "$refs the model schema from the POST requestBody instead of {type:object}" do
      spec = Tina4::Swagger.generate
      body = spec.dig("paths", "/api/swagger_crud_models", "post",
                      "requestBody", "content", "application/json", "schema")
      expect(body).to eq({ "$ref" => "#/components/schemas/SwaggerCrudModel" })
    end
  end
end
