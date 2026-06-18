# frozen_string_literal: true

require "spec_helper"
require "openssl"

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
      expect(result).to eq({ "api_key" => true })
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
      expect(env["tina4.auth"]).to eq({ "api_key" => true })
    end

    it "rejects a wrong API key via the Rack bearer_auth path" do
      env = { "HTTP_AUTHORIZATION" => "Bearer not-the-key" }
      expect(Tina4::Auth.bearer_auth.call(env)).to be false
      expect(env["tina4.auth"]).to be_nil
    end

    it "routes authenticate_request through the timing-safe validate_api_key (not ==)" do
      # If the fast-path went through plain ==, validate_api_key would never
      # be consulted. Asserting the call proves the timing-safe routing.
      expect(Tina4::Auth).to receive(:validate_api_key)
        .with("super-secret-api-key-value").and_call_original
      Tina4::Auth.authenticate_request(
        { "HTTP_AUTHORIZATION" => "Bearer super-secret-api-key-value" }
      )
    end

    it "routes the Rack bearer_auth path through the timing-safe validate_api_key (not ==)" do
      expect(Tina4::Auth).to receive(:validate_api_key)
        .with("super-secret-api-key-value").and_call_original
      Tina4::Auth.bearer_auth.call(
        { "HTTP_AUTHORIZATION" => "Bearer super-secret-api-key-value" }
      )
    end

    it "validate_api_key itself uses OpenSSL.fixed_length_secure_compare" do
      expect(OpenSSL).to receive(:fixed_length_secure_compare)
        .with("abc", "abc").and_call_original
      expect(Tina4::Auth.validate_api_key("abc", expected: "abc")).to be true
    end

    it "source uses no non-timing-safe `token == api_key` fast-path" do
      src = File.read(File.join(File.dirname(__FILE__), "..", "lib", "tina4", "auth.rb"))
      expect(src).not_to include("token == api_key")
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
  describe "Session backend-failure policy" do
    # A handler that always raises on every backend operation — stands in for
    # an unreachable Redis/Valkey/Mongo.
    class RaisingHandler
      def read(_id);  raise "connection refused"; end
      def write(*);   raise "connection refused"; end
      def destroy(_id); raise "connection refused"; end
      def gc(_ttl);   raise "connection refused"; end
    end

    # A genuinely-empty but HEALTHY handler — returns nil/{} WITHOUT raising.
    class EmptyHealthyHandler
      def read(_id);   nil; end
      def write(*);    true; end
      def destroy(_id); true; end
      def gc(_ttl);    0; end
    end

    let(:env) { { "HTTP_COOKIE" => "" } }

    def build_session(handler, strict: false)
      prev_strict = ENV["TINA4_SESSION_STRICT"]
      ENV["TINA4_SESSION_STRICT"] = strict ? "true" : "false"
      session = Tina4::Session.new(env, { handler: :file, handler_options: {} })
      session.instance_variable_set(:@handler, handler)
      session.instance_variable_set(:@strict, strict)
      session
    ensure
      if prev_strict.nil?
        ENV.delete("TINA4_SESSION_STRICT")
      else
        ENV["TINA4_SESSION_STRICT"] = prev_strict
      end
    end

    # Invariant 1: unreachable backend on start() does NOT raise; returns a
    # session id, empty data, AND logs an error (never silent).
    it "start() on an unreachable backend returns id + empty data and logs an error" do
      expect(Tina4::Log).to receive(:error).at_least(:once)
      session = build_session(RaisingHandler.new)
      expect { @id = session.start("some-id") }.not_to raise_error
      expect(@id).to be_a(String)
      expect(@id.length).to be > 0
      expect(session.data).to eq({})
    end

    it "construction (load_session) on an unreachable backend degrades to {} and logs" do
      expect(Tina4::Log).to receive(:error).at_least(:once)
      session = nil
      expect { session = build_session(RaisingHandler.new) }.not_to raise_error
      # The constructor already ran load_session against the file handler; force
      # a re-read through the raising handler to prove the boundary degrades.
      expect(session.read("x")).to eq({})
    end

    # Invariant 2: save() on an unreachable backend returns false-y, retains
    # the dirty flag, logs an error, does not crash.
    it "save() on an unreachable backend returns false, retains dirty, logs, no crash" do
      expect(Tina4::Log).to receive(:error).at_least(:once)
      session = build_session(RaisingHandler.new)
      session["user"] = "Alice" # marks dirty
      result = nil
      expect { result = session.save }.not_to raise_error
      expect(result).to be_falsey
      # dirty retained → a subsequent save still attempts the write (still false)
      expect(session.instance_variable_get(:@modified)).to be true
    end

    # Invariant 3: destroy()/gc() on an unreachable backend log + do not crash.
    it "destroy() on an unreachable backend logs and does not crash" do
      expect(Tina4::Log).to receive(:error).at_least(:once)
      session = build_session(RaisingHandler.new)
      expect { session.destroy }.not_to raise_error
      expect(session.data).to eq({})
    end

    it "gc() on an unreachable backend logs and does not crash" do
      expect(Tina4::Log).to receive(:error).at_least(:once)
      session = build_session(RaisingHandler.new)
      expect { session.gc(3600) }.not_to raise_error
    end

    # Invariant 4: a genuinely EMPTY but HEALTHY backend logs ZERO errors.
    it "an empty-but-healthy backend (read returns {} without raising) logs NO errors" do
      expect(Tina4::Log).not_to receive(:error)
      session = build_session(EmptyHealthyHandler.new)
      expect(session.start("fresh-id")).to be_a(String)
      expect(session.read("anything")).to eq({})
      # a write/destroy/gc against the healthy backend also logs nothing
      session["k"] = "v"
      expect(session.save).to be true
      expect { session.destroy }.not_to raise_error
      expect { session.gc(3600) }.not_to raise_error
    end

    # Invariant 5: with TINA4_SESSION_STRICT=true, read/write failures RE-RAISE.
    it "strict mode re-raises a read failure" do
      session = build_session(RaisingHandler.new, strict: true)
      expect { session.read("x") }.to raise_error(/connection refused/)
    end

    it "strict mode re-raises a write failure" do
      session = build_session(RaisingHandler.new, strict: true)
      session["user"] = "Bob"
      expect { session.save }.to raise_error(/connection refused/)
    end

    it "strict mode re-raises a destroy failure" do
      session = build_session(RaisingHandler.new, strict: true)
      expect { session.destroy }.to raise_error(/connection refused/)
    end

    it "strict mode re-raises a gc failure" do
      session = build_session(RaisingHandler.new, strict: true)
      expect { session.gc(3600) }.to raise_error(/connection refused/)
    end

    it "honours TINA4_SESSION_STRICT env (true) read from the constructor" do
      prev = ENV["TINA4_SESSION_STRICT"]
      ENV["TINA4_SESSION_STRICT"] = "true"
      begin
        session = Tina4::Session.new(env, { handler: :file, handler_options: {} })
        session.instance_variable_set(:@handler, RaisingHandler.new)
        expect { session.read("x") }.to raise_error(/connection refused/)
      ensure
        if prev.nil?
          ENV.delete("TINA4_SESSION_STRICT")
        else
          ENV["TINA4_SESSION_STRICT"] = prev
        end
      end
    end
  end
end
