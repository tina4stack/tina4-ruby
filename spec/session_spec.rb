# frozen_string_literal: true

require "spec_helper"
require "socket"

RSpec.describe Tina4::Session do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sess_test") }
  let(:env) { { "HTTP_COOKIE" => "" } }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  # Set REAL environment variables for one example and always restore the prior
  # state (present-or-absent + value). NO mocks — the code under test reads the
  # real process env exactly as it would in production. A nil value deletes.
  def with_env(pairs)
    saved = pairs.keys.to_h { |key| [key, [ENV.key?(key), ENV[key]]] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, (had, previous)| had ? ENV[key] = previous : ENV.delete(key) }
  end

  # ── Session.cookie_name — the ONE shared cookie-name resolver (3.13.79) ───
  #
  # Single source of truth for TINA4_SESSION_NAME, used by BOTH the write path
  # (#cookie_header) and the read paths (#extract_session_id + RackApp's
  # incoming-cookie parse). Parity with Python's session_cookie_name(). Pure
  # ENV read — no dependency, no double.
  describe ".cookie_name" do
    it "defaults to tina4_session when TINA4_SESSION_NAME is unset" do
      with_env("TINA4_SESSION_NAME" => nil) do
        expect(Tina4::Session.cookie_name).to eq("tina4_session")
      end
    end

    it "returns the configured name when TINA4_SESSION_NAME is set" do
      with_env("TINA4_SESSION_NAME" => "my_app_session") do
        expect(Tina4::Session.cookie_name).to eq("my_app_session")
      end
    end

    it "falls back to the default when TINA4_SESSION_NAME is blank (never emits `=`)" do
      with_env("TINA4_SESSION_NAME" => "") do
        expect(Tina4::Session.cookie_name).to eq("tina4_session")
      end
    end

    it "drives BOTH the write name and the read (extract) name off the one resolver" do
      with_env("TINA4_SESSION_NAME" => "renamed_sess") do
        writer = Tina4::Session.new({ "HTTP_COOKIE" => "" },
                                    handler: :file, handler_options: { dir: tmp_dir })
        expect(writer.cookie_header).to start_with("renamed_sess=")
        # Persist it first: strict session mode (ADR-0021) adopts a cookie id
        # only when the store already holds a session under it, so an unsaved
        # id would be discarded here for the right reason and mask what this
        # example is actually about (cookie-NAME resolution).
        writer["k"] = "v"
        writer.save
        # The read side resolves the SAME name: a cookie under the configured
        # name is extracted back into the resumed session id.
        reader = Tina4::Session.new({ "HTTP_COOKIE" => "renamed_sess=#{writer.id}" },
                                    handler: :file, handler_options: { dir: tmp_dir })
        expect(reader.id).to eq(writer.id)
        # A cookie under the OLD default name is NOT matched once renamed.
        stale = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{writer.id}" },
                                   handler: :file, handler_options: { dir: tmp_dir })
        expect(stale.id).not_to eq(writer.id)
      end
    end
  end

  # ── TINA4_SESSION_BACKEND handler selection ──────────────────────────────
  #
  # Lock-in for the env-var wiring: Ruby SHIPPED the redis/valkey/mongo/database
  # handlers but nothing read TINA4_SESSION_BACKEND, so every non-file backend
  # was unreachable by configuration while the docs documented it. These specs
  # pin the resolution contract against the Python master
  # (tina4_python/tina4_python/session/__init__.py::_resolve_handler):
  #
  #   file|filesystem → File, redis → Redis, valkey → Valkey,
  #   mongodb|mongo → Mongo, database|db → Database,
  #   UNKNOWN → File (silent fallback, never raises).
  #
  # NO MOCKS: each example sets the REAL env var and builds a REAL Tina4::Session
  # whose REAL handler is constructed. The Redis/Valkey handlers connect lazily
  # (one short-lived RESP connection per command), so SELECTION is observable
  # without a live server; the round-trip example below is service-gated and
  # hits a REAL Redis.
  describe "TINA4_SESSION_BACKEND" do
    def self.service_reachable?(host, port)
      Socket.tcp(host, port, connect_timeout: 0.5) { true }
    rescue StandardError
      false
    end

    # Set the REAL env var for one example and always restore the prior value.
    def with_backend(value)
      had = ENV.key?("TINA4_SESSION_BACKEND")
      previous = ENV["TINA4_SESSION_BACKEND"]
      value.nil? ? ENV.delete("TINA4_SESSION_BACKEND") : ENV["TINA4_SESSION_BACKEND"] = value
      yield
    ensure
      had ? ENV["TINA4_SESSION_BACKEND"] = previous : ENV.delete("TINA4_SESSION_BACKEND")
    end

    def handler_for(backend, opts = {})
      with_backend(backend) do
        session = Tina4::Session.new(env, { handler_options: { dir: tmp_dir } }.merge(opts))
        session.instance_variable_get(:@handler)
      end
    end

    it "selects the Redis handler when set to redis" do
      expect(handler_for("redis")).to be_a(Tina4::SessionHandlers::RedisHandler)
    end

    it "selects the Valkey handler when set to valkey" do
      expect(handler_for("valkey")).to be_a(Tina4::SessionHandlers::ValkeyHandler)
    end

    it "selects the file handler when set to file" do
      expect(handler_for("file")).to be_a(Tina4::SessionHandlers::FileHandler)
    end

    it "accepts the filesystem alias for the file handler" do
      expect(handler_for("filesystem")).to be_a(Tina4::SessionHandlers::FileHandler)
    end

    it "defaults to the file handler when the variable is unset" do
      expect(handler_for(nil)).to be_a(Tina4::SessionHandlers::FileHandler)
    end

    it "is case-insensitive and ignores surrounding whitespace" do
      expect(handler_for("  ReDiS  ")).to be_a(Tina4::SessionHandlers::RedisHandler)
    end

    # NEGATIVE, INVERTED 2026-07-31 by owner decision. This case used to assert
    # the opposite - that an unknown value falls back to the file handler and
    # never raises - on the reasoning that "an app with a typo'd backend must
    # still serve". It does still serve, on the WRONG storage, which is worse:
    # sessions go to local disk while the operator believes they are in Redis,
    # nothing is logged, and the symptom only appears later as users being logged
    # out whenever a request lands on another instance. All four frameworks now
    # raise. Full coverage lives in session_backend_validation_spec.rb; this case
    # stays here so the old contract cannot quietly return through this file.
    it "raises on an unknown value instead of falling back to the file handler" do
      expect { handler_for("not-a-real-backend") }
        .to raise_error(ArgumentError, /Unknown session backend/)
    end

    # NEGATIVE: an explicitly passed :handler outranks the environment.
    it "lets an explicit :handler option win over the env var" do
      expect(handler_for("redis", handler: :file)).to be_a(Tina4::SessionHandlers::FileHandler)
    end

    describe "the database backend" do
      let(:db_path) { File.join(tmp_dir, "sessions.db") }
      let(:database) { Tina4::Database.new("sqlite://#{db_path}") }

      it "selects the Database handler when set to database" do
        Tina4.bind_database(database)
        expect(handler_for("database")).to be_a(Tina4::SessionHandlers::DatabaseHandler)
      end

      it "accepts the db alias" do
        Tina4.bind_database(database)
        expect(handler_for("db")).to be_a(Tina4::SessionHandlers::DatabaseHandler)
      end

      # Parity with Python (_resolve_handler → DatabaseSessionHandler(ORM._get_db())):
      # the backend must reuse the SAME connection the ORM resolves, not open a
      # second one of its own. Uses a REAL SQLite database on disk.
      it "reuses the connection the ORM is bound to" do
        Tina4.bind_database(database)
        handler = handler_for("database")
        expect(handler.instance_variable_get(:@db)).to equal(database)
      end

      # End-to-end through the REAL SQLite database selected purely by env var.
      # The row assertion is what makes this discriminating: a round-trip alone
      # would still pass on the file handler (the pre-fix fallback), so the data
      # is read back out of the REAL tina4_session table to prove the env var
      # selected a backend that stores where it says it does.
      it "round-trips session data through the env-selected database" do
        Tina4.bind_database(database)
        with_backend("database") do
          writer = Tina4::Session.new(env, handler_options: {})
          writer["user"] = "Alice"
          expect(writer.save).to be true

          row = database.fetch_one(
            "SELECT data FROM tina4_session WHERE session_id = ?", [writer.id]
          )
          expect(row).not_to be_nil, "the session must be persisted in the real database table"
          expect(JSON.parse(row[:data] || row["data"])).to eq({ "user" => "Alice" })

          reader = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{writer.id}" },
                                      handler_options: {})
          expect(reader["user"]).to eq("Alice")
        end
      end
    end

    # A live-service round-trip proving the env var selects a handler that really
    # stores where it says. Skipped when Redis is not running; CI provisions it
    # and TINA4_REQUIRE_SERVICES turns this skip into a hard failure.
    describe "against a live Redis" do
      before do
        skip "redis not running" unless self.class.service_reachable?("localhost", 6379)
      end

      it "round-trips session data through the env-selected Redis" do
        with_backend("redis") do
          writer = Tina4::Session.new(env, handler_options: {})
          writer["user"] = "Alice"
          expect(writer.save).to be true

          reader = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{writer.id}" },
                                      handler_options: {})
          expect(reader["user"]).to eq("Alice")
          reader.destroy
        end
      end
    end
  end

  describe "#initialize" do
    it "creates a session with a unique id" do
      session = Tina4::Session.new(env, options)
      expect(session.id).to be_a(String)
      expect(session.id.length).to be > 0
    end

    it "generates a 64-char hex id" do
      session = Tina4::Session.new(env, options)
      expect(session.id).to match(/\A[0-9a-f]{64}\z/)
    end

    it "generates unique ids for different sessions" do
      s1 = Tina4::Session.new(env, options)
      s2 = Tina4::Session.new(env, options)
      expect(s1.id).not_to eq(s2.id)
    end

    it "restores session from cookie" do
      s1 = Tina4::Session.new(env, options)
      s1["user"] = "Alice"
      s1.save

      env2 = { "HTTP_COOKIE" => "tina4_session=#{s1.id}" }
      s2 = Tina4::Session.new(env2, options)
      expect(s2["user"]).to eq("Alice")
    end

    it "extracts session id from cookie with multiple cookies" do
      s1 = Tina4::Session.new(env, options)
      s1["color"] = "blue"
      s1.save

      env2 = { "HTTP_COOKIE" => "other=abc; tina4_session=#{s1.id}; foo=bar" }
      s2 = Tina4::Session.new(env2, options)
      expect(s2["color"]).to eq("blue")
    end

    it "starts with empty data for a new session" do
      session = Tina4::Session.new(env, options)
      expect(session.data).to eq({})
    end

    it "constructs without a secret when none provided (no guessable default)" do
      session = Tina4::Session.new(env, { handler: :file, handler_options: { dir: tmp_dir } })
      expect(session).not_to be_nil
    end
  end

  describe "#[] and #[]=" do
    it "gets and sets values" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      expect(session["key"]).to eq("value")
    end

    it "converts keys to strings" do
      session = Tina4::Session.new(env, options)
      session[:symbol_key] = "test"
      expect(session["symbol_key"]).to eq("test")
    end

    it "returns nil for missing keys" do
      session = Tina4::Session.new(env, options)
      expect(session["nonexistent"]).to be_nil
    end

    it "overwrites existing values" do
      session = Tina4::Session.new(env, options)
      session["key"] = "first"
      session["key"] = "second"
      expect(session["key"]).to eq("second")
    end
  end

  describe "#get and #set" do
    it "get returns the value for existing key" do
      session = Tina4::Session.new(env, options)
      session.set("name", "Alice")
      expect(session.get("name")).to eq("Alice")
    end

    it "get returns default for missing key" do
      session = Tina4::Session.new(env, options)
      expect(session.get("missing", "fallback")).to eq("fallback")
    end

    it "get returns nil when no default provided" do
      session = Tina4::Session.new(env, options)
      expect(session.get("missing")).to be_nil
    end

    # A STORED false is a value, not an absence. `@data[key] || default` returned
    # the caller's default for ANY falsy stored value, so a legitimately stored
    # false read back as the default — a feature flag stored false read back true.
    # Python (dict.get), PHP (??) and Node (??) all return the stored false, so
    # Ruby was the 1-of-4 outlier. Shared contract name across all four repos.
    #
    # BOTH halves matter: without the absent-key control, a "fix" that simply
    # never returned the default would pass while being a worse bug.
    it "session get returns a stored false instead of the default" do
      session = Tina4::Session.new(env, options)
      session.set("flag", false)

      # POSITIVE — the stored false comes back as false, not as the default.
      expect(session.has?("flag")).to be true
      expect(session.get("flag", true)).to be false
      expect(session.get("flag")).to be false

      # NEGATIVE CONTROL — an ABSENT key still returns the default.
      expect(session.has?("absent")).to be false
      expect(session.get("absent", "fallback")).to eq("fallback")
      expect(session.get("absent")).to be_nil
    end
  end

  describe "#has?" do
    it "returns true for existing key" do
      session = Tina4::Session.new(env, options)
      session["present"] = "yes"
      expect(session.has?("present")).to be true
    end

    it "returns false for missing key" do
      session = Tina4::Session.new(env, options)
      expect(session.has?("absent")).to be false
    end

    it "converts key to string" do
      session = Tina4::Session.new(env, options)
      session["key"] = "val"
      expect(session.has?(:key)).to be true
    end
  end

  describe "#all" do
    it "returns a copy of session data" do
      session = Tina4::Session.new(env, options)
      session["a"] = 1
      session["b"] = 2
      all = session.all
      expect(all).to eq({ "a" => 1, "b" => 2 })
    end

    it "returns a copy that does not affect the session" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      all = session.all
      all["key"] = "modified"
      expect(session["key"]).to eq("value")
    end
  end

  describe "#delete" do
    it "removes a key" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      session.delete("key")
      expect(session["key"]).to be_nil
    end

    it "marks session as modified" do
      session = Tina4::Session.new(env, options)
      session["key"] = "value"
      session.save
      session.delete("key")
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["key"]).to be_nil
    end
  end

  describe "#clear" do
    it "clears all data" do
      session = Tina4::Session.new(env, options)
      session["a"] = 1
      session["b"] = 2
      session.clear
      expect(session.to_hash).to eq({})
    end
  end

  describe "#save" do
    it "persists session data" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Bob"
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["name"]).to eq("Bob")
    end

    it "does not write a session file when never modified" do
      session = Tina4::Session.new(env, options)
      # No modifications made: save must be a genuine no-op (returns true early,
      # before touching the backend) so an untouched session never persists.
      expect(session.save).to be true
      expect(Dir.glob(File.join(tmp_dir, "sess_*.json"))).to be_empty

      # Sanity: once a value is set, the SAME id DOES write a file — proving the
      # no-op above was the modified-flag gate, not a broken handler/dir.
      session["touched"] = "now"
      expect(session.save).to be true
      # The on-disk name is the SHA-256 of the id (ADR-0021), never the id
      # itself: a raw id would be lossy-sanitised and could collide.
      expect(
        Dir.glob(File.join(tmp_dir, "sess_#{Digest::SHA256.hexdigest(session.id)}.json"))
      ).not_to be_empty
    end

    it "persists multiple values" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Alice"
      session["role"] = "admin"
      session["count"] = 42
      session.save

      s2 = Tina4::Session.new({ "HTTP_COOKIE" => "tina4_session=#{session.id}" }, options)
      expect(s2["name"]).to eq("Alice")
      expect(s2["role"]).to eq("admin")
      expect(s2["count"]).to eq(42)
    end
  end

  describe "#destroy" do
    it "destroys session data" do
      session = Tina4::Session.new(env, options)
      session["name"] = "Bob"
      session.save
      session.destroy
      expect(session.to_hash).to eq({})
    end
  end

  describe "#flash" do
    it "sets a flash value" do
      session = Tina4::Session.new(env, options)
      session.flash("message", "Hello!")
      expect(session.flash("message")).to eq("Hello!")
    end

    it "removes flash value after reading" do
      session = Tina4::Session.new(env, options)
      session.flash("notice", "Done!")
      session.flash("notice") # first read
      expect(session.flash("notice")).to be_nil
    end

    it "returns nil for missing flash key" do
      session = Tina4::Session.new(env, options)
      expect(session.flash("nonexistent")).to be_nil
    end

    it "stores flash with a prefix key internally" do
      session = Tina4::Session.new(env, options)
      session.flash("msg", "hi")
      expect(session.data).to have_key("_flash_msg")
    end
  end

  describe "#regenerate" do
    it "changes the session id" do
      session = Tina4::Session.new(env, options)
      old_id = session.id
      session.regenerate
      expect(session.id).not_to eq(old_id)
    end

    it "generates a valid new id" do
      session = Tina4::Session.new(env, options)
      session.regenerate
      expect(session.id).to match(/\A[0-9a-f]{64}\z/)
    end

    it "preserves session data" do
      session = Tina4::Session.new(env, options)
      session["keep"] = "this"
      session.save
      session.regenerate
      expect(session.get("keep")).to eq("this")
    end
  end

  describe "#cookie_header" do
    it "returns a valid Set-Cookie string" do
      session = Tina4::Session.new(env, options)
      header = session.cookie_header
      expect(header).to include("tina4_session=")
      expect(header).to include("HttpOnly")
      expect(header).to include("Path=/")
    end

    it "includes SameSite=Lax" do
      session = Tina4::Session.new(env, options)
      expect(session.cookie_header).to include("SameSite=Lax")
    end

    it "includes Max-Age" do
      session = Tina4::Session.new(env, options)
      expect(session.cookie_header).to include("Max-Age=3600")
    end

    it "uses custom cookie name" do
      custom_opts = options.merge(cookie_name: "my_session")
      session = Tina4::Session.new(env, custom_opts)
      expect(session.cookie_header).to include("my_session=")
    end

    # ── issue #31: Secure / SameSite were silent no-ops ────────────────────
    #
    # These pin the unified Secure contract (parity with tina4-php#175/#179) and
    # prove TINA4_SESSION_SAMESITE is honoured rather than hardcoded to Lax.
    # `env` here is a plain-HTTP request (no x-forwarded-proto, no rack https),
    # so the request-scheme signal is off unless a test opts it in.

    it "honours TINA4_SESSION_SAMESITE instead of hardcoding Lax" do
      with_env("TINA4_SESSION_SAMESITE" => "Strict", "TINA4_SESSION_SECURE" => nil) do
        header = Tina4::Session.new(env, options).cookie_header
        expect(header).to include("SameSite=Strict")
        expect(header).not_to include("SameSite=Lax")
      end
    end

    it "emits Secure when TINA4_SESSION_SECURE is truthy (on plain HTTP)" do
      with_env("TINA4_SESSION_SECURE" => "true", "TINA4_SESSION_SAMESITE" => nil) do
        expect(Tina4::Session.new(env, options).cookie_header).to include("Secure")
      end
    end

    it "does NOT emit Secure by default on a plain-HTTP request" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        expect(Tina4::Session.new(env, options).cookie_header).not_to include("Secure")
      end
    end

    it "emits Secure on an https request via x-forwarded-proto (proxy-aware)" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        https_env = env.merge("HTTP_X_FORWARDED_PROTO" => "https")
        expect(Tina4::Session.new(https_env, options).cookie_header).to include("Secure")
      end
    end

    it "reads only the first hop of an x-forwarded-proto chain" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        # client-facing hop is https -> Secure
        secure = env.merge("HTTP_X_FORWARDED_PROTO" => "https, http")
        expect(Tina4::Session.new(secure, options).cookie_header).to include("Secure")
        # client-facing hop is http -> not Secure (an inner https hop is irrelevant)
        insecure = env.merge("HTTP_X_FORWARDED_PROTO" => "http, https")
        expect(Tina4::Session.new(insecure, options).cookie_header).not_to include("Secure")
      end
    end

    it "emits Secure on a native https request (rack.url_scheme)" do
      with_env("TINA4_SESSION_SECURE" => nil, "TINA4_SESSION_SAMESITE" => nil) do
        https_env = env.merge("rack.url_scheme" => "https")
        expect(Tina4::Session.new(https_env, options).cookie_header).to include("Secure")
      end
    end

    it "forces Secure when SameSite=None even on plain HTTP (RFC 6265bis)" do
      with_env("TINA4_SESSION_SAMESITE" => "None", "TINA4_SESSION_SECURE" => nil) do
        header = Tina4::Session.new(env, options).cookie_header
        expect(header).to include("SameSite=None")
        expect(header).to include("Secure")
      end
    end

    it "honours TINA4_SESSION_HTTPONLY=false" do
      with_env("TINA4_SESSION_HTTPONLY" => "false") do
        expect(Tina4::Session.new(env, options).cookie_header).not_to include("HttpOnly")
      end
    end

    it "honours TINA4_SESSION_TTL for the cookie Max-Age" do
      with_env("TINA4_SESSION_TTL" => "7200") do
        expect(Tina4::Session.new(env, options).cookie_header).to include("Max-Age=7200")
      end
    end
  end

  # ── Task B: Redis / Mongo handlers read their connection from env ─────────
  #
  # Ruby SHIPPED redis/valkey/mongo handlers, but the Redis handler read NO env
  # (hardcoded localhost:6379) and the Mongo handler read NO env (hardcoded
  # mongodb://localhost:27017, db "tina4_sessions"), so TINA4_SESSION_BACKEND
  # could select them but nothing could point them at a server. These pin the
  # env-var contract mirrored from Python's handlers. NO mocks: each example
  # constructs the REAL handler which resolves its config from the REAL env.
  # Explicit constructor options must still win over the environment.
  describe "backend handler env configuration" do
    describe "RedisHandler" do
      # RedisHandler connects lazily (the redis gem / RESP client only dials on
      # the first command), so SELECTION + config resolution are observable with
      # no live Redis — no service gate needed for these.
      it "reads host/port/db/password from TINA4_SESSION_REDIS_* env vars" do
        with_env(
          "TINA4_SESSION_REDIS_HOST" => "redis.internal.example",
          "TINA4_SESSION_REDIS_PORT" => "6380",
          "TINA4_SESSION_REDIS_DB" => "3",
          "TINA4_SESSION_REDIS_PASSWORD" => "s3cr3t"
        ) do
          handler = Tina4::SessionHandlers::RedisHandler.new
          expect(handler.instance_variable_get(:@host)).to eq("redis.internal.example")
          expect(handler.instance_variable_get(:@port)).to eq(6380)
          expect(handler.instance_variable_get(:@db)).to eq(3)
          expect(handler.instance_variable_get(:@password)).to eq("s3cr3t")
        end
      end

      it "defaults to localhost:6379 / db 0 when no env is set" do
        with_env(
          "TINA4_SESSION_REDIS_HOST" => nil, "TINA4_SESSION_REDIS_PORT" => nil,
          "TINA4_SESSION_REDIS_DB" => nil, "TINA4_SESSION_REDIS_PASSWORD" => nil
        ) do
          handler = Tina4::SessionHandlers::RedisHandler.new
          expect(handler.instance_variable_get(:@host)).to eq("localhost")
          expect(handler.instance_variable_get(:@port)).to eq(6379)
          expect(handler.instance_variable_get(:@db)).to eq(0)
        end
      end

      it "lets an explicit constructor option win over the env var" do
        with_env("TINA4_SESSION_REDIS_HOST" => "env-host") do
          handler = Tina4::SessionHandlers::RedisHandler.new(host: "opt-host")
          expect(handler.instance_variable_get(:@host)).to eq("opt-host")
        end
      end
    end

    describe "MongoHandler" do
      # The mongo gem is required at construction; the connection is lazy but
      # ensure_ttl_index does dial the server, so the test URIs carry a short
      # serverSelectionTimeoutMS — with no live Mongo, construction fails fast
      # (~200ms), the error is caught + logged, and the resolved config ivars
      # are still populated (they are set BEFORE the connect). No mock: a REAL
      # Mongo::Client parses the REAL env-derived URI.
      before do
        require "mongo"
      rescue LoadError
        skip "mongo gem not installed"
      end

      let(:fast_uri) { "mongodb://127.0.0.1:27017/?serverSelectionTimeoutMS=200" }

      it "reads uri/db/collection from TINA4_SESSION_MONGO_* env vars" do
        with_env(
          "TINA4_SESSION_MONGO_URI" => fast_uri,
          "TINA4_SESSION_MONGO_DB" => "app_sessions",
          "TINA4_SESSION_MONGO_COLLECTION" => "sess",
          "TINA4_SESSION_MONGO_URL" => nil
        ) do
          handler = Tina4::SessionHandlers::MongoHandler.new
          expect(handler.instance_variable_get(:@uri)).to eq(fast_uri)
          expect(handler.instance_variable_get(:@database)).to eq("app_sessions")
          expect(handler.instance_variable_get(:@collection_name)).to eq("sess")
        end
      end

      it "accepts TINA4_SESSION_MONGO_URL as a legacy alias for the URI" do
        with_env("TINA4_SESSION_MONGO_URI" => nil, "TINA4_SESSION_MONGO_URL" => fast_uri) do
          handler = Tina4::SessionHandlers::MongoHandler.new
          expect(handler.instance_variable_get(:@uri)).to eq(fast_uri)
        end
      end

      it "defaults the database to Python's 'tina4' (not the old 'tina4_sessions')" do
        with_env(
          "TINA4_SESSION_MONGO_URI" => fast_uri, "TINA4_SESSION_MONGO_URL" => nil,
          "TINA4_SESSION_MONGO_DB" => nil, "TINA4_SESSION_MONGO_COLLECTION" => nil
        ) do
          handler = Tina4::SessionHandlers::MongoHandler.new
          expect(handler.instance_variable_get(:@database)).to eq("tina4")
        end
      end

      it "lets an explicit :database option win over the env var" do
        with_env("TINA4_SESSION_MONGO_URI" => fast_uri, "TINA4_SESSION_MONGO_DB" => "env-db") do
          handler = Tina4::SessionHandlers::MongoHandler.new(database: "opt-db")
          expect(handler.instance_variable_get(:@database)).to eq("opt-db")
        end
      end
    end
  end

  describe "#to_hash" do
    it "returns a copy of session data" do
      session = Tina4::Session.new(env, options)
      session["x"] = 1
      hash = session.to_hash
      expect(hash).to eq({ "x" => 1 })
    end

    it "returns a copy that does not affect original" do
      session = Tina4::Session.new(env, options)
      session["x"] = 1
      hash = session.to_hash
      hash["x"] = 999
      expect(session["x"]).to eq(1)
    end
  end
