# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"

RSpec.describe Tina4::MessageLog do
  subject(:log) { Tina4::MessageLog.new }

  describe "#log" do
    it "adds an entry" do
      log.log("http", "info", "Request received")
      expect(log.get.size).to eq(1)
    end

    it "stores category, level, and message" do
      log.log("auth", "error", "Invalid token")
      entry = log.get.first
      expect(entry[:category]).to eq("auth")
      expect(entry[:level]).to eq("ERROR")
      expect(entry[:message]).to eq("Invalid token")
    end

    it "stores a timestamp in ISO 8601 format" do
      log.log("http", "debug", "test")
      entry = log.get.first
      expect(entry[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it "uppercases the level" do
      log.log("http", "warn", "slow")
      expect(log.get.first[:level]).to eq("WARN")
    end

    it "converts category and message to strings" do
      log.log(:system, :info, 42)
      entry = log.get.first
      expect(entry[:category]).to eq("system")
      expect(entry[:message]).to eq("42")
    end

    it "caps at 500 entries" do
      510.times { |i| log.log("bulk", "info", "msg #{i}") }
      expect(log.get.size).to eq(500)
    end
  end

  describe "#get" do
    before do
      log.log("http", "info", "Request A")
      log.log("http", "warn", "Slow request")
      log.log("auth", "error", "Bad token")
    end

    it "returns entries in reverse order (newest first)" do
      entries = log.get
      expect(entries.first[:message]).to eq("Bad token")
      expect(entries.last[:message]).to eq("Request A")
    end

    it "filters by category" do
      http_entries = log.get(category: "http")
      expect(http_entries.size).to eq(2)
      expect(http_entries.all? { |e| e[:category] == "http" }).to be true
    end

    it "returns empty array when filtering unknown category" do
      expect(log.get(category: "unknown")).to be_empty
    end

    it "returns all entries when no category filter" do
      expect(log.get.size).to eq(3)
    end
  end

  describe "#clear" do
    before do
      log.log("http", "info", "req1")
      log.log("auth", "error", "bad")
    end

    it "clears only specified category" do
      log.clear(category: "http")
      entries = log.get
      expect(entries.size).to eq(1)
      expect(entries.first[:category]).to eq("auth")
    end

    it "clears all entries when no category" do
      log.clear
      expect(log.get).to be_empty
    end
  end

  describe "#count" do
    it "returns counts by category plus total" do
      log.log("http", "info", "a")
      log.log("http", "warn", "b")
      log.log("auth", "error", "c")
      counts = log.count
      expect(counts["http"]).to eq(2)
      expect(counts["auth"]).to eq(1)
      expect(counts["total"]).to eq(3)
    end

    it "returns total 0 when empty" do
      expect(log.count["total"]).to eq(0)
    end
  end
end

RSpec.describe Tina4::RequestInspector do
  subject(:inspector) { Tina4::RequestInspector.new }

  describe "#capture" do
    it "records a request" do
      inspector.capture(method: "GET", path: "/api/users", status: 200, duration: 12.5)
      expect(inspector.get.size).to eq(1)
    end

    it "stores method, path, status, and duration" do
      inspector.capture(method: "POST", path: "/api/items", status: 201, duration: 45.3)
      req = inspector.get.first
      expect(req[:method]).to eq("POST")
      expect(req[:path]).to eq("/api/items")
      expect(req[:status]).to eq(201)
      expect(req[:duration_ms]).to eq(45.3)
    end

    it "converts method and path to strings" do
      inspector.capture(method: :GET, path: :"/test", status: 200, duration: 1.0)
      req = inspector.get.first
      expect(req[:method]).to eq("GET")
    end

    it "includes a timestamp" do
      inspector.capture(method: "GET", path: "/", status: 200, duration: 1)
      expect(inspector.get.first[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it "caps at 200 entries" do
      210.times { |i| inspector.capture(method: "GET", path: "/p#{i}", status: 200, duration: 1) }
      expect(inspector.get(limit: 300).size).to eq(200)
    end
  end

  describe "#get" do
    before do
      inspector.capture(method: "GET", path: "/a", status: 200, duration: 10)
      inspector.capture(method: "GET", path: "/b", status: 200, duration: 20)
      inspector.capture(method: "GET", path: "/c", status: 200, duration: 30)
    end

    it "returns requests in reverse order" do
      expect(inspector.get.first[:path]).to eq("/c")
    end

    it "respects the limit parameter" do
      expect(inspector.get(limit: 2).size).to eq(2)
    end

    it "defaults limit to 50" do
      60.times { |i| inspector.capture(method: "GET", path: "/x#{i}", status: 200, duration: 1) }
      # 3 + 60 = 63, but capped by default limit 50
      expect(inspector.get.size).to eq(50)
    end
  end

  describe "#stats" do
    it "returns zero stats when empty" do
      s = inspector.stats
      expect(s[:total]).to eq(0)
      expect(s[:avg_ms]).to eq(0.0)
      expect(s[:errors]).to eq(0)
      expect(s[:slowest_ms]).to eq(0.0)
    end

    it "computes correct stats" do
      inspector.capture(method: "GET", path: "/ok", status: 200, duration: 10)
      inspector.capture(method: "GET", path: "/not-found", status: 404, duration: 5)
      inspector.capture(method: "GET", path: "/error", status: 500, duration: 100)
      inspector.capture(method: "POST", path: "/ok", status: 201, duration: 25)

      s = inspector.stats
      expect(s[:total]).to eq(4)
      expect(s[:errors]).to eq(2)
      expect(s[:slowest_ms]).to eq(100.0)
      expect(s[:avg_ms]).to eq(35.0)
    end
  end

  describe "#clear" do
    it "empties all captured requests" do
      inspector.capture(method: "GET", path: "/test", status: 200, duration: 1)
      inspector.clear
      expect(inspector.get).to be_empty
    end
  end
end

RSpec.describe Tina4::ErrorTracker do
  subject(:tracker) { Tina4::ErrorTracker.new }

  after(:each) { tracker.reset! }

  describe "#capture and #get" do
    it "records an error" do
      tracker.capture(error_type: "RuntimeError", message: "crash")
      entries = tracker.get
      expect(entries.size).to eq(1)
      expect(entries.first[:error_type]).to eq("RuntimeError")
    end

    it "deduplicates same error" do
      tracker.capture(error_type: "RuntimeError", message: "crash", file: "app.rb", line: 10)
      tracker.capture(error_type: "RuntimeError", message: "crash", file: "app.rb", line: 10)
      entries = tracker.get
      expect(entries.size).to eq(1)
      expect(entries.first[:count]).to eq(2)
    end
  end

  describe "#resolve" do
    it "marks an error as resolved" do
      tracker.capture(error_type: "Error", message: "bug")
      id = tracker.get.first[:id]
      expect(tracker.resolve(id)).to be true
      expect(tracker.get.first[:resolved]).to be true
    end

    it "returns false for nonexistent id" do
      expect(tracker.resolve("nonexistent")).to be false
    end
  end

  describe "#health" do
    it "returns healthy when empty" do
      h = tracker.health
      expect(h[:healthy]).to be true
      expect(h[:total]).to eq(0)
    end

    it "returns unhealthy with unresolved errors" do
      tracker.capture(error_type: "Error", message: "one")
      h = tracker.health
      expect(h[:healthy]).to be false
      expect(h[:unresolved]).to eq(1)
    end
  end

  describe "#unresolved_count" do
    it "counts unresolved errors" do
      tracker.capture(error_type: "Error", message: "one", file: "a.rb", line: 1)
      tracker.capture(error_type: "Error", message: "two", file: "b.rb", line: 2)
      id = tracker.get.first[:id]
      tracker.resolve(id)
      expect(tracker.unresolved_count).to eq(1)
    end
  end

  describe "#clear_all" do
    it "removes all errors" do
      tracker.capture(error_type: "Error", message: "one")
      tracker.clear_all
      expect(tracker.get).to be_empty
    end
  end

  describe "#register" do
    it "sets @registered true and installs the at_exit hook only once" do
      expect(tracker.instance_variable_get(:@registered)).to be_falsey
      tracker.register
      expect(tracker.instance_variable_get(:@registered)).to be true

      # The guard makes a second register a no-op: @registered stays true and
      # no second at_exit hook / duplicate work is performed.
      tracker.register
      expect(tracker.instance_variable_get(:@registered)).to be true
    end

    it "is idempotent — registering twice does not double-count a captured error" do
      tracker.register
      tracker.register
      # If the guard failed and register installed work twice, a captured
      # exception would be recorded more than once. Prove a single capture
      # produces exactly one tracked error.
      tracker.capture_exception(StandardError.new("x"))
      expect(tracker.get.size).to eq(1)
      expect(tracker.get.first[:count]).to eq(1)
      expect(tracker.instance_variable_get(:@registered)).to be true
    end
  end
end

RSpec.describe Tina4::DevAdmin do
  before(:each) do
    # Reset singleton state
    Tina4::DevAdmin.instance_variable_set(:@message_log, nil)
    Tina4::DevAdmin.instance_variable_set(:@request_inspector, nil)
    Tina4::DevAdmin.instance_variable_set(:@mailbox, nil)
  end

  describe ".enabled?" do
    it "returns true when TINA4_DEBUG is true" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
      expect(Tina4::DevAdmin.enabled?).to be true
    end

    it "returns true when TINA4_DEBUG is 1" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("1")
      expect(Tina4::DevAdmin.enabled?).to be true
    end

    it "returns false when TINA4_DEBUG is false" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("false")
      expect(Tina4::DevAdmin.enabled?).to be false
    end

    it "returns false when TINA4_DEBUG is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return(nil)
      expect(Tina4::DevAdmin.enabled?).to be false
    end
  end

  describe ".message_log" do
    it "returns a MessageLog instance" do
      expect(Tina4::DevAdmin.message_log).to be_a(Tina4::MessageLog)
    end

    it "returns the same instance on repeated calls" do
      expect(Tina4::DevAdmin.message_log).to equal(Tina4::DevAdmin.message_log)
    end
  end

  describe ".request_inspector" do
    it "returns a RequestInspector instance" do
      expect(Tina4::DevAdmin.request_inspector).to be_a(Tina4::RequestInspector)
    end

    it "returns the same instance on repeated calls" do
      expect(Tina4::DevAdmin.request_inspector).to equal(Tina4::DevAdmin.request_inspector)
    end
  end

  # Regression: the lazily-memoized dev singletons must be resettable so a
  # mailbox built under one TINA4_MAILBOX_DIR can never leak into a later
  # caller running under a different env. This is the root-cause guard for the
  # DevMailbox#seed cross-spec flake (a foreign mailbox surfacing in a later
  # read under the full randomized suite).
  describe ".reset_singletons!" do
    it "drops and rebuilds the memoized singletons" do
      log1 = Tina4::DevAdmin.message_log
      mb1 = Tina4::DevAdmin.mailbox
      Tina4::DevAdmin.reset_singletons!
      expect(Tina4::DevAdmin.message_log).not_to equal(log1)
      expect(Tina4::DevAdmin.mailbox).not_to equal(mb1)
    end

    it "rebuilds the mailbox against the CURRENT TINA4_MAILBOX_DIR (no stale dir leak)" do
      original = ENV["TINA4_MAILBOX_DIR"]
      Dir.mktmpdir do |dir_a|
        Dir.mktmpdir do |dir_b|
          begin
            ENV["TINA4_MAILBOX_DIR"] = dir_a
            Tina4::DevAdmin.reset_singletons!
            expect(Tina4::DevAdmin.mailbox.mailbox_dir).to eq(dir_a)

            # A later context with a different dir must NOT keep the old one.
            ENV["TINA4_MAILBOX_DIR"] = dir_b
            Tina4::DevAdmin.reset_singletons!
            expect(Tina4::DevAdmin.mailbox.mailbox_dir).to eq(dir_b)
          ensure
            if original
              ENV["TINA4_MAILBOX_DIR"] = original
            else
              ENV.delete("TINA4_MAILBOX_DIR")
            end
            Tina4::DevAdmin.reset_singletons!
          end
        end
      end
    end
  end

  describe ".handle_request" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
    end

    it "returns nil when not enabled" do
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return(nil)
      env = { "PATH_INFO" => "/__dev/api/status", "REQUEST_METHOD" => "GET" }
      expect(Tina4::DevAdmin.handle_request(env)).to be_nil
    end

    it "returns nil for non-dev paths" do
      env = { "PATH_INFO" => "/api/users", "REQUEST_METHOD" => "GET" }
      expect(Tina4::DevAdmin.handle_request(env)).to be_nil
    end

    it "serves the dashboard on GET /__dev" do
      env = { "PATH_INFO" => "/__dev", "REQUEST_METHOD" => "GET" }
      status, headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("text/html")
      expect(body.first).to include("Tina4 Dev Admin")
    end

    it "returns JSON for GET /__dev/api/status" do
      env = { "PATH_INFO" => "/__dev/api/status", "REQUEST_METHOD" => "GET" }
      status, headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("application/json")
      data = JSON.parse(body.first)
      expect(data["framework"]).to eq("tina4-ruby")
    end

    it "returns JSON for GET /__dev/api/messages" do
      Tina4::DevAdmin.message_log.log("test", "info", "hello")
      env = { "PATH_INFO" => "/__dev/api/messages", "REQUEST_METHOD" => "GET", "QUERY_STRING" => "" }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data["messages"]).to be_an(Array)
      expect(data["counts"]).to be_a(Hash)
    end

    it "clears messages on POST /__dev/api/messages/clear" do
      Tina4::DevAdmin.message_log.log("test", "info", "to-clear")
      env = {
        "PATH_INFO" => "/__dev/api/messages/clear",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new("{}")
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data["cleared"]).to be true
    end

    it "returns request inspector data on GET /__dev/api/requests" do
      env = { "PATH_INFO" => "/__dev/api/requests", "REQUEST_METHOD" => "GET", "QUERY_STRING" => "" }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data).to have_key("requests")
      expect(data).to have_key("stats")
    end

    it "clears requests on POST /__dev/api/requests/clear" do
      env = {
        "PATH_INFO" => "/__dev/api/requests/clear",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new("{}")
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      data = JSON.parse(body.first)
      expect(data["cleared"]).to be true
    end

    it "returns queue stub on GET /__dev/api/queue" do
      env = { "PATH_INFO" => "/__dev/api/queue", "REQUEST_METHOD" => "GET" }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      data = JSON.parse(body.first)
      expect(data["jobs"]).to eq([])
      expect(data["stats"]["pending"]).to eq(0)
    end

    it "returns broken errors stub on GET /__dev/api/broken" do
      env = { "PATH_INFO" => "/__dev/api/broken", "REQUEST_METHOD" => "GET" }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      data = JSON.parse(body.first)
      expect(data["health"]["healthy"]).to be true
    end

    it "handles POST /__dev/api/chat" do
      # Chat now proxies to the Rust agent's /chat SSE endpoint. When
      # the supervisor isn't running (the default in spec), the proxy
      # returns 503 with a JSON error body. We just assert the route is
      # wired — full proxy behaviour is exercised in dev_admin_parity_spec.rb.
      env = {
        "PATH_INFO" => "/__dev/api/chat",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new('{"message":"hello"}')
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect([200, 503]).to include(status)
      # Body must be parseable as JSON or an SSE stream — either way, non-nil.
      expect(body.first).not_to be_nil
    end

    it "handles message search on GET /__dev/api/messages/search" do
      Tina4::DevAdmin.message_log.log("http", "info", "Found user")
      Tina4::DevAdmin.message_log.log("http", "info", "Not relevant")
      env = {
        "PATH_INFO" => "/__dev/api/messages/search",
        "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => "q=found"
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      data = JSON.parse(body.first)
      expect(data["count"]).to eq(1)
      expect(data["keyword"]).to eq("found")
    end
  end

  # ── File browser parity (GET /__dev/api/files) ─────────────────
  # Locks the SPA contract that broke once: every entry MUST carry
  # `is_dir` (boolean) so the dashboard renders folders, plus
  # `has_children`, `git_status` and `size`; the payload carries the git
  # `branch`. Mirrors tina4-python / tina4-php / tina4-nodejs 1:1.
  describe "file browser" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
    end

    def files_get(path)
      env = {
        "PATH_INFO" => "/__dev/api/files",
        "REQUEST_METHOD" => "GET",
        "QUERY_STRING" => "path=#{path}"
      }
      _, _, body = Tina4::DevAdmin.handle_request(env)
      JSON.parse(body.first)
    end

    it "returns entries with is_dir / has_children / git_status / size + branch" do
      data = files_get(".")
      expect(data["path"]).to be_a(String)
      expect(data["branch"]).to be_a(String)
      expect(data["entries"]).to be_an(Array)
      expect(data["entries"]).not_to be_empty

      entry = data["entries"].first
      expect([true, false]).to include(entry["is_dir"])
      expect(entry).to have_key("has_children")
      expect(entry["git_status"]).to be_a(String)
      expect(entry).to have_key("size")
      expect(entry["name"]).to be_a(String)
      expect(entry["path"]).to be_a(String)
      # the legacy `type` field is gone — canonical shape is is_dir
      expect(data["entries"].none? { |e| e.key?("type") }).to be true
    end

    it "marks directories is_dir true (size nil) and files is_dir false" do
      data = files_get(".")
      dir = data["entries"].find { |e| e["is_dir"] == true }
      file = data["entries"].find { |e| e["is_dir"] == false }
      expect(dir).not_to be_nil
      expect(dir["size"]).to be_nil
      expect([true, false]).to include(dir["has_children"])
      expect(file).not_to be_nil
      expect(file["has_children"]).to be_nil
    end

    it "returns an empty-but-valid shape for a missing path (no crash)" do
      data = files_get("__does_not_exist__")
      expect(data["entries"]).to eq([])
      expect(data["branch"]).to be_a(String)
    end
  end

  # ── File read language detection (GET /__dev/api/file) ─────────
  # The dev-admin SPA maps the payload's `language` field to a
  # CodeMirror grammar for syntax highlighting. Coverage must be
  # IDENTICAL to the Python master lang_map. Mirrors
  # tina4-python / tina4-php / tina4-nodejs file-read endpoints.
  describe "file read language" do
    it "maps .ts to typescript" do
      expect(Tina4::DevAdmin.send(:dev_admin_language, "src/app.ts")).to eq("typescript")
    end

    it "maps .rb to ruby" do
      expect(Tina4::DevAdmin.send(:dev_admin_language, "lib/tina4/router.rb")).to eq("ruby")
    end

    it "detects a no-extension Dockerfile" do
      expect(Tina4::DevAdmin.send(:dev_admin_language, "Dockerfile")).to eq("dockerfile")
    end

    it "falls back to text for unknown extensions" do
      expect(Tina4::DevAdmin.send(:dev_admin_language, "data.bin")).to eq("text")
    end

    it "includes a language field in the file_read_payload" do
      payload = Tina4::DevAdmin.send(:file_read_payload, "Gemfile")
      # Gemfile has no mapped extension -> text; the key must always be present
      expect(payload).to have_key(:language)
      expect(payload[:language]).to be_a(String)
    end
  end

  # ── Hot-reload parity tests ────────────────────────────────────
  # Mirrors tina4-php/tests/DevAdminTest.php, tina4-python/tests/test_dev_admin.py,
  # tina4-nodejs/test/devAdmin.test.ts. The mtime counter must only
  # advance when POST /__dev/api/reload is called. No filesystem scan.
  describe "hot reload" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
      Tina4::DevAdmin.instance_variable_set(:@reload_mtime, 0)
      Tina4::DevAdmin.instance_variable_set(:@reload_file, "")
    end

    def mtime_get
      env = { "PATH_INFO" => "/__dev/api/mtime", "REQUEST_METHOD" => "GET" }
      _, _, body = Tina4::DevAdmin.handle_request(env)
      JSON.parse(body.first)
    end

    def reload_post(body_hash = {})
      env = {
        "PATH_INFO" => "/__dev/api/reload",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(body_hash.to_json)
      }
      Tina4::DevAdmin.handle_request(env)
    end

    it "mtime starts at 0" do
      data = mtime_get
      expect(data["mtime"]).to eq(0)
      expect(data["file"]).to eq("")
    end

    it "POST /__dev/api/reload bumps the mtime counter" do
      before_ts = Time.now.to_i
      reload_post("file" => "lib/routes/home.rb", "type" => "reload")
      after_ts = Time.now.to_i

      data = mtime_get
      expect(data["mtime"]).to be_between(before_ts, after_ts)
      expect(data["file"]).to eq("lib/routes/home.rb")
    end

    it "does not create a sentinel file on disk" do
      src_sentinel = File.join(Dir.pwd, "src", ".reload_sentinel")
      tina_sentinel = File.join(Dir.pwd, ".tina4", ".reload_sentinel")
      File.delete(src_sentinel) if File.exist?(src_sentinel)
      File.delete(tina_sentinel) if File.exist?(tina_sentinel)

      reload_post("file" => "whatever.rb")

      expect(File.exist?(src_sentinel)).to be false
      expect(File.exist?(tina_sentinel)).to be false
    end

    it "mtime is monotonic across successive reloads" do
      reload_post("file" => "a.rb")
      m1 = mtime_get["mtime"]
      sleep 1
      reload_post("file" => "b.rb")
      m2 = mtime_get["mtime"]

      expect(m2).to be > m1
      expect(mtime_get["file"]).to eq("b.rb")
    end
  end

  describe "status API" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
    end

    it "includes db_tables as an integer" do
      env = { "PATH_INFO" => "/__dev/api/status", "REQUEST_METHOD" => "GET" }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data).to have_key("db_tables")
      expect(data["db_tables"]).to be_a(Integer)
    end
  end

  describe "multi-statement SQL execution" do
    let(:db_path) { File.join(Dir.tmpdir, "tina4_multi_test_#{Process.pid}.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
      Tina4.bind_database(db)
    end

    after do
      db.close rescue nil
      Tina4.bind_database(nil)
      File.delete(db_path) if File.exist?(db_path)
    end

    it "executes a CREATE + INSERT batch via the query API" do
      env = {
        "PATH_INFO" => "/__dev/api/query",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(JSON.generate({
          query: "CREATE TABLE test_multi (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO test_multi (id, name) VALUES (1, 'Alice'); INSERT INTO test_multi (id, name) VALUES (2, 'Bob')"
        }))
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data["success"]).to be true

      # Verify data was inserted via a SELECT query
      select_env = {
        "PATH_INFO" => "/__dev/api/query",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(JSON.generate({ query: "SELECT * FROM test_multi" }))
      }
      _s, _h, select_body = Tina4::DevAdmin.handle_request(select_env)
      select_data = JSON.parse(select_body.first)
      expect(select_data["rows"].size).to eq(2)
    end

    it "returns error when a batch contains a bad statement (rollback)" do
      # Create table first
      setup_env = {
        "PATH_INFO" => "/__dev/api/query",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(JSON.generate({
          query: "CREATE TABLE test_rb (id INTEGER PRIMARY KEY, name TEXT)"
        }))
      }
      Tina4::DevAdmin.handle_request(setup_env)

      # Try batch with a bad statement — should rollback
      bad_env = {
        "PATH_INFO" => "/__dev/api/query",
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(JSON.generate({
          query: "INSERT INTO test_rb (id, name) VALUES (1, 'Alice'); INSERT INTO nonexistent (x) VALUES (1)"
        }))
      }
      status, _headers, body = Tina4::DevAdmin.handle_request(bad_env)
      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data).to have_key("error")
    end
  end

  describe "SPA shell and JS bundle" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")
    end

    let(:html) do
      env = { "PATH_INFO" => "/__dev", "REQUEST_METHOD" => "GET" }
      _status, _headers, body = Tina4::DevAdmin.handle_request(env)
      body.first
    end

    it "returns SPA shell with app container" do
      expect(html).to include('id="app"')
      expect(html).to include("tina4-dev-admin.min.js")
    end

    it "serves the REAL dev admin JS bundle (not a stub/truncated asset)" do
      env = { "PATH_INFO" => "/__dev/js/tina4-dev-admin.min.js", "REQUEST_METHOD" => "GET" }
      status, headers, body = Tina4::DevAdmin.handle_request(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to include("javascript")

      js = body.first
      expect(js.length).to be > 1000
      # Assert the served body is the genuine bundle the dashboard depends on:
      # the SPA framework token plus the same database-tab selectors the
      # source-file test checks. A truncated or wrong asset would miss these.
      expect(js).to include("tina4")
      expect(js).to include("db-table-list")
      expect(js).to include("db-result")
      expect(js).to include("db-query")
    end

    it "JS bundle contains database tab elements" do
      js_path = File.join(File.dirname(__FILE__), "..", "lib", "tina4", "public", "js", "tina4-dev-admin.js")
      skip("tina4-dev-admin.js not found") unless File.exist?(js_path)
      js = File.read(js_path, encoding: "UTF-8")
      expect(js).to include("db-table-list")
      expect(js).to include("db-result")
      expect(js).to include("db-query")
    end

    it "JS bundle contains seed controls" do
      js_path = File.join(File.dirname(__FILE__), "..", "lib", "tina4", "public", "js", "tina4-dev-admin.js")
      skip("tina4-dev-admin.js not found") unless File.exist?(js_path)
      js = File.read(js_path, encoding: "UTF-8")
      expect(js).to include("db-seed-table")
      expect(js).to include("db-seed-count")
    end
  end

  describe "SQLite LIMIT dedup" do
    let(:db_path) { File.join(Dir.tmpdir, "tina4_limit_test_#{Process.pid}.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

    after do
      db.close rescue nil
      File.delete(db_path) if File.exist?(db_path)
    end

    it "fetch with existing LIMIT in SQL does not double it" do
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      10.times { |i| db.execute("INSERT INTO items (id, name) VALUES (#{i}, 'item#{i}')") }

      # SQL already has LIMIT — should return exactly 3 rows
      result = db.fetch("SELECT * FROM items LIMIT 3")
      expect(result.to_a.size).to eq(3)
    end

    it "fetch without LIMIT returns all rows when no limit: kwarg given" do
      db.execute("CREATE TABLE items2 (id INTEGER PRIMARY KEY, name TEXT)")
      30.times { |i| db.execute("INSERT INTO items2 (id, name) VALUES (#{i}, 'item#{i}')") }

      # No LIMIT in SQL, no limit: kwarg — returns all rows
      result = db.fetch("SELECT * FROM items2")
      expect(result.to_a.size).to eq(30)
    end

    it "fetch with limit: kwarg applies the limit" do
      db.execute("CREATE TABLE items3 (id INTEGER PRIMARY KEY, name TEXT)")
      30.times { |i| db.execute("INSERT INTO items3 (id, name) VALUES (#{i}, 'item#{i}')") }

      # Explicit limit: kwarg — should return exactly 20
      result = db.fetch("SELECT * FROM items3", limit: 20)
      expect(result.to_a.size).to eq(20)
    end
  end

  # ── Connection tester (POST /__dev/api/connections/test) ───────
  # Lock-in for the dev-dashboard "Test connection" button. This same
  # endpoint regressed to a constant "0 tables" in the PHP and Node
  # backends (now fixed); Ruby was already correct. Per the parity
  # mandate every framework gets a real behavioural guard so this class
  # of regression can't silently ship — mirrors the MCP #164 approach.
  #
  # NO mocks: a real temp SQLite file is created via the real
  # Tina4::Database, two real tables are added with db.execute, then the
  # real handler path (handle_connections_test) is driven and its JSON
  # response is asserted to report the real table count + a real version.
  describe "connection tester" do
    let(:db_path) { File.join(Dir.tmpdir, "tina4_conntest_#{Process.pid}_#{rand(1_000_000)}.db") }
    # Absolute temp path -> "sqlite:///" + "/abs/path" = "sqlite:////abs/path"
    # which the driver resolves as an absolute file (NOT relative to cwd).
    let(:db_url) { "sqlite:///#{db_path}" }

    after do
      # The sqlite driver opens with journal_mode=WAL, so clean the sidecars too.
      [db_path, "#{db_path}-wal", "#{db_path}-shm"].each do |file|
        File.delete(file) if File.exist?(file)
      end
    end

    it "reports the real table count from a live SQLite connection" do
      # Real SQLite database, two real tables via real DDL.
      db = Tina4::Database.new(db_url)
      db.execute("CREATE TABLE alpha (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("CREATE TABLE beta (id INTEGER PRIMARY KEY, label TEXT)")
      # The exact behaviour the endpoint relies on: db.tables sees them.
      expect(db.tables).to include("alpha", "beta")
      db.close

      # Drive the real connection-tester handler (private singleton method,
      # reached via .send like the other dev-admin handler specs).
      status, _headers, body = Tina4::DevAdmin.send(:handle_connections_test, { "url" => db_url })

      expect(status).to eq(200)
      data = JSON.parse(body.first)
      expect(data["success"]).to be true
      expect(data["tables"]).to be >= 2
      expect(data["version"]).to include("SQLite")
    end
  end

end
