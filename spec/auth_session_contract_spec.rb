# frozen_string_literal: true

require "spec_helper"
require "base64"
require "fileutils"
require "json"
require "openssl"
require "stringio"
require "tmpdir"
require "digest"

# Regression specs for the feature 41/42 auth + session contract (ADR-0021).
#
# Each example is named for the behaviour it pins and carries a positive AND a
# negative half, so reverting a fix reproduces the original bug rather than
# silently passing. The example names are IDENTICAL in all four frameworks
# (tina4-python/tests/test_auth_session_contract.py,
# tina4-php/tests/AuthSessionContractTest.php,
# tina4-nodejs/test/authSessionContract.test.ts).
#
# No doubles anywhere: real Tina4::Auth against real OpenSSL HMAC digests, real
# Tina4::Session against a real filesystem in a real Dir.mktmpdir, and the real
# Tina4::RackApp.enforce_route_auth gate over a real Tina4::Route.
RSpec.describe "Auth + session contract" do
  let(:secret) { "auth-session-contract-secret" }
  let(:tmp_dir) { Dir.mktmpdir("tina4_auth_session_contract") }

  # Pin the process into HMAC mode for every example: a real TINA4_SECRET and a
  # .keys directory that does not exist, so use_hmac? is deterministically true
  # under the randomized spec order and no RSA path (or key generation) is ever
  # reached. Every value is restored afterwards.
  before(:each) do
    @previous_secret  = ENV["TINA4_SECRET"]
    @previous_api_key = ENV["TINA4_API_KEY"]
    @previous_keys_dir = Tina4::Auth.instance_variable_get(:@keys_dir)
    ENV["TINA4_SECRET"] = secret
    ENV.delete("TINA4_API_KEY")
    Tina4::Auth.instance_variable_set(:@keys_dir, File.join(tmp_dir, ".keys"))
  end

  after(:each) do
    Tina4::Auth.instance_variable_set(:@keys_dir, @previous_keys_dir)
    if @previous_secret.nil? then ENV.delete("TINA4_SECRET") else ENV["TINA4_SECRET"] = @previous_secret end
    if @previous_api_key.nil? then ENV.delete("TINA4_API_KEY") else ENV["TINA4_API_KEY"] = @previous_api_key end
    FileUtils.rm_rf(tmp_dir)
  end

  # Mint a token with arbitrary claims, correctly signed with a REAL HMAC.
  # The signature is genuine, so every example below isolates the CLAIM check
  # under test rather than accidentally passing because the signature failed.
  def forge(claims, signing_secret)
    header  = Base64.urlsafe_encode64(JSON.generate({ "alg" => "HS256", "typ" => "JWT" }), padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    signing_input = "#{header}.#{payload}"
    signature = Base64.urlsafe_encode64(
      OpenSSL::HMAC.digest(OpenSSL::Digest::SHA256.new, signing_secret, signing_input),
      padding: false
    )
    "#{signing_input}.#{signature}"
  end

  def file_session(dir, cookie_id = nil)
    env = cookie_id.nil? ? {} : { "HTTP_COOKIE" => "#{Tina4::Session.cookie_name}=#{cookie_id}" }
    Tina4::Session.new(env, { handler: :file, handler_options: { dir: dir } })
  end

  # ── 42: a session id is opaque and can never be a filesystem path ──

  it "session id from cookie cannot escape the session directory" do
    sessions = File.join(tmp_dir, "data", "sessions")
    outside  = File.join(tmp_dir, "outside")
    FileUtils.mkdir_p(sessions)
    FileUtils.mkdir_p(outside)

    hostile = "../../outside/pwned"

    # The constructor path is the one the LIVE SERVER uses: the id arrives on
    # the session cookie, which the client fully controls.
    from_cookie = file_session(sessions, hostile)
    from_cookie.set("owned", "yes")
    from_cookie.save

    # ...and the explicit start() path.
    started = file_session(sessions)
    adopted = started.start(hostile)
    started.set("owned", "yes")
    started.save

    expect(File.exist?(File.join(outside, "pwned.json"))).to be(false),
      "session cookie escaped the session directory - arbitrary file write"
    expect(Dir.glob(File.join(outside, "**", "*"))).to be_empty,
      "something was written outside the session directory"
    expect(adopted).not_to eq(hostile), "a traversal session id was adopted verbatim"
    expect(from_cookie.id).not_to eq(hostile),
      "a traversal session id from the cookie was adopted verbatim"

    # Positive half: a legitimate session in the same directory still round-trips.
    good = file_session(sessions)
    good_id = good.start
    good.set("k", "v")
    good.save

    resumed = file_session(sessions)
    resumed.start(good_id)
    expect(resumed.get("k")).to eq("v")
  end

  it "session id with path separator is rejected and a fresh id minted" do
    hostile_ids = [
      "../../outside/pwned",
      "a/b",
      "a\\b",
      "a.b",
      "..",
      "",
      # Ruby-specific: an anchor of ^...$ instead of \A...\z would accept this,
      # because ^/$ match LINE boundaries and the first line looks legitimate.
      "valid_looking_id_1234\n../../etc/passwd"
    ]

    # Pin the ALPHABET (and the \A..\z anchors) on the validator DIRECTLY, not
    # only through adoption. Strict mode would discard every id below anyway
    # simply because the store has never seen it, so without these assertions the
    # validator could be deleted outright and every adoption check here would
    # still pass.
    (hostile_ids + ["a" * 129]).each do |bad|
      expect(Tina4::Session.valid_session_id?(bad)).to be(false),
        "valid_session_id? accepted #{bad.inspect}"
    end

    # Positive half of the validator: the opaque alphabet passes at ANY length
    # from 1 to 128. There is deliberately no entropy floor - a short id is a
    # trusted caller's own programmatic id, and unguessability comes from the
    # framework minting the id, never from inspecting one an app passed on
    # purpose. The alphabet was always the vulnerability, never the length.
    ["a", "short", "my-session-id", "0123456789abcdef0123456789abcdef", "a" * 128].each do |good|
      expect(Tina4::Session.valid_session_id?(good)).to be(true),
        "valid_session_id? rejected a legitimate id #{good.inspect}"
    end

    # Validation is defence in depth BEHIND strict mode, and it has to be: a
    # record already sitting in the backend under a malformed id (written by an
    # older Tina4 whose file handler sanitised instead of rejecting, or by the
    # raw Session#write passthrough) would otherwise satisfy strict mode's
    # "the store knows this id" test and be adopted. Seeded through the REAL
    # handler, so the store genuinely holds it.
    legacy = "../../outside/pwned"
    Tina4::SessionHandlers::FileHandler.new(dir: tmp_dir).write(legacy, { "owner" => "attacker" })
    planted = file_session(tmp_dir, legacy)
    expect(planted.id).not_to eq(legacy),
      "a malformed id already present in the backend was adopted - validation is not enforced"
    expect(planted.get("owner")).to be_nil,
      "a session stored under a malformed id was served to the client"

    hostile_ids.each do |hostile|
      session = file_session(tmp_dir)
      adopted = session.start(hostile)
      expect(adopted).not_to eq(hostile), "hostile session id adopted verbatim: #{hostile.inspect}"
      expect(Tina4::Session.valid_session_id?(adopted)).to be(true),
        "replacement id is itself invalid for input #{hostile.inspect}"

      # The constructor (cookie) path must discard it too - that is the path the
      # live server takes, and adopting an attacker-planted cookie id is session
      # fixation: the id survives the victim's login.
      from_cookie = file_session(tmp_dir, hostile)
      expect(from_cookie.id).not_to eq(hostile),
        "hostile cookie session id adopted verbatim: #{hostile.inspect}"
      expect(Tina4::Session.valid_session_id?(from_cookie.id)).to be(true),
        "replacement cookie id is itself invalid for input #{hostile.inspect}"
    end

  end

  it "session ids differing only in stripped characters do not share a session" do
    # Asserted at the HANDLER, deliberately: Session-level validation already
    # rejects both of these, so only a direct handler test can pin the reason
    # they cannot collide. The old session_path did
    # gsub(/[^a-zA-Z0-9_-]/, "") - traversal-safe but LOSSY, so "a/b" and "ab"
    # became the same file and one session's data surfaced in another's.
    handler = Tina4::SessionHandlers::FileHandler.new(dir: tmp_dir)
    collide_a = "#{'a' * 20}/b"
    collide_b = "#{'a' * 20}b"
    expect(collide_a.gsub(/[^a-zA-Z0-9_-]/, "")).to eq(collide_b),
      "fixture no longer exercises the sanitiser collision"

    handler.write(collide_a, { "who" => "a" })
    handler.write(collide_b, { "who" => "b" })

    expect(handler.read(collide_a)).to eq({ "who" => "a" }),
      "two distinct session ids collapsed onto one session file - cross-session data leak"
    expect(handler.read(collide_b)).to eq({ "who" => "b" }),
      "two distinct session ids collapsed onto one session file - cross-session data leak"
    expect(Dir.glob(File.join(tmp_dir, "sess_*.json")).length).to eq(2),
      "two distinct session ids shared ONE file on disk"

    # Positive half: the id is still never a path component, and a normal id
    # round-trips through the same handler.
    handler.write("../../outside/pwned", { "hack" => true })
    expect(Dir.glob(File.join(tmp_dir, "**", "*.json")).all? { |f| File.dirname(f) == tmp_dir }).to be(true),
      "a session id escaped the session directory"
    handler.write("0123456789abcdef0123456789abcdef", { "ok" => true })
    expect(handler.read("0123456789abcdef0123456789abcdef")).to eq({ "ok" => true })
  end

  it "well formed but unknown session id is not adopted" do
    # OWASP strict session mode (PHP's session.use_strict_mode=1): a WELL-FORMED
    # id the store has never seen is still attacker-chosen, so it must not be
    # adopted - otherwise an attacker plants a valid-looking cookie, the victim
    # logs in under it, and the attacker already holds the session id.
    unknown = "unknown0123456789abcdef0123456789"
    expect(Tina4::Session.valid_session_id?(unknown)).to be(true), "fixture must be well-formed"

    from_cookie = file_session(tmp_dir, unknown)
    expect(from_cookie.id).not_to eq(unknown),
      "an unknown (attacker-planted) cookie session id was adopted - session fixation"
    expect(Tina4::Session.valid_session_id?(from_cookie.id)).to be(true)

    started = file_session(tmp_dir)
    expect(started.start(unknown)).not_to eq(unknown),
      "start() adopted an unknown session id - session fixation"

    # Positive half: an id the store DOES know resumes unchanged, with its data.
    writer = file_session(tmp_dir)
    known = writer.start
    writer.set("owner", "victim")
    writer.save

    resumed_cookie = file_session(tmp_dir, known)
    expect(resumed_cookie.id).to eq(known), "a KNOWN session id was not resumed"
    expect(resumed_cookie.get("owner")).to eq("victim")

    resumed_start = file_session(tmp_dir)
    expect(resumed_start.start(known)).to eq(known), "start() did not resume a KNOWN session id"
    expect(resumed_start.get("owner")).to eq("victim")

    # A backend OUTAGE must not be read as "unknown id". If it were, one blip
    # would rotate every id and log the entire userbase out. Triggered for REAL
    # (no doubles): a directory where the session file belongs makes File.read
    # raise Errno::EISDIR, deterministically and regardless of uid.
    outage_dir = File.join(tmp_dir, "outage")
    FileUtils.mkdir_p(outage_dir)
    outage_id = "outage0123456789abcdef0123456789"
    FileUtils.mkdir_p(
      File.join(outage_dir, "sess_#{Digest::SHA256.hexdigest(outage_id)}.json")
    )
    expect { Tina4::SessionHandlers::FileHandler.new(dir: outage_dir).read(outage_id) }
      .to raise_error(StandardError), "fixture no longer produces a REAL backend read failure"

    during_outage = file_session(outage_dir, outage_id)
    expect(during_outage.id).to eq(outage_id),
      "a backend outage rotated the session id - one blip logs every user out"
    expect(during_outage.all).to eq({})
  end

  it "legitimate session round trips end to end" do
    # NEGATIVE CONTROL for the whole session half of this contract: a fix that
    # simply broke every session would pass every other example here. This one
    # fails if sessions stop working at all.
    writer = file_session(tmp_dir)
    id = writer.start
    writer.set("user_id", 42)
    writer.set("role", "admin")
    expect(writer.save).to be(true)

    # Resumed through the CONSTRUCTOR (cookie) path - what the live server does.
    resumed = file_session(tmp_dir, id)
    expect(resumed.id).to eq(id)
    expect(resumed.get("user_id")).to eq(42)
    expect(resumed.get("role")).to eq("admin")

    # ...and through the explicit start() path.
    restarted = file_session(tmp_dir)
    expect(restarted.start(id)).to eq(id)
    expect(restarted.get("user_id")).to eq(42)

    # A write on the resumed session is visible to the next read of the same id.
    resumed.set("role", "auditor")
    expect(resumed.save).to be(true)
    expect(file_session(tmp_dir, id).get("role")).to eq("auditor")

    # Negative half: destroying it makes the id unknown again, so it is no longer
    # adopted and the data is gone.
    resumed.destroy
    after_destroy = file_session(tmp_dir, id)
    expect(after_destroy.get("user_id")).to be_nil
    expect(after_destroy.id).not_to eq(id), "a destroyed session id was still adopted"
  end

  it "valid generated session id is accepted unchanged" do
    session = file_session(tmp_dir)
    minted = session.start
    expect(Tina4::Session.valid_session_id?(minted)).to be(true)
    # Store it, so the id is one the backend KNOWS: under strict session mode an
    # id is adopted only when it is well-formed AND already in the store.
    session.set("k", "v")
    session.save

    resumed = file_session(tmp_dir)
    expect(resumed.start(minted)).to eq(minted), "a self-minted id was not resumed as-is"

    # The constructor mints a valid id too, and a valid KNOWN cookie id is
    # adopted UNCHANGED (the fix must not log every legitimate visitor out).
    constructed = file_session(tmp_dir)
    expect(Tina4::Session.valid_session_id?(constructed.id)).to be(true)
    from_cookie = file_session(tmp_dir, minted)
    expect(from_cookie.id).to eq(minted), "a valid cookie session id was not adopted"

    # ...and the data written under it is still readable, so this is non-breaking
    # for every session already in flight.
    expect(from_cookie.get("k")).to eq("v")

    # The id shapes the other three frameworks mint must also be accepted, so a
    # shared Redis/Mongo session store stays readable across the family.
    {
      "PHP/Node hex(16)"      => "0123456789abcdef0123456789abcdef",
      "Ruby hex(32)"          => "0" * 64,
      "Python token_urlsafe"  => "Ab-_9" * 8
    }.each do |shape, foreign|
      expect(Tina4::Session.valid_session_id?(foreign)).to be(true),
        "rejected a sibling id shape (#{shape}): #{foreign.inspect}"
    end

    # Negative half: a non-String and an over-long id are still rejected.
    expect(Tina4::Session.valid_session_id?(nil)).to be(false)
    expect(Tina4::Session.valid_session_id?(:symbol_id)).to be(false)
    expect(Tina4::Session.valid_session_id?("a" * 129)).to be(false)
  end

  # ── 41: RFC 7519 s4.1.4 - the token MUST NOT be accepted at or after exp ──

  it "jwt expired exactly at exp is rejected" do
    now = Time.now.to_i
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now }, secret))).to be_nil,
      "token accepted at exactly exp - RFC 7519 s4.1.4 requires now < exp"
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now - 1 }, secret))).to be_nil,
      "token accepted one second AFTER exp"

    # Positive half: strictly before exp is still valid.
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now + 60 }, secret))).not_to be_nil
  end

  it "jwt one second before exp is accepted" do
    now = Time.now.to_i
    payload = Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now + 2 }, secret))
    expect(payload).not_to be_nil, "a token two seconds from expiry was rejected"
    expect(payload["user_id"]).to eq(1)

    # Negative half: the same token one second past exp is not.
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now - 1 }, secret))).to be_nil
  end

  it "jwt non numeric exp is rejected not treated as no expiry" do
    now = Time.now.to_i

    # RFC 7519 s2 defines exp as a NumericDate. A PRESENT but malformed exp must
    # never read as "this token never expires" - Ruby's `payload["exp"] && ...`
    # skipped the check entirely when exp was nil/false.
    [nil, false, true, "not-a-number", "#{now + 600}", [], {}].each do |bad_exp|
      token = forge({ "user_id" => 1, "exp" => bad_exp }, secret)
      expect(Tina4::Auth.valid_token(token)).to be_nil,
        "token with exp=#{bad_exp.inspect} was accepted as non-expiring"
    end

    # Positive half: a numeric exp in the future is accepted, and NO exp key at
    # all stays unconstrained (non-breaking).
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now + 600 }, secret))).not_to be_nil
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1 }, secret))).not_to be_nil
  end

  it "jwt non numeric nbf is rejected not treated as unconstrained" do
    now = Time.now.to_i

    [nil, false, true, "not-a-number", "#{now - 600}", [], {}].each do |bad_nbf|
      claims = { "user_id" => 1, "exp" => now + 600, "nbf" => bad_nbf }
      expect(Tina4::Auth.valid_token(forge(claims, secret))).to be_nil,
        "token with nbf=#{bad_nbf.inspect} was accepted as unconstrained"
    end

    # Positive half: a numeric past nbf is accepted, NO nbf at all stays
    # unconstrained, and a genuinely post-dated nbf is still rejected.
    expect(Tina4::Auth.valid_token(
      forge({ "user_id" => 1, "exp" => now + 600, "nbf" => now - 600 }, secret)
    )).not_to be_nil
    expect(Tina4::Auth.valid_token(forge({ "user_id" => 1, "exp" => now + 600 }, secret))).not_to be_nil
    expect(Tina4::Auth.valid_token(
      forge({ "user_id" => 1, "exp" => now + 6000, "nbf" => now + 3600 }, secret)
    )).to be_nil
  end

  # ── 41: authenticate_request authenticates, or returns nil ──

  it "basic authorization header is not an authenticated request" do
    credentials = Base64.strict_encode64("admin:whatever-i-like")
    expect(
      Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Basic #{credentials}" })
    ).to be_nil, "an unverified Basic header authenticated the request"
    expect(
      Tina4::Auth.bearer_auth.call({ "HTTP_AUTHORIZATION" => "Basic #{credentials}" })
    ).to be(false), "an unverified Basic header passed the Rack bearer_auth gate"

    # Positive half: a real Bearer JWT still authenticates.
    token = Tina4::Auth.get_token({ "user_id" => 7 })
    payload = Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })
    expect(payload).not_to be_nil
    expect(payload["user_id"]).to eq(7)
  end

  it "authenticate request api key payload shape is uniform" do
    ENV["TINA4_API_KEY"] = "contract-api-key-value"

    payload = Tina4::Auth.authenticate_request(
      { "HTTP_AUTHORIZATION" => "Bearer contract-api-key-value" }
    )
    expect(payload).to eq({ "_auth" => "api_key" }), "api_key payload shape drifted: #{payload.inspect}"

    # The Rack bearer_auth path carries the SAME shape.
    env = { "HTTP_AUTHORIZATION" => "Bearer contract-api-key-value" }
    expect(Tina4::Auth.bearer_auth.call(env)).to be(true)
    expect(env["tina4.auth"]).to eq({ "_auth" => "api_key" }),
      "bearer_auth api_key payload shape drifted: #{env['tina4.auth'].inspect}"

    # Negative half: a wrong key (and a wrong-LENGTH key) is not authenticated.
    expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer wrong-key" })).to be_nil
    expect(
      Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer contract-api-key-valuE" })
    ).to be_nil
    wrong_env = { "HTTP_AUTHORIZATION" => "Bearer wrong-key" }
    expect(Tina4::Auth.bearer_auth.call(wrong_env)).to be(false)
    expect(wrong_env["tina4.auth"]).to be_nil

    # The JWT is checked FIRST (parity with Python/PHP/Node). Proven for real by
    # making the API key BE a valid JWT: an api-key-first implementation returns
    # the {"_auth" => "api_key"} shape, a JWT-first one returns the payload.
    token = Tina4::Auth.get_token({ "user_id" => 9 })
    ENV["TINA4_API_KEY"] = token
    jwt_first = Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })
    expect(jwt_first["user_id"]).to eq(9),
      "the API key was checked BEFORE the JWT - order drifted from Python/PHP/Node"
    order_env = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
    expect(Tina4::Auth.bearer_auth.call(order_env)).to be(true)
    expect(order_env["tina4.auth"]["user_id"]).to eq(9),
      "bearer_auth checked the API key BEFORE the JWT"
  end

  it "route gate api key comparison is timing safe" do
    # Asserting on the SOURCE of the gate is deliberate: a timing measurement is
    # inherently flaky, whereas "the gate routes through the timing-safe helper"
    # is exact and is the property under test. The method locates its own source
    # so this survives line-number drift.
    # Read as UTF-8 explicitly: the framework sources carry UTF-8 punctuation and
    # Encoding.default_external is US-ASCII under a locale-less shell, where a
    # plain readlines raises Encoding::CompatibilityError instead of asserting.
    gate_file, gate_line = Tina4::RackApp.method(:enforce_route_auth).source_location
    gate_source = +""
    File.readlines(gate_file, encoding: "UTF-8")[(gate_line - 1)..].each do |source_line|
      gate_source << source_line
      break if source_line.rstrip == "    end"
    end

    # Comment lines are stripped so the assertion is about CODE: the comment
    # explaining WHY the timing-unsafe `==` was removed necessarily quotes it.
    gate_code = gate_source.lines.reject { |source_line| source_line.strip.start_with?("#") }.join

    expect(gate_code).to include("validate_api_key"),
      "enforce_route_auth no longer routes the API key through validate_api_key"
    expect(gate_code).not_to include("token == api_key"),
      "enforce_route_auth still compares the API key with a timing-unsafe =="

    # Behavioural half, through the REAL gate over a REAL write route.
    ENV["TINA4_API_KEY"] = "gate-key-contract-value"
    route = Tina4::Route.new("POST", "/contract/gate", ->(_request, _response) { nil })
    expect(route.auth_required).to be(true), "a POST route is not secure by default"

    gate_env = lambda do |token|
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/contract/gate",
        "HTTP_AUTHORIZATION" => "Bearer #{token}",
        "rack.input" => StringIO.new("")
      }
    end

    allowed = gate_env.call("gate-key-contract-value")
    expect(Tina4::RackApp.enforce_route_auth(allowed, route)).to be_nil,
      "the correct API key did not pass the write-route gate"
    expect(allowed["tina4.auth_payload"]).to eq({ "_auth" => "api_key" }),
      "gate api_key payload shape drifted: #{allowed['tina4.auth_payload'].inspect}"

    # Negative half: a wrong key of the SAME length, and of a different length,
    # are both refused with a 401 (a different length must not raise, either).
    ["gate-key-contract-valuE", "gate-key-contract-value-longer", ""].each do |wrong|
      refused = gate_env.call(wrong)
      status, _headers, _body = Tina4::RackApp.enforce_route_auth(refused, route)
      expect(status).to eq(401), "the gate accepted a wrong API key: #{wrong.inspect}"
      expect(refused["tina4.auth_payload"]).to be_nil
    end

    # ...on the real timing-safe helper the gate now calls.
    expect(Tina4::Auth.validate_api_key("gate-key-contract-value")).to be(true)
    expect(Tina4::Auth.validate_api_key("gate-key-contract-valuE")).to be(false)
    expect(Tina4::Auth.validate_api_key("gate-key-contract-value-longer")).to be(false)
    expect(Tina4::Auth.validate_api_key("")).to be(false)
    expect(Tina4::Auth.validate_api_key(nil)).to be(false)
  end
end
