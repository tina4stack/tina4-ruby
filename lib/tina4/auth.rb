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
        ensure_keys
      end

      def generate_token(payload, expires_in: 3600)
        ensure_keys
        now = Time.now.to_i
        claims = payload.merge(
          "iat" => now,
          "exp" => now + expires_in,
          "nbf" => now
        )
        require "jwt"
        JWT.encode(claims, private_key, "RS256")
      end

      def validate_token(token)
        ensure_keys
        require "jwt"
        decoded = JWT.decode(token, public_key, true, algorithm: "RS256")
        { valid: true, payload: decoded[0] }
      rescue JWT::ExpiredSignature
        { valid: false, error: "Token expired" }
      rescue JWT::DecodeError => e
        { valid: false, error: e.message }
      end

      def hash_password(password)
        require "bcrypt"
        BCrypt::Password.create(password)
      end

      def verify_password(password, hash)
        require "bcrypt"
        BCrypt::Password.new(hash) == password
      rescue BCrypt::Errors::InvalidHash
        false
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

          result = validate_token(token)
          if result[:valid]
            env["tina4.auth"] = result[:payload]
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

      def private_key
        @private_key ||= OpenSSL::PKey::RSA.new(File.read(private_key_path))
      end

      def public_key
        @public_key ||= OpenSSL::PKey::RSA.new(File.read(public_key_path))
      end

      private

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
          result = validate_token(Regexp.last_match(1))
          result[:valid]
        else
          false
        end
      end
    end
  end
end
