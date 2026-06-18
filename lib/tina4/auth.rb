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
      ".env before serving traffic."

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

      # Build a JWT using HS256 with Ruby's OpenSSL::HMAC (no gem needed)
      def hmac_encode(claims, secret)
        header = { "alg" => "HS256", "typ" => "JWT" }
        segments = [
          base64url_encode(JSON.generate(header)),
          base64url_encode(JSON.generate(claims))
        ]
        signing_input = segments.join(".")
        signature = OpenSSL::HMAC.digest("SHA256", secret, signing_input)
        segments << base64url_encode(signature)
        segments.join(".")
      end

      # Decode and verify a JWT signed with HS256. Returns the payload hash or nil.
      def hmac_decode(token, secret)
        parts = token.split(".")
        return nil unless parts.length == 3

        header_json = base64url_decode(parts[0])
        header = JSON.parse(header_json)
        return nil unless header["alg"] == "HS256"

        # Verify signature
        signing_input = "#{parts[0]}.#{parts[1]}"
        expected_sig = OpenSSL::HMAC.digest("SHA256", secret, signing_input)
        actual_sig = base64url_decode(parts[2])

        # Constant-time comparison to prevent timing attacks
        return nil unless OpenSSL.fixed_length_secure_compare(expected_sig, actual_sig)

        payload = JSON.parse(base64url_decode(parts[1]))

        # Check expiry
        now = Time.now.to_i
        return nil if payload["exp"] && now >= payload["exp"]
        return nil if payload["nbf"] && now < payload["nbf"]

        payload
      rescue ArgumentError, JSON::ParserError, OpenSSL::HMACError
        nil
      end

      # ── Token API (auto-selects HS256 or RS256) ─────────────────

      def get_token(payload, expires_in: 60, secret: nil)
        now = Time.now.to_i
        claims = payload.merge(
          "iat" => now,
          "exp" => now + (expires_in * 60).to_i,
          "nbf" => now
        )

        if secret
          hmac_encode(claims, secret)
        elsif use_hmac?
          hmac_encode(claims, hmac_secret)
        else
          ensure_keys
          require "jwt"
          JWT.encode(claims, private_key, "RS256")
        end
      end


      # Verify a JWT signature + expiry.
      #
      # 3.13.0: return type changed from `Boolean` to `Hash | nil`. The
      # decoded payload is returned on success, nil on failure. Matches
      # firebase/jwt-ruby and Python's Auth.valid_token in 3.13.0.
      #
      # Legacy `if Tina4::Auth.valid_token(t)` patterns keep working
      # because a non-empty Hash is truthy and nil is falsy.
      def valid_token(token)
        if use_hmac?
          hmac_decode(token, hmac_secret) # returns Hash payload or nil
        else
          ensure_keys
          require "jwt"
          decoded = JWT.decode(token, public_key, true, algorithm: "RS256")
          decoded[0] # firebase/jwt-ruby returns [payload, header]
        end
      rescue JWT::ExpiredSignature, JWT::DecodeError
        nil
      end

      def valid_token_detail(token)
        if use_hmac?
          payload = hmac_decode(token, hmac_secret)
          if payload
            { valid: true, payload: payload }
          else
            { valid: false, error: "Invalid or expired token" }
          end
        else
          ensure_keys
          require "jwt"
          decoded = JWT.decode(token, public_key, true, algorithm: "RS256")
          { valid: true, payload: decoded[0] }
        end
      rescue JWT::ExpiredSignature
        { valid: false, error: "Token expired" }
      rescue JWT::DecodeError => e
        { valid: false, error: e.message }
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

      def refresh_token(token, expires_in: 60)
        return nil unless valid_token(token)

        payload = get_payload(token)
        return nil unless payload
        payload = payload.reject { |k, _| %w[iat exp nbf].include?(k) }
        get_token(payload, expires_in: expires_in)
      end

      def authenticate_request(headers, secret: nil, algorithm: "HS256")
        auth_header = headers["HTTP_AUTHORIZATION"] || headers["Authorization"] || ""
        return nil unless auth_header =~ /\ABearer\s+(.+)\z/i

        token = Regexp.last_match(1)

        # API_KEY bypass — timing-safe comparison via validate_api_key
        # (OpenSSL.fixed_length_secure_compare). Parity with Python's
        # authenticate_request (validate_api_key), PHP (hash_equals) and
        # Node (timingSafeEqual). Never use a plain `==` here — that leaks the
        # key length/prefix through comparison timing.
        if validate_api_key(token)
          return { "api_key" => true }
        end

        # If a custom secret is provided, validate against it directly
        if secret
          payload = hmac_decode(token, secret)
          return payload ? payload : nil
        end

        valid_token(token) ? get_payload(token) : nil
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

          # API_KEY bypass — timing-safe comparison via validate_api_key
          # (OpenSSL.fixed_length_secure_compare). Parity with Python's
          # authenticate_request (validate_api_key), PHP (hash_equals) and
          # Node (timingSafeEqual). Never use a plain `==` here — that leaks the
          # key length/prefix through comparison timing.
          if validate_api_key(token)
            env["tina4.auth"] = { "api_key" => true }
            return true
          end

          if valid_token(token)
            env["tina4.auth"] = get_payload(token)
            true
          else
            false
          end
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