end

RSpec.describe Tina4::LazySession do
  let(:tmp_dir) { Dir.mktmpdir("tina4_lazy_sess_test") }
  let(:env) { { "HTTP_COOKIE" => "" } }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it "lazy-loads session on first access" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["test"] = "value"
    expect(lazy["test"]).to eq("value")
  end

  it "delegates get to underlying session" do
    lazy = Tina4::LazySession.new(env, options)
    lazy.set("name", "Alice")
    expect(lazy.get("name")).to eq("Alice")
  end

  it "delegates get with default" do
    lazy = Tina4::LazySession.new(env, options)
    expect(lazy.get("missing", "default")).to eq("default")
  end

  it "delegates has?" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["key"] = "val"
    expect(lazy.has?("key")).to be true
    expect(lazy.has?("other")).to be false
  end

  it "delegates all" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["a"] = 1
    expect(lazy.all).to eq({ "a" => 1 })
  end

  it "delegates flash" do
    lazy = Tina4::LazySession.new(env, options)
    lazy.flash("msg", "hi")
    expect(lazy.flash("msg")).to eq("hi")
    expect(lazy.flash("msg")).to be_nil
  end

  it "delegates delete" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["key"] = "val"
    lazy.delete("key")
    expect(lazy["key"]).to be_nil
  end

  it "delegates clear" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["a"] = 1
    lazy.clear
    expect(lazy.all).to eq({})
  end

  it "delegates to_hash" do
    lazy = Tina4::LazySession.new(env, options)
    lazy["x"] = 42
    expect(lazy.to_hash).to eq({ "x" => 42 })
  end

  it "delegates cookie_header" do
    lazy = Tina4::LazySession.new(env, options)
    expect(lazy.cookie_header).to include("tina4_session=")
  end

  it "save does nothing when session not loaded" do
    lazy = Tina4::LazySession.new(env, options)
    expect { lazy.save }.not_to raise_error
  end

  it "destroy does nothing when session not loaded" do
    lazy = Tina4::LazySession.new(env, options)
    expect { lazy.destroy }.not_to raise_error
  end
end
