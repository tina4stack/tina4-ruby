# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"

module Tina4
  # Invalid setting, removed setting, or an inaccessible selected sink.
  class LogConfigurationError < ArgumentError
    attr_accessor :setting, :value, :accepted, :sink, :operation

    def initialize(message, setting: nil, value: nil, accepted: nil, sink: nil, operation: nil)
      super(message)
      @setting = setting
      @value = value
      @accepted = accepted
      @sink = sink
      @operation = operation
    end
  end

  # Invalid argument to a public logger method.
  class LogArgumentError < ArgumentError
    attr_accessor :argument, :accepted

    def initialize(message, argument: nil, accepted: nil)
      super(message)
      @argument = argument
      @accepted = accepted
    end
  end

  # A selected sink failed after configuration succeeded, under strict mode.
  class LogWriteError < RuntimeError
    attr_accessor :sink, :operation

    def initialize(message, sink: nil, operation: nil)
      super(message)
      @sink = sink
      @operation = operation
    end
  end

  # One owned log file: bounded, PREDICTIVE rotation guarded by a single
  # in-process (thread) exclusive lock over the size check, rotation and
  # append.
  #
  # Decision 20 (2026-08-10 owner override): SINGLE FILE + IN-PROCESS LOCK
  # ONLY. Cross-process exclusive locking is deliberately not implemented;
  # concurrent PROCESSES writing the same file may interleave. Run one file
  # per process, or route through a log shipper, for that case.
  class LogFileSink
    LOCK_TIMEOUT_SECONDS = 2.0

    attr_reader :path

    def initialize(path, rotate_size, rotate_keep)
      @path = path
      @rotate_size = rotate_size
      @rotate_keep = rotate_keep
      @mutex = Mutex.new
    end

    # Create the directory and prove the file is writable.
    def open
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)
      File.open(@path, "a") {}
    rescue SystemCallError, IOError => e
      raise LogConfigurationError.new(
        "cannot open log sink #{@path}: #{e.message}", sink: @path, operation: "open"
      )
    end

    def rotate_if_needed(next_record_bytes)
      current_size = File.exist?(@path) ? File.size(@path) : 0
      return if current_size.zero?
      return if current_size + next_record_bytes <= @rotate_size

      if @rotate_keep <= 0
        File.delete(@path)
        return
      end

      oldest = "#{@path}.#{@rotate_keep}"
      File.delete(oldest) if File.exist?(oldest)
      (@rotate_keep - 1).downto(1) do |n|
        src = "#{@path}.#{n}"
        dst = "#{@path}.#{n + 1}"
        File.rename(src, dst) if File.exist?(src)
      end
      File.rename(@path, "#{@path}.1")
    end

    # Append one complete encoded record, rotating first if it would cross
    # the threshold. Raises LogWriteError (timeout/write) to the caller,
    # which applies the sink failure policy.
    def write(encoded_line)
      clean = encoded_line.gsub(/\e\[[0-9;]*m/, "")
      payload = clean.b

      acquired = try_lock_with_timeout
      raise LogWriteError.new("timed out acquiring the log sink lock for #{@path}", sink: @path, operation: "lock") unless acquired

      begin
        rotate_if_needed(payload.bytesize)
        File.open(@path, "ab") { |f| f.write(payload) }
      rescue SystemCallError, IOError => e
        raise LogWriteError.new("cannot write log sink #{@path}: #{e.message}", sink: @path, operation: "write")
      ensure
        @mutex.unlock if @mutex.owned?
      end
    end

    def close; end

    private

    def try_lock_with_timeout
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_TIMEOUT_SECONDS
      until @mutex.try_lock
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(0.005)
      end
      true
    end
  end

  # Structured logger. Conformant to the shared cross-framework contract at
  # plan/v3/fixtures/logger_contract.json (feature 2), decided in
  # plan/v3/features/002-structured-logger.md and ADR-0041.
  #
  # BREAKING CHANGES from the pre-3.14 logger (this pass, 2026-08-13):
  #
  #  * Format defaults to JSON in production and TEXT only when TINA4_DEBUG
  #    is truthy (Decision 3) -- unchanged in spirit, restated as the shared
  #    contract's canonical rule.
  #  * TINA4_LOG_APPEND is REMOVED -- setting it is now a hard configuration
  #    error.
  #  * TINA4_LOG_STRICT / TINA4_LOG_FUNC accept ONLY the literal tokens
  #    "true"/"false" (case-insensitive) -- not "1"/"yes"/"on" (Decision 19:
  #    "native booleans, not private truth-token parsing").
  #  * The legacy bracket level spelling ("[TINA4_LOG_ERROR]") is REMOVED --
  #    it now hard-fails configuration; use the plain name ("ERROR").
  #  * Embedded CR/LF in a message is now ESCAPED in text format rather than
  #    passed through raw (Decision 11), and rotation is delegated to a
  #    hand-written, PREDICTIVE, byte-exact LogFileSink rather than stdlib
  #    ::Logger (whose backup numbering starts at ".0", not ".1", and whose
  #    rotation is reactive).
  #  * New TINA4_LOG_FILE_LEVEL (default ALL) independently gates the FILE
  #    sink; TINA4_LOG_LEVEL now gates the CONSOLE only (2026-08-10 owner
  #    override of Decision 8). `enabled?` accepts an optional sink: and is
  #    sink-aware.
  #  * `reset` is new: flushes/closes owned sinks and clears the snapshot AND
  #    the current thread's request id.
  #  * `close_file_logger` is removed (LOG-A02 prohibits it); `reset` is the
  #    one lifecycle method now.
  module Log
    LEVELS = { "ALL" => 0, "DEBUG" => 1, "INFO" => 2, "WARNING" => 3, "ERROR" => 4, "CRITICAL" => 5, "NONE" => 6 }.freeze
    DEFAULT_LEVEL = "INFO"
    DEFAULT_FILE_LEVEL = "ALL"
    DEFAULT_ROTATE_SIZE = 10 * 1024 * 1024
    DEFAULT_ROTATE_KEEP = 5
    MIN_ROTATE_SIZE = 1024
    STDOUT_MAX_BYTES = 8192
    OVERFLOW_MESSAGE = "Log event omitted: encoded size exceeds sink limit"

    REMOVED_SETTINGS = {
      "TINA4_LOG_MAX_SIZE" => "removed setting -- use TINA4_LOG_ROTATE_SIZE (bytes, not megabytes)",
      "TINA4_LOG_KEEP" => "removed setting -- use TINA4_LOG_ROTATE_KEEP",
      "TINA4_LOG_APPEND" => "removed setting -- logs always append; truncate explicitly outside logger startup",
      "TINA4_DEBUG_LEVEL" => "removed setting -- use TINA4_LOG_LEVEL",
      "TINA4_LOG_CRITICAL" => "removed setting -- critical always emits, subject only to TINA4_LOG_LEVEL"
    }.freeze

    COLORS = { "DEBUG" => "\e[36m", "INFO" => "\e[32m", "WARNING" => "\e[33m", "ERROR" => "\e[31m", "CRITICAL" => "\e[35m" }.freeze
    RESET = "\e[0m"

    JSON_KEY_ORDER = %w[timestamp level message request_id function context].freeze
    CONTROL_CHARS = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.freeze

    class << self
      # ── configuration ──────────────────────────────────────────────

      # Resolve and activate a new configuration snapshot.
      #
      # Precedence for every field (ADR-0041): explicit argument, then the
      # matching TINA4_LOG_* environment value, then the built-in default.
      # Every field is validated BEFORE any directory is created or file is
      # opened; a failed reconfiguration leaves the prior snapshot untouched.
      def configure(log_dir: nil, log_file: nil, level: nil, file_level: nil, format: nil,
                     output: nil, rotate_size: nil, rotate_keep: nil, strict: nil, caller_capture: nil)
        REMOVED_SETTINGS.each do |name, hint|
          raise LogConfigurationError.new("#{name} is a removed setting -- #{hint}", setting: name, value: ENV[name]) if ENV.key?(name)
        end

        resolved_level = resolve_level(level, "TINA4_LOG_LEVEL", DEFAULT_LEVEL)
        resolved_file_level = resolve_level(file_level, "TINA4_LOG_FILE_LEVEL", DEFAULT_FILE_LEVEL)
        resolved_format = resolve_format(format)
        stdout_enabled, file_enabled = resolve_output(output)
        resolved_rotate_size = resolve_int(rotate_size, "TINA4_LOG_ROTATE_SIZE", DEFAULT_ROTATE_SIZE, MIN_ROTATE_SIZE)
        resolved_rotate_keep = resolve_int(rotate_keep, "TINA4_LOG_ROTATE_KEEP", DEFAULT_ROTATE_KEEP, 0)
        resolved_strict = resolve_bool(strict, "TINA4_LOG_STRICT", false)
        resolved_caller = resolve_bool(caller_capture, "TINA4_LOG_FUNC", false)

        dir_raw = resolve_str(log_dir, "TINA4_LOG_DIR", "logs", allow_empty: false)
        file_raw = resolve_str(log_file, "TINA4_LOG_FILE", nil, allow_empty: true)

        project_root = Dir.pwd
        dir_candidate = dir_raw
        file_candidate = file_raw
        if file_candidate.nil? && target_is_file?(dir_candidate)
          file_candidate = File.basename(dir_candidate)
          dir_candidate = File.dirname(dir_candidate)
        end

        resolved_log_dir = File.absolute_path?(dir_candidate) ? dir_candidate : File.join(project_root, dir_candidate)
        resolved_log_dir = resolved_log_dir.chomp("/")

        if file_candidate && !file_candidate.empty?
          resolved_log_file = File.absolute_path?(file_candidate) ? file_candidate : File.join(resolved_log_dir, file_candidate)
          layout = "single"
        else
          resolved_log_file = nil
          layout = "directory"
        end

        output_selector = if stdout_enabled && file_enabled
                             "both"
                           else
                             file_enabled ? "file" : "stdout"
                           end

        snap = {
          level: resolved_level, file_level: resolved_file_level, format: resolved_format,
          output: output_selector, log_dir: resolved_log_dir, log_file: resolved_log_file,
          layout: layout, rotate_size: resolved_rotate_size, rotate_keep: resolved_rotate_keep,
          strict: resolved_strict, caller_capture: resolved_caller,
          stdout_enabled: stdout_enabled, file_enabled: file_enabled,
          main_sink: nil, error_sink: nil
        }

        if file_enabled
          if layout == "single"
            sink = LogFileSink.new(resolved_log_file, resolved_rotate_size, resolved_rotate_keep)
            sink.open
            snap[:main_sink] = sink
          else
            main_sink = LogFileSink.new(File.join(resolved_log_dir, "tina4.log"), resolved_rotate_size, resolved_rotate_keep)
            main_sink.open
            error_sink = LogFileSink.new(File.join(resolved_log_dir, "error.log"), resolved_rotate_size, resolved_rotate_keep)
            error_sink.open
            snap[:main_sink] = main_sink
            snap[:error_sink] = error_sink
          end
        end

        # v3.13.14: unbuffer stdout so logs reach `docker logs` / k8s
        # immediately -- a non-TTY $stdout (every container) is
        # block-buffered by default, so lines sat in the buffer until it
        # filled or the process exited.
        $stdout.sync = true if stdout_enabled

        @snapshot = snap
        @pid = Process.pid
        nil
      end

      # Flush/close owned sinks, clear the snapshot and the current thread's
      # request id. Idempotent; the next use resolves a fresh snapshot.
      def reset
        @snapshot = nil
        Thread.current[:tina4_request_id] = nil
        nil
      end

      # A defensive native-map copy of the effective, stable configuration.
      def configuration
        snap = ensure_snapshot
        {
          "level" => snap[:level], "file_level" => snap[:file_level], "format" => snap[:format],
          "output" => snap[:output], "log_dir" => snap[:log_dir], "log_file" => snap[:log_file],
          "layout" => snap[:layout], "rotate_size" => snap[:rotate_size], "rotate_keep" => snap[:rotate_keep],
          "strict" => snap[:strict], "caller" => snap[:caller_capture],
          "stdout_enabled" => snap[:stdout_enabled], "file_enabled" => snap[:file_enabled]
        }
      end

      # ── request id (thread-local; Decision 12) ───────────────────────

      def set_request_id(request_id)
        discard_state_if_forked
        Thread.current[:tina4_request_id] = request_id
      end

      def get_request_id
        discard_state_if_forked
        Thread.current[:tina4_request_id]
      end

      def clear_request_id
        Thread.current[:tina4_request_id] = nil
      end

      def sanitize_request_id(value)
        return nil if value.nil? || value.empty?
        return nil if value.length > 128
        return nil if value =~ /[^A-Za-z0-9._-]/

        value
      end

      # ── threshold ─────────────────────────────────────────────────

      # True when `level` passes the queried sink's threshold and that sink
      # is active. `sink:` is nil (console, the historical meaning),
      # :console/"console"/:stdout/"stdout", or :file/"file".
      def enabled?(level, sink: nil)
        raise LogArgumentError.new("enabled? requires a level", argument: "level") if level.nil?

        key = level.to_s.strip.upcase
        raise LogArgumentError.new("#{level.inspect} is not a valid level", argument: "level", accepted: LEVELS.keys) unless LEVELS.key?(key)

        snap = ensure_snapshot
        sink_key = sink.nil? ? nil : sink.to_s
        case sink_key
        when nil, "console", "stdout"
          snap[:stdout_enabled] && LEVELS[key] >= LEVELS[snap[:level]]
        when "file"
          snap[:file_enabled] && LEVELS[key] >= LEVELS[snap[:file_level]]
        else
          raise LogArgumentError.new("#{sink.inspect} is not a valid sink", argument: "sink", accepted: %w[console file])
        end
      end

      # ── event methods (Decision 23, section 5) ───────────────────────

      def debug(message, context = {})
        emit("DEBUG", message, context)
      end

      def info(message, context = {})
        emit("INFO", message, context)
      end

      def warning(message, context = {})
        emit("WARNING", message, context)
      end

      def error(message, context = {})
        emit("ERROR", message, context)
      end

      # Critical -- the highest severity. Always emitted, subject only to
      # the configured threshold.
      def critical(message, context = {})
        emit("CRITICAL", message, context)
      end

      private

      def emit(level, message, context)
        snap = ensure_snapshot
        console_ok = snap[:stdout_enabled] && LEVELS[level] >= LEVELS[snap[:level]]
        file_ok = snap[:file_enabled] && LEVELS[level] >= LEVELS[snap[:file_level]]
        return unless console_ok || file_ok

        request_id = Thread.current[:tina4_request_id]
        caller_name = snap[:caller_capture] ? resolve_caller_name : nil
        event = build_event(level, message, request_id, caller_name, context)

        if console_ok
          stdout_line = bounded_for_sink(event, snap[:format], STDOUT_MAX_BYTES).chomp("\n")
          plain = snap[:format] == "json" || !stdout_tty?
          color = plain ? "" : (COLORS[level] || "")
          reset_code = plain ? "" : RESET
          write_stdout("#{color}#{stdout_line}#{reset_code}\n")
        end

        if file_ok && snap[:main_sink]
          main_line = bounded_for_sink(event, snap[:format], snap[:rotate_size])
          write_sink(snap[:main_sink], main_line, snap[:strict])
          if snap[:layout] == "directory" && snap[:error_sink] && LEVELS[level] >= LEVELS["WARNING"]
            write_sink(snap[:error_sink], main_line, snap[:strict])
          end
        end
        nil
      end

      def write_stdout(line)
        $stdout.write(line)
        $stdout.flush
      end

      def write_sink(sink, line, strict)
        sink.write(line)
      rescue LogWriteError => e
        raise e if strict

        write_stdout("tina4: log sink #{sink.path} failed: #{e.message}\n")
      end

      def stdout_tty?
        $stdout.respond_to?(:tty?) && $stdout.tty?
      end

      # ── caller capture (Decision 16) ─────────────────────────────────

      OWN_FRAMES = %w[resolve_caller_name build_event emit debug info warning error critical].freeze
      NOISE_FRAME_RE = /\A(?:block(?: \(\d+ levels\))? in |<top \(required\)>|<main>)/.freeze

      def resolve_caller_name
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

      # ── native normalization (Decision 14, section 6) ────────────────

      def normalize(value, ancestors = [])
        return value if value.nil? || value == true || value == false

        case value
        when String
          decode_maybe_binary(value)
        when Integer
          value
        when Float
          value.finite? ? value : "[Unsupported]"
        when Array
          return "[Circular]" if ancestors.any? { |a| a.equal?(value) }

          nxt = ancestors + [value]
          value.map { |v| normalize(v, nxt) }
        when Hash
          return "[Circular]" if ancestors.any? { |a| a.equal?(value) }

          nxt = ancestors + [value]
          out = {}
          value.each { |k, v| out[k.to_s] = normalize(v, nxt) }
          out
        else
          "[Unsupported]"
        end
      end

      def decode_maybe_binary(str)
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

        utf8 = str.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        "<binary #{str.bytesize} bytes sha256=#{Digest::SHA256.hexdigest(str)}>"
      end

      def sort_keys_recursive(value)
        case value
        when Hash
          value.keys.sort.each_with_object({}) { |k, out| out[k] = sort_keys_recursive(value[k]) }
        when Array
          value.map { |v| sort_keys_recursive(v) }
        else
          value
        end
      end

      def compact_json(value)
        JSON.generate(value)
      end

      # The top-level `message` field: a string passes through; anything
      # else uses compact, key-sorted JSON spelling (Decision 14).
      def message_to_string(raw)
        return decode_maybe_binary(raw) if raw.is_a?(String)

        normalized = normalize(raw)
        return "null" if normalized.nil?
        return "true" if normalized == true
        return "false" if normalized == false
        return JSON.generate(normalized) if normalized.is_a?(Numeric)
        return compact_json(sort_keys_recursive(normalized)) if normalized.is_a?(Array) || normalized.is_a?(Hash)

        normalized.to_s # already a marker string
      end

      # Escape backslash, CR, LF (in that order) and strip other C0/DEL so a
      # text-format record is exactly one physical LF-terminated line
      # (Decision 11).
      ESCAPE_CHARS = /[\\\r\n]/.freeze

      # Escape backslash, CR, LF and strip other C0/DEL so a text-format
      # record is exactly one physical LF-terminated line (Decision 11). A
      # single combined regex + BLOCK replacement (not a string replacement
      # -- String#gsub treats "\\"/"\1" etc. in a string replacement
      # specially, which is exactly the kind of double-escaping bug this
      # needs to avoid) walks the original string once, so a
      # newly-introduced backslash from escaping \r or \n is never
      # re-scanned or double-escaped.
      def escape_text(str)
        out = str.gsub(ESCAPE_CHARS) do |c|
          case c
          when "\\" then '\\\\'
          when "\r" then '\r'
          when "\n" then '\n'
          end
        end
        out.gsub(CONTROL_CHARS, "")
      end

      # ── canonical event + encoding (Decision 15) ─────────────────────

      def timestamp_now
        now = Time.now.utc
        now.strftime("%Y-%m-%dT%H:%M:%S.") + format("%03d", now.usec / 1000) + "Z"
      end

      def build_event(level, message, request_id, caller_name, context)
        event = { "timestamp" => timestamp_now, "level" => level, "message" => message_to_string(message) }
        event["request_id"] = request_id if request_id && !request_id.empty?
        event["function"] = caller_name if caller_name && !caller_name.empty?
        if context && !context.empty?
          normalized_ctx = sort_keys_recursive(normalize(context))
          event["context"] = normalized_ctx if normalized_ctx && !normalized_ctx.empty?
        end
        event
      end

      def encode_json(event)
        ordered = {}
        JSON_KEY_ORDER.each { |k| ordered[k] = event[k] if event.key?(k) }
        "#{compact_json(ordered)}\n"
      end

      def encode_text(event)
        parts = [event["timestamp"], "[#{event['level'].ljust(8)}]"]
        parts << "[#{event['request_id']}]" if event.key?("request_id")
        parts << "[#{event['function']}]" if event.key?("function")
        parts << escape_text(event["message"])
        parts << compact_json(event["context"]) if event.key?("context")
        "#{parts.join(' ')}\n"
      end

      def encode(event, fmt)
        fmt == "json" ? encode_json(event) : encode_text(event)
      end

      def overflow_record(original_event, original_encoded, fmt)
        original_bytes = original_encoded.b
        replacement = {
          "timestamp" => original_event["timestamp"], "level" => original_event["level"],
          "message" => OVERFLOW_MESSAGE,
          "context" => { "truncated" => true, "original_bytes" => original_bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(original_bytes) }
        }
        encode(replacement, fmt)
      end

      def bounded_for_sink(event, fmt, max_bytes)
        encoded = encode(event, fmt)
        return encoded if encoded.b.bytesize <= max_bytes

        overflow_record(event, encoded, fmt)
      end

      # ── resolution helpers ────────────────────────────────────────

      # Delegates to the ONE shared env-truthiness table (Tina4::Env.is_truthy)
      # rather than a private list of its own. Log used to keep its own
      # y/t-inclusive list here, which is the EXACT historical bug
      # spec/dotenv_corpus_spec.rb exists to catch: TINA4_LOG_FUNC=y switched
      # function logging ON while TINA4_DEBUG=y left debug OFF, in the same
      # process, because two subsystems answered "is this truthy" two
      # different ways from the same .env.
      def truthy?(value)
        Tina4::Env.is_truthy(value)
      end

      def truthy_debug?
        truthy?(ENV["TINA4_DEBUG"])
      end

      def parse_bool_setting(name, default)
        return default unless ENV.key?(name)

        token = ENV[name].strip.downcase
        return true if token == "true"
        return false if token == "false"

        raise LogConfigurationError.new(
          "#{name}=#{ENV[name].inspect} is not a valid boolean; accepted: true, false",
          setting: name, value: ENV[name], accepted: %w[true false]
        )
      end

      def resolve_bool(explicit, env_name, default)
        return explicit unless explicit.nil?

        parse_bool_setting(env_name, default)
      end

      def resolve_level(explicit, env_name, default)
        if !explicit.nil?
          candidate = explicit.to_s
          source = "argument"
        elsif ENV.key?(env_name)
          candidate = ENV[env_name]
          source = env_name
        else
          return default
        end
        key = candidate.strip.upcase
        unless LEVELS.key?(key)
          raise LogConfigurationError.new(
            "#{source}=#{candidate.inspect} is not a valid level; accepted: #{LEVELS.keys}",
            setting: env_name, value: candidate, accepted: LEVELS.keys
          )
        end
        key
      end

      def resolve_format(explicit)
        if !explicit.nil?
          candidate = explicit.to_s.strip.downcase
          unless %w[text json].include?(candidate)
            raise LogConfigurationError.new("format=#{explicit.inspect} is not valid; accepted: text, json", setting: "TINA4_LOG_FORMAT", value: explicit, accepted: %w[text json])
          end
          return candidate
        end
        if ENV.key?("TINA4_LOG_FORMAT")
          candidate = ENV["TINA4_LOG_FORMAT"].strip.downcase
          unless %w[text json].include?(candidate)
            raise LogConfigurationError.new("TINA4_LOG_FORMAT=#{ENV['TINA4_LOG_FORMAT'].inspect} is not valid; accepted: text, json", setting: "TINA4_LOG_FORMAT", value: ENV["TINA4_LOG_FORMAT"], accepted: %w[text json])
          end
          return candidate
        end
        truthy_debug? ? "text" : "json"
      end

      def resolve_output(explicit)
        if !explicit.nil?
          candidate = explicit.to_s.strip.downcase
          source = "argument"
        elsif ENV.key?("TINA4_LOG_OUTPUT")
          candidate = ENV["TINA4_LOG_OUTPUT"].strip.downcase
          source = "TINA4_LOG_OUTPUT"
        else
          return [true, truthy_debug?]
        end
        unless %w[stdout file both].include?(candidate)
          raise LogConfigurationError.new("#{source}=#{candidate.inspect} is not valid; accepted: stdout, file, both", setting: "TINA4_LOG_OUTPUT", value: candidate, accepted: %w[stdout file both])
        end
        case candidate
        when "stdout" then [true, false]
        when "file" then [false, true]
        when "both" then [true, true]
        end
      end

      def resolve_int(explicit, env_name, default, minimum)
        if !explicit.nil?
          raise LogConfigurationError.new("#{env_name}=#{explicit.inspect} is not a valid integer", setting: env_name, value: explicit) unless explicit.is_a?(Integer)

          value = explicit
          source = "argument"
        elsif ENV.key?(env_name)
          raw = ENV[env_name]
          unless raw.strip =~ /\A-?\d+\z/
            raise LogConfigurationError.new("#{env_name}=#{raw.inspect} is not a valid integer", setting: env_name, value: raw)
          end
          value = raw.to_i
          source = env_name
        else
          return default
        end
        if !minimum.nil? && value < minimum
          raise LogConfigurationError.new("#{source}=#{value} must be >= #{minimum}", setting: env_name, value: value, accepted: ">= #{minimum}")
        end
        value
      end

      def resolve_str(explicit, env_name, default, allow_empty:)
        if !explicit.nil?
          raise LogConfigurationError.new("#{env_name} may not be an empty string", setting: env_name, value: explicit) if explicit.empty?
          raise LogConfigurationError.new("#{env_name} may not contain a NUL byte", setting: env_name, value: explicit) if explicit.include?("\0")

          return explicit
        end
        return default unless ENV.key?(env_name)

        raw = ENV[env_name]
        if raw.empty?
          raise LogConfigurationError.new("#{env_name} may not be an empty string", setting: env_name, value: raw) unless allow_empty

          return default
        end
        raise LogConfigurationError.new("#{env_name} may not contain a NUL byte", setting: env_name, value: raw) if raw.include?("\0")

        raw
      end

      def target_is_file?(path)
        return false if File.directory?(path)

        base = File.basename(path)
        base.include?(".") && !base.start_with?(".")
      end

      def ensure_snapshot
        discard_state_if_forked
        configure if @snapshot.nil?
        @snapshot
      end

      # Ruby has no built-in post-fork hook (Process.fork is a raw syscall
      # wrapper), so a forked child inherits every class-level ivar's value
      # at the instant of fork -- including an owned sink and any thread's
      # request id snapshot at fork time (Decision 24 / LOG-Q05 requires a
      # forked child to discard inherited state and resolve fresh).
      # Detecting "my PID changed since I last touched this state" lazily,
      # on every access, achieves the same observable effect as an eager
      # fork hook.
      def discard_state_if_forked
        current = Process.pid
        if !@pid.nil? && @pid != current
          @snapshot = nil
          Thread.current[:tina4_request_id] = nil
        end
        @pid = current
      end
    end
  end

  # Tina4::Debug (backward-compat alias) is defined once in lib/tina4/debug.rb,
  # not here, to avoid the "already initialized constant" redefinition warning.
end
