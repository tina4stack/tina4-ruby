# frozen_string_literal: true

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "shellwords"

RSpec.describe "CLI generate commands" do
  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4_cli_gen_test") do |dir|
      @tmp_dir = dir
      Dir.chdir(dir) do
        example.run
      end
    end
  end

  # ── generate model ─────────────────────────────────────────────

  describe "generate model" do
    it "creates a model file in src/orm/" do
      expect {
        cli.run(["generate", "model", "Product"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "orm", "product.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("class Product < Tina4::ORM")
      expect(content).to include('table_name "product"')
      expect(content).to include("integer_field :id, primary_key: true, auto_increment: true")
    end

    it "creates a model with custom fields" do
      expect {
        cli.run(["generate", "model", "Product", "--fields", "name:string,price:float"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "orm", "product.rb")
      content = File.read(path)
      expect(content).to include("string_field :name")
      expect(content).to include("float_field :price")
    end

    it "generates a matching migration" do
      expect {
        cli.run(["generate", "model", "Product", "--fields", "name:string"])
      }.to output(/Created/).to_stdout

      migrations = Dir.glob(File.join(@tmp_dir, "migrations", "*create_product*.sql"))
      expect(migrations.length).to be >= 1
    end

    it "does not overwrite existing model" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "orm"))
      File.write(File.join(@tmp_dir, "src", "orm", "product.rb"), "existing")

      expect {
        cli.run(["generate", "model", "Product"])
      }.to output(/already exists/).to_stdout

      expect(File.read(File.join(@tmp_dir, "src", "orm", "product.rb"))).to eq("existing")
    end

    it "adds created_at field" do
      expect {
        cli.run(["generate", "model", "Widget"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "widget.rb"))
      expect(content).to include("created_at")
    end

    it "uses snake_case for CamelCase names" do
      expect {
        cli.run(["generate", "model", "BlogPost"])
      }.to output(/Created/).to_stdout

      expect(File.exist?(File.join(@tmp_dir, "src", "orm", "blog_post.rb"))).to be true
    end
  end

  # ── generate route ─────────────────────────────────────────────

  describe "generate route" do
    it "creates a route file in src/routes/" do
      expect {
        cli.run(["generate", "route", "widgets"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "routes", "widgets.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("/api/widgets")
    end

    it "creates a route with model reference" do
      expect {
        cli.run(["generate", "route", "products", "--model", "Product"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "routes", "products.rb"))
      expect(content).to include("Product")
      expect(content).to include("product")
    end

    it "does not overwrite existing route" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "routes"))
      File.write(File.join(@tmp_dir, "src", "routes", "widgets.rb"), "existing")

      expect {
        cli.run(["generate", "route", "widgets"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate migration ─────────────────────────────────────────

  describe "generate migration" do
    it "creates a migration file with timestamp" do
      expect {
        cli.run(["generate", "migration", "add_status_to_orders"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*.sql"))
      expect(files.length).to be >= 1

      filename = File.basename(files.first)
      expect(filename).to match(/^\d{14}_add_status_to_orders/)
    end

    it "creates create table SQL for create_ prefixed migrations" do
      expect {
        cli.run(["generate", "migration", "create_orders", "--fields", "name:string,total:float"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*create_orders.sql"))
      content = File.read(files.first)
      expect(content).to include("CREATE TABLE IF NOT EXISTS")
      expect(content).to include("name VARCHAR(255)")
      expect(content).to include("total REAL")
    end

    it "creates a .down.sql rollback file" do
      expect {
        cli.run(["generate", "migration", "create_items"])
      }.to output(/Created/).to_stdout

      down_files = Dir.glob(File.join(@tmp_dir, "migrations", "*create_items.down.sql"))
      expect(down_files.length).to eq(1)
    end

    it "creates placeholder SQL for non-create migrations" do
      expect {
        cli.run(["generate", "migration", "add_email_to_users"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*add_email_to_users.sql"))
      content = File.read(files.first)
      expect(content).to include("-- Write your UP migration SQL here")
    end
  end

  # ── generate middleware ─────────────────────────────────────────

  describe "generate middleware" do
    it "creates a middleware file" do
      expect {
        cli.run(["generate", "middleware", "RateLimiter"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "middleware", "rate_limiter.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("class RateLimiter")
      expect(content).to include("def self.before_rate_limiter")
      expect(content).to include("def self.after_rate_limiter")
    end

    it "does not overwrite existing middleware" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "middleware"))
      File.write(File.join(@tmp_dir, "src", "middleware", "rate_limiter.rb"), "existing")

      expect {
        cli.run(["generate", "middleware", "RateLimiter"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate test ──────────────────────────────────────────────

  describe "generate test" do
    it "creates a spec file" do
      expect {
        cli.run(["generate", "test", "widgets"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "spec", "widgets_spec.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("RSpec.describe")
    end

    it "creates a model-aware spec when --model is given" do
      expect {
        cli.run(["generate", "test", "products", "--model", "Product"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "spec", "products_spec.rb"))
      expect(content).to include("Product")
      expect(content).to include("creates a product")
      expect(content).to include("deletes a product")
    end

    it "does not overwrite existing spec" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "spec"))
      File.write(File.join(@tmp_dir, "spec", "widgets_spec.rb"), "existing")

      expect {
        cli.run(["generate", "test", "widgets"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate with missing name ─────────────────────────────────

  describe "missing name argument" do
    it "exits with error for generate model without name" do
      expect {
        begin
          cli.run(["generate", "model"])
        rescue SystemExit
          # expected
        end
      }.to output(/Usage/).to_stdout
    end

    it "exits with error for generate without subcommand" do
      expect {
        begin
          cli.run(["generate"])
        rescue SystemExit
          # expected
        end
      }.to output(/Usage/).to_stdout
    end

    it "exits with error for unknown generator" do
      expect {
        begin
          cli.run(["generate", "foobar", "Widget"])
        rescue SystemExit
          # expected
        end
      }.to output(/Unknown generator/).to_stdout
    end
  end

  # ── Helper methods ─────────────────────────────────────────────

  describe "helper methods" do
    it "to_snake_case converts CamelCase" do
      expect(cli.send(:to_snake_case, "BlogPost")).to eq("blog_post")
      expect(cli.send(:to_snake_case, "HTMLParser")).to eq("html_parser")
      expect(cli.send(:to_snake_case, "simple")).to eq("simple")
    end

    it "parse_fields parses comma-separated field definitions" do
      fields = cli.send(:parse_fields, "name:string,price:float,count:integer")
      expect(fields).to eq([["name", "string"], ["price", "float"], ["count", "integer"]])
    end

    it "parse_fields handles fields without type (defaults to string)" do
      fields = cli.send(:parse_fields, "name,email")
      expect(fields).to eq([["name", "string"], ["email", "string"]])
    end

    it "parse_fields handles nil input" do
      expect(cli.send(:parse_fields, nil)).to eq([])
    end

    it "parse_fields handles empty string" do
      expect(cli.send(:parse_fields, "")).to eq([])
    end

    it "to_table_name uses snake_case" do
      expect(cli.send(:to_table_name, "BlogPost")).to eq("blog_post")
    end
  end

  # ── FIELD_TYPE_MAP ─────────────────────────────────────────────

  describe "FIELD_TYPE_MAP" do
    it "drives string_field output for both string and str field types" do
      expect {
        cli.run(["generate", "model", "Thing", "--fields", "name:string,nick:str"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "thing.rb"))
      # Both the "string" and "str" map entries must resolve to string_field in
      # the generated ORM class — exercised through the generator, not by reading
      # the constant against itself.
      expect(content).to include("string_field :name")
      expect(content).to include("string_field :nick")
    end

    it "drives integer_field output and INTEGER DDL for integer and int field types" do
      expect {
        cli.run(["generate", "model", "Thing", "--fields", "count:integer,qty:int"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "thing.rb"))
      # Both the "integer" and "int" map entries must resolve to integer_field.
      expect(content).to include("integer_field :count")
      expect(content).to include("integer_field :qty")

      # The matching create_thing migration emits the :sql mapping (INTEGER) too.
      migrations = Dir.glob(File.join(@tmp_dir, "migrations", "*create_thing.sql"))
      expect(migrations.length).to be >= 1
      migration = File.read(migrations.first)
      expect(migration).to include("count INTEGER")
      expect(migration).to include("qty INTEGER")
    end

    it "drives float_field output and REAL DDL for float and decimal field types" do
      expect {
        cli.run(["generate", "model", "Thing", "--fields", "price:float,rate:decimal"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "thing.rb"))
      # Both the "float" and "decimal" map entries must resolve to float_field.
      expect(content).to include("float_field :price")
      expect(content).to include("float_field :rate")

      # The matching create_thing migration emits the :sql mapping (REAL).
      migrations = Dir.glob(File.join(@tmp_dir, "migrations", "*create_thing.sql"))
      expect(migrations.length).to be >= 1
      migration = File.read(migrations.first)
      expect(migration).to include("price REAL")
      expect(migration).to include("rate REAL")
    end

    it "drives boolean_field output for both boolean and bool field types" do
      expect {
        cli.run(["generate", "model", "Thing", "--fields", "active:boolean,flag:bool"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "thing.rb"))
      # Both the "boolean" and "bool" map entries must resolve to boolean_field.
      expect(content).to include("boolean_field :active")
      expect(content).to include("boolean_field :flag")
    end

    it "emits the :sql type mappings into generated create_ migration DDL" do
      expect {
        cli.run(["generate", "migration", "create_things", "--fields", "name:string,n:integer,body:text"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*create_things.sql"))
      expect(files.length).to be >= 1
      content = File.read(files.first)
      # The :sql values for string/integer/text are emitted verbatim into the DDL.
      expect(content).to include("name VARCHAR(255)")
      expect(content).to include("n INTEGER")
      expect(content).to include("body TEXT")
    end
  end
end

# ══════════════════════════════════════════════════════════════════════════
# Scaffolding-first acceptance matrix — real temp project, real TestClient,
# real ServiceRunner / event bus, NO mocks. Compile + load + boot behaviour,
# not string-grep. Ported from tina4-python tests/test_cli_generate.py.
# ══════════════════════════════════════════════════════════════════════════
require "stringio"

RSpec.describe "CLI scaffolding-first generators" do
  REPO_ROOT = File.expand_path("..", __dir__)
  REPO_LIB  = File.join(REPO_ROOT, "lib")

  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4_scaffold_test") do |dir|
      @tmp_dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  before(:each) do
    Tina4::Router.clear!
    Tina4::ServiceRunner.clear! if Tina4::ServiceRunner.respond_to?(:clear!)
    Tina4::Events.clear
  end

  after(:each) do
    ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
  end

  # Run a generator, capturing (and returning) its stdout so idempotency
  # assertions read it without polluting the test output.
  def gen(*argv)
    original = $stdout
    $stdout = StringIO.new
    cli.run(["generate", *argv])
    $stdout.string
  ensure
    $stdout = original
  end

  def compiles?(path)
    `ruby -c #{path.shellescape} 2>&1`.strip == "Syntax OK"
  end

  # Read a generated file as UTF-8. The AI-FILL / EXTEND banners contain box-
  # drawing chars; the CI env's default_external is US-ASCII, so a plain
  # File.read would tag the bytes wrong and String#scan/#include? would raise.
  def slurp(path)
    File.read(path, encoding: "UTF-8")
  end

  # Reset RSA key material + drop any stray API key so get_token / valid_token
  # agree and no key silently authorises every write (mirrors
  # spec/test_client_auth_spec.rb — real JWT, no mocks).
  def boot_auth!
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(@tmp_dir)
    @prior_api_key = ENV.delete("TINA4_API_KEY")
  end

  def bind_db!
    Tina4.bind_database(Tina4::Database.new("sqlite:///" + File.join(@tmp_dir, "app.db")))
  end

  def load_gen(*parts)
    load File.join(@tmp_dir, *parts)
  end

  # ── Helper unit tests ──────────────────────────────────────────────
  describe "ai_fill / extend_marker / parse_every helpers" do
    it "ai_fill is a grounded fill-spec that raises" do
      block = cli.send(:ai_fill, "create_widget", "persist a widget",
                       "Widget.create(request.body)", "create_widget: persist and return",
                       given: "request.body -> Hash", ret: "response.json(item.to_h, 201)",
                       ground: 'tina4_context("create ORM record", "ruby")')
      expect(block).to include("AI-FILL: create_widget")
      expect(block).to include("# Intent:").and include("# Use:").and include("# Ground:")
      expect(block).to include('raise NotImplementedError, "create_widget: persist and return"')
    end

    it "extend_marker marks without NotImplementedError" do
      block = cli.send(:extend_marker, "validate before persist", "e.g. reject invalid input")
      expect(block).to include("EXTEND: validate before persist")
      expect(block).not_to include("NotImplementedError")
    end

    it "parse_every parses durations, falls back to 60" do
      expect(cli.send(:parse_every, "5m")).to eq(300)
      expect(cli.send(:parse_every, "30s")).to eq(30)
      expect(cli.send(:parse_every, "2h")).to eq(7200)
      expect(cli.send(:parse_every, "1d")).to eq(86400)
      expect(cli.send(:parse_every, "45")).to eq(45)
      expect(cli.send(:parse_every, "")).to eq(60)          # default
      expect(cli.send(:parse_every, "garbage")).to eq(60)   # unparseable → default
    end
  end

  # ── Route: secure-by-default source posture ────────────────────────
  describe "generate route — secure-by-default source" do
    it "model route emits NO opt-out on any write or read by default" do
      gen("model", "Cog", "--fields", "name:string", "--no-migration")
      gen("route", "cogs", "--model", "Cog")
      src = slurp(File.join(@tmp_dir, "src", "routes", "cogs.rb"))
      expect(src).not_to include(".no_auth")
      expect(src).not_to include("auth: false")
      # writes register through Tina4::Router.post/put/delete (secure by default)
      expect(src).to include('Tina4::Router.post "/api/cogs"')
    end

    it "no-model route is an AI-FILL stub — raise, banner, secure by default" do
      gen("route", "items")
      src = slurp(File.join(@tmp_dir, "src", "routes", "items.rb"))
      expect(src).to include("AI-FILL")
      expect(src).to include("raise NotImplementedError")
      expect(src).not_to include(".no_auth")             # secure by default
      # No ACTUAL model import statement (a top-level require_relative line). The
      # AI-FILL `Use:` hint may still MENTION require_relative as guidance inside
      # a comment — that is expected.
      expect(src.lines.grep(/^require_relative/)).to be_empty
    end

    it "--public adds .no_auth on the 3 writes only, never on GET" do
      gen("model", "Gadget", "--fields", "name:string", "--no-migration")
      gen("route", "gadgets", "--model", "Gadget", "--public")
      src = slurp(File.join(@tmp_dir, "src", "routes", "gadgets.rb"))
      expect(src.scan("end.no_auth").length).to eq(3)    # create + update + delete
      # neither GET block is opened
      get_blocks = src.scan(/Tina4::Router\.get.*?\nend(\.no_auth)?/m)
      expect(get_blocks.map { |m| m.include?("no_auth") }).to all(be false)
    end
  end

  # ── Route: secure-by-default BEHAVIOUR via the real TestClient ──────
  describe "generate route — secure-by-default boot-gate (real TestClient)" do
    it "reads public, tokenless write 401, token write 201" do
      boot_auth!
      gen("model", "Sprocket", "--fields", "name:string", "--no-migration")
      gen("route", "sprockets", "--model", "Sprocket")
      load_gen("src", "routes", "sprockets.rb")   # require_relatives the model + registers 5 routes
      bind_db!
      Object.const_get(:Sprocket).create_table

      # all five routes registered
      paths = Tina4::Router.routes.map { |r| [r.method, r.path] }
      expect(paths).to include(["GET", "/api/sprockets"])
      expect(paths).to include(["GET", "/api/sprockets/{id:int}"])
      expect(paths).to include(["POST", "/api/sprockets"])
      expect(paths).to include(["PUT", "/api/sprockets/{id:int}"])
      expect(paths).to include(["DELETE", "/api/sprockets/{id:int}"])

      client = Tina4::TestClient.new
      expect(client.get("/api/sprockets").status).to eq(200)                        # read public
      expect(client.get("/api/sprockets/1").status).to satisfy { |s| [200, 404].include?(s) }
      expect(client.post("/api/sprockets", json: { name: "a" }).status).to eq(401)  # write gated
      token = Tina4::Auth.get_token({ "user_id" => 1 })
      created = client.post("/api/sprockets", json: { name: "a" },
                            headers: { "Authorization" => "Bearer #{token}" })
      expect(created.status).to eq(201)                                             # token → 201
    end

    it "--public opens the writes: anonymous POST creates (201)" do
      boot_auth!
      gen("model", "Widget", "--fields", "name:string", "--no-migration")
      gen("route", "widgets", "--model", "Widget", "--public")
      load_gen("src", "routes", "widgets.rb")
      bind_db!
      Object.const_get(:Widget).create_table

      client = Tina4::TestClient.new
      expect(client.post("/api/widgets", json: { name: "a" }).status).to eq(201)  # open write
      expect(client.delete("/api/widgets/999").status).to satisfy { |s| [204, 404].include?(s) }
    end

    it "no-model stub: gate holds (401) yet the handler raises when called" do
      boot_auth!
      gen("route", "notes")
      load_gen("src", "routes", "notes.rb")
      expect(Tina4::Router.routes.count { |r| r.path.include?("/api/notes") }).to eq(5)
      # gate runs before the (stub) handler → 401, no raise leaks to the client
      expect(Tina4::TestClient.new.post("/api/notes", json: {}).status).to eq(401)
      # the placeholder is LIVE — calling a handler raises NotImplementedError
      route, = Tina4::Router.match("GET", "/api/notes")
      expect { route.handler.call(nil, nil) }.to raise_error(NotImplementedError)
    end
  end

  # ── CRUD: secure posture + the emitted spec runs green ──────────────
  describe "generate crud — secure-by-default" do
    it "default routes are secure (no opt-out)" do
      gen("crud", "Doohickey", "--fields", "name:string")
      src = slurp(File.join(@tmp_dir, "src", "routes", "doohickeys.rb"))
      expect(src).not_to include(".no_auth")
    end

    it "--public opens exactly the 3 writes" do
      gen("crud", "Contraption", "--fields", "name:string", "--public")
      src = slurp(File.join(@tmp_dir, "src", "routes", "contraptions.rb"))
      expect(src.scan("end.no_auth").length).to eq(3)
    end

    it "the emitted CRUD spec runs green in a real rspec subprocess" do
      gen("crud", "Trinket", "--fields", "name:string,qty:int")
      spec_file = File.join(@tmp_dir, "spec", "trinkets_spec.rb")
      expect(File.exist?(spec_file)).to be true
      expect(compiles?(spec_file)).to be true

      # Minimal spec_helper so the emitted spec's `require "spec_helper"`
      # resolves; mirrors the framework's essential per-example resets.
      File.write(File.join(@tmp_dir, "spec", "spec_helper.rb"), <<~RUBY)
        $LOAD_PATH.unshift #{REPO_LIB.inspect}
        require "tina4"
        RSpec.configure do |c|
          c.after(:each) do
            Tina4::Router.clear! if defined?(Tina4::Router)
            Tina4.instance_variable_set(:@database, nil)
            Tina4.instance_variable_set(:@databases, {})
          end
        end
      RUBY

      status, output = run_rspec(spec_file)
      expect(status).to eq(0), output
    end
  end

  # ── The six logic-shaped generators (compile + load + raise + wire) ─
  describe "generate service" do
    it "interval service registers on ServiceRunner; task raises; idempotent" do
      gen("service", "Reaper", "--every", "5m")
      path = File.join(@tmp_dir, "src", "services", "reaper.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      load path
      src = slurp(path)
      expect(src).to include("AI-FILL").and include("# Ground:")
      expect { reaper_task(nil) }.to raise_error(NotImplementedError)   # stub is live
      svc = Tina4::ServiceRunner.list.find { |s| s[:name] == "reaper" }
      expect(svc).not_to be_nil
      expect(svc[:options][:interval]).to eq(300)                       # registered for real
      expect(gen("service", "Reaper", "--every", "5m")).to include("already exists")
    end

    it "cron service uses the :timing option key" do
      gen("service", "Nightly", "--cron", "0 3 * * *")
      load File.join(@tmp_dir, "src", "services", "nightly.rb")
      svc = Tina4::ServiceRunner.list.find { |s| s[:name] == "nightly" }
      expect(svc[:options][:timing]).to eq("0 3 * * *")
    end
  end

  describe "generate queue" do
    it "producer real-pushes, handler raises, consumer wired as daemon" do
      gen("queue", "order-emails")
      path = File.join(@tmp_dir, "src", "services", "order_emails_consumer.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      load path
      expect(slurp(path)).to include("AI-FILL").and include("# Ground:")
      expect { handle_order_emails({}) }.to raise_error(NotImplementedError)   # stub is live
      # consumer wired as a daemon service on the real ServiceRunner
      svc = Tina4::ServiceRunner.list.find { |s| s[:name] == "order-emails-consumer" }
      expect(svc).not_to be_nil
      expect(svc[:options][:daemon]).to be true
      # producer pushes to the real lite/file backend → a real Job
      job = publish_order_emails({ "to" => "a@b.c" })
      expect(job).not_to be_nil
      expect(job.id).not_to be_nil
    end

    it "is idempotent" do
      gen("queue", "invoices")
      expect(gen("queue", "invoices")).to include("already exists")
    end

    it "wires topic + per-job handle so `queue work` can drive it directly" do
      # Phase 3: the scaffold registers `topic:` and a callable `handle:` on the
      # ServiceRunner so `tina4ruby queue work <topic>` resolves and invokes the
      # per-job handler (owning the poll loop / --once drain) — additive to the
      # existing daemon wiring.
      gen("queue", "shipments")
      path = File.join(@tmp_dir, "src", "services", "shipments_consumer.rb")
      src = slurp(path)
      expect(src).to include('topic: "shipments"')
      expect(src).to include("handle: method(:handle_shipments)")

      load path
      svc = Tina4::ServiceRunner.list.find { |s| s[:name] == "shipments-consumer" }
      expect(svc).not_to be_nil
      expect(svc[:options][:topic]).to eq("shipments")
      expect(svc[:options][:handle]).to respond_to(:call)
      expect(svc[:options][:daemon]).to be true # still a daemon service
    end
  end

  describe "generate validator" do
    it "loads, wires Tina4::Validator, raises when called, idempotent" do
      gen("validator", "CreateUser")
      path = File.join(@tmp_dir, "src", "validators", "create_user.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      load path
      src = slurp(path)
      expect(src).to include("AI-FILL").and include("# Ground:")
      expect(src).to include("Tina4::Validator")                       # real wiring
      expect { validate_create_user({}) }.to raise_error(NotImplementedError)
      expect(gen("validator", "CreateUser")).to include("already exists")
    end
  end

  describe "generate seeder" do
    it "loads clean w/o DB, override raises, seed_orm seeds the model for real" do
      gen("model", "Sprocket", "--fields", "name:string", "--no-migration")
      gen("seeder", "Sprocket")
      path = File.join(@tmp_dir, "seeds", "sprocket_seeder.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      # B3 — loads cleanly with NO DB bound (the guard skips the placeholder)
      Tina4.instance_variable_set(:@database, nil)
      expect { load path }.not_to raise_error
      src = slurp(path)
      expect(src).to include("AI-FILL").and include("Tina4.seed_orm")
      # S1 — the override raises until filled
      expect { sprocket_field_overrides(Tina4::FakeData.new) }.to raise_error(NotImplementedError)
      # S3 — the wiring target is real: seed_orm actually seeds the generated model
      bind_db!
      model = Object.const_get(:Sprocket)
      model.create_table
      summary = Tina4.seed_orm(model, count: 2, overrides: {})
      expect(summary.seeded).to eq(2)
      expect(gen("seeder", "Sprocket")).to include("already exists")
    end
  end

  describe "generate websocket" do
    it "registers on the real Router ws routes; message handler raises" do
      gen("websocket", "chat")
      path = File.join(@tmp_dir, "src", "routes", "ws_chat.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      load path
      expect(slurp(path)).to include("AI-FILL").and include("# Ground:")
      ws = Tina4::Router.get_web_socket_routes.find { |r| r.path == "/ws/chat" }
      expect(ws).not_to be_nil                                          # real registration
      expect { ws.handler.call(nil, :message, nil) }.to raise_error(NotImplementedError)
      expect(gen("websocket", "chat")).to include("already exists")
    end
  end

  describe "generate listener" do
    it "binds on the real event bus; reaction raises when called" do
      gen("listener", "user.created")
      path = File.join(@tmp_dir, "src", "listeners", "user_created.rb")
      expect(File.exist?(path)).to be true
      expect(compiles?(path)).to be true
      load path
      expect(slurp(path)).to include("AI-FILL").and include("# Ground:")
      expect(Tina4::Events.events).to include("user.created")           # real binding
      expect(Tina4::Events.listeners("user.created").length).to be >= 1
      expect { on_user_created({ "id" => 1 }) }.to raise_error(NotImplementedError)
      expect(gen("listener", "user.created")).to include("already exists")
    end
  end

  # ── Regression guard: auth generator NOT over-swept ─────────────────
  describe "auth generator stays public" do
    it "register + login clear BOTH write gates (genuinely public)" do
      boot_auth!
      gen("auth")   # also writes src/orm/user.rb, which the route file requires
      load_gen("src", "routes", "auth.rb")

      %w[/api/auth/register /api/auth/login].each do |path|
        route, = Tina4::Router.match("POST", path)
        expect(route).not_to be_nil, "expected #{path} to be registered"
        # A genuinely public write mints tokens before any token exists: the
        # router gate (auth_required) AND the bearer auth_handler must both be
        # cleared, or an anonymous register/login would 401/403 — unusable.
        expect(route.auth_required).to eq(false), "#{path} must not be router-gated"
        expect(route.auth_handler).to be_nil, "#{path} must carry no bearer auth_handler"
      end

      # Behavioural proof: an anonymous POST is NOT rejected by the gate. (400
      # for the empty body is the handler validating — not a 401/403 auth block.)
      status = Tina4::TestClient.new.post("/api/auth/register", json: {}).status
      expect(status).not_to eq(401)
      expect(status).not_to eq(403)
    end
  end

  # Run rspec on a single spec file inside the temp project, returning
  # [exit_status, combined_output]. Uses the repo's bundle but a clean
  # bundler env so the child resolves rspec without inheriting the parent run.
  def run_rspec(spec_file)
    cmd = ["bundle", "exec", "rspec", "-Ispec", spec_file]
    env = { "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile") }
    out = nil
    status = nil
    block = lambda do
      out = IO.popen(env, cmd, chdir: @tmp_dir, err: [:child, :out], &:read)
      status = $?.exitstatus
    end
    if defined?(Bundler)
      Bundler.with_unbundled_env(&block)
    else
      block.call
    end
    [status, out]
  end
end
