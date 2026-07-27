# frozen_string_literal: true

# Regression specs for the JWT algorithm/nbf cluster (the Ruby half of
# python#105/#106/#107). Ported from tina4-python's
# tests/test_auth_jwt_algorithm_nbf.py — the Python master is the reference.
#
# Each example is named for the behaviour it pins and carries a positive AND a
# negative case, so reverting the fix reproduces the original bug rather than
# silently passing. No doubles anywhere: real Tina4::Auth, real OpenSSL HMAC,
# real process ENV.
#
# Run: bundle exec rspec spec/auth_jwt_algorithm_nbf_spec.rb

require "spec_helper"
require "openssl"
require "base64"
require "json"
require "tmpdir"
require "fileutils"

# alg -> the OpenSSL digest NAME (named independently of the framework's own map,
# so the expectation is not derived from the code under test) and the digest size
# in bytes. Declared at file scope: Ruby forbids constant assignment inside a block.
JWT_CONTRACT_ALGORITHMS = {
  "HS256" => ["SHA256", 32],
  "HS384" => ["SHA384", 48],
  "HS512" => ["SHA512", 64]
}.freeze

RSpec.describe "Tina4::Auth JWT algorithm + nbf contract" do
  let(:secret) { "jwt-cluster-regression-secret" }
  let(:keys_dir) { Dir.mktmpdir("tina4_jwt_contract_no_rsa") }

  before(:each) do
    @previous_env = {
      "TINA4_SECRET" => ENV["TINA4_SECRET"],
      "TINA4_JWT_ALGORITHM" => ENV["TINA4_JWT_ALGORITHM"]
    }
    @previous_keys_dir = Tina4::Auth.instance_variable_get(:@keys_dir)

    ENV["TINA4_SECRET"] = secret
    ENV.delete("TINA4_JWT_ALGORITHM")
    # Point at an EMPTY keys dir so no RSA pems exist and use_hmac? is true —
    # the public get_token/valid_token then deterministically exercise the HMAC
    # path (a dev checkout can carry a real .keys/ in the repo root, which would
    # otherwise route these through the legacy RS256 branch).
    Tina4::Auth.instance_variable_set(:@keys_dir, keys_dir)
  end

  after(:each) do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Tina4::Auth.instance_variable_set(:@keys_dir, @previous_keys_dir)
    FileUtils.rm_rf(keys_dir)
  end

  # ── helpers: real decoding, no doubles ───────────────────────────

  def token_parts(token)
    header, payload, signature = token.split(".")
    [JSON.parse(Tina4::Auth.base64url_decode(header)),
     JSON.parse(Tina4::Auth.base64url_decode(payload)),
     signature]
  end

  def signing_input(token)
    token.split(".").first(2).join(".")
  end

  def base64url(bytes)
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  # ── the header must name the algorithm that actually signed (python#105) ──

  describe "header alg is the algorithm that actually signed" do
    JWT_CONTRACT_ALGORITHMS.each do |algorithm, (digest_name, _size)|
      it "POSITIVE: #{algorithm} signature equals an independently computed #{digest_name} HMAC" do
        # Before the fix, hmac_encode hardcoded a "HS256" header AND a SHA256
        # digest, so an HS512 request produced neither. This recomputes the HMAC
        # from scratch with OpenSSL, not through the framework's algorithm map.
        token = Tina4::Auth.hmac_encode({ "user_id" => 7 }, secret, algorithm: algorithm)
        header, _payload, signature = token_parts(token)

        expect(header["alg"]).to eq(algorithm)
        expected = base64url(OpenSSL::HMAC.digest(digest_name, secret, signing_input(token)))
        expect(signature).to eq(expected), "#{algorithm} header does not match the signing digest"
      end
    end

    JWT_CONTRACT_ALGORITHMS.each do |algorithm, (_digest_name, size)|
      it "NEGATIVE: #{algorithm} signature is #{size} bytes — the digest really varies with alg" do
        # Comparing an HS256 token's signature to an HS512 token's is NOT a valid
        # probe here: the header is part of the signing input, so the two differ
        # even when both are secretly signed with SHA256. The digest LENGTH cannot
        # lie — SHA256 is 32 bytes, SHA384 48, SHA512 64. Under the old hardcoded
        # SHA256 every token carried 32 bytes whatever alg it advertised.
        token = Tina4::Auth.hmac_encode({ "user_id" => 7 }, secret, algorithm: algorithm)
        raw = Tina4::Auth.base64url_decode(token.split(".")[2])
        expect(raw.bytesize).to eq(size)
      end
    end

    it "NEGATIVE: a forged header alg (none / a different HS / RS256) is rejected" do
      token = Tina4::Auth.hmac_encode({ "user_id" => 7 }, secret, algorithm: "HS256")
      _header, _payload, signature = token_parts(token)
      payload_segment = token.split(".")[1]

      %w[none HS384 HS512 RS256].each do |forged_algorithm|
        forged_header = base64url(JSON.generate({ "alg" => forged_algorithm, "typ" => "JWT" }))
        forged = "#{forged_header}.#{payload_segment}.#{signature}"
        expect(Tina4::Auth.hmac_decode(forged, secret, algorithm: "HS256"))
          .to be_nil, "forged alg #{forged_algorithm} was accepted"
      end

      # POSITIVE: the untampered token still validates.
      expect(Tina4::Auth.hmac_decode(token, secret, algorithm: "HS256")).not_to be_nil
    end

    it "NEGATIVE: a token signed with a different supported alg does not validate" do
      hs512_token = Tina4::Auth.hmac_encode({ "user_id" => 7 }, secret, algorithm: "HS512")

      expect(Tina4::Auth.hmac_decode(hs512_token, secret, algorithm: "HS256")).to be_nil
      expect(Tina4::Auth.hmac_decode(hs512_token, secret, algorithm: "HS512")).not_to be_nil
    end
  end

  # ── TINA4_JWT_ALGORITHM must actually be read (python#106) ──

  describe "algorithm resolution: explicit argument > TINA4_JWT_ALGORITHM > HS256" do
    it "POSITIVE: the env var is honoured when no explicit algorithm is given" do
      # It was registered in the CLI's known_vars and then never read here, so a
      # user could set HS512, see it listed as a known variable, and still get
      # HS256 tokens.
      ENV["TINA4_JWT_ALGORITHM"] = "HS512"

      expect(Tina4::Auth.resolve_algorithm).to eq("HS512")
      header, = token_parts(Tina4::Auth.get_token({ "user_id" => 1 }))
      expect(header["alg"]).to eq("HS512")
      expect(Tina4::Auth.base64url_decode(Tina4::Auth.get_token({ "user_id" => 1 }).split(".")[2]).bytesize)
        .to eq(64)
    end

    it "NEGATIVE for precedence: an explicit argument beats the env var" do
      ENV["TINA4_JWT_ALGORITHM"] = "HS512"

      expect(Tina4::Auth.resolve_algorithm("HS256")).to eq("HS256")
      header, = token_parts(Tina4::Auth.get_token({ "user_id" => 1 }, algorithm: "HS256"))
      expect(header["alg"]).to eq("HS256")
    end

    it "POSITIVE: defaults to HS256 when the env var is unset" do
      ENV.delete("TINA4_JWT_ALGORITHM")

      expect(Tina4::Auth.resolve_algorithm).to eq("HS256")
      header, = token_parts(Tina4::Auth.get_token({ "user_id" => 1 }))
      expect(header["alg"]).to eq("HS256")
    end

    it "POSITIVE: a blank env var is treated as unset, not as an unsupported alg" do
      ENV["TINA4_JWT_ALGORITHM"] = "   "
      expect(Tina4::Auth.resolve_algorithm).to eq("HS256")
    end

    it "NEGATIVE: an unsupported algorithm raises, naming the supported set" do
      # A silent downgrade to HS256 is the whole bug — it must fail loudly.
      expect { Tina4::Auth.resolve_algorithm("RS256") }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include("RS256")
        %w[HS256 HS384 HS512].each { |supported| expect(error.message).to include(supported) }
        expect(error.message).to include("TINA4_JWT_ALGORITHM")
      }
    end

    it "NEGATIVE: an unsupported env algorithm also raises, on signing and on verifying" do
      ENV["TINA4_JWT_ALGORITHM"] = "banana"

      expect { Tina4::Auth.get_token({ "user_id" => 1 }) }.to raise_error(ArgumentError, /banana/)
      expect { Tina4::Auth.hmac_decode("a.b.c", secret) }.to raise_error(ArgumentError, /banana/)
    end
  end

  # ── nbf (not-before) with clock-skew leeway (python#107) ──

  describe "nbf validation with #{Tina4::Auth::JWT_LEEWAY_SECONDS}s of leeway" do
    it "NEGATIVE: a post-dated token is rejected until its nbf passes" do
      future = Time.now.to_i + Tina4::Auth::JWT_LEEWAY_SECONDS + 600
      token = Tina4::Auth.get_token({ "user_id" => 1, "nbf" => future })

      expect(Tina4::Auth.valid_token(token)).to be_nil
    end

    it "POSITIVE: a token whose nbf has passed is accepted" do
      past = Time.now.to_i - 600
      payload = Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 1, "nbf" => past }))

      expect(payload).not_to be_nil
      expect(payload["user_id"]).to eq(1)
    end

    it "POSITIVE: an nbf inside the leeway still validates (clock skew tolerance)" do
      # The normal case for a token minted on a host a second or two ahead. With
      # no leeway (the old behaviour) this was rejected for nothing.
      slightly_ahead = Time.now.to_i + [1, Tina4::Auth::JWT_LEEWAY_SECONDS / 2].max
      payload = Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 1, "nbf" => slightly_ahead }))

      expect(payload).not_to be_nil
    end

    it "NEGATIVE: an nbf just outside the leeway is still rejected" do
      # Pins the boundary: the leeway is a small tolerance, not an amnesty.
      just_outside = Time.now.to_i + Tina4::Auth::JWT_LEEWAY_SECONDS + 30

      expect(Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 1, "nbf" => just_outside }))).to be_nil
    end

    it "POSITIVE: a token without nbf is unaffected" do
      token = Tina4::Auth.get_token({ "user_id" => 1 })

      expect(Tina4::Auth.get_payload(token)).not_to have_key("nbf")
      expect(Tina4::Auth.valid_token(token)).not_to be_nil
    end

    it "NEGATIVE: expiry is still enforced alongside nbf" do
      # expires_in: 0 keeps the caller's own exp, which is already in the past.
      expired = Tina4::Auth.get_token({ "user_id" => 1, "exp" => Time.now.to_i - 600 }, expires_in: 0)

      expect(Tina4::Auth.valid_token(expired)).to be_nil
    end
  end

  # ── get_token no longer auto-stamps nbf (deliberate breaking change) ──

  describe "get_token does not emit an nbf claim" do
    it "POSITIVE: minted claims carry iat and exp but no nbf" do
      _header, claims, = token_parts(Tina4::Auth.get_token({ "user_id" => 1 }))

      expect(claims).to have_key("iat")
      expect(claims).to have_key("exp")
      expect(claims).not_to have_key("nbf")
    end

    it "POSITIVE: the same holds for an explicit secret and every supported alg" do
      JWT_CONTRACT_ALGORITHMS.each_key do |algorithm|
        _header, claims, = token_parts(
          Tina4::Auth.get_token({ "user_id" => 1 }, secret: "an-explicit-secret", algorithm: algorithm)
        )
        expect(claims).not_to have_key("nbf"), "#{algorithm} auto-stamped nbf"
      end
    end

    it "NEGATIVE: a caller-supplied nbf is still carried through untouched" do
      # Removing the auto-stamp must not remove SUPPORT for nbf — RFC 7519 nbf is
      # for deliberately post-dated tokens, which is the caller's business.
      chosen = Time.now.to_i - 30
      _header, claims, = token_parts(Tina4::Auth.get_token({ "user_id" => 1, "nbf" => chosen }))

      expect(claims["nbf"]).to eq(chosen)
    end

    it "NEGATIVE: refresh_token preserves a caller-supplied nbf (it only re-stamps iat/exp)" do
      chosen = Time.now.to_i - 30
      original = Tina4::Auth.get_token({ "user_id" => 1, "nbf" => chosen })
      refreshed = Tina4::Auth.refresh_token(original)

      expect(refreshed).not_to be_nil
      claims = Tina4::Auth.get_payload(refreshed)
      expect(claims["nbf"]).to eq(chosen)
      expect(claims["iat"]).not_to be_nil
      expect(claims["exp"]).not_to be_nil
    end
  end

  # ── round trip + wrong secret, across every supported algorithm ──

  describe "sign/validate round trip per algorithm" do
    JWT_CONTRACT_ALGORITHMS.each_key do |algorithm|
      it "POSITIVE: #{algorithm} signs and validates through the public API" do
        ENV["TINA4_JWT_ALGORITHM"] = algorithm

        payload = Tina4::Auth.valid_token(Tina4::Auth.get_token({ "user_id" => 3, "role" => "admin" }))

        expect(payload).not_to be_nil
        expect(payload["user_id"]).to eq(3)
        expect(payload["role"]).to eq("admin")
      end

      it "NEGATIVE: #{algorithm} never validates under a different secret" do
        token = Tina4::Auth.hmac_encode({ "user_id" => 3 }, secret, algorithm: algorithm)

        expect(Tina4::Auth.hmac_decode(token, "not-the-secret", algorithm: algorithm)).to be_nil
      end
    end
  end
end
