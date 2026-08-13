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
                   "Note: these may come from a .env file loaded by dotenv, not just",
                   "the runtime environment - check your image / build context (a .env",
                   "baked into a Docker image is loaded at startup) as well as k8s/CI env.",
                   "",
                   "FIX: run `tina4 env --migrate` to rewrite your .env automatically",
                   "(it renames every legacy name to its TINA4_ form in place).",
                   "Or rename manually. See https://tina4.com/release/3.12.0",
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
      "TINA4_LOG_LEVEL" => "ALL"
    }.freeze

    # The ONE env truthiness table. Every env boolean in every Tina4 framework
    # answers from this set (case-insensitive after strip):
    #
    #   truthy: "true", "1", "yes", "on"     falsy: everything else
    #
    # BREAKING (parity): "y", "t", "n" and "f" were accepted here and NOWHERE
    # ELSE — not by Ruby's own Log/Mcp checks, and not by Python, PHP or Node.
    # So TINA4_LOG_FUNC=y switched function logging ON while TINA4_DEBUG=y left
    # debug OFF, in the same process, from the same .env. Single letters are
    # dropped rather than spread: systemd's boolean set is 1/yes/true/on with no
    # letters, and YAML 1.2 removed y/n precisely because a bare letter reads as
    # a value (the Norway problem). Use "true"/"false".
    # There is deliberately NO falsy table. Falsy is "not in TRUTHY", so there
    # is exactly one list to keep correct. A second table is a second thing
    # that can drift, and it is what let `bool` and `is_truthy` disagree.
    TRUTHY = %w[true 1 yes on].freeze

    # Check if a value is truthy for env boolean checks.
    #
    # Accepts: "true", "True", "TRUE", "1", "yes", "Yes", "YES", "on", "On", "ON".
    # Everything else is falsy (including empty string, nil, not set).
    def self.is_truthy(val)
      TRUTHY.include?(val.to_s.strip.downcase)
    end

    # Read an env var and coerce to Boolean. Returns +default+ only when the
    # var is UNSET — a value that IS set is answered by the one truthiness
    # table, never quietly replaced by the default. Never raises.
    def self.bool(name, default: false)
      raw = ENV[name.to_s]
      return default if raw.nil?
      is_truthy(raw)
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
        # Precedence: real-env > .env.local > .env. Both loads are first-wins
        # (override=false / `ENV[key] ||= value`), so a key already present in
        # the real process environment is NEVER clobbered. .env.local loads
        # FIRST so its values beat .env, but a real env var set before boot
        # still wins over both. This is the security-correct ordering: a stray
        # gitignored .env.local (e.g. a stale auto-generated dev secret) must
        # not override an explicitly-set real TINA4_SECRET. The ensure-dev-secret
        # bootstrap runs AFTER this (only mints a secret if still unset in dev).
        local = load_local_env(root_dir)
        # .env.local WINS on a duplicate key, so it merges last. Both hashes
        # already report the value in effect, so a real env var that beat both
        # is what a caller reads back either way.
        parse_env_file(env_file).merge(local)
      end

      # Load .env.local with first-wins semantics (override=false). A real
      # process env var already present wins; this only fills keys not already
      # set. Loaded BEFORE .env so .env.local beats .env (real-env > .env.local
      # > .env). No-op when the file is absent (common for fresh checkouts).
      def load_local_env(root_dir = Dir.pwd)
        local_file = File.join(root_dir, ".env.local")
        return {} unless File.exist?(local_file)
        parse_env_file(local_file)
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
      # Validate that required env vars exist, and return them.
      #
      # RENAMED from require_env! on 2026-07-31. The bang was Ruby-idiomatic for
      # "raises", but the concept is named require_env in the other three, and
      # the surface-table rule is one name per concept with idiomatic CASING
      # only. An alias would paper over the mismatch instead of fixing it, so
      # the primary is renamed. Breaking for anyone calling require_env!.
      #
      # Returns a hash of every requested key to its value, matching Python,
      # PHP and Node - it used to return nothing, so a caller could validate but
      # not read in one step.
      #
      # Reports every missing name in one raise rather than the first: an
      # operator fixing a deployment wants the whole list, not one name per
      # restart.
      def require_env(*keys)
        names = keys.flatten.map(&:to_s)
        missing = names.reject { |k| ENV.key?(k) }
        unless missing.empty?
          raise KeyError, "Missing required environment variables: #{missing.join(', ')}"
        end
        names.to_h { |k| [k, ENV[k]] }
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
      # override=false (default): `ENV[key] ||= value` — first-wins; a key
      # already present (real env var, or a higher-precedence file loaded
      # earlier) is never clobbered. Both .env.local and .env are loaded this
      # way; ordering (.env.local first) gives the precedence real-env >
      # .env.local > .env.
      # override=true: `ENV[key] = value` — unconditional set. NOT used by the
      # boot load sequence; kept only as an explicit opt-in for callers that
      # genuinely need to force values.
      # Returns a hash of the keys this file declared, mapped to the value that
      # WON - not the value the file declared. The two differ exactly when the
      # real environment beat the file, which is the case an operator most needs
      # to see: reporting the file's value there would return "from_local" while
      # the process is actually running on the real env var. A map that
      # disagrees with ENV is worse than no map, because it looks authoritative.
      def parse_env_file(path, override: false)
        effective = {}
        return effective unless File.exist?(path)
        warned_refs = {}
        File.readlines(path).each_with_index do |raw, index|
          key, value = parse_env_line(raw, path, index + 1, warned_refs)
          next if key.nil?
          if override
            ENV[key] = value
          else
            ENV[key] ||= value
          end
          @loaded_keys ||= []
          @loaded_keys << key
          effective[key] = ENV[key]
        end
        effective
      end

      # Parse ONE dotenv line into [key, value], or [nil, nil] for a line that
      # sets nothing (blank, comment, or malformed).
      #
      # The rules are the cross-framework behaviour table (feature 1 of the
      # feature audit): identical in Python, PHP, Ruby and Node, driven off one
      # committed fixture. Ruby used to differ on two of them, silently.
      def parse_env_line(raw, path, line_no, warned_refs)
        line = raw.strip
        return [nil, nil] if line.empty? || line.start_with?("#")

        # Rule 2: a shell-style `export FOO=bar` is valid input, not an error.
        # Ruby used to fall straight through this line, leaving the variable
        # UNSET with no warning -- so a .env copied out of a shell profile lost
        # keys, and the failure surfaced somewhere unrelated (a blank
        # TINA4_SECRET, a missing database URL).
        line = line.sub(/\Aexport\s+/, "")

        # Rule 3: split on the FIRST `=` only. A line with no `=` is skipped
        # with a warning naming the line -- never in silence.
        eq = line.index("=")
        if eq.nil?
          warn_env("#{path}:#{line_no}: no '=' in \"#{line}\", line skipped")
          return [nil, nil]
        end

        key = line[0...eq].strip
        # Rule 4: reject a key that is not a valid identifier, by name and line.
        unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          warn_env("#{path}:#{line_no}: invalid key #{key.inspect}, line skipped")
          return [nil, nil]
        end

        [key, parse_env_value(line[(eq + 1)..].to_s.strip, path, line_no, warned_refs)]
      end

      # Rule 5 + 6: quoting decides escapes AND interpolation, in that order.
      def parse_env_value(value, path, line_no, warned_refs)
        # A QUOTED value ends at its CLOSING QUOTE, and anything after it is a
        # comment. Testing the LAST character instead was wrong: a trailing
        # comment makes the last character non-quote, so `PW="s3cret" # note`
        # fell through to the unquoted branch below, which strips only the ` #`
        # and left the QUOTE CHARACTERS in the value -- a credential handed to a
        # driver as "\"s3cret\"". PHP already scanned for the terminator; this is
        # that mechanism, and the scan SKIPS a quote preceded by a backslash so
        # an escaped \" cannot end the value early.
        if !value.empty? && (value.start_with?("'") || value.start_with?('"'))
          quote = value[0]
          i = 1
          while i < value.length
            if value[i] == "\\" && quote == '"' && i + 1 < value.length
              i += 2
              next
            end
            break if value[i] == quote
            i += 1
          end

          if i < value.length
            inner = value[1...i]
            # Single quotes are verbatim: no escapes, no interpolation. Shell
            # semantics, and the documented way to keep a literal ${...}.
            return inner if quote == "'"

            inner = inner.gsub("\\n", "\n")
                         .gsub("\\r", "\r")
                         .gsub("\\t", "\t")
                         .gsub('\\"', '"')
                         .gsub("\\\\", "\\")
            return interpolate_env(inner, path, line_no, warned_refs)
          end
        end

        # Rule 5: an unquoted value is truncated at the first SPACE-HASH, then
        # trimmed. Ruby used to keep the whole line, so `FOO=value # note`
        # became "value # note" -- a wrong value rather than an absent one,
        # which is the harder kind to notice.
        hash = value.index(" #")
        value = value[0...hash] if hash
        interpolate_env(value.rstrip, path, line_no, warned_refs)
      end

      # Rule 6: expand ${VAR} against already-loaded keys plus the real
      # environment. An unresolved name is left LITERAL and warned about once
      # per name, so a typo is visible without breaking the load.
      def interpolate_env(value, path, line_no, warned_refs)
        value.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/) do
          name = Regexp.last_match(1)
          if ENV.key?(name)
            ENV[name]
          else
            unless warned_refs[name]
              warned_refs[name] = true
              warn_env("#{path}:#{line_no}: ${#{name}} is not set, left as-is")
            end
            "${#{name}}"
          end
        end
      end

      # One place to emit a parse warning. Routed through Tina4::Log when it is
      # loaded (env.rb is required before the logger during boot), else $stderr.
      def warn_env(message)
        if defined?(Tina4::Log) && Tina4::Log.respond_to?(:warning)
          Tina4::Log.warning(message)
        else
          $stderr.puts("[tina4] #{message}")
        end
      end
    end
  end
end
