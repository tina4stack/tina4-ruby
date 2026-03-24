# frozen_string_literal: true
require "openssl"
require "base64"
require "json"
require "fileutils"

module Tina4
  module Auth
    KEYS_DIR = ".keys"

    class << self
      def setup(root_dir = Dir.pwd)
        @keys_dir = File.join(root_dir, KEYS_DIR)
        FileUtils.mkdir_p(@keys_dir)
        ensure_keys unless use_hmac?
      end

      # ── HS256 helpers (stdlib only, no gem) ──────────────────────

      # Returns true when SECRET env var is set and no RSA keys exist in .keys/
      def use_hmac?
        secret = ENV["SECRET"]
        return false if secret.nil? || secret.empty?

        # If RSA keys already exist on disk, prefer RS256 for backward compat
        @keys_dir ||= File.join(Dir.pwd, KEYS_DIR)
        !(File.exist?(File.join(@keys_dir, "private.pem")) &&
          File.exist?(File.join(@keys_dir, "public.pem")))
      end

      def hmac_secret
        ENV["SECRET"]
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

      def get_token(payload, expires_in: 3600)
        now = Time.now.to_i
        claims = payload.merge(
          "iat" => now,
          "exp" => now + expires_in,
          "nbf" => now
        )

        if use_hmac?
          hmac_encode(claims, hmac_secret)
        else
          ensure_keys
          require "jwt"
          JWT.encode(claims, private_key, "RS256")
        end
      end


      def valid_token(token)
        if use_hmac?
          hmac_decode(token, hmac_secret)
        else
          ensure_keys
          require "jwt"
          decoded = JWT.decode(token, public_key, true, algorithm: "RS256")
          decoded[0]
        end
      rescue JWT::ExpiredSignature
        nil
      rescue JWT::DecodeError
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

      def hash_password(password)
        require "bcrypt"
        BCrypt::Password.create(password)
      end

      def check_password(password, hash)
        require "bcrypt"
        BCrypt::Password.new(hash) == password
      rescue BCrypt::Errors::InvalidHash
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

      def refresh_token(token, expires_in: 3600)
        payload = valid_token(token)
        return nil unless payload

        payload = payload.reject { |k, _| %w[iat exp nbf].include?(k) }
        get_token(payload, expires_in: expires_in)
      end

      def authenticate_request(headers)
        auth_header = headers["HTTP_AUTHORIZATION"] || headers["Authorization"] || ""
        return nil unless auth_header =~ /\ABearer\s+(.+)\z/i

        token = Regexp.last_match(1)

        # API_KEY bypass — matches tina4_python behavior
        api_key = ENV["TINA4_API_KEY"] || ENV["API_KEY"]
        if api_key && !api_key.empty? && token == api_key
          return { "api_key" => true }
        end

        valid_token(token)
      end

      def validate_api_key(provided, expected: nil)
        expected ||= ENV["TINA4_API_KEY"] || ENV["API_KEY"]
        return false if expected.nil? || expected.empty?
        return false if provided.nil? || provided.empty?

        provided == expected
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

          # API_KEY bypass — matches tina4_python behavior
          api_key = ENV["API_KEY"]
          if api_key && !api_key.empty? && token == api_key
            env["tina4.auth"] = { "api_key" => true }
            return true
          end

          payload = valid_token(token)
          if payload
            env["tina4.auth"] = payload
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

      def ensure_keys
        return if use_hmac?

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
          !valid_token(Regexp.last_match(1)).nil?
        else
          false
        end
      end
    end
  end
end
