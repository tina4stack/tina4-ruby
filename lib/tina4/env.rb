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
    DEFAULT_ENV = {
      "PROJECT_NAME" => "Tina4 Ruby Project",
      "TINA4_SWAGGER_VERSION" => "1.0.0",
      "TINA4_LOCALE" => "en",
      "TINA4_DEBUG" => "true",
      "TINA4_LOG_LEVEL" => "[TINA4_LOG_ALL]",
      "TINA4_SECRET" => "tina4-secret-change-me"
    }.freeze

    # Check if a value is truthy for env boolean checks.
    #
    # Accepts: "true", "True", "TRUE", "1", "yes", "Yes", "YES", "on", "On", "ON".
    # Everything else is falsy (including empty string, nil, not set).
    def self.is_truthy(val)
      %w[true 1 yes on].include?(val.to_s.strip.downcase)
    end

    class << self
      def load_env(root_dir = Dir.pwd)
        env_file = resolve_env_file(root_dir)
        unless File.exist?(env_file)
          create_default_env(env_file)
        end
        parse_env_file(env_file)
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

      def parse_env_file(path)
        return unless File.exist?(path)
        File.readlines(path).each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          if (match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=["']?(.*)["']?\z/))
            key = match[1]
            value = match[2].gsub(/["']\z/, "")
            ENV[key] ||= value
            @loaded_keys ||= []
            @loaded_keys << key
          end
        end
      end
    end
  end
end
