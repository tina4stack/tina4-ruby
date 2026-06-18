# frozen_string_literal: true
require "digest"

module Tina4
  # Legacy env var names that v3.12 has retired. If any of these are set in
  # the environment we refuse to boot — silently ignoring them would cause
  # auth/db/mail to fall back to defaults with no warning. Each maps to its
  # new TINA4_-prefixed canonical name.
  LEGACY_ENV_VARS = {
    "DATABASE_URL"           => "TINA4_DATABASE_URL",
    "DATABASE_USERNAME"      => "TINA4_DATABASE_USERNAME",
    "DATABASE_PASSWORD"      => "TINA4_DATABASE_PASSWORD",
    "DB_URL"                 => "TINA4_DATABASE_URL",
    "SECRET"                 => "TINA4_SECRET",
    "API_KEY"                => "TINA4_API_KEY",
    "JWT_ALGORITHM"          => "TINA4_JWT_ALGORITHM",
    "SMTP_HOST"              => "TINA4_MAIL_HOST",
    "SMTP_PORT"              => "TINA4_MAIL_PORT",
    "SMTP_USERNAME"          => "TINA4_MAIL_USERNAME",
    "SMTP_PASSWORD"          => "TINA4_MAIL_PASSWORD",
    "SMTP_FROM"              => "TINA4_MAIL_FROM",
    "SMTP_FROM_NAME"         => "TINA4_MAIL_FROM_NAME",
    "IMAP_HOST"              => "TINA4_MAIL_IMAP_HOST",
    "IMAP_PORT"              => "TINA4_MAIL_IMAP_PORT",
    "IMAP_USER"              => "TINA4_MAIL_IMAP_USERNAME",
    "IMAP_PASS"              => "TINA4_MAIL_IMAP_PASSWORD",
    "HOST_NAME"              => "TINA4_HOST_NAME",
    "SWAGGER_TITLE"          => "TINA4_SWAGGER_TITLE",
    "SWAGGER_DESCRIPTION"    => "TINA4_SWAGGER_DESCRIPTION",
    "SWAGGER_VERSION"        => "TINA4_SWAGGER_VERSION",
    "ORM_PLURAL_TABLE_NAMES" => "TINA4_ORM_PLURAL_TABLE_NAMES"
  }.freeze

  # Raised by check_legacy_env_vars! when the caller opts out of process exit.
  class LegacyEnvError < StandardError; end

  # Refuse to boot if pre-3.12 un-prefixed env vars are still set.
  #
  # Tina4 v3.12 hard-renamed every framework-specific env var to use the
  # TINA4_ prefix. Booting silently with a legacy DATABASE_URL or SECRET
  # would let auth, DB, or mail fall back to insecure defaults while the
  # user thought their config was being read. Better to die loudly with a
  # list of names to fix.
  #
  # Bypass with TINA4_ALLOW_LEGACY_ENV=true in CI / migration scripts that
  # genuinely need both names set during a transition window.
  def self.check_legacy_env_vars!(io: $stderr, exit_on_error: true)
    bypass = ENV["TINA4_ALLOW_LEGACY_ENV"].to_s.downcase
    return if %w[true 1 yes].include?(bypass)

    found = LEGACY_ENV_VARS.keys.select { |name| ENV.key?(name) }.sort
    return if found.empty?

    sep = "─" * 72
    lines = ["", sep,
             "Tina4 v3.12 requires TINA4_ prefix on all framework env vars.",
             "Your environment still has these legacy names:",
             ""]
    found.each do |old|
      new_name = LEGACY_ENV_VARS[old]
      lines << format("    %-28s  →  %s", old, new_name)
    end
    lines.concat([
                   "",
                   "Run `tina4 env --migrate` to rewrite your .env automatically,",
                   "or rename manually. See https://tina4.com/release/3.12.0",
                   "Set TINA4_ALLOW_LEGACY_ENV=true to bypass during migration.",
                   sep, ""
                 ])
    io.puts lines.join("\n")
    raise LegacyEnvError, "Legacy env vars present: #{found.join(', ')}" unless exit_on_error

    exit(2)
  end

  module Env
    # NOTE: TINA4_SECRET is deliberately ABSENT here. The default signing
    # secret must never become a guessable built-in. A blank secret is the
    # signal for Auth.ensure_dev_secret to mint a per-machine random dev secret
    # (saved to gitignored .env.local) in dev, or to emit the actionable
    # "set TINA4_SECRET" warning in CI/prod. Parity with the Python master.
    DEFAULT_ENV = {
      "PROJECT_NAME" => "Tina4 Ruby Project",
      "TINA4_SWAGGER_VERSION" => "1.0.0",
      "TINA4_LOCALE" => "en",
      "TINA4_DEBUG" => "true",
      "TINA4_LOG_LEVEL" => "[TINA4_LOG_ALL]"
    }.freeze

    # Typed env-var coercion — parity with tina4_python's Env class,
    # tina4-php's Tina4\Env, and tina4-nodejs's Env. Truthy values
    # (case-insensitive after strip): "1", "true", "on", "yes", "y", "t".
    # Falsy: "0", "false", "off", "no", "n", "f", empty string. Anything
    # else falls through to default.
    TRUTHY = %w[1 true on yes y t].freeze
    FALSY  = %w[0 false off no n f].freeze

    # Check if a value is truthy for env boolean checks.
    #
    # Accepts: "true", "True", "TRUE", "1", "yes", "Yes", "YES", "on", "On", "ON".
    # Everything else is falsy (including empty string, nil, not set).
    def self.is_truthy(val)
      %w[true 1 yes on].include?(val.to_s.strip.downcase)
    end

    # Read an env var and coerce to Boolean. Returns +default+ when the
    # var is unset or holds a value outside the TRUTHY/FALSY tables.
    # Never raises — bad input falls through to default.
    def self.bool(name, default: false)
      raw = ENV[name.to_s]
      return default if raw.nil?
      token = raw.strip.downcase
      return true  if TRUTHY.include?(token)
      return false if FALSY.include?(token) || token.empty?
      default
    end

    # Read an env var and coerce to Integer. Logs a warning via Tina4::Log
    # (if loaded) and returns +default+ on parse failure. Never raises.
    def self.int(name, default: 0)
      raw = ENV[name.to_s]
      return default if raw.nil?
      Integer(raw.strip)
    rescue ArgumentError, TypeError
      log_warning("Env.int(#{name.inspect}): could not parse #{raw.inspect} as Integer — using default #{default.inspect}")
      default
    end

    # Read an env var and coerce to Float. Logs a warning via Tina4::Log
    # (if loaded) and returns +default+ on parse failure. Never raises.
    def self.float(name, default: 0.0)
      raw = ENV[name.to_s]
      return default if raw.nil?
      Float(raw.strip)
    rescue ArgumentError, TypeError
      log_warning("Env.float(#{name.inspect}): could not parse #{raw.inspect} as Float — using default #{default.inspect}")
      default
    end

    # Read an env var as a String. Returns +default+ when unset.
    # Whitespace is preserved — this is a pass-through for the raw env value,
    # matching Python's Env.str semantics.
    def self.str(name, default: "")
      raw = ENV[name.to_s]
      return default if raw.nil?
      raw
    end

    # Emit a warning via Tina4::Log without creating a load-order dependency.
    # Mirrors Python's Env._log_warning: silently skip if Log isn't loaded.
    def self.log_warning(message)
      Tina4::Log.warning(message) if defined?(Tina4::Log)
    rescue NameError, StandardError
      # Log not wired up yet (very early bootstrap) — swallow.
    end
    private_class_method :log_warning

    class << self
      def load_env(root_dir = Dir.pwd)
        env_file = resolve_env_file(root_dir)
        unless File.exist?(env_file)
          create_default_env(env_file)
        end
        parse_env_file(env_file)
        # Standard "local overrides, gitignored" pattern: .env loads first
        # (it never clobbers a real process env var), then .env.local re-loads
        # with override=true so a previously-generated dev secret (or any local
        # override) wins. Parity with Python's load_env(".env.local",
        # override=True) after the main .env load. .env.local is gitignored.
        load_local_env(root_dir)
      end

      # Load .env.local as an OVERRIDE on top of whatever is already in ENV.
      # No-op when the file is absent (the common case for fresh checkouts).
      def load_local_env(root_dir = Dir.pwd)
        local_file = File.join(root_dir, ".env.local")
        parse_env_file(local_file, override: true) if File.exist?(local_file)
      end

      # Get an env var value, with optional default
      def get_env(key, default = nil)
        ENV[key.to_s] || default
      end

      # Check if an env var exists
      def has_env?(key)
        ENV.key?(key.to_s)
      end

      # Return all current ENV vars as a hash
      def all_env
        ENV.to_h
      end

      # Raise if any of the given keys are missing from ENV
      def require_env!(*keys)
        missing = keys.map(&:to_s).reject { |k| ENV.key?(k) }
        unless missing.empty?
          raise KeyError, "Missing required env vars: #{missing.join(', ')}"
        end
      end

      # Reset: clear all env vars that were loaded (restore to process defaults)
      def reset_env
        @loaded_keys&.each { |k| ENV.delete(k) }
        @loaded_keys = []
      end

      private

      def resolve_env_file(root_dir)
        # TINA4_ENV_FILE wins — explicit path or filename (resolved against root_dir).
        explicit = ENV["TINA4_ENV_FILE"]
        if explicit && !explicit.empty?
          return File.absolute_path?(explicit) ? explicit : File.join(root_dir, explicit)
        end

        environment = ENV["ENVIRONMENT"]
        if environment && !environment.empty?
          candidate = File.join(root_dir, ".env.#{environment}")
          return candidate if File.exist?(candidate)
        end
        File.join(root_dir, ".env")
      end

      def create_default_env(path)
        api_key = Digest::MD5.hexdigest(Time.now.to_s)
        content = DEFAULT_ENV.map { |k, v| "#{k}=\"#{v}\"" }.join("\n")
        content += "\nTINA4_API_KEY=\"#{api_key}\"\n"
        File.write(path, content)
      end

      # Parse a dotenv file into ENV.
      #
      # override=false (default): `ENV[key] ||= value` — a real process env var
      # always wins, so .env never clobbers the environment.
      # override=true: `ENV[key] = value` — used for .env.local so local
      # overrides (e.g. a generated dev secret) take precedence.
      def parse_env_file(path, override: false)
        return unless File.exist?(path)
        File.readlines(path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          if (match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=["']?(.*)["']?\z/))
            key = match[1]
            value = match[2].gsub(/["']\z/, "")
            if override
              ENV[key] = value
            else
              ENV[key] ||= value
            end
            @loaded_keys ||= []
            @loaded_keys << key
          end
        end
      end
    end
  end
end
