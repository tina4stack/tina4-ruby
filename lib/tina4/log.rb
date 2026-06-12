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
      "[TINA4_LOG_NONE]" => 4
    }.freeze

    SEVERITY_MAP = {
      debug: 0, info: 1, warn: 2, error: 3
    }.freeze

    COLORS = {
      reset: "\e[0m", red: "\e[31m", green: "\e[32m",
      yellow: "\e[33m", blue: "\e[34m", magenta: "\e[35m",
      cyan: "\e[36m", gray: "\e[90m"
    }.freeze

    # ANSI escape code regex for stripping from file output
    ANSI_RE = /\033\[[0-9;]*m/

    # Defaults used when env vars are unset.
    DEFAULT_ROTATE_SIZE = 10 * 1024 * 1024 # 10MB
    DEFAULT_ROTATE_KEEP = 5

    class << self
      attr_reader :log_dir, :log_file_path

      def configure(root_dir = Dir.pwd)
        # TINA4_LOG_DIR — relative or absolute. Default "logs".
        log_dir_env = ENV["TINA4_LOG_DIR"]
        log_dir_env = "logs" if log_dir_env.nil? || log_dir_env.empty?
        @log_dir = if File.absolute_path?(log_dir_env)
                     log_dir_env
                   else
                     File.join(root_dir, log_dir_env)
                   end
        FileUtils.mkdir_p(@log_dir)

        # TINA4_LOG_FILE — explicit log file path (absolute or relative to log_dir).
        # Default: <log_dir>/tina4.log.
        log_file_env = ENV["TINA4_LOG_FILE"]
        @log_file_path = if log_file_env && !log_file_env.empty?
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

        # TINA4_LOG_OUTPUT — "stdout", "file", or "both". Defaults to "both".
        output_env = ENV["TINA4_LOG_OUTPUT"]
        @output = output_env && !output_env.empty? ? output_env.downcase : "both"
        unless %w[stdout file both].include?(@output)
          @output = "both"
        end

        # TINA4_LOG_CRITICAL — when true, raise on log write failures instead of swallowing.
        @critical = truthy?(ENV["TINA4_LOG_CRITICAL"])

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
        if @output != "stdout"
          @file_logger = if @rotate_size > 0
                           ::Logger.new(@log_file_path, @rotate_keep, @rotate_size)
                         else
                           ::Logger.new(@log_file_path)
                         end
          # We do our own formatting — strip Logger's default formatter.
          @file_logger.formatter = proc { |_sev, _t, _p, msg| msg.to_s.end_with?("\n") ? msg : "#{msg}\n" }
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

      # Test/teardown helper — closes the underlying Logger so the file
      # handle is released (Windows / tmpdir cleanup).
      def close_file_logger
        @file_logger&.close rescue nil
        @file_logger = nil
      end

      private

      def truthy?(val)
        %w[true 1 yes on].include?(val.to_s.strip.downcase)
      end

      def production?
        env = ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
        env.downcase == "production"
      end

      def log(level, message, context = {})
        configure unless @initialized
        @current_context = context.is_a?(Hash) ? context : {}

        formatted = format_line(level, message)

        # Console output respects TINA4_LOG_LEVEL and TINA4_LOG_OUTPUT
        severity = SEVERITY_MAP[level] || 0
        if severity >= @console_level && @output != "file"
          if @json_mode
            $stdout.puts json_line(level, message)
          else
            $stdout.puts colorize(level, formatted)
          end
        end

        # File output — always full level (consumer parses themselves) — unless disabled.
        if @output != "stdout" && @file_logger
          payload = @json_mode ? json_line(level, message) : strip_ansi(formatted)
          write_to_file(payload)
        end

        @current_context = {}
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
        "#{ts} [#{level_str.ljust(7)}]#{rid_str}#{fn_str} #{message}#{ctx}"
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
                else COLORS[:reset]
                end
        "#{color}#{line}#{COLORS[:reset]}"
      end

      def write_to_file(line)
        return unless @file_logger
        # Use << to bypass Logger's severity filtering — we already filtered above.
        @file_logger << "#{line}\n"
      rescue IOError, SystemCallError => e
        raise if @critical
        # Don't crash on log write failure
      end
    end
  end
end
