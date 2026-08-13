# frozen_string_literal: true

# Real end-to-end specs for the dev-admin run-chip / grounding / queue /
# websocket parity routes added to lib/tina4/dev_admin.rb.
#
# NO MOCKS. A real Puma server (Puma gives us rack.hijack, which the WebSocket
# upgrade needs) is booted from a throwaway scaffolded Tina4 project on a
# unique high port, and every assertion is made over real HTTP / a real RFC
# 6455 client against a real SQLite database and the real file-backed queue.
#
#   Tier 1 — POST /__dev/api/migrate   applies a real pending migration
#            POST /__dev/api/seed/run  runs a real seeder that inserts a row
#            POST /__dev/api/test      runs the project RSpec suite (pass+fail)
#   Tier 2 — GET  /__dev/api/grounding/status  reflects .env token state
#            POST /__dev/api/grounding/token    upserts TINA4_MCP_TOKEN in .env
#   Tier 3 — POST /__dev/api/queue/purge   really removes an enqueued job
#            GET  /__dev/api/websockets     lists a real live connection
#            POST /__dev/api/websockets/disconnect  really drops it

require "spec_helper"
require "json"
require "socket"
require "securerandom"
require "net/http"
require "timeout"
require "fileutils"
require "tmpdir"

RSpec.describe "dev-admin run-chip parity (live Puma, real deps)", :slow, order: :defined do
  require "puma"

  PROJECT = Dir.mktmpdir("tina4-devadmin-chips-")

  def self.free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  PORT = free_port

  # ── HTTP helpers ─────────────────────────────────────────────
  def post_json(path, body = {})
    Net::HTTP.start("127.0.0.1", PORT, open_timeout: 5, read_timeout: 180) do |http|
      res = http.post(path, JSON.generate(body), "Content-Type" => "application/json")
      [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
    end
  end

  def get_json(path)
    Net::HTTP.start("127.0.0.1", PORT, open_timeout: 5, read_timeout: 30) do |http|
      res = http.get(path)
      [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
    end
  end

  # Open a raw RFC 6455 WebSocket to +path+ and return the still-open socket
  # once the 101 handshake completes (so the connection stays registered on
  # the server while we introspect it).
  def ws_connect(path, timeout: 10)
    sock = TCPSocket.new("127.0.0.1", PORT)
    key = [SecureRandom.bytes(16)].pack("m0")
    sock.write(
      "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{PORT}\r\n" \
      "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    Timeout.timeout(timeout) do
      headers = +""
      headers << sock.readpartial(1) until headers.end_with?("\r\n\r\n")
      raise "handshake failed: #{headers.lines.first}" unless headers.start_with?("HTTP/1.1 101")
    end
    sock
  end

  before(:all) do
    proj = PROJECT
    FileUtils.mkdir_p(File.join(proj, "src", "routes"))
    FileUtils.mkdir_p(File.join(proj, "migrations"))
    FileUtils.mkdir_p(File.join(proj, "seeds"))
    FileUtils.mkdir_p(File.join(proj, "spec"))

    # .env — sqlite DB, debug on, auto-migrate OFF so the migration is still
    # pending when POST /migrate is called.
    File.write(File.join(proj, ".env"), <<~ENV)
      TINA4_DEBUG=true
      TINA4_LOG_LEVEL=NONE
      TINA4_AUTO_MIGRATE=false
      TINA4_DATABASE_URL=sqlite:app.db
    ENV

    # A real pending migration.
    File.write(File.join(proj, "migrations", "20260101000000_create_widgets.sql"), <<~SQL)
      CREATE TABLE widgets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT
      );
    SQL

    # A real seeder — inserts one row via the live DB handle.
    File.write(File.join(proj, "seeds", "001_seed_widgets.rb"), <<~RB)
      db = Tina4.database
      db.execute("INSERT INTO widgets (name) VALUES ('seeded-row')")
    RB

    # A passing project spec for the /test tier (self-contained — no helper).
    File.write(File.join(proj, "spec", "widget_spec.rb"), <<~RB)
      RSpec.describe "widget" do
        it "passes" do
          expect(1 + 1).to eq(2)
        end
      end
    RB

    lib = File.expand_path("../lib", __dir__)
    File.write(File.join(proj, "config.ru"), <<~RU)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"
      Tina4.initialize!(#{proj.inspect})
      Tina4::Health.register!
      Tina4::Frond.register_live_endpoint!
      Tina4::Router.load_routes(File.join(#{proj.inspect}, "src", "routes"))
      run Tina4::RackApp.new(root_dir: #{proj.inspect})
    RU

    # Pin the queue store INSIDE this project, for the server and for this
    # process alike. TINA4_QUEUE_PATH is an ABSOLUTE store shared by everything
    # that inherits it (CI exports one), so Dir.chdir below would not isolate
    # anything on its own - these examples would count jobs another spec file
    # pushed. Deliberately not <cwd>/data/queue either, so a handler that
    # re-derives the path from the working directory still fails here.
    @saved_queue_path = ENV["TINA4_QUEUE_PATH"]
    ENV["TINA4_QUEUE_PATH"] = File.join(proj, "queue-store")

    puma_bin = Gem.bin_path("puma", "puma")
    @log_path = File.join(proj, "puma.log")
    child_env = {
      "TINA4_DEBUG" => "true",
      "TINA4_LOG_LEVEL" => "NONE",
      "TINA4_AUTO_MIGRATE" => "false",
      "TINA4_QUEUE_PATH" => ENV["TINA4_QUEUE_PATH"],
      "TINA4_DATABASE_URL" => "sqlite:app.db",
      "TINA4_NO_AI_PORT" => "true",
      "TINA4_OVERRIDE_CLIENT" => "true",
      "LANG" => "en_US.UTF-8",
      "LC_ALL" => "en_US.UTF-8"
      # NOTE: bundler env is intentionally inherited (not stripped) so the
      # server's `rspec` shell-out in the /test tier resolves under the same
      # bundle as this suite.
    }
    @pid = spawn(
      child_env,
      RbConfig.ruby, puma_bin, "-b", "tcp://127.0.0.1:#{PORT}", File.join(proj, "config.ru"),
      chdir: proj, out: @log_path, err: @log_path
    )

    # Wait until the server answers a real dev-admin request.
    ready = false
    deadline = Time.now + 30
    while Time.now < deadline
      begin
        code, = get_json("/__dev/api/status")
        (ready = true) && break if code == 200
      rescue StandardError
        # not up yet
      end
      sleep 0.2
    end
    unless ready
      log = File.exist?(@log_path) ? File.read(@log_path) : "(no log)"
      raise "Puma dev server never came up on #{PORT}\n--- puma.log ---\n#{log}"
    end
  end

  after(:all) do
    if defined?(@saved_queue_path)
      @saved_queue_path.nil? ? ENV.delete("TINA4_QUEUE_PATH") : ENV["TINA4_QUEUE_PATH"] = @saved_queue_path
    end
    if @pid
      Process.kill("TERM", @pid) rescue nil
      begin
        Timeout.timeout(5) { Process.waitpid(@pid) }
      rescue StandardError
        Process.kill("KILL", @pid) rescue nil
      end
    end
    FileUtils.remove_entry(PROJECT) rescue nil
  end

  # ── Tier 1 ───────────────────────────────────────────────────

  it "POST /__dev/api/migrate applies the real pending migration" do
    code, body = post_json("/__dev/api/migrate")
    expect(code).to eq(200)
    expect(body["applied"]).to include("20260101000000_create_widgets.sql")
    expect(body["failed"]).to eq([])

    # The table really exists now (verified through the live DB via /tables).
    _, tables = get_json("/__dev/api/tables")
    expect(Array(tables["tables"])).to include("widgets")

    # Re-running finds nothing pending — proves the apply persisted.
    _, again = post_json("/__dev/api/migrate")
    expect(again["applied"]).to eq([])
  end

  it "POST /__dev/api/seed/run runs the real seeder and inserts a row" do
    code, body = post_json("/__dev/api/seed/run")
    expect(code).to eq(200)
    expect(body["seeded"]).to eq(1)
    expect(body["failed"]).to eq(0)

    # The row is really in the DB (queried through the live dev-admin SQL route).
    _, q = post_json("/__dev/api/query", { "query" => "SELECT COUNT(*) AS c FROM widgets" })
    row = Array(q["rows"]).first
    count = row && (row["c"] || row[:c] || row.values.first)
    expect(count.to_i).to be >= 1
  end

  it "POST /__dev/api/test runs the project RSpec suite (green, then red)" do
    code, body = post_json("/__dev/api/test")
    expect(code).to eq(200)
    expect(body["ok"]).to be(true), "expected green suite, got: #{body["output"]}"
    expect(body["code"]).to eq(0)
    expect(body["output"].to_s).to match(/1 example, 0 failures/)

    # Negative case — flip the spec to a failing one; the real runner must
    # report a non-zero exit and ok:false.
    File.write(File.join(PROJECT, "spec", "widget_spec.rb"), <<~RB)
      RSpec.describe "widget" do
        it "fails on purpose" do
          expect(1 + 1).to eq(3)
        end
      end
    RB
    _, red = post_json("/__dev/api/test")
    expect(red["ok"]).to be(false)
    expect(red["code"]).not_to eq(0)
    expect(red["output"].to_s).to match(/1 example, 1 failure/)
  end

  # ── Tier 2 ───────────────────────────────────────────────────

  it "grounding status + token upsert round-trips through .env" do
    # Baseline — no token configured.
    code, status = get_json("/__dev/api/grounding/status")
    expect(code).to eq(200)
    expect(status["configured"]).to be(false)
    expect(status["last4"]).to eq("")
    expect(status["url"]).to eq("https://mcp.tina4.com")

    # Save a token — response reports configured + last4, and .env is written.
    _, saved = post_json("/__dev/api/grounding/token", { "token" => "wxyz1234" })
    expect(saved["ok"]).to be(true)
    expect(saved["configured"]).to be(true)
    expect(saved["last4"]).to eq("1234")

    env_body = File.read(File.join(PROJECT, ".env"))
    expect(env_body).to include("TINA4_MCP_TOKEN=wxyz1234")

    # Status now flips to configured.
    _, status2 = get_json("/__dev/api/grounding/status")
    expect(status2["configured"]).to be(true)
    expect(status2["last4"]).to eq("1234")

    # Clearing empties the value and flips configured back off.
    _, cleared = post_json("/__dev/api/grounding/token", { "token" => "" })
    expect(cleared["configured"]).to be(false)
    expect(cleared["last4"]).to eq("")
    expect(File.read(File.join(PROJECT, ".env"))).to match(/^TINA4_MCP_TOKEN=$/)
  end

  # ── Tier 3 ───────────────────────────────────────────────────

  it "POST /__dev/api/queue/purge actually removes a real enqueued job" do
    # Enqueue a real job into the SAME file-backed queue the server reads
    # (both resolve the TINA4_QUEUE_PATH store pinned inside the project).
    Dir.chdir(PROJECT) do
      q = Tina4::Queue.new(backend: :file, topic: "default")
      q.push({ "hello" => "world" })
      expect(q.size(status: "pending")).to eq(1)
    end

    code, body = post_json("/__dev/api/queue/purge", { "topic" => "default", "status" => "pending" })
    expect(code).to eq(200)
    expect(body["purged"]).to be(true)
    expect(body["removed"]).to eq(1)

    # It is really gone from disk.
    Dir.chdir(PROJECT) do
      q = Tina4::Queue.new(backend: :file, topic: "default")
      expect(q.size(status: "pending")).to eq(0)
    end
  end

  it "GET /__dev/api/queue reports real non-zero stats (size called by keyword)" do
    # Regression: the handler used to call queue.size("pending") positionally,
    # but Queue#size is keyword-only — the ArgumentError was swallowed by the
    # rescue, so stats always read all-zeros. Enqueue real jobs into a fresh
    # topic and assert the payload reflects them.
    topic = "statscheck"
    Dir.chdir(PROJECT) do
      q = Tina4::Queue.new(backend: :file, topic: topic)
      q.push({ "n" => 1 })
      q.push({ "n" => 2 })
      expect(q.size(status: "pending")).to eq(2)
    end

    code, body = get_json("/__dev/api/queue?topic=#{topic}")
    expect(code).to eq(200)
    expect(body["stats"]).to be_a(Hash)
    expect(body["stats"]["pending"].to_i).to eq(2)
  end

  it "queue retry/replay respond from the real queue" do
    # retry_failed on an empty failed set is a real no-op (0), not a stub true.
    _, retried = post_json("/__dev/api/queue/retry", { "topic" => "default" })
    expect(retried["retried"]).to eq(0)

    # replay without an id is a real validation error, not a stub true.
    _, replay = post_json("/__dev/api/queue/replay", { "topic" => "default" })
    expect(replay["replayed"]).to be(false)
    expect(replay["error"]).to match(/id/i)
  end

  it "GET /__dev/api/websockets lists a real connection and disconnect drops it" do
    _, before = get_json("/__dev/api/websockets")
    base = before["count"].to_i

    sock = ws_connect("/__dev_reload")
    begin
      # Give the upgrade a moment to register on the manager.
      target = nil
      deadline = Time.now + 5
      loop do
        _, list = get_json("/__dev/api/websockets")
        if list["count"].to_i > base
          target = Array(list["connections"]).first
          break
        end
        break if Time.now > deadline
        sleep 0.1
      end
      expect(target).not_to be_nil, "no live WebSocket connection was enumerated"
      expect(target["id"]).to be_a(String)

      # Disconnect it for real.
      _, dropped = post_json("/__dev/api/websockets/disconnect", { "id" => target["id"] })
      expect(dropped["disconnected"]).to be(true)

      _, after = get_json("/__dev/api/websockets")
      expect(Array(after["connections"]).map { |c| c["id"] }).not_to include(target["id"])
    ensure
      sock.close rescue nil
    end
  end
end
