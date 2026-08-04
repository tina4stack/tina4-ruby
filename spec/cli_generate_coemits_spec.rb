# frozen_string_literal: true
#
# ══════════════════════════════════════════════════════════════════════════
# Meta-spec: every code-producing generator co-emits a REAL, green spec.
#
# For each generator we scaffold into a fresh temp project via the ACTUAL
# `tina4ruby generate <what> <name>` command (a real subprocess through the real
# exe entry point), then RUN the co-emitted *_spec.rb with real rspec in a real
# subprocess and assert it passes (exit 0). No mocks anywhere: real generate,
# real rspec run of the emitted file, real SQLite / TestClient / Router /
# ServiceRunner / Queue / event bus / Migration underneath.
#
# This proves the co-emitted spec is (a) actually written next to the code and
# (b) green on generation — a scaffolded spec that fails on creation is bad DX.
# Ruby mirror of tina4-python tests/test_cli_generate_coemits.py.
# ══════════════════════════════════════════════════════════════════════════
require "spec_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "CLI generators co-emit a real green spec" do
  TINA4_EXE   = File.join(REPO_ROOT, "exe", "tina4ruby")
  REPO_GEMFILE = File.join(REPO_ROOT, "Gemfile")

  around(:each) do |example|
    Dir.mktmpdir("tina4_coemit") do |dir|
      @project = dir
      example.run
    end
  end

  # Run `tina4ruby <args>` in the project dir through the REAL exe entry point
  # (a real subprocess). Requires success.
  def run_cli(*args)
    out = IO.popen([RbConfig.ruby, TINA4_EXE, *args], chdir: @project, err: [:child, :out], &:read)
    status = $?.exitstatus
    expect(status).to eq(0), "`tina4ruby #{args.join(' ')}` failed (exit #{status}):\n#{out}"
  end

  # Minimal spec_helper so the emitted spec's `require "spec_helper"` resolves —
  # mirrors the framework's essential per-example resets (Router + DB), the same
  # bootstrap the CRUD acceptance meta-test uses.
  def write_spec_helper
    FileUtils.mkdir_p(File.join(@project, "spec"))
    File.write(File.join(@project, "spec", "spec_helper.rb"), <<~RUBY)
      $LOAD_PATH.unshift #{REPO_LIB.inspect}
      require "tina4"
      require "stringio"
      RSpec.configure do |c|
        c.after(:each) do
          Tina4::Router.clear! if defined?(Tina4::Router)
          Tina4.instance_variable_set(:@database, nil)
          Tina4.instance_variable_set(:@databases, {})
        end
      end
    RUBY
  end

  # Run rspec on a single emitted spec inside the temp project, returning
  # [exit_status, combined_output]. Uses the repo's bundle but a clean bundler
  # env so the child resolves rspec without inheriting the parent run.
  def run_rspec(spec_rel)
    spec_file = File.join(@project, spec_rel)
    expect(File.exist?(spec_file)).to be(true), "generator did not co-emit #{spec_rel}"
    cmd = ["bundle", "exec", "rspec", "-Ispec", spec_rel]
    env = { "BUNDLE_GEMFILE" => REPO_GEMFILE }
    out = nil
    status = nil
    block = lambda do
      out = IO.popen(env, cmd, chdir: @project, err: [:child, :out], &:read)
      status = $?.exitstatus
    end
    if defined?(Bundler)
      Bundler.with_unbundled_env(&block)
    else
      block.call
    end
    [status, out]
  end

  # (id, [pre-generate arg-lists], generate args, co-emitted spec file)
  CASES = [
    ["model", [],
     ["generate", "model", "Product", "--fields", "name:string,price:float"],
     "spec/product_model_spec.rb"],
    ["route_with_model", [["generate", "model", "Product"]],
     ["generate", "route", "products", "--model", "Product"],
     "spec/products_spec.rb"],
    ["route_public", [["generate", "model", "Widget"]],
     ["generate", "route", "widgets", "--model", "Widget", "--public"],
     "spec/widgets_spec.rb"],
    ["route_no_model", [],
     ["generate", "route", "notes"],
     "spec/notes_spec.rb"],
    ["middleware", [],
     ["generate", "middleware", "AuthLog"],
     "spec/auth_log_spec.rb"],
    ["service", [],
     ["generate", "service", "Reaper", "--every", "5m"],
     "spec/reaper_spec.rb"],
    ["queue", [],
     ["generate", "queue", "order-emails"],
     "spec/order_emails_spec.rb"],
    ["validator", [],
     ["generate", "validator", "CreateUser"],
     "spec/create_user_spec.rb"],
    ["seeder", [["generate", "model", "Product"]],
     ["generate", "seeder", "Product"],
     "spec/product_seeder_spec.rb"],
    ["websocket", [],
     ["generate", "websocket", "chat"],
     "spec/ws_chat_spec.rb"],
    ["listener", [],
     ["generate", "listener", "user.created"],
     "spec/user_created_spec.rb"],
    ["auth", [],
     ["generate", "auth"],
     "spec/auth_spec.rb"],
    ["migration", [],
     ["generate", "migration", "create_widget", "--fields", "name:string"],
     "spec/widget_migration_spec.rb"],
    ["crud", [],
     ["generate", "crud", "Trinket", "--fields", "name:string,qty:int"],
     "spec/trinkets_spec.rb"],
  ].freeze

  CASES.each do |id, pre_commands, generate_command, spec_rel|
    it "#{id}: the co-emitted #{spec_rel} runs green on generation" do
      pre_commands.each { |pre| run_cli(*pre) }
      run_cli(*generate_command)
      write_spec_helper
      status, output = run_rspec(spec_rel)
      expect(status).to eq(0), output
    end
  end

  # ── Regression (ruby#33 / tina4-python#101) ─────────────────────────────
  # `generate model/crud` WITHOUT --fields used to write a model declaring
  # `name` while its migration created only id + created_at, so the first write
  # died with "no such column: name". Ruby had an extra sting: an EMPTY array is
  # truthy, so `fields_override || parse_fields(...)` short-circuited to [] and
  # the fallback never fired. Every case above passes --fields explicitly, which
  # is exactly why the bug survived — these exercise the no-fields path.
  describe "generate without --fields (ruby#33)" do
    # The generated UP migration (Ruby writes UP and DOWN as separate files).
    def up_sql
      ups = Dir.glob(File.join(@project, "migrations", "*.sql")).reject { |f| f.end_with?(".down.sql") }
      expect(ups).not_to be_empty, "no UP migration was generated"
      File.read(ups.first)
    end

    # Field names declared on the generated model's *_field DSL calls.
    def model_fields(snake)
      File.read(File.join(@project, "src", "orm", "#{snake}.rb"))
          .scan(/^\s*\w*_field :(\w+)/).flatten
    end

    it "model: the migration contains EVERY field the model declares" do
      run_cli("generate", "model", "Todo")
      declared = model_fields("todo")
      expect(declared).to include("name"), "model should declare the default name field, got #{declared}"
      up = up_sql
      declared.each { |f| expect(up).to include(f), "model declares #{f.inspect} but the migration omits it:\n#{up}" }
    end

    it "crud: the migration contains EVERY field the model declares" do
      run_cli("generate", "crud", "Todo")
      up = up_sql
      model_fields("todo").each do |f|
        expect(up).to include(f), "model declares #{f.inspect} but the migration omits it:\n#{up}"
      end
    end

    it "explicit --fields still reach the migration (positive control)" do
      run_cli("generate", "model", "Product", "--fields", "title:string,price:float,in_stock:bool")
      up = up_sql
      %w[title price in_stock].each { |f| expect(up).to include(f), "#{f.inspect} missing:\n#{up}" }
    end

    it "the generated schema accepts a row using the model's own fields (real SQLite)" do
      require "sqlite3"
      run_cli("generate", "model", "Todo")
      cols = model_fields("todo") - %w[id created_at]
      db = SQLite3::Database.new(":memory:")
      begin
        db.execute_batch(up_sql)
        db.execute("INSERT INTO todo (#{cols.join(', ')}) VALUES (#{(['?'] * cols.size).join(', ')})",
                   cols.map { "x" })
        expect(db.get_first_value("SELECT COUNT(*) FROM todo")).to eq(1)
      ensure
        db.close
      end
    end

    it "the generated create/update routes check the write result before to_h" do
      run_cli("generate", "crud", "Todo")
      route = File.read(File.join(@project, "src", "routes", "todos.rb"))
      # create/save return false rather than raising; unchecked, a failed write
      # surfaces as an unrelated NoMethodError on false and hides the cause.
      expect(route).to include("if item == false")
      expect(route).to include("if item.save == false")
      expect(route.index("if item == false")).to be < route.index("item.to_h, 201")
    end
  end

  it "form / view are template-only and co-emit NO spec" do
    run_cli("generate", "form", "Product", "--fields", "name:string")
    run_cli("generate", "view", "Product", "--fields", "name:string")
    expect(File.exist?(File.join(@project, "src", "templates", "forms", "product.twig"))).to be true
    expect(File.exist?(File.join(@project, "src", "templates", "pages", "products.twig"))).to be true
    emitted = Dir.glob(File.join(@project, "spec", "*_spec.rb"))
    expect(emitted).to eq([]), "template-only generators should emit no spec, got #{emitted}"
  end
end
