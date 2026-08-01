# frozen_string_literal: true
require "openssl"
require "base64"
require "json"
require "fileutils"
require "securerandom"

module Tina4
  module Auth
    KEYS_DIR = ".keys"

    # Single source of truth for the blank-secret warning, emitted identically
    # from both the CI/prod boot path (ensure_dev_secret) and the lazy
    # per-call resolver (hmac_secret). Actionable: names exactly what to set.
    BLANK_SECRET_WARNING =
      "Auth: TINA4_SECRET is not set — JWT signing is insecure. Set TINA4_SECRET " \
      "to a random value (e.g. `openssl rand -hex 32`) in your environment or " \
      ".env before serving traffic. " \
      "For LOCAL DEV, set TINA4_DEBUG=true and a per-machine secret is generated " \
      "automatically into .env.local (gitignored). Seeing this warning means the " \
      "run was NOT detected as dev - typically a container or CI without " \
      "TINA4_DEBUG set, or TINA4_ENV=production."

    # Supported JWT algorithms. HMAC only — the whole family ships in OpenSSL, so
    # this stays zero-gem. The header's "alg" is now always the one we actually
    # sign with: the digest is looked up here rather than hardcoded to SHA256.
    # Mirrors the Python master's _HMAC_ALGORITHMS (a name -> digest map); the
    # value is the digest CLASS and a fresh instance is made per signature, so
    # nothing about the digest state is shared between calls or threads.
    HMAC_ALGORITHMS = {
      "HS256" => OpenSSL::Digest::SHA256,
      "HS384" => OpenSSL::Digest::SHA384,
      "HS512" => OpenSSL::Digest::SHA512
    }.freeze

    # RS256 (RSA-SHA256) is the OPT-IN asymmetric algorithm, and Ruby needs NO gem
    # for it: OpenSSL is a stdlib DEFAULT GEM, so OpenSSL::PKey::RSA#sign/#verify
    # emit and check exactly the RFC 7515 signature the other frameworks do
    # (measured: a token minted here verifies under PHP openssl_verify AND Node
    # crypto.createVerify, and a tampered payload goes INVALID in both). The `jwt`
    # gem was declared only to wrap the base64url envelope this file already
    # builds for HMAC, so it was dropped.
    #
    # The contract requires a LOUD, ACTIONABLE failure wherever RS256 is
    # unavailable. In Ruby that branch is UNREACHABLE in practice: the
    # `require "openssl"` at the top of this file is what supplies OpenSSL::HMAC
    # for the HMAC path too, so an interpreter lacking it cannot load Tina4 at
    # all. The message therefore names the real remedy and deliberately does NOT
    # suggest installing a library — there is none to install.
    RS256_UNAVAILABLE_MESSAGE =
      "RS256 is unavailable: this Ruby has no OpenSSL::PKey::RSA. OpenSSL is a " \
      "Ruby stdlib DEFAULT GEM, so this interpreter was built without the openssl " \
      "extension — rebuild Ruby with OpenSSL support, or use a build that ships " \
      "it. Do NOT install a JWT gem: Tina4 signs and verifies RS256 with stdlib " \
      "OpenSSL and needs no third-party library. Tina4's standard algorithms are " \
      "HS256/HS384/HS512, which are stdlib OpenSSL too."

    # Seconds of clock skew tolerated on the "nbf" (not-before) claim. Without
    # this a token minted on one host and validated on another a second behind is
    # rejected for no real reason; RFC 7519 explicitly allows "a small leeway".
    JWT_LEEWAY_SECONDS = 60

    class << self
      def setup(root_dir = Dir.pwd)
        @keys_dir = File.join(root_dir, KEYS_DIR)
        FileUtils.mkdir_p(@keys_dir)
        ensure_keys
      end

      # Boot-time bootstrap (run once after env load, before auth is used).
      #
      # Mirrors the Python master's tina4_python.auth.ensure_dev_secret:
      #   - If TINA4_SECRET is already set → no-op (returns nil).
      #   - Else if NOT dev, OR CI, OR production → emit the actionable
      #     blank-secret warning and return nil. NEVER generates or persists a
      #     secret in CI or production. (Hard security constraint.)
      #   - Else (dev, not CI, not prod, blank secret) → mint a 32-byte
      #     (64 hex char) random secret, set it in the process env immediately,
      #     then APPEND it to <root_dir>/.env.local (gitignored, created if
      #     missing). On ANY write failure keep the in-memory secret and warn —
      #     never raise (boot must not crash).
      #
      # `root_dir` exists only so tests can target a temp dir without chdir;
      # production callers pass nothing (defaults to Dir.pwd).
      #
      # Returns the generated secret (String) when it mints one, else nil.
      def ensure_dev_secret(root_dir = Dir.pwd)
        existing = ENV["TINA4_SECRET"]
        return nil if existing && !existing.empty?

        unless dev? && !ci? && !production?
          warn_blank_secret
          return nil
        end

        new_secret = SecureRandom.hex(32) # 32 bytes -> 64 hex chars
        ENV["TINA4_SECRET"] = new_secret  # available for this run immediately

        begin
          local_path = File.join(root_dir, ".env.local")
          # If the file exists and does not end in a newline, prepend one so the
          # new key lands on its own line rather than gluing onto the last value.
          prefix = ""
          if File.exist?(local_path)
            content = File.read(local_path)
            prefix = "\n" if !content.empty? && !content.end_with?("\n")
          end
          File.open(local_path, "a") { |f| f.write("#{prefix}TINA4_SECRET=#{new_secret}\n") }
          log_info("Auth: generated a development secret, saved to .env.local (gitignored)")
        rescue StandardError => e
          # Keep the in-memory secret for this run; just warn. Never crash boot.
          log_warning("Auth: generated a development secret but could not write .env.local (#{e.message}); using it for this run only")
        end

        new_secret
      end

      # ── HS256 helpers (stdlib only, no gem) ──────────────────────

      # Returns true when SECRET env var is set and no RSA keys exist in .keys/
      def use_hmac?
        secret = ENV["TINA4_SECRET"]
        return false if secret.nil? || secret.empty?

        # If RSA keys already exist on disk, prefer RS256 for backward compat
        @keys_dir ||= File.join(Dir.pwd, KEYS_DIR)
        !(File.exist?(File.join(@keys_dir, "private.pem")) &&
          File.exist?(File.join(@keys_dir, "public.pem")))
      end

      # Lazy per-call secret resolver. When the secret is blank, emit the
      # actionable blank-secret warning (the same text the CI/prod bootstrap
      # path uses) before returning. Parity with Python's _resolve_secret.
      def hmac_secret
        secret = ENV["TINA4_SECRET"]
        warn_blank_secret if secret.nil? || secret.empty?
        secret
      end

      # Base64url-encode without padding (JWT spec)
      def base64url_encode(data)
        Base64.urlsafe_encode64(data, padding: false)
      end

      # Base64url-decode (handles missing padding)
      def base64url_decode(str)
        # Add back padding
        remainder = str.length % 4
        str += "=" * ((4 - remainder) % 4) if remainder != 0
        Base64.urlsafe_decode64(str)
      end

      # Pick the JWT algorithm: explicit argument, else TINA4_JWT_ALGORITHM, else
      # HS256. A blank value counts as unset (parity with Python, where an empty
      # env string is falsy and falls through).
      #
      # Raises ArgumentError naming the supported set when asked for one we cannot
      # sign — Ruby's idiomatic equivalent of the master's ValueError. The env var
      # was registered in the CLI's known_vars and then silently ignored here, so a
      # user could set HS512 and still get HS256 tokens.
      def resolve_algorithm(algorithm = nil)
        candidate = [algorithm, ENV["TINA4_JWT_ALGORITHM"]]
                    .find { |value| !value.nil? && !value.to_s.strip.empty? }
        chosen = (candidate || "HS256").to_s.strip
        unless HMAC_ALGORITHMS.key?(chosen)
          raise ArgumentError,
                "Unsupported JWT algorithm #{chosen.inspect}. Tina4 signs with " \
                "#{HMAC_ALGORITHMS.keys.sort.join(', ')} (HMAC only, zero-dependency). " \
                "Set TINA4_JWT_ALGORITHM to one of those."
        end
        chosen
      end

      # HMAC the signing input with the digest the algorithm actually names, so the
      # header's "alg" can never disagree with the bytes we produced.
      def hmac_signature(algorithm, secret, signing_input)
        OpenSSL::HMAC.digest(HMAC_ALGORITHMS.fetch(algorithm).new, secret.to_s, signing_input)
      end

      # Write the base64url header.payload.signature envelope. The signature bytes
      # come from the block, so the HMAC and RS256 paths share ONE envelope writer
      # — and one place where "alg" is stamped from whatever actually signed.
      def encode_envelope(algorithm, claims)
        segments = [
          base64url_encode(JSON.generate({ "alg" => algorithm, "typ" => "JWT" })),
          base64url_encode(JSON.generate(claims))
        ]
        segments << base64url_encode(yield(segments.join(".")))
        segments.join(".")
      end

      # Read the envelope, PIN the header alg, check the signature via the block,
      # then apply the RFC 7519 claim rules. Returns the payload hash or nil.
      #
      # The algorithm is PINNED to our configured one rather than trusted from the
      # token: a header asking to be verified as anything else — "none", a
      # different HMAC, or RS256 while we are configured for HMAC — is rejected
      # before any signature work. Making RS256 opt-in must NOT open algorithm
      # substitution, so both paths share this one pin.
      def decode_envelope(token, algorithm)
        parts = token.to_s.split(".")
        return nil unless parts.length == 3
        return nil unless JSON.parse(base64url_decode(parts[0]))["alg"] == algorithm
        return nil unless yield("#{parts[0]}.#{parts[1]}", base64url_decode(parts[2]))

        payload = JSON.parse(base64url_decode(parts[1]))
        now = Time.now.to_i

        # RFC 7519 s4.1.4: "The processing of the 'exp' claim requires that the
        # current date/time MUST be before the expiration date/time". now == exp
        # is therefore ALREADY expired, so the test is >=.
        #
        # key? — NOT a truthiness test on the value. A PRESENT but malformed exp
        # must never read as "no constraint": `payload["exp"] && ...` skipped the
        # check entirely for exp: null / exp: false, turning a broken token into
        # one that never expires.
        if payload.key?("exp")
          exp = numeric_date(payload["exp"])
          return nil if exp.nil? || now >= exp
        end

        # "nbf" (not-before): a post-dated token is not valid yet. Tolerate
        # JWT_LEEWAY_SECONDS of clock skew so a token minted on a host a second
        # ahead is not rejected for nothing. Same malformed-is-rejected rule as
        # exp; NO nbf key at all stays unconstrained (non-breaking).
        if payload.key?("nbf")
          nbf = numeric_date(payload["nbf"])
          return nil if nbf.nil? || now + JWT_LEEWAY_SECONDS < nbf
        end

        payload
      rescue ArgumentError, JSON::ParserError, OpenSSL::OpenSSLError
        nil
      end

      # Build a JWT with Ruby's OpenSSL::HMAC (no gem needed). The algorithm is the
      # explicit argument, else TINA4_JWT_ALGORITHM, else HS256 — and the header
      # advertises exactly the algorithm that signed.
      def hmac_encode(claims, secret, algorithm: nil)
        alg = resolve_algorithm(algorithm)
        encode_envelope(alg, claims) { |input| hmac_signature(alg, secret, input) }
      end

      # Decode and verify an HMAC-signed JWT. Returns the payload hash or nil.
      def hmac_decode(token, secret, algorithm: nil)
        # Resolved OUTSIDE decode_envelope's rescue: an unsupported algorithm is a
        # configuration error that must surface, not become a nil "invalid token".
        alg = resolve_algorithm(algorithm)

        decode_envelope(token, alg) do |input, signature|
          expected = hmac_signature(alg, secret, input)
          # Constant-time comparison to prevent timing attacks. Lengths must match
          # first — fixed_length_secure_compare RAISES on a length mismatch, which
          # a forged signature of the wrong digest size would trigger.
          expected.bytesize == signature.bytesize &&
            OpenSSL.fixed_length_secure_compare(expected, signature)
        end
      end

      # ── RS256: opt-in, stdlib OpenSSL, zero gems ─────────────────

      # Does this runtime provide RSA natively? Ruby ships OpenSSL as a stdlib
      # DEFAULT GEM, so this is true on every normal build — there is nothing to
      # install and nothing to opt into at the library level.
      def rs256_available?
        defined?(OpenSSL::PKey::RSA) ? true : false
      end

      # RSA-SHA256, with a FRESH digest instance per call so nothing about the
      # digest state is shared between calls or threads (same rule as HMAC).
      def rs256_encode(claims)
        require_rs256!
        encode_envelope("RS256", claims) { |input| private_key.sign(OpenSSL::Digest::SHA256.new, input) }
      end

      def rs256_decode(token)
        require_rs256!
        decode_envelope(token, "RS256") { |input, sig| public_key.verify(OpenSSL::Digest::SHA256.new, sig, input) }
      end

      # ── Token API (HMAC by default; RS256 when RSA keys are present) ──

      # Mint a signed JWT.
      #
      # `algorithm:` selects the HMAC algorithm (else TINA4_JWT_ALGORITHM, else
      # HS256); an unsupported one raises ArgumentError rather than quietly
      # downgrading. It applies to the HMAC path only — the opt-in RS256 path
      # (RSA keys present in .keys/) is unaffected.
      #
      # BREAKING (deliberate): no "nbf" claim is stamped. It duplicated "iat",
      # added no security, and created clock-skew rejections; RFC 7519 nbf is for
      # deliberately post-dated tokens, which stays fully supported when the caller
      # passes its own "nbf" in the payload. Python/PHP/Node never auto-stamped it,
      # so Ruby doing so was the parity break.
      def get_token(payload, expires_in: 60, secret: nil, algorithm: nil)
        now = Time.now.to_i
        claims = payload.merge(
          "iat" => now,
          "exp" => now + (expires_in * 60).to_i
        )

        if secret
          hmac_encode(claims, secret, algorithm: algorithm)
        elsif use_hmac?
          hmac_encode(claims, hmac_secret, algorithm: algorithm)
        else
          ensure_keys
          rs256_encode(claims)
        end
      end

      # Verify a JWT signature + expiry.
      #
      # 3.13.0: return type changed from `Boolean` to `Hash | nil`. The
      # decoded payload is returned on success, nil on failure. Matches
      # Python's Auth.valid_token in 3.13.0.
      #
      # Legacy `if Tina4::Auth.valid_token(t)` patterns keep working
      # because a non-empty Hash is truthy and nil is falsy.
      def valid_token(token)
        if use_hmac?
          hmac_decode(token, hmac_secret) # returns Hash payload or nil
        else
          ensure_keys
          rs256_decode(token)
        end
      end

      # BREAKING (deliberate): the RS256 branch used to surface the jwt gem's own
      # wording ("Signature has expired", or a raw decode message). Both paths now
      # report the single HMAC-path wording, so the detail shape no longer depends
      # on which algorithm signed.
      def valid_token_detail(token)
        payload = valid_token(token)
        payload ? { valid: true, payload: payload } : { valid: false, error: "Invalid or expired token" }
      end

      def hash_password(password, salt = nil, iterations = 260000)
        salt ||= SecureRandom.hex(16)
        dk = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: iterations, length: 32, hash: "sha256")
        "pbkdf2_sha256$#{iterations}$#{salt}$#{dk.unpack1('H*')}"
      end

      def check_password(password, hash)
        parts = hash.split('$')
        return false unless parts.length == 4 && parts[0] == 'pbkdf2_sha256'
        iterations = parts[1].to_i
        salt = parts[2]
        expected = parts[3]
        dk = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: iterations, length: 32, hash: "sha256")
        actual = dk.unpack1('H*')
        # Timing-safe comparison
        OpenSSL.fixed_length_secure_compare(actual, expected)
      rescue
        false
      end


      def get_payload(token)
        parts = token.split(".")
        return nil unless parts.length == 3

        payload_json = base64url_decode(parts[1])
        JSON.parse(payload_json)
      rescue ArgumentError, JSON::ParserError
        nil
      end

      # Validate and re-issue a token with the same claims.
      #
      # Only "iat"/"exp" are dropped (they are re-stamped). A caller-supplied "nbf"
      # is PRESERVED — matching the Python master, and keeping the promise made
      # when auto-nbf was removed: a deliberately post-dated claim is the issuer's,
      # and a refresh must not quietly erase it.
      def refresh_token(token, expires_in: 60)
        return nil unless valid_token(token)

        payload = get_payload(token)
        return nil unless payload
        payload = payload.reject { |k, _| %w[iat exp].include?(k) }
        get_token(payload, expires_in: expires_in)
      end

      # Extract and validate auth from request headers.
      #
      # `secret:` and `algorithm:` are real overrides. `algorithm:` used to be
      # accepted with a hardcoded "HS256" default and then dropped on the floor, so
      # an explicit argument silently lost to TINA4_JWT_ALGORITHM — the precedence
      # is now honoured here too (explicit > env > HS256).
      def authenticate_request(headers, secret: nil, algorithm: nil)
        auth_header = headers["HTTP_AUTHORIZATION"] || headers["Authorization"] || ""
        return nil unless auth_header =~ /\ABearer\s+(.+)\z/i

        token = Regexp.last_match(1)

        # The JWT is checked FIRST, then the API key — the order Python, PHP and
        # Node all use. Ruby checked the API key first, so the same request could
        # authenticate differently depending on the framework.
        #
        # A custom secret and/or algorithm validates against those directly rather
        # than this process's env-resolved defaults.
        payload = if secret || algorithm
                    hmac_decode(token, secret || hmac_secret, algorithm: algorithm)
                  elsif valid_token(token)
                    get_payload(token)
                  end
        return payload if payload

        # API_KEY bypass — timing-safe comparison via validate_api_key
        # (OpenSSL.fixed_length_secure_compare). Parity with Python's
        # authenticate_request (validate_api_key), PHP (hash_equals) and
        # Node (timingSafeEqual). Never use a plain `==` here — that leaks the
        # key length/prefix through comparison timing.
        #
        # "_auth" is the cross-framework key for a non-JWT auth result; PHP and
        # Node already used it, Python used "auth_type" and Ruby "api_key", so the
        # same successful auth read three different ways.
        return { "_auth" => "api_key" } if validate_api_key(token)

        nil
      end

      def validate_api_key(provided, expected: nil)
        expected ||= ENV["TINA4_API_KEY"]
        return false if expected.nil? || expected.empty?
        return false if provided.nil? || provided.empty?
        return false if provided.length != expected.length

        OpenSSL.fixed_length_secure_compare(provided, expected)
      end

      def auth_handler(&block)
        if block_given?
          @custom_handler = block
        else
          @custom_handler || method(:default_auth_handler)
        end
      end

      def bearer_auth
        lambda do |env|
          auth_header = env["HTTP_AUTHORIZATION"] || ""
          return false unless auth_header =~ /\ABearer\s+(.+)\z/i

          token = Regexp.last_match(1)

          # JWT first, then the API key — same order and same payload shape as
          # authenticate_request above (and as Python/PHP/Node).
          if valid_token(token)
            env["tina4.auth"] = get_payload(token)
            return true
          end

          # API_KEY bypass — timing-safe comparison via validate_api_key
          # (OpenSSL.fixed_length_secure_compare). Parity with Python's
          # authenticate_request (validate_api_key), PHP (hash_equals) and
          # Node (timingSafeEqual). Never use a plain `==` here — that leaks the
          # key length/prefix through comparison timing.
          if validate_api_key(token)
            env["tina4.auth"] = { "_auth" => "api_key" }
            return true
          end

          false
        end
      end

      # Default auth handler for secured routes (POST/PUT/PATCH/DELETE)
      # Used automatically unless auth: false is passed
      def default_secure_auth
        @default_secure_auth ||= bearer_auth
      end

      # Legacy aliases
      alias_method :create_token, :get_token
      alias_method :validate_token, :valid_token_detail

      def private_key
        @private_key ||= OpenSSL::PKey::RSA.new(File.read(private_key_path))
      end

      def public_key
        @public_key ||= OpenSSL::PKey::RSA.new(File.read(public_key_path))
      end

      private

      # The loud, actionable RS256 gate. NotImplementedError is deliberate: it is
      # Ruby's "not available on this platform" error AND it is NOT a
      # StandardError, so a caller's blanket `rescue => e` cannot swallow it into
      # a mysterious false. Unreachable on any Ruby that can load this file.
      def require_rs256!
        raise NotImplementedError, RS256_UNAVAILABLE_MESSAGE unless rs256_available?
      end

      # Coerce an RFC 7519 NumericDate claim to integer seconds, else nil.
      #
      # RFC 7519 s2 defines exp/nbf/iat as a NumericDate — a JSON numeric value.
      # A claim that is PRESENT but not a number is malformed, and a malformed
      # constraint must never read as "no constraint": treating a non-numeric exp
      # as absent turns a broken token into one that never expires. Every
      # non-numeric JSON type (null, true/false, String, Array, Hash) returns nil
      # so the caller rejects the token. Mirrors the Python master's
      # _numeric_date; Ruby needs no bool special-case because TrueClass is not
      # an Integer (in Python bool IS an int subclass, so exp: true would compare
      # as 1970).
      def numeric_date(value)
        return nil unless value.is_a?(Integer) || value.is_a?(Float)

        value.to_i
      end

      # ── Dev-secret bootstrap helpers (parity with Python master) ──

      # Dev when the framework debug flag is truthy (TINA4_DEBUG).
      def dev?
        Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])
      end

      # CI when the de-facto CI env var is truthy.
      def ci?
        Tina4::Env.is_truthy(ENV["CI"])
      end

      # Production when TINA4_ENV (default "development") is "production".
      def production?
        (ENV["TINA4_ENV"] || "development").to_s.strip.downcase == "production"
      end

      # Emit the single actionable blank-secret warning. Same text from the
      # CI/prod bootstrap path and the lazy per-call resolver.
      def warn_blank_secret
        log_warning(BLANK_SECRET_WARNING)
      end

      def log_info(message)
        if defined?(Tina4::Log)
          Tina4::Log.info(message)
        else
          warn(message)
        end
      rescue StandardError
        warn(message)
      end

      def log_warning(message)
        if defined?(Tina4::Log)
          Tina4::Log.warning(message)
        else
          warn(message)
        end
      rescue StandardError
        warn(message)
      end

      def ensure_keys
        @keys_dir ||= File.join(Dir.pwd, KEYS_DIR)
        FileUtils.mkdir_p(@keys_dir)
        unless File.exist?(private_key_path) && File.exist?(public_key_path)
          generate_keys
        end
      end

      def generate_keys
        Tina4::Log.info("Generating RSA key pair for JWT authentication")
        key = OpenSSL::PKey::RSA.generate(2048)
        File.write(private_key_path, key.to_pem)
        File.write(public_key_path, key.public_key.to_pem)
        @private_key = nil
        @public_key = nil
      end

      def private_key_path
        File.join(@keys_dir, "private.pem")
      end

      def public_key_path
        File.join(@keys_dir, "public.pem")
      end

      def default_auth_handler(env)
        auth_header = env["HTTP_AUTHORIZATION"] || ""
        return true if auth_header.empty?

        if auth_header =~ /\ABearer\s+(.+)\z/i
          valid_token(Regexp.last_match(1))
        else
          false
        end
      end
    end
  end
end
