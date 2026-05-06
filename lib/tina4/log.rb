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
        env_level = ENV["TINA4_LOG_LEVEL"] || "[TINA4_LOG_ALL]"
        LEVELS[env_level] || 0
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
        ctx = @current_context && !@current_context.empty? ? " #{JSON.generate(@current_context)}" : ""
        "#{ts} [#{level_str.ljust(7)}]#{rid_str} #{message}#{ctx}"
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
        entry[:context] = @current_context if @current_context && !@current_context.empty?
        JSON.generate(entry)
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
