# frozen_string_literal: true

# Tina4::Docs — Live API RAG test corpus.
#
# Mirrors tina4-php/tests/DocsTest.php and tina4-python/tests/test_docs.py.
# Same test names, same assertions, different language. Both files live RED
# until the corresponding `Docs` module is implemented in each framework.
#
# Spec: plan/v3/22-LIVE-API-RAG.md

require "spec_helper"
require "fileutils"
require "securerandom"
require "tmpdir"

require "tina4/docs"

RSpec.describe Tina4::Docs do
  # ── Fixture project ────────────────────────────────────────────────
  before(:all) do
    @fixture = File.join(Dir.tmpdir, "tina4-docs-fixture-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(File.join(@fixture, "src", "orm"))
    FileUtils.mkdir_p(File.join(@fixture, "src", "routes"))
    FileUtils.mkdir_p(File.join(@fixture, "src", "templates"))

    File.write(File.join(@fixture, "src", "orm", "User.rb"), <<~RUBY)
      # User ORM model.
      module App
        module Models
          class User < Tina4::ORM
            # Find a user by email — returns nil if not found.
            def self.find_by_email(email)
              nil
            end

            # @internal
            def _hash_password(plain)
              plain
            end
          end
        end
      end
    RUBY

    File.write(File.join(@fixture, "src", "routes", "contact.rb"), <<~RUBY)
      Tina4::Router.post("/contact") do |request, response|
        response.json({ ok: true })
      end
    RUBY

    File.write(File.join(@fixture, "src", "templates", "home.twig"), <<~TWIG)
      {% extends 'base.twig' %}
      {% block content %}
        <h1>{{ title }}</h1>
      {% endblock %}
    TWIG
  end

  after(:all) do
    FileUtils.rm_rf(@fixture)
  end

  let(:docs) { Tina4::Docs.new(@fixture) }

  # ── 1 ────────────────────────────────────────────────────────────
  it "search finds framework render method" do
    hits = docs.search("render template", k: 5)
    expect(hits).not_to be_empty, "search returned zero results"
    top3 = hits.first(3).map { |h| h[:fqn] || h["fqn"] }
    expect(top3).to include("Tina4::Response#render"),
      "Tina4::Response#render should rank in top 3 for 'render template'; got #{top3.inspect}"
  end

  # ── 2 ────────────────────────────────────────────────────────────
  it "search finds user model" do
    hits = docs.search("User", k: 5)
    user_hits = hits.select { |h| (h[:source] || h["source"]) == "user" }
    expect(user_hits).not_to be_empty, "expected at least one user-source hit for 'User'"
    found = hits.first(3).any? { |h| (h[:fqn] || h["fqn"]).to_s.include?("App::Models::User") }
    expect(found).to be(true), "App::Models::User should rank in top 3 for 'User'"
  end

  # ── 3 ────────────────────────────────────────────────────────────
  it "search source filter excludes the other source" do
    fw_only = docs.search("User", k: 10, source: "framework")
    fw_only.each do |h|
      expect(h[:source] || h["source"]).to eq("framework"),
        "source=framework leaked a non-framework hit"
    end
    user_only = docs.search("User", k: 10, source: "user")
    user_only.each do |h|
      expect(h[:source] || h["source"]).to eq("user"),
        "source=user leaked a non-user hit"
    end
  end

  # ── 4 ────────────────────────────────────────────────────────────
  it "class endpoint returns full method list" do
    spec = docs.class_spec("Tina4::Response")
    expect(spec).not_to be_nil, "Tina4::Response should be reflectable"
    methods = spec[:methods] || spec["methods"]
    expect(methods).not_to be_nil
    expect(methods.size).to be >= 5
    methods.each do |m|
      expect(m).to have_key(:signature).or have_key("signature")
      expect(m).to have_key(:file).or have_key("file")
      expect(m).to have_key(:line).or have_key("line")
    end
  end

  # ── 5 ────────────────────────────────────────────────────────────
  it "class endpoint returns nil for missing class" do
    spec = docs.class_spec("Tina4::NotARealClass")
    expect(spec).to be_nil, "unknown class should return nil (404 path on HTTP)"
  end

  # ── 6 ────────────────────────────────────────────────────────────
  it "method endpoint returns signature" do
    spec = docs.method_spec("Tina4::Response", "render")
    expect(spec).not_to be_nil
    expect(spec[:name] || spec["name"]).to eq("render")
    expect(spec[:signature] || spec["signature"]).not_to be_empty
    expect(spec[:visibility] || spec["visibility"]).to eq("public")
    expect(spec[:source] || spec["source"]).to eq("framework")
  end

  # ── 7 ────────────────────────────────────────────────────────────
  it "user class appears in class endpoint" do
    spec = docs.class_spec("App::Models::User")
    expect(spec).not_to be_nil, "user model should be reflectable"
    expect(spec[:source] || spec["source"]).to eq("user")
    method_names = (spec[:methods] || spec["methods"]).map { |m| m[:name] || m["name"] }
    expect(method_names).to include("find_by_email")
  end

  # ── 8 ────────────────────────────────────────────────────────────
  it "index endpoint lists all" do
    idx = docs.index
    expect(idx.size).to be >= 50, "expected at least 50 entities (framework + user)"
    sources = idx.map { |e| e[:source] || e["source"] }.uniq
    expect(sources).to include("framework")
    expect(sources).to include("user")
  end

  # ── 9 ────────────────────────────────────────────────────────────
  it "mcp docs search matches direct call" do
    direct  = docs.search("render", k: 3)
    via_mcp = Tina4::Docs.mcp_search("render", k: 3, project_root: @fixture)
    expect(direct.map { |h| h[:fqn] || h["fqn"] })
      .to eq(via_mcp.map { |h| h[:fqn] || h["fqn"] }),
      "MCP and direct call must return the same ranked hits"
  end

  # ── 10 ───────────────────────────────────────────────────────────
  it "mcp docs method matches direct call" do
    direct  = docs.method_spec("Tina4::Response", "render")
    via_mcp = Tina4::Docs.mcp_method("Tina4::Response", "render", project_root: @fixture)
    expect(direct).to eq(via_mcp)
  end

  # ── 11 ───────────────────────────────────────────────────────────
  it "index refreshes on user file change" do
    before = docs.method_spec("App::Models::User", "find_active")
    expect(before).to be_nil, "precondition: find_active does not exist yet"

    path = File.join(@fixture, "src", "orm", "User.rb")
    src  = File.read(path)
    patched = src.sub(
      "def self.find_by_email(email)",
      "def self.find_active\n              []\n            end\n\n            def self.find_by_email(email)",
    )
    File.write(path, patched)
    # mtime resolution is 1s on some FS — bump explicitly.
    new_time = Time.now + 2
    File.utime(new_time, new_time, path)

    after = docs.method_spec("App::Models::User", "find_active")
    expect(after).not_to be_nil, "index should pick up newly-added method on next query"
  end

  # ── 12 ───────────────────────────────────────────────────────────
  it "drift detector finds doc inconsistency" do
    tmp = File.join(@fixture, "CLAUDE.md")
    File.write(tmp, "```ruby\nresponse.fake_method_that_does_not_exist()\n```\n")
    report = Tina4::Docs.check_docs(tmp)
    expect(report[:drift] || report["drift"]).not_to be_empty,
      "drift detector should flag fake_method_that_does_not_exist"
  end

  # ── 13 ───────────────────────────────────────────────────────────
  it "sync overwrites only the marked section" do
    tmp = File.join(@fixture, "CLAUDE.md")
    original = "Prose above\n<!-- BEGIN GENERATED API -->\nold content\n" \
               "<!-- END GENERATED API -->\nProse below\n"
    File.write(tmp, original)
    Tina4::Docs.sync_docs(tmp)
    updated = File.read(tmp)
    expect(updated).to include("Prose above"), "prose above must be preserved"
    expect(updated).to include("Prose below"), "prose below must be preserved"
    expect(updated).not_to include("old content"), "old generated content must be replaced"
    expect(updated).to(include("Tina4::Response").or(include("Response")))
  end

  # ── 14 ───────────────────────────────────────────────────────────
  it "search response under 50ms" do
    docs.search("warm-up", k: 1) # build the index once
    # Best-of-N, not a single sample: one wall-clock measurement on a shared CI
    # runner is flaky - a GC pause or CPU contention spikes a single call past
    # the budget (green on a PR run, red on the push run, same code). The FASTEST
    # of several runs reflects the true search cost and still catches a real
    # O(n^2)-style regression (every sample would blow the budget), without
    # failing on scheduler jitter.
    samples = Array.new(20) do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      docs.search("render", k: 5)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0
    end
    best_ms = samples.min
    expect(best_ms).to be < 50.0,
                       "fastest of #{samples.size} searches took #{format('%.1f', best_ms)}ms (budget 50ms)"
  end

  # ── 15 ───────────────────────────────────────────────────────────
  it "no private methods in default search" do
    hits = docs.search("hash_password", k: 10)
    hits.each do |h|
      fqn = h[:fqn] || h["fqn"]
      expect(fqn).not_to eq("App::Models::User#_hash_password"),
        "private/internal methods must be excluded from default search"
    end
    opt_in = docs.search("hash_password", k: 10, include_private: true)
    fqns = opt_in.map { |h| h[:fqn] || h["fqn"] }
    expect(fqns).to include("App::Models::User#_hash_password"),
      "include_private=true must surface private methods"
  end

  # ── 16 ───────────────────────────────────────────────────────────
  it "no vendor third-party in results" do
    hits = docs.search("rspec", k: 20)
    hits.each do |h|
      src = h[:source] || h["source"]
      expect(src).not_to eq("vendor"), "vendor results leaked into default search"
      file_path = (h[:file] || h["file"]).to_s
      expect(file_path).not_to start_with("gems/"),
        "gems/ paths leaked into default search"
      expect(file_path).not_to start_with("vendor/"),
        "vendor/ paths leaked into default search"
    end
  end

  # ── 17 ───────────────────────────────────────────────────────────
  # Frond's add_filter/add_global/add_test are a dual class+instance facade
  # (`def self.add_filter` AND `def add_filter`). They are public, documented
  # API and must be indexed with a usable signature leading with the method
  # name. (In Python/PHP these are metaprogrammed and the reflector originally
  # dropped them; in Ruby they are normal `def`s, so this verifies parity.)
  it "facade-defined Frond methods are indexed" do
    %w[add_filter add_global add_test].each do |name|
      spec = docs.method_spec("Tina4::Frond", name)
      expect(spec).not_to be_nil, "Tina4::Frond##{name} must be indexed"
      sig = (spec[:signature] || spec["signature"]).to_s
      expect(sig).to include("#{name}("),
        "signature should lead with the method name: #{sig.inspect}"
      # No Ruby receiver tokens should leak into the public signature.
      expect(sig).not_to include("(self"), "receiver must not appear in signature: #{sig.inspect}"
    end
  end

  # ── 18 ───────────────────────────────────────────────────────────
  # A "Class.method" / "Class method" query must rank that class's method
  # first — the class qualifier has to steer ranking, not be dead weight.
  it "class-qualified search ranks the owning method" do
    ["Frond.add_test", "Frond add_test", "add_test"].each do |query|
      hits = docs.search(query, k: 3)
      expect(hits).not_to be_empty, "no hits for #{query.inspect}"
      top = hits.first[:fqn] || hits.first["fqn"]
      expect(top).to eq("Tina4::Frond#add_test"),
        "#{query.inspect} should rank Tina4::Frond#add_test #1; got #{hits.map { |h| h[:fqn] || h["fqn"] }.inspect}"
    end
  end

  # ── 19 ───────────────────────────────────────────────────────────
  # A longer documented path that nests the class name resolves to the same
  # class as the exact stored FQN, and method_spec resolves through it too.
  it "lookup resolves a longer documented path" do
    exact  = "Tina4::Database"
    nested = "Tina4::Database::Database"
    expect(docs.class_spec(exact)).not_to be_nil, "precondition: exact FQN resolves"
    expect(docs.class_spec(nested)).not_to be_nil, "nested documented path must resolve"
    expect(docs.method_spec(nested, "execute")).not_to be_nil,
      "method_spec must resolve via the nested path"
    # Both paths point at the same class.
    expect((docs.class_spec(nested)[:fqn] || docs.class_spec(nested)["fqn"]))
      .to eq((docs.class_spec(exact)[:fqn] || docs.class_spec(exact)["fqn"]))
  end

  # ── 20 ───────────────────────────────────────────────────────────
  # A bare class name (Database) resolves to the one matching class.
  it "lookup resolves a bare class name" do
    spec = docs.class_spec("Database")
    expect(spec).not_to be_nil, "bare class name must resolve"
    expect((spec[:fqn] || spec["fqn"]).to_s).to end_with("Database")
    expect(docs.method_spec("Database", "execute")).not_to be_nil
    # A leading :: resolves to the same class.
    expect(docs.class_spec("::Tina4::Database")).not_to be_nil
    # A truly unknown name still returns nil (no false positives).
    expect(docs.class_spec("DefinitelyNotAClass")).to be_nil
  end
end
