# frozen_string_literal: true

require "fileutils"
require "json"
require "logger"

module Tina4
  module Log
    LEVELS = {
      "[TINA4_LOG_ALL]" => 0,
      "[TINA4_LOG_DEBUG]" => 0,
      "[TINA4_LOG_INFO]" => 1,
      "[TINA4_LOG_WARNING]" => 2,
      "[TINA4_LOG_ERROR]" => 3,
      "[TINA4_LOG_CRITICAL]" => 4,
      "[TINA4_LOG_NONE]" => 5
    }.freeze

    SEVERITY_MAP = {
      debug: 0, info: 1, warn: 2, error: 3, critical: 4
    }.freeze

    COLORS = {
      reset: "\e[0m", red: "\e[31m", green: "\e[32m",
      yellow: "\e[33m", blue: "\e[34m", magenta: "\e[35m",
      cyan: "\e[36m", gray: "\e[90m"
    }.freeze

    # ANSI escape code regex for stripping from file output
    ANSI_RE = /\033\[[0-9;]*m/

    # The logger must never be surprised by what it is handed. Console lines are
    # capped; control characters never reach a terminal. Same numbers in all four
    # frameworks (feature 2 of the feature audit).
    STDOUT_MAX_CHARS = 2000
    CONTROL_CHARS = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/

    # Defaults used when env vars are unset.
    DEFAULT_ROTATE_SIZE = 10 * 1024 * 1024 # 10MB
    DEFAULT_ROTATE_KEEP = 5

    # The error classes TINA4_LOG_STRICT must let ESCAPE stdlib ::Logger.
    #
    # TINA4_LOG_STRICT is documented as "raise on a log write failure instead of
    # swallowing", and #write_to_file dutifully rescues IOError/SystemCallError
    # and re-raises when @strict. It was a NO-OP anyway: ::Logger::LogDevice
    # wraps every device write in its own `handle_write_errors`, which rescues
    # and turns the failure into a bare `warn` on stderr. The real error was
    # swallowed one layer BELOW Tina4 and never reached Tina4's rescue at all.
    #
    # MEASURED 2026-08-01 on a genuinely full 1MB HFS+ ram disk (0 KB free),
    # Ruby 4.0.2: with TINA4_LOG_STRICT=true, Tina4::Log.info(...) printed
    # "log writing failed. No space left on device @ rb_sys_fail_on_write" to
    # stderr and returned normally. The operator got a stderr warning and strict
    # mode did nothing.
    #
    # ::Logger has a first-class seam for exactly this — `reraise_write_errors:`
    # (logger >= 1.5.0), which handle_write_errors re-raises through instead of
    # warning. Listing the two classes #write_to_file already rescues keeps the
    # two ends of the strict path in agreement. Note Errno::ENOSPC (and every
    # other errno) is a SystemCallError, so the real disk-full case is covered.
    STRICT_WRITE_ERRORS = [IOError, SystemCallError].freeze

    class << self
      attr_reader :log_dir, :log_file_path

      # configure(target = nil)
      #
      # Logs land in a `logs/` folder by default. The argument OVERRIDES that,
      # and it accepts a DIRECTORY or a FILE PATH:
      #
      #   configure                            -> ./logs/tina4.log + ./logs/error.log
      #   configure("/var/log/myapp")          -> /var/log/myapp/tina4.log + error.log
      #   configure("/var/log/myapp/app.log")  -> that exact file (no error.log sibling)
      #   TINA4_LOG_DIR=log                    -> ./log/
      #
      # A target with a file extension is a file path; anything else is a
      # directory (an existing directory is always treated as one, extension or
      # not). Naming a file means "one file at this path", so no error.log
      # appears beside it -- same rule TINA4_LOG_FILE already followed.
      #
      # BREAKING for Ruby callers: the argument used to be a project ROOT with
      # `logs/` appended, so `configure("/app")` wrote to /app/logs/ while the
      # identical call on Python and PHP wrote to /app/. That is the same
      # file-versus-directory confusion feature 1 found in loadEnv, and it made
      # "put the logs exactly here" impossible to express. If you relied on the
      # old behaviour, pass the parent explicitly: `configure(File.join(root, "logs"))`.
      def configure(target = nil)
        # Explicit argument wins, then TINA4_LOG_DIR, then ./logs.
        log_dir_env = ENV["TINA4_LOG_DIR"]
        log_dir_env = nil if log_dir_env && log_dir_env.empty?
        chosen = target || log_dir_env || "logs"
        chosen = File.join(Dir.pwd, chosen) unless File.absolute_path?(chosen)

        if target_is_file?(chosen)
          @log_dir = File.dirname(chosen)
          explicit_target_file = chosen
        else
          @log_dir = chosen
          explicit_target_file = nil
        end
        FileUtils.mkdir_p(@log_dir)

        # A file path passed to configure() wins, then TINA4_LOG_FILE (absolute
        # or relative to log_dir). Default: <log_dir>/tina4.log.
        log_file_env = ENV["TINA4_LOG_FILE"]
        log_file_env = nil if log_file_env && log_file_env.empty?
        @log_file_path = if explicit_target_file
                           explicit_target_file
                         elsif log_file_env
                           File.absolute_path?(log_file_env) ? log_file_env : File.join(@log_dir, log_file_env)
                         else
                           File.join(@log_dir, "tina4.log")
                         end

        # TINA4_LOG_ROTATE_SIZE — bytes per file before rotation. 0 = no rotation.
        @rotate_size = (ENV["TINA4_LOG_ROTATE_SIZE"] || DEFAULT_ROTATE_SIZE).to_i
        # TINA4_LOG_ROTATE_KEEP — number of rotated backups to keep.
        @rotate_keep = (ENV["TINA4_LOG_ROTATE_KEEP"] || DEFAULT_ROTATE_KEEP).to_i

        # TINA4_LOG_FORMAT — "text" or "json". Defaults to "json" in production, else "text".
        format_env = ENV["TINA4_LOG_FORMAT"]
        @format = format_env && !format_env.empty? ? format_env.downcase : (production? ? "json" : "text")
        @json_mode = @format == "json"

        # TINA4_LOG_OUTPUT — "stdout", "file", or "both".
        #
        # Default (UNSET): stdout is ALWAYS on. The log FILE (tina4.log + any
        # error log) is written ONLY in development — i.e. when TINA4_DEBUG is
        # truthy. In production / containers (TINA4_DEBUG falsy) the logger is
        # stdout-only: writing a log file inside a container just bloats the
        # writable layer + disk, and 12-factor wants logs on stdout for the
        # platform to capture. An explicit TINA4_LOG_OUTPUT=file/both (or an
        # explicit TINA4_LOG_FILE path) overrides this and STILL writes a file.
        # Mirrors the Python master (debug/__init__.py configure()).
        # An explicit TINA4_LOG_FILE always wins: a path the operator named must
        # be written even in production (parity with the Python master, where an
        # explicit log_file builds a writer unconditionally), so the dev-gated
        # default below resolves to "both" (stdout + file) rather than "stdout".
        # "The operator named ONE file" — via TINA4_LOG_FILE or by passing a file
        # path to configure(). Either way a file must be written even in
        # production, and no error.log sibling appears next to it.
        explicit_file = !log_file_env.nil? || !explicit_target_file.nil?
        default_output = if explicit_file || truthy?(ENV["TINA4_DEBUG"])
                           "both"
                         else
                           "stdout"
                         end
        output_env = ENV["TINA4_LOG_OUTPUT"]
        @output = if output_env && !output_env.empty?
                    output_env.downcase
                  else
                    default_output
                  end
        @output = default_output unless %w[stdout file both].include?(@output)

        # TINA4_LOG_STRICT — when true, raise on log write failures instead of swallowing.
        @strict = truthy?(ENV["TINA4_LOG_STRICT"])

        @console_level = resolve_level
        @request_id = nil
        @current_context = {}
        @mutex = Mutex.new

        # v3.13.14: unbuffer stdout so logs reach `docker logs` / k8s
        # immediately. A non-TTY $stdout (every container) is block-buffered
        # by default — logs sat in the buffer until it filled or the process
        # exited, so operators "weren't getting logs". No-op when output is
        # file-only.
        $stdout.sync = true if @output != "file"

        # Build the file logger via stdlib Logger which handles rotation natively.
        # Logger.new(path, shift_age, shift_size):
        #   shift_age  = number of files to keep
        #   shift_size = bytes before rotation
        # When @rotate_size is 0, omit rotation args.
        close_file_logger

        # TINA4_LOG_APPEND — append (default) or overwrite on startup.
        #
        # APPEND IS THE DEFAULT: a log you can lose by restarting the process is
        # not a log. Set it false when you want one file per run (a short CLI, a
        # test fixture, a container that ships logs elsewhere) and the file is
        # truncated once here at configure time, never per line.
        @append = ENV["TINA4_LOG_APPEND"].nil? || truthy?(ENV["TINA4_LOG_APPEND"])

        if @output != "stdout"
          unless @append
            [@log_file_path, File.join(@log_dir, "error.log")].each do |path|
              File.write(path, "") if File.exist?(path)
            end
          end
          @file_logger = build_file_logger(@log_file_path)

          # Mirror WARNING and above into a dedicated error.log so
          # `tail -f logs/error.log` gives just the stuff worth looking at.
          # Ruby wrote ONE file where Python and PHP wrote two, so anyone whose
          # alerting tails error.log got silence here (feature 2 of the audit,
          # D3). Skipped when the operator named an explicit TINA4_LOG_FILE:
          # they asked for one file at one path, so a sibling error.log
          # appearing next to it would be a surprise.
          @error_logger = if explicit_file
                            nil
                          else
                            build_file_logger(File.join(@log_dir, "error.log"))
                          end
        end

        @initialized = true
      end

      def set_request_id(id)
        @mutex.synchronize { @request_id = id }
      end

      def clear_request_id
        @mutex.synchronize { @request_id = nil }
      end

      def get_request_id
        @mutex.synchronize { @request_id }
      end

      def json_mode?
        @json_mode
      end

      # Would a message at `level` pass the configured MINIMUM CONSOLE LEVEL
      # (TINA4_LOG_LEVEL)? Returns true iff `log` would print it to stdout —
      # it reflects CONSOLE visibility only. The log FILE records every level
      # regardless of this threshold, so this never gates file output.
      #
      # `level` accepts a String or Symbol and is case-insensitive
      # ("INFO", :info, "Warning", :warning all work). Mirrors Python's
      # Log.is_enabled. It REUSES the exact severity >= @console_level
      # comparison the console branch in `log` uses (line ~167) via
      # SEVERITY_MAP / resolve_level — it never re-implements level
      # comparison, so it can never disagree with what the logger prints.
      #
      # "critical" is a FIRST-CLASS top-level severity (4 — above error 3),
      # not a parity alias for error. It is evaluated with ordinary threshold
      # logic (critical 4 >= @console_level), so it passes at every level
      # except none (5) — matching the Python master.
      def enabled?(level)
        sym = normalize_level(level)
        severity = SEVERITY_MAP[sym] || 0
        severity >= console_level
      end

      def info(message, context = {})
        log(:info, message, context)
      end

      def debug(message, context = {})
        log(:debug, message, context)
      end

      def warning(message, context = {})
        log(:warn, message, context)
      end

      def error(message, context = {})
        log(:error, message, context)
      end

      # critical is the HIGHEST severity (4, above error). Like every other
      # level it ALWAYS emits, subject only to the TINA4_LOG_LEVEL threshold
      # (which critical passes at every level except none). A critical log is
      # never a silent no-op. Mirrors the Python master.
      def critical(message, context = {})
        log(:critical, message, context)
      end

      # Test/teardown helper — closes the underlying Logger so the file
      # handle is released (Windows / tmpdir cleanup).
      def close_file_logger
        @file_logger&.close rescue nil
        @file_logger = nil
        @error_logger&.close rescue nil
        @error_logger = nil
      end

      private

      def truthy?(val)
        Tina4::Env.is_truthy(val)
      end

      def production?
        env = ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
        env.downcase == "production"
      end

      def log(level, message, context = {})
        configure unless @initialized
        @current_context = context.is_a?(Hash) ? context : {}

        # Coerce FIRST. Anything can arrive as a message: a Hash from a handler,
        # a binary payload off a socket, a 10MB string. See coerce_message.
        message = coerce_message(message)
        formatted = format_line(level, message)

        # Console output respects TINA4_LOG_LEVEL and TINA4_LOG_OUTPUT
        severity = SEVERITY_MAP[level] || 0
        if severity >= @console_level && @output != "file"
          # Truncate on the CONSOLE only. The file keeps the full line so a
          # consumer parsing it loses nothing; a terminal does not need 10MB.
          if @json_mode
            $stdout.puts truncate_for_stdout(json_line(level, message))
          else
            $stdout.puts colorize(level, truncate_for_stdout(formatted))
          end
        end

        # File output — always full level (consumer parses themselves) — unless disabled.
        if @output != "stdout" && @file_logger
          payload = @json_mode ? json_line(level, message) : strip_ansi(formatted)
          write_to_file(payload, level)
        end

        @current_context = {}
      end

      # The current minimum console level as an integer (the same value
      # the console branch in `log` compares against). Ensures the logger
      # is configured so `enabled?` works before any log call has run.
      def console_level
        configure unless @initialized
        @console_level
      end

      # Map a level (String or Symbol, case-insensitive) onto the symbol
      # space used by SEVERITY_MAP. Accepts the public method names
      # (debug/info/warning/error/critical) and the internal :warn symbol.
      # critical is a FIRST-CLASS level (severity 4), not an alias for error.
      # Unknown levels fall through to their own symbol and resolve to
      # severity 0 in `enabled?`.
      def normalize_level(level)
        sym = level.to_s.strip.downcase.to_sym
        case sym
        when :warning then :warn
        else sym
        end
      end

      def resolve_level
        # v3.13.14: default is INFO (was ALL) so a deployed app surfaces
        # request/startup/warn/error without debug noise, matching
        # Python/PHP/Node. Accept BOTH the legacy bracket form
        # ("[TINA4_LOG_ERROR]") AND plain names ("ERROR") so the env value
        # is portable across all four frameworks.
        raw = (ENV["TINA4_LOG_LEVEL"] || "").strip
        return 1 if raw.empty? # INFO
        key = raw.start_with?("[") ? raw.upcase : "[TINA4_LOG_#{raw.upcase}]"
        LEVELS[key] || 1
      end

      def severity_to_level(level)
        case level
        when :debug then "DEBUG"
        when :info  then "INFO"
        when :warn  then "WARNING"
        when :error then "ERROR"
        when :critical then "CRITICAL"
        else level.to_s.upcase
        end
      end

      def utc_timestamp
        now = Time.now.utc
        now.strftime("%Y-%m-%dT%H:%M:%S.") + format("%03d", now.usec / 1000) + "Z"
      end

      def strip_ansi(text)
        text.gsub(ANSI_RE, "")
      end

      def format_line(level, message)
        level_str = severity_to_level(level)
        ts = utc_timestamp
        rid = get_request_id
        rid_str = rid ? " [#{rid}]" : ""
        fn = caller_name
        fn_str = fn ? " [#{fn}]" : ""
        ctx = @current_context && !@current_context.empty? ? " #{JSON.generate(@current_context)}" : ""
        # Pad to 8, not 7: CRITICAL is eight characters, so a 7-wide column was
        # broken by our own highest level. 8 is the only width that fits every
        # level name. Cross-framework format table (feature 2 of the audit).
        "#{ts} [#{level_str.ljust(8)}]#{rid_str}#{fn_str} #{message}#{ctx}"
      end

      def json_line(level, message)
        level_str = severity_to_level(level)
        entry = {
          timestamp: utc_timestamp,
          level: level_str,
          message: message
        }
        rid = get_request_id
        entry[:request_id] = rid if rid
        fn = caller_name
        entry[:function] = fn if fn
        entry[:context] = @current_context if @current_context && !@current_context.empty?
        JSON.generate(entry)
      end

      # Names that belong to Log itself — walk past them so the reported
      # frame is the real caller (e.g. the route handler or service
      # method that called Log.info). Kept as a Set for O(1) lookup.
      OWN_FRAMES = %w[
        caller_name format_line json_line log colorize write_to_file
        debug info warning error critical
      ].freeze

      # Names that are noise — Ruby block labels, lambdas, top-level
      # script frames. We skip these the same way Python skips <module>
      # and <lambda>.
      NOISE_FRAME_RE = /\A(?:block(?: \(\d+ levels\))? in |<top \(required\)>|<main>)/

      # Return the name of the function that called Log.{debug,info,warning,error}.
      # Active only when TINA4_LOG_FUNC=true (parity feature #41).
      # Returns nil on any error so it never crashes a log call.
      def caller_name
        return nil unless Tina4::Env.bool("TINA4_LOG_FUNC")

        # caller_locations(2, 16) skips this method + log() and gives us
        # up to 16 frames to walk. We bail out the moment we hit a frame
        # whose base_label isn't in OWN_FRAMES and isn't a block label.
        locs = caller_locations(2, 16) || []
        locs.each do |loc|
          label = loc.base_label.to_s
          next if OWN_FRAMES.include?(label)
          next if label.empty? || NOISE_FRAME_RE.match?(label)
          return label
        end
        nil
      rescue StandardError
        nil
      end

      def colorize(level, line)
        color = case level
                when :debug   then COLORS[:cyan]
                when :info    then COLORS[:green]
                when :warn    then COLORS[:yellow]
                when :error   then COLORS[:red]
                when :critical then COLORS[:magenta]
                else COLORS[:reset]
                end
        "#{color}#{line}#{COLORS[:reset]}"
      end

      # Build one rotating file logger. stdlib Logger handles rotation natively:
      #   Logger.new(path, shift_age, shift_size)  — files to keep, bytes before roll.
      # With @rotate_size 0 the rotation args are omitted. tina4.log and error.log
      # each get their own logger so they rotate independently.
      # Turn anything into a single safe line of text.
      #
      # A String passes through when it is valid UTF-8. Binary is described
      # rather than dumped: raw bytes at a terminal garble it and can emit
      # escape sequences. Anything else becomes JSON, because a Hash rendered as
      # text is the whole reason the caller logged it, falling back to inspect
      # for a value JSON cannot represent. The logger must never be the reason a
      # request dies.
      def coerce_message(message)
        text = case message
               when String
                 if message.encoding == Encoding::BINARY || !message.valid_encoding?
                   utf8 = message.dup.force_encoding(Encoding::UTF_8)
                   return "<binary #{message.bytesize} bytes>" unless utf8.valid_encoding?
                   utf8
                 else
                   message
                 end
               when Hash, Array
                 begin
                   JSON.generate(message)
                 rescue StandardError
                   message.inspect
                 end
               when nil
                 ""
               else
                 message.respond_to?(:to_s) ? message.to_s : message.inspect
               end
        text.gsub(CONTROL_CHARS, "")
      end

      def truncate_for_stdout(line)
        return line if line.length <= STDOUT_MAX_CHARS
        "#{line[0, STDOUT_MAX_CHARS]}... (truncated, #{line.length} chars)"
      end

      # Is this target a FILE PATH or a DIRECTORY?
      #
      # An existing directory is always a directory, extension or not. Otherwise
      # a basename with an extension (app.log, app.txt) is a file and anything
      # else is a directory to create. That keeps `configure("/var/log/myapp")`
      # a directory and `configure("/var/log/myapp/app.log")` a file without
      # needing the path to exist yet.
      def target_is_file?(path)
        return false if File.directory?(path)
        File.extname(path) != ""
      end

      def build_file_logger(path)
        # In strict mode ask ::Logger to let a real write error through instead
        # of warning on stderr and returning (see STRICT_WRITE_ERRORS). Empty
        # otherwise, which is the stdlib default, so the non-strict path behaves
        # byte for byte as it always has.
        reraise = @strict ? STRICT_WRITE_ERRORS : []
        logger = if @rotate_size > 0
                   ::Logger.new(path, @rotate_keep, @rotate_size, reraise_write_errors: reraise)
                 else
                   ::Logger.new(path, reraise_write_errors: reraise)
                 end
        # We do our own formatting — strip Logger's default formatter.
        logger.formatter = proc { |_sev, _t, _p, msg| msg.to_s.end_with?("\n") ? msg : "#{msg}\n" }
        logger
      end

      def write_to_file(line, level = nil)
        return unless @file_logger
        # Use << to bypass Logger's severity filtering — we already filtered above.
        @file_logger << "#{line}\n"
        # WARNING and above only. Matches the Python master and PHP, which both
        # mirror warning+ rather than error+ -- error.log is "the stuff worth
        # looking at", and a warning qualifies.
        if @error_logger && level && (SEVERITY_MAP[level] || 0) >= SEVERITY_MAP[:warn]
          @error_logger << "#{line}\n"
        end
      rescue IOError, SystemCallError => e
        raise if @strict
        # Don't crash on log write failure
      end
    end
  end
end
