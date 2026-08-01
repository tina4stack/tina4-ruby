# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "tmpdir"
require "fileutils"
require_relative "support/real_log_capture"
require_relative "support/real_env"

# Lock-in specs for three v3 security/parity hardening fixes:
#   1. API-key auth uses a timing-safe comparison (not `==`).
#   2. session.rb carries no guessable hardcoded secret.
#   3. Session backend-failure policy: log-loud + degrade (5 Python invariants).
RSpec.describe "Security hardening" do
  # ────────────────────────────────────────────────────────────────
  # 1. API-key timing-safe comparison
  # ────────────────────────────────────────────────────────────────
  describe "Tina4::Auth API-key timing safety" do
    around(:each) do |example|
      prev = ENV["TINA4_API_KEY"]
      ENV["TINA4_API_KEY"] = "super-secret-api-key-value"
      example.run
      if prev.nil?
        ENV.delete("TINA4_API_KEY")
      else
        ENV["TINA4_API_KEY"] = prev
      end
    end

    it "accepts a correct API key via authenticate_request" do
      result = Tina4::Auth.authenticate_request(
        { "HTTP_AUTHORIZATION" => "Bearer super-secret-api-key-value" }
      )
      expect(result).to eq({ "_auth" => "api_key" })
    end

    it "rejects a wrong API key via authenticate_request" do
      result = Tina4::Auth.authenticate_request(
        { "HTTP_AUTHORIZATION" => "Bearer wrong-key" }
      )
      expect(result).to be_nil
    end

    it "accepts a correct API key via the Rack bearer_auth path" do
      env = { "HTTP_AUTHORIZATION" => "Bearer super-secret-api-key-value" }
      expect(Tina4::Auth.bearer_auth.call(env)).to be true
      expect(env["tina4.auth"]).to eq({ "_auth" => "api_key" })
    end

    it "rejects a wrong API key via the Rack bearer_auth path" do
      env = { "HTTP_AUTHORIZATION" => "Bearer not-the-key" }
      expect(Tina4::Auth.bearer_auth.call(env)).to be false
      expect(env["tina4.auth"]).to be_nil
    end

    # ── How the timing-safe routing is proven WITHOUT a double ──────────
    #
    # This block used to carry three message expectations —
    # `expect(Tina4::Auth).to receive(:validate_api_key)` twice and
    # `expect(OpenSSL).to receive(:fixed_length_secure_compare)` once. Each
    # REPLACES a real collaborator with a mock proxy for the example, which is
    # banned outright here, and the OpenSSL one is worse than banned: it
    # intercepts a stdlib module used by every other library in the process.
    #
    # Timing safety is a property of the COMPARISON, and the comparison has no
    # observable output difference — a wrong key is nil/false whether it was
    # rejected by `==` or by OpenSSL.fixed_length_secure_compare. "The call
    # happened" is simply not in the output, so it cannot be asserted without a
    # double. The contract is therefore split into the two halves that CAN be
    # proven for real:
    #
    #   * RUNTIME — the real end-to-end API-key behaviour through the real
    #     authenticate_request / bearer_auth against real env vars: correct
    #     key, same-length wrong key (the case that genuinely reaches
    #     fixed_length_secure_compare), different-length key (the case that
    #     RAISES ArgumentError out of OpenSSL if the length guard is dropped),
    #     a rotated key, and a blank key.
    #   * SOURCE — a real read of the real lib/tina4/auth.rb, asserting both
    #     call sites route through validate_api_key, that validate_api_key
    #     byte-compares via OpenSSL.fixed_length_secure_compare, and that no
    #     `token == api_key` fast-path exists.
    #
    # Honest scoping: the SOURCE half is weaker than the message expectation it
    # replaces at proving the call happened. The RUNTIME half is strictly
    # stronger than anything that was here before — the old examples never
    # exercised the length guard, a rotated key, or a blank key at all.

    it "rejects a SAME-LENGTH wrong key (the case that really reaches the byte compare)" do
      wrong = "super-secret-api-key-VALUE" # same byte length, different bytes
      expect(wrong.bytesize).to eq("super-secret-api-key-value".bytesize)
      expect(Tina4::Auth.validate_api_key(wrong)).to be false
      expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{wrong}" })).to be_nil
      expect(Tina4::Auth.bearer_auth.call({ "HTTP_AUTHORIZATION" => "Bearer #{wrong}" })).to be false
    end

    it "rejects a DIFFERENT-LENGTH key cleanly instead of raising out of OpenSSL" do
      # OpenSSL.fixed_length_secure_compare RAISES ArgumentError on unequal
      # byte lengths, so auth.rb must gate on length BEFORE comparing. Drop
      # that guard and this example goes red with ArgumentError escaping into
      # the request path (a 500 where a 401 belongs) — a real gate on a real
      # line of production code.
      short = "nope"
      expect(short.bytesize).not_to eq("super-secret-api-key-value".bytesize)
      expect { Tina4::Auth.validate_api_key(short) }.not_to raise_error
      expect(Tina4::Auth.validate_api_key(short)).to be false
      expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{short}" })).to be_nil
      expect(Tina4::Auth.bearer_auth.call({ "HTTP_AUTHORIZATION" => "Bearer #{short}" })).to be false
    end

    it "reads the REAL TINA4_API_KEY on every call (a rotated key takes effect immediately)" do
      # A memoised key would keep authenticating the OLD value after rotation.
      # Real env var, set for real — not `allow(ENV).to receive(:[])`, which
      # would leave ENV.fetch and any memoised read seeing the unstubbed value.
      set_real_env("TINA4_API_KEY" => "rotated-key-0000000000000")
      expect(Tina4::Auth.validate_api_key("rotated-key-0000000000000")).to be true
      expect(Tina4::Auth.validate_api_key("super-secret-api-key-value")).to be false
      # ADR-0021 renamed the API-key auth result to the cross-framework
      # {"_auth" => "api_key"} (PHP and Node already used it; Python moved in the
      # same change). This example was authored on a branch that forked BEFORE
      # that landed, so it still asserted the old Ruby-only {"api_key" => true}
      # — the two examples at the top of this block already assert "_auth", so
      # the file contradicted itself after the merge.
      expect(
        Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer rotated-key-0000000000000" })
      ).to eq({ "_auth" => "api_key" })
    end

    it "never authenticates when the REAL TINA4_API_KEY is blank or unset" do
      set_real_env("TINA4_API_KEY" => "")
      expect(Tina4::Auth.validate_api_key("")).to be false
      expect(Tina4::Auth.validate_api_key("anything")).to be false

      set_real_env("TINA4_API_KEY" => nil)
      expect(Tina4::Auth.validate_api_key("anything")).to be false
      expect(
        Tina4::Auth.bearer_auth.call({ "HTTP_AUTHORIZATION" => "Bearer anything" })
      ).to be false
    end

    # ── Source invariants (a real read of a real file — nothing substituted) ──
    let(:auth_src) do
      # binread + force_encoding, not File.read: Ruby's default external
      # encoding here is US-ASCII, and auth.rb's comments carry UTF-8 em
      # dashes, so a plain File.read yields a US-ASCII string that raises
      # "invalid byte sequence in US-ASCII" the moment it is scanned. Same
      # trap, same fix as read_real_log in spec/support/real_log_capture.rb.
      File.binread(File.join(File.dirname(__FILE__), "..", "lib", "tina4", "auth.rb"))
          .force_encoding(Encoding::UTF_8)
    end

    # Scoped to validate_api_key's OWN body. A file-wide grep would not go red
    # if the compare were swapped for `==` here, because auth.rb names
    # fixed_length_secure_compare in five other places (the JWT signature
    # check, check_password, and three comments).
    let(:validate_api_key_body) do
      auth_src[/^      def validate_api_key\b.*?^      end$/m] or
        raise "validate_api_key not found in lib/tina4/auth.rb — the source invariant is broken, not the code"
    end

    it "validate_api_key byte-compares with OpenSSL.fixed_length_secure_compare" do
      expect(validate_api_key_body).to include("OpenSSL.fixed_length_secure_compare(provided, expected)")
      expect(validate_api_key_body).not_to match(/provided\s*==\s*expected/)
    end

    it "validate_api_key gates on length before the byte compare" do
      expect(validate_api_key_body).to include("provided.length != expected.length")
    end

    it "both the header and the Rack bearer_auth path route through validate_api_key" do
      # Exactly two call sites consult it (authenticate_request + bearer_auth).
      # The definition does not match (it takes `provided`, not `token`), and
      # COMMENT lines are stripped first, so prose naming validate_api_key can
      # never stand in for a real call.
      #
      # This used to scan /^\s*if validate_api_key\(token\)$/ — an anchored
      # leading-`if` STATEMENT. ADR-0021 rewrote authenticate_request's call site
      # into a trailing modifier-if (`return { "_auth" => "api_key" } if
      # validate_api_key(token)`), so the anchored form counted 1 and went red
      # against correct code. The invariant is "both paths route through
      # validate_api_key", not "both spell their `if` the same way".
      code = auth_src.lines.reject { |line| line.strip.start_with?("#") }.join
      call_sites = code.scan(/validate_api_key\(token\)/)
      expect(call_sites.length).to eq(2)
    end

    it "source uses no non-timing-safe `token == api_key` fast-path" do
      expect(auth_src).not_to include("token == api_key")
    end
  end

  # ────────────────────────────────────────────────────────────────
  # 2. No guessable hardcoded session secret
  # ────────────────────────────────────────────────────────────────
  describe "session.rb has no guessable hardcoded secret" do
    let(:session_src) do
      File.read(File.join(File.dirname(__FILE__), "..", "lib", "tina4", "session.rb"))
    end

    it "no longer contains the string 'tina4-default-secret'" do
      expect(session_src).not_to include("tina4-default-secret")
    end

    it "constructs sanely with TINA4_SECRET unset" do
      prev = ENV["TINA4_SECRET"]
      ENV.delete("TINA4_SECRET")
      tmp = Dir.mktmpdir("tina4_sess_secret")
      begin
        session = Tina4::Session.new(
          { "HTTP_COOKIE" => "" },
          { handler: :file, handler_options: { dir: tmp } }
        )
        expect(session).not_to be_nil
        expect(session.id).to match(/\A[0-9a-f]{64}\z/)
      ensure
        FileUtils.rm_rf(tmp)
        ENV["TINA4_SECRET"] = prev unless prev.nil?
      end
    end
  end

  # ────────────────────────────────────────────────────────────────
  # 3. Backend-failure policy: log-loud + degrade
  # ────────────────────────────────────────────────────────────────
  #
  # NO DOUBLES. This block used to run entirely on two in-test classes —
  # RaisingHandler (every op `raise "connection refused"`) and
  # EmptyHealthyHandler — plus six `expect(Tina4::Log).to receive(:error)`
  # message expectations. So the whole session-degradation policy had never
  # touched a real backend, and the "never silent" guarantee was verified by
  # counting messages to a replaced method.
  #
  # Replacements, all real:
  #   * unreachable backend  -> the REAL RedisHandler / ValkeyHandler /
  #     MemcachedHandler pointed at 127.0.0.1:6399, a genuinely CLOSED port.
  #     The error is therefore whatever the real client actually raises.
  #   * healthy backend      -> the REAL servers on 6379 / 6380 / 11211, read
  #     with a freshly generated session id so the empty read is genuinely
  #     empty rather than simulated.
  #   * "was it logged"      -> the REAL Tina4::Log writing a REAL file, then
  #     grepped (see spec/support/real_log_capture.rb).
  #
  # MEASURED while converting (2026-08-01, Ruby 4.0.2, this host):
  #   * The real error is Errno::ECONNREFUSED with message "Connection refused
  #     - connect(2) for 127.0.0.1:6399" (Redis/Valkey) or a RuntimeError
  #     "Memcached session backend at 127.0.0.1:6399 failed: ..." (Memcached) —
  #     NOT the RuntimeError("connection refused") the fake raised. The old
  #     strict-mode assertions matched /connection refused/ with a LOWERCASE c,
  #     which the real Redis/Valkey message does not contain. The fake's message
  #     was the only reason those assertions passed.
  #   * Session#gc returns early unless the handler responds to :gc
  #     (session.rb:252). The REAL RedisHandler and ValkeyHandler expose
  #     `cleanup`, NOT `gc`, so session.gc against them is a silent no-op that
  #     never reaches the backend. The old fake DID define gc, so the old "gc()
  #     on an unreachable backend logs" example exercised a handler shape that
  #     no real Redis/Valkey handler has. It was first re-pointed at
  #     MemcachedHandler, which exposes gc — but exposed a BROKEN one, and that
  #     bug (arity 0) was the only reason the example went green. The gc
  #     invariant is now proven against the REAL DatabaseHandler on a REAL
  #     SQLite database, the one handler whose gc genuinely reaches a backend
  #     that can genuinely fail. See #with_really_broken_session_table.
  describe "Session backend-failure policy" do
    # A port nothing listens on. Asserted below rather than assumed, so this
    # can never silently become "reachable" and turn the failure specs green.
    CLOSED_PORT = 6399

    # Real reachability probe. Any spec that needs a service SKIPS LOUDLY naming
    # host and port, with wording spec_helper.rb's TINA4_REQUIRE_SERVICES gate
    # recognises ("redis ... not reachable"), so a skip fails CI rather than
    # passing green.
    def self.port_open?(port)
      require "socket"
      Socket.tcp("127.0.0.1", port, connect_timeout: 1) { |s| s.close }
      true
    rescue StandardError
      false
    end

    def skip_unless_reachable(service, port)
      unless self.class.port_open?(port)
        skip "#{service} not reachable at 127.0.0.1:#{port} — start it or unset TINA4_REQUIRE_SERVICES"
      end
    end

    # The REAL handler classes, pointed at a real host/port.
    HANDLER_CLASSES = {
      redis: Tina4::SessionHandlers::RedisHandler,
      valkey: Tina4::SessionHandlers::ValkeyHandler,
      memcached: Tina4::SessionHandlers::MemcachedHandler
    }.freeze

    HEALTHY_PORTS = { redis: 6379, valkey: 6380, memcached: 11211 }.freeze

    # A real handler whose backend genuinely cannot be reached.
    def unreachable_handler(kind)
      if self.class.port_open?(CLOSED_PORT)
        skip "port #{CLOSED_PORT} is unexpectedly OPEN on 127.0.0.1 — " \
             "cannot prove unreachable-backend behaviour against a live listener"
      end
      HANDLER_CLASSES.fetch(kind).new(host: "127.0.0.1", port: CLOSED_PORT)
    end

    # A real handler talking to the real running server.
    def healthy_handler(kind)
      port = HEALTHY_PORTS.fetch(kind)
      skip_unless_reachable(kind.to_s, port)
      HANDLER_CLASSES.fetch(kind).new(host: "127.0.0.1", port: port)
    end

    let(:env) { { "HTTP_COOKIE" => "" } }

    # Build a REAL Tina4::Session and point it at the REAL handler under test.
    # Assigning @handler is state injection on the real object, not a double:
    # the handler is a genuine framework class talking to a genuine socket.
    def build_session(handler, strict: false)
      set_real_env("TINA4_SESSION_STRICT" => strict ? "true" : "false")
      session = Tina4::Session.new(env, { handler: :file, handler_options: {} })
      session.instance_variable_set(:@handler, handler)
      session.instance_variable_set(:@strict, strict)
      session
    end

    # The REAL error a REAL client raises against a REAL closed port, asserted by
    # its ROOT CAUSE instead of by one client's wrapper class.
    #
    # RedisHandler PREFERS the `redis` gem when it is installed and falls back to
    # the zero-dependency RespClient when it is not (redis_handler.rb#build_gem_client).
    # The two raise different classes for the very same closed port — measured on
    # this host, 2026-08-01, against 127.0.0.1:6399:
    #
    #   RespClient (raw socket) → Errno::ECONNREFUSED
    #                             "Connection refused - connect(2) for 127.0.0.1:6399"
    #   redis gem 5.4.1         → Redis::CannotConnectError
    #                             "Connection refused - connect(2) for 127.0.0.1:6399 (redis://…)"
    #                             cause → RedisClient::CannotConnectError
    #                             cause → Errno::ECONNREFUSED   ← the real one
    #
    # These examples were authored on a host where the OPTIONAL :databases
    # bundler group was absent, so ONLY the RespClient path was ever measured and
    # Errno::ECONNREFUSED got written down as if it were the contract. It is not:
    # whether an optional gem happens to be installed must never decide whether
    # the strict policy counts as honoured. So assert what IS the contract,
    # without relaxing it:
    #
    #   1. strict mode RE-RAISES (it does not degrade to {} / false),
    #   2. the failure is a genuine connection REFUSAL, not some other error, and
    #   3. its ROOT cause is a real Errno::ECONNREFUSED off a real socket.
    #
    # (3) is strictly STRONGER than the class assertion it replaces: an
    # in-process RuntimeError.new("Connection refused") would satisfy a bare
    # message match, but carries no ECONNREFUSED anywhere in its cause chain.
    def expect_real_connection_refusal
      raised = nil
      expect { yield }.to raise_error(StandardError) { |e| raised = e }

      chain = []
      err = raised
      while err && chain.length < 10
        chain << err
        err = err.cause
      end

      expect(raised.message).to match(/Connection refused/i)
      expect(chain.map(&:class)).to include(Errno::ECONNREFUSED),
                                   "strict mode must re-raise the REAL socket error; " \
                                   "cause chain was #{chain.map { |e| "#{e.class}: #{e.message}" }.inspect}"
    end

    # Invariant 1: unreachable backend on start() does NOT raise; returns a
    # session id, empty data, AND logs an error (never silent).
    %i[redis valkey memcached].each do |kind|
      it "start() on a really-unreachable #{kind} returns id + empty data and logs an error" do
        handler = unreachable_handler(kind)
        id = nil
        session = nil
        text = capture_real_log do
          session = build_session(handler)
          expect { id = session.start("some-id") }.not_to raise_error
        end

        expect(id).to be_a(String)
        expect(id.length).to be > 0
        expect(session.data).to eq({})
        # The REAL log line, formatted by the REAL logger, names the operation
        # and the concrete handler class (session.rb:300-301).
        expect(text).to match(/ERROR/i)
        expect(text).to include(HANDLER_CLASSES.fetch(kind).name)
      end
    end

    it "construction (load_session) on a really-unreachable redis degrades to {} and logs" do
      handler = unreachable_handler(:redis)
      session = nil
      text = capture_real_log do
        expect { session = build_session(handler) }.not_to raise_error
        expect(session.read("x")).to eq({})
      end
      expect(text).to match(/ERROR/i)
      expect(text).to include("RedisHandler")
    end

    # Invariant 2: save() on an unreachable backend returns false-y, retains
    # the dirty flag, logs an error, does not crash.
    it "save() on a really-unreachable redis returns false, retains dirty, logs, no crash" do
      handler = unreachable_handler(:redis)
      result = nil
      session = nil
      text = capture_real_log do
        session = build_session(handler)
        session["user"] = "Alice" # marks dirty
        expect { result = session.save }.not_to raise_error
      end

      expect(result).to be_falsey
      # dirty retained → a subsequent save still attempts the write (still false)
      expect(session.instance_variable_get(:@modified)).to be true
      expect(text).to match(/ERROR/i)
      expect(text).to include("RedisHandler")
    end

    # Invariant 3: destroy()/gc() on an unreachable backend log + do not crash.
    it "destroy() on a really-unreachable redis logs and does not crash" do
      handler = unreachable_handler(:redis)
      session = nil
      text = capture_real_log do
        session = build_session(handler)
        expect { session.destroy }.not_to raise_error
      end
      expect(session.data).to eq({})
      expect(text).to match(/ERROR/i)
      expect(text).to include("RedisHandler")
    end

    # A REAL DatabaseHandler on a REAL SQLite database whose session table has
    # been REALLY dropped out from under it, so #gc runs its genuine
    # "DELETE FROM tina4_session ..." against a real engine and gets a real
    # engine error back. Nothing is substituted: a real Database, a real file, a
    # real DDL statement, a real SQL failure. (An operator who drops the session
    # table gets exactly this.)
    #
    # WHY NOT MEMCACHED. These gc examples used to point at MemcachedHandler
    # "because it is the only one of the three real handlers that exposes #gc".
    # It exposed a BROKEN one: `alias gc cleanup` gave it arity 0 while Session
    # calls gc(max_lifetime), so every call raised ArgumentError — and THAT is
    # the only reason the old examples went green. They were observing an
    # internal arity bug, not a backend outage. With the arity fixed,
    # MemcachedHandler#gc is what it always meant to be: a purely local no-op
    # (memcached expires its own keys) that opens no socket and therefore cannot
    # fail. FileHandler#gc swallows per-file errors by design. DatabaseHandler is
    # the one handler whose gc genuinely reaches a backend that can genuinely
    # fail, so the invariant is proven there.
    def with_really_broken_session_table
      dir = Dir.mktmpdir("tina4-sess-gc-")
      db = Tina4::Database.new("sqlite:///#{File.join(dir, "sessions.db")}")
      handler = Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600)
      handler.write("seed", { "seeded" => true }, 3600) # the table really exists here
      db.execute("DROP TABLE #{Tina4::SessionHandlers::DatabaseHandler::TABLE_NAME}")
      yield handler
    ensure
      begin
        db&.close
      rescue StandardError
        nil
      end
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    end

    it "gc() on a really-broken database backend logs and does not crash" do
      with_really_broken_session_table do |handler|
        text = capture_real_log do
          session = build_session(handler)
          expect { session.gc(3600) }.not_to raise_error
        end
        expect(text).to match(/ERROR/i)
        expect(text).to include("DatabaseHandler")
        expect(text).to include("tina4_session")
      end
    end

    # The truthful memcached control, and the negative half of the arity fix.
    # MemcachedHandler#gc must ACCEPT the one argument Session#gc passes and must
    # stay a purely local no-op — so even against a genuinely CLOSED port it
    # neither raises nor logs, because there is no round trip to fail. Restore
    # `alias gc cleanup` and this goes red on the ArgumentError log line.
    it "gc() on memcached is a local no-op: no socket, no error, no log line" do
      handler = unreachable_handler(:memcached)
      expect(handler).to respond_to(:gc) # guard the premise
      text = capture_real_log do
        session = build_session(handler)
        expect { session.gc(3600) }.not_to raise_error
      end
      expect(text).not_to match(/\[ERROR/i)
      expect(text).not_to include("wrong number of arguments")
    end

    # Invariant 4: a genuinely EMPTY but HEALTHY backend logs ZERO errors.
    # Both halves are now real: a real running server, and a real log file that
    # must contain no ERROR line.
    # NOTE: the :memcached case of this example WAS failing, and was a TRUE
    # POSITIVE — same root cause as "strict mode re-raises a real gc failure"
    # below: session.gc(3600) raised ArgumentError inside MemcachedHandler
    # (`alias gc cleanup`, arity 0), which Session logged as an ERROR, so a
    # genuinely healthy memcached emitted an error line on every sweep. The
    # PRODUCTION code was fixed (MemcachedHandler#gc(_max_age = nil)); the
    # example is unchanged. Do not silence it by dropping the gc() call — that
    # would hide a broken GC path on a real backend.
    %i[redis valkey memcached].each do |kind|
      it "a really-healthy, genuinely-empty #{kind} logs NO errors" do
        require "securerandom"
        handler = healthy_handler(kind)
        fresh_id = "notest-#{SecureRandom.hex(16)}" # genuinely absent key

        session = nil
        saved = nil
        text = capture_real_log do
          session = build_session(handler)
          expect(session.start(fresh_id)).to be_a(String)
          # A real read of a key that really does not exist. Redis/Valkey return
          # nil here and Memcached returns {}; the framework normalises both to
          # {} — that normalisation is now genuinely exercised.
          expect(session.read("absent-#{SecureRandom.hex(8)}")).to eq({})
          session["k"] = "v"
          saved = session.save
          expect { session.destroy }.not_to raise_error
          expect { session.gc(3600) }.not_to raise_error
        end

        expect(saved).to be_truthy
        # The load-bearing negative: the REAL log file contains no ERROR line.
        expect(text).not_to match(/\[ERROR/i)
      end
    end

    # A real round-trip through the real server, proving the value genuinely
    # left this process — the gap the old EmptyHealthyHandler could never close
    # (it returned true from write without storing anything).
    %i[redis valkey memcached].each do |kind|
      it "#{kind} really persists: a second handler instance reads the written value back" do
        require "securerandom"
        writer = healthy_handler(kind)
        sid = "notest-#{SecureRandom.hex(16)}"
        writer.write(sid, { "user" => "Alice" })

        # A SEPARATE real client — proves the bytes crossed the socket.
        reader = HANDLER_CLASSES.fetch(kind).new(host: "127.0.0.1", port: HEALTHY_PORTS.fetch(kind))
        expect(reader.read(sid)).to eq({ "user" => "Alice" })
        reader.destroy(sid)
      end
    end

    # Invariant 5: with TINA4_SESSION_STRICT=true, read/write failures RE-RAISE.
    # The expected error is the REAL one the REAL client raises against the real
    # closed port — not a hand-written message.
    it "strict mode re-raises a real read failure" do
      session = build_session(unreachable_handler(:redis), strict: true)
      expect_real_connection_refusal { session.read("x") }
    end

    it "strict mode re-raises a real write failure" do
      session = build_session(unreachable_handler(:redis), strict: true)
      session["user"] = "Bob"
      expect_real_connection_refusal { session.save }
    end

    it "strict mode re-raises a real destroy failure" do
      session = build_session(unreachable_handler(:redis), strict: true)
      expect_real_connection_refusal { session.destroy }
    end

    # !! WAS FAILING — TRUE POSITIVE, NOT A BROKEN TEST. NOW FIXED IN THE CODE. !!
    #
    # REAL FRAMEWORK BUG found by the no-mock conversion, fixed 2026-08-01 in
    # lib/tina4/session_handlers/memcached_handler.rb:
    #
    #   Tina4::Session#gc calls @handler.gc(max_lifetime) with ONE argument
    #   (session.rb:254), but MemcachedHandler got #gc from `alias gc cleanup`
    #   and #cleanup takes ZERO arguments. Measured: MemcachedHandler#gc.arity
    #   == 0, and gc(3600) raised ArgumentError "wrong number of arguments
    #   (given 1, expected 0)" against the real memcached on 127.0.0.1:11211.
    #
    #   So session GC had NEVER worked on a Memcached session backend: every
    #   call raised, and Session#gc's rescue reported it as a BACKEND failure —
    #   "Session gc failed (…MemcachedHandler): wrong number of arguments" —
    #   misattributing an internal arity bug to the operator's memcached.
    #   FileHandler#gc(max_age = nil) and DatabaseHandler#gc(max_age) both take
    #   the argument, so Memcached was the odd one out. The fix gives it
    #   #gc(_max_age = nil) delegating to #cleanup.
    #
    #   The old RaisingHandler/EmptyHealthyHandler fakes both defined
    #   `gc(_ttl)` with one parameter — matching what Session CALLS rather than
    #   what the real handler ACCEPTS — which is precisely why this shipped.
    #
    # This example asserts the CORRECT behaviour (a real backend failure must
    # surface as the backend's own error). It must NEVER be "fixed" by asserting
    # ArgumentError, which would lock the arity bug back in.
    it "strict mode re-raises a real gc failure" do
      # The REAL DatabaseHandler against a REAL SQLite database whose session
      # table is really gone — the one handler whose gc genuinely reaches a
      # backend (see #with_really_broken_session_table). The engine is fixed and
      # ours here, so its own error text is the precise thing to assert.
      with_really_broken_session_table do |handler|
        session = build_session(handler, strict: true)
        expect { session.gc(3600) }.to raise_error(StandardError, /no such table: tina4_session/i)
      end
    end

    it "honours TINA4_SESSION_STRICT env (true) read from the constructor" do
      handler = unreachable_handler(:redis)
      set_real_env("TINA4_SESSION_STRICT" => "true")
      session = Tina4::Session.new(env, { handler: :file, handler_options: {} })
      session.instance_variable_set(:@handler, handler)
      expect_real_connection_refusal { session.read("x") }
    end
  end
end
