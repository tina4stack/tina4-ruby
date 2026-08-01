# frozen_string_literal: true

# Regression specs for the RS256-opt-in / drop-the-jwt-gem ruling.
#
# Three things are pinned here:
#
#   1. HMAC (HS256/HS384/HS512) is the standard algorithm and is zero-dependency
#      — Ruby signs it with stdlib OpenSSL::HMAC.
#   2. RS256 is OPT-IN and ALSO zero-dependency in Ruby: OpenSSL is a stdlib
#      DEFAULT GEM, so OpenSSL::PKey::RSA#sign/#verify produce the real RFC 7515
#      RS256 signature. The `jwt` gem was dropped; nothing may re-introduce it.
#   3. Making RS256 opt-in must NOT open algorithm substitution. Under an HMAC
#      configuration a token whose header claims RS256 — INCLUDING a genuinely
#      RSA-signed one — is rejected, and alg:"none" stays rejected.
#
# No doubles anywhere: real Tina4::Auth, real OpenSSL, real RSA keys on disk,
# real process ENV. The signature expectations are recomputed independently with
# OpenSSL rather than read back out of the code under test.
#
# Run: bundle exec rspec spec/auth_rs256_optin_spec.rb

require "spec_helper"
require "openssl"
require "base64"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe "Tina4::Auth RS256 opt-in (no jwt gem)" do
  let(:secret) { "rs256-optin-regression-secret" }
  # A keys dir WITH real RSA pems (RS256 path) and one WITHOUT (HMAC path). The
  # branch is chosen by use_hmac?: a secret and no pems -> HMAC, else RS256.
  let(:rsa_keys_root) { Dir.mktmpdir("tina4_rs256_with_keys") }
  let(:empty_keys_dir) { Dir.mktmpdir("tina4_rs256_no_keys") }

  before(:each) do
    @previous_env = {
      "TINA4_SECRET" => ENV["TINA4_SECRET"],
      "TINA4_JWT_ALGORITHM" => ENV["TINA4_JWT_ALGORITHM"]
    }
    @previous_keys_dir = Tina4::Auth.instance_variable_get(:@keys_dir)
    @previous_private = Tina4::Auth.instance_variable_get(:@private_key)
    @previous_public = Tina4::Auth.instance_variable_get(:@public_key)
    ENV.delete("TINA4_JWT_ALGORITHM")
  end

  after(:each) do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Tina4::Auth.instance_variable_set(:@keys_dir, @previous_keys_dir)
    Tina4::Auth.instance_variable_set(:@private_key, @previous_private)
    Tina4::Auth.instance_variable_set(:@public_key, @previous_public)
    FileUtils.rm_rf(rsa_keys_root)
    FileUtils.rm_rf(empty_keys_dir)
  end

  # Configure the RS256 path: real RSA pems generated on disk, no secret.
  def configure_rs256!
    ENV.delete("TINA4_SECRET")
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(rsa_keys_root) # generates .keys/private.pem + public.pem
  end

  # Configure the HMAC path: a secret, and a keys dir with no pems in it.
  def configure_hmac!
    ENV["TINA4_SECRET"] = secret
    Tina4::Auth.instance_variable_set(:@keys_dir, empty_keys_dir)
  end

  def base64url(bytes)
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  def segments(token)
    token.split(".")
  end

  # ── RS256 is real, and it is stdlib OpenSSL ─────────────────────

  describe "RS256 is signed and verified with stdlib OpenSSL, not a gem" do
    it "POSITIVE: a get_token RS256 token verifies against an independently computed OpenSSL RSA verify" do
      configure_rs256!
      token = Tina4::Auth.get_token({ "user_id" => 42 })
      header, payload, signature = segments(token)

      expect(JSON.parse(Tina4::Auth.base64url_decode(header))["alg"]).to eq("RS256")

      # Recomputed from the PEM on disk with raw OpenSSL — never through the code
      # under test. If rs256_encode signed anything other than RSA-SHA256 over
      # "header.payload", this fails.
      public_key = OpenSSL::PKey::RSA.new(File.read(File.join(rsa_keys_root, ".keys", "public.pem")))
      verified = public_key.verify(OpenSSL::Digest::SHA256.new,
                                   Tina4::Auth.base64url_decode(signature),
                                   "#{header}.#{payload}")
      expect(verified).to be(true), "RS256 signature is not a raw RSA-SHA256 over the signing input"

      # ...and the framework agrees.
      expect(Tina4::Auth.valid_token(token)).to include("user_id" => 42)
      expect(Tina4::Auth.valid_token_detail(token)[:valid]).to be true
    end

    it "NEGATIVE: an RS256 token with a tampered payload is rejected" do
      configure_rs256!
      token = Tina4::Auth.get_token({ "user_id" => 42 })
      header, _payload, signature = segments(token)

      # Privilege escalation attempt: keep the real signature, swap the claims.
      forged_payload = base64url(JSON.generate({ "user_id" => 1, "exp" => Time.now.to_i + 999 }))
      forged = "#{header}.#{forged_payload}.#{signature}"

      expect(Tina4::Auth.valid_token(forged)).to be_nil
      expect(Tina4::Auth.valid_token_detail(forged)[:valid]).to be false
    end

    it "NEGATIVE: the jwt gem is never loaded by either token path" do
      # The whole point of the ruling: RS256 costs no third-party dependency in
      # Ruby. Exercising BOTH paths must leave the jwt gem out of the load path.
      configure_rs256!
      Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 1 }))
      configure_hmac!
      Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 1 }))

      loaded_jwt = $LOADED_FEATURES.grep(%r{/jwt(\.rb|/)})
      expect(loaded_jwt).to be_empty, "the jwt gem was loaded: #{loaded_jwt.inspect}"
    end
  end

  # ── algorithm substitution stays closed (the classic JWT attack) ──

  describe "algorithm pinning under an HMAC configuration" do
    # ── which examples here actually GATE the pin, measured ──
    #
    # Deleting the `alg` comparison in decode_envelope turns exactly the examples
    # below RED, and no others. The distinction is whether the signature covers
    # the LYING header:
    #
    #   * GATES the pin — the two "over a VALID signature" examples (they RE-SIGN
    #     over the lying header, so the HMAC genuinely verifies) and the
    #     "duplicate alg key" ones (the header bytes are untouched, so the
    #     original signature still verifies while the header PARSES differently).
    #   * does NOT gate the pin — the "re-labelled" example further down, which
    #     keeps a signature computed over the HONEST header. That is refused even
    #     with no pin at all, because rewriting the header breaks the signature.
    #     It is still worth keeping (it pins the OUTCOME a caller depends on),
    #     but it must not be mistaken for a gate.
    #
    # PHP and Python had only the second, non-gating shape until 2026-08-01;
    # deleting their pin left their suites green. Hence the duplicate-key
    # example, which gates the pin in all four.

    it "GATE NEGATIVE: a header claiming RS256 over a VALID HS256 signature is REJECTED" do
      configure_hmac!
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => Time.now.to_i + 999 }))
      lying_header = base64url(JSON.generate({ "alg" => "RS256", "typ" => "JWT" }))
      signing_input = "#{lying_header}.#{claims}"
      # A REAL, correct HS256 signature over the lying header — computed with raw
      # OpenSSL, so it is not derived from the code under test.
      signature = base64url(OpenSSL::HMAC.digest("SHA256", secret, signing_input))

      expect(Tina4::Auth.valid_token("#{signing_input}.#{signature}")).to be_nil,
                                                                         "a token advertising RS256 was accepted under an HMAC configuration"
      expect(Tina4::Auth.hmac_decode("#{signing_input}.#{signature}", secret, algorithm: "HS256")).to be_nil
    end

    # ── THE gate on the algorithm pin ──
    #
    # The header BYTES are identical between signing and verifying, so the
    # signature genuinely verifies — but the header carries `alg` TWICE, and
    # Ruby's JSON.parse (like PHP's json_decode, Python's json.loads and JS's
    # JSON.parse) takes the LAST duplicate key. The token therefore PARSES as the
    # smuggled algorithm while carrying a valid signature, and only a verifier
    # that compares the parsed alg against its OWN configuration rejects it.
    #
    # A real split-brain shape, not a synthetic one: a gateway that pre-validates
    # on the first `alg` and a backend that acts on the last see two different
    # tokens.
    [%w[HS256 none], %w[HS256 RS256], %w[HS512 HS256], %w[HS384 HS512]].each do |honest, smuggled|
      it "GATE NEGATIVE: a valid #{honest} signature whose header PARSES as #{smuggled} is REJECTED" do
        configure_hmac!
        ENV["TINA4_JWT_ALGORITHM"] = honest

        claims = base64url(JSON.generate({ "user_id" => 42, "exp" => 4_102_444_800 }))
        raw_header = %({"alg":"#{honest}","alg":"#{smuggled}","typ":"JWT"})
        header = base64url(raw_header)
        signing_input = "#{header}.#{claims}"
        signature = base64url(OpenSSL::HMAC.digest(honest.sub("HS", "SHA"), secret, signing_input))

        # CONTROL: the header really parses as the smuggled alg, so the rejection
        # below is the pin and not a malformed token.
        expect(JSON.parse(raw_header)["alg"]).to eq(smuggled)

        expect(Tina4::Auth.valid_token("#{signing_input}.#{signature}")).to be_nil,
                                                                           "a valid #{honest} token whose header parses as #{smuggled} was ACCEPTED - the algorithm pin is gone"
      end
    end

    it "GATE POSITIVE: the same construction with ONE honest alg IS accepted" do
      # Without this, a pin that rejected every duplicate-key header — or every
      # token — would look like success.
      configure_hmac!
      ENV["TINA4_JWT_ALGORITHM"] = "HS256"
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => 4_102_444_800 }))
      header = base64url(%({"alg":"HS256","typ":"JWT"}))
      signing_input = "#{header}.#{claims}"
      signature = base64url(OpenSSL::HMAC.digest("SHA256", secret, signing_input))

      expect(Tina4::Auth.valid_token("#{signing_input}.#{signature}")).to include("user_id" => 42)
    end

    it 'GATE NEGATIVE: a header claiming "none" over a VALID HS256 signature is REJECTED' do
      configure_hmac!
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => Time.now.to_i + 999 }))
      none_header = base64url(JSON.generate({ "alg" => "none", "typ" => "JWT" }))
      signing_input = "#{none_header}.#{claims}"
      signature = base64url(OpenSSL::HMAC.digest("SHA256", secret, signing_input))

      expect(Tina4::Auth.valid_token("#{signing_input}.#{signature}")).to be_nil,
                                                                         'a token advertising alg:"none" was accepted under an HMAC configuration'
    end

    it "GATE POSITIVE: the SAME signature with an honest HS256 header IS accepted" do
      # The negative control for the two gates above: identical construction,
      # only the advertised algorithm is truthful. Without this, a pin that
      # rejected everything would look like success.
      configure_hmac!
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => Time.now.to_i + 999 }))
      honest_header = base64url(JSON.generate({ "alg" => "HS256", "typ" => "JWT" }))
      signing_input = "#{honest_header}.#{claims}"
      signature = base64url(OpenSSL::HMAC.digest("SHA256", secret, signing_input))

      expect(Tina4::Auth.valid_token("#{signing_input}.#{signature}")).to include("user_id" => 42)
    end

    it "NEGATIVE: a GENUINELY RSA-SIGNED RS256 token is REJECTED when configured for HMAC" do
      # Not a forged header — a real RS256 token, minted by the real RS256 path
      # with a real RSA key. Under HMAC configuration it must not authenticate:
      # otherwise an attacker who knows the public key could mint tokens.
      configure_rs256!
      rs256_token = Tina4::Auth.get_token({ "user_id" => 42 })
      expect(Tina4::Auth.valid_token(rs256_token)).not_to be_nil # sanity: it IS valid as RS256

      configure_hmac!
      expect(Tina4::Auth.valid_token(rs256_token)).to be_nil,
                                                      "an RS256 token authenticated under an HMAC configuration"
      expect(Tina4::Auth.valid_token_detail(rs256_token)[:valid]).to be false
      expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{rs256_token}" })).to be_nil
    end

    it 'NEGATIVE: alg:"none" with an empty signature is REJECTED under HMAC' do
      configure_hmac!
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => Time.now.to_i + 999 }))
      none_header = base64url(JSON.generate({ "alg" => "none", "typ" => "JWT" }))

      ["#{none_header}.#{claims}.", "#{none_header}.#{claims}.#{base64url('')}"].each do |token|
        expect(Tina4::Auth.valid_token(token)).to be_nil, "alg:none was accepted (#{token.inspect})"
        expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })).to be_nil
      end
    end

    it 'NEGATIVE: a header re-labelled RS256 over an HMAC signature is REJECTED under HMAC' do
      configure_hmac!
      token = Tina4::Auth.get_token({ "user_id" => 42 })
      _header, payload, signature = segments(token)

      relabelled = "#{base64url(JSON.generate({ 'alg' => 'RS256', 'typ' => 'JWT' }))}.#{payload}.#{signature}"
      expect(Tina4::Auth.valid_token(relabelled)).to be_nil
    end

    it "POSITIVE: the untampered HMAC token still authenticates (the pin does not just reject everything)" do
      configure_hmac!
      token = Tina4::Auth.get_token({ "user_id" => 42 })

      expect(JSON.parse(Tina4::Auth.base64url_decode(segments(token)[0]))["alg"]).to eq("HS256")
      expect(Tina4::Auth.valid_token(token)).to include("user_id" => 42)
      expect(Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" }))
        .to include("user_id" => 42)
    end

    it 'NEGATIVE: alg:"none" is REJECTED on the RS256 path too' do
      configure_rs256!
      claims = base64url(JSON.generate({ "user_id" => 42, "exp" => Time.now.to_i + 999 }))
      none_header = base64url(JSON.generate({ "alg" => "none", "typ" => "JWT" }))

      expect(Tina4::Auth.valid_token("#{none_header}.#{claims}.")).to be_nil
    end
  end

  # ── the cross-framework wire contract ──────────────────────────

  describe "the cross-framework JWT contract fixture" do
    # spec/fixtures/jwt_cross_framework.json is a byte-identical copy of the file
    # in tina4-nodejs, tina4-python and tina4-php (same convention as
    # adapter_contract.json). The tokens were minted by tina4-nodejs with
    # node:crypto; nothing here re-implements JWT, so agreement is real interop
    # rather than two copies of the same bug.
    let(:fixture_path) { File.join(__dir__, "fixtures", "jwt_cross_framework.json") }
    let(:fixture) { JSON.parse(File.read(fixture_path)) }

    # Ruby picks RS256 by key presence, so an RS256 entry is verified by writing
    # the fixture's PUBLIC pem into a keys dir - the framework's own switch.
    def verify(entry)
      key = fixture.fetch(entry["key"])
      if entry["algorithm"] == "RS256"
        dir = Dir.mktmpdir("tina4_fixture_keys")
        File.write(File.join(dir, "private.pem"), key)
        File.write(File.join(dir, "public.pem"), key)
        ENV.delete("TINA4_SECRET")
        Tina4::Auth.instance_variable_set(:@keys_dir, dir)
        Tina4::Auth.instance_variable_set(:@private_key, nil)
        Tina4::Auth.instance_variable_set(:@public_key, nil)
      else
        ENV["TINA4_SECRET"] = key
        ENV["TINA4_JWT_ALGORITHM"] = entry["algorithm"]
        Tina4::Auth.instance_variable_set(:@keys_dir, empty_keys_dir)
      end
      Tina4::Auth.valid_token(entry["token"])
    end

    it "POSITIVE: every accept entry validates and yields the expected claims" do
      # CONTROL: the fixture really was read and really carries both halves.
      expect(fixture["accept"].length).to be >= 4
      expect(fixture["reject"].length).to be >= 10
      expect(fixture["wrongSecret"]).not_to eq(fixture["hmacSecret"])
      expect(File.read(fixture_path)).not_to include("PRIVATE KEY")

      fixture["accept"].each do |entry|
        payload = verify(entry)
        expect(payload).not_to be_nil, "fixture accept rejected: #{entry['name']}"
        expect(payload).to eq(fixture["expectedPayload"]), "claims differ: #{entry['name']}"
      end
    end

    it "NEGATIVE: every reject entry is refused" do
      fixture["reject"].each do |entry|
        expect(verify(entry)).to be_nil, "fixture reject ACCEPTED: #{entry['name']}"
      end
    end
  end

  # ── the availability contract (shape parity with the other frameworks) ──

  describe "RS256 availability" do
    it "POSITIVE: RS256 is available on this Ruby, because OpenSSL is a stdlib default gem" do
      # Ruby is NOT like Python here. Python needs a third-party library for
      # asymmetric crypto; Ruby ships it. So this must be true on any normal
      # build, and the framework must never tell a user to install anything.
      expect(defined?(OpenSSL::PKey::RSA)).to eq("constant")
      expect(Tina4::Auth.rs256_available?).to be true
    end

    it "the unavailable message names the real remedy and never suggests installing a library" do
      message = Tina4::Auth::RS256_UNAVAILABLE_MESSAGE

      # Loud and actionable: says what is missing and how to get it.
      expect(message).to include("RS256 is unavailable")
      expect(message).to include("OpenSSL::PKey::RSA")
      expect(message).to include("rebuild Ruby with OpenSSL support")
      # ...and it must NOT send the user after a gem they do not need.
      expect(message).to match(/Do NOT install a JWT gem/i)
      expect(message).not_to match(/gem install|bundle add|add_dependency/i)
    end
  end
end
