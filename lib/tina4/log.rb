# frozen_string_literal: true

require "fileutils"
require "json"

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

    class << self
      attr_reader :log_dir

      def configure(root_dir = Dir.pwd)
        @log_dir = File.join(root_dir, "logs")
        FileUtils.mkdir_p(@log_dir)

        @max_size_mb = (ENV["TINA4_LOG_MAX_SIZE"] || "10").to_i
        @max_size = @max_size_mb * 1024 * 1024
        @keep = (ENV["TINA4_LOG_KEEP"] || "5").to_i
        @json_mode = production?
        @log_file = File.join(@log_dir, "tina4.log")

        @console_level = resolve_level
        @request_id = nil
        @current_context = {}
        @mutex = Mutex.new
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

      private

      def production?
        env = ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
        env.downcase == "production"
      end

      def log(level, message, context = {})
        configure unless @initialized
        @current_context = context.is_a?(Hash) ? context : {}

        formatted = format_line(level, message)

        # Console output respects TINA4_LOG_LEVEL
        severity = SEVERITY_MAP[level] || 0
        if severity >= @console_level
          if @json_mode
            $stdout.puts json_line(level, message)
          else
            $stdout.puts colorize(level, formatted)
          end
        end

        # File always gets ALL levels, plain text (no ANSI)
        write_to_file(strip_ansi(formatted))

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
        rotate_if_needed
        begin
          File.open(@log_file, "a") { |f| f.puts(line) }
        rescue IOError, SystemCallError
          # Don't crash on log write failure
        end
      end

      # Numbered rotation: tina4.log → tina4.log.1 → tina4.log.2 → ... → tina4.log.{keep}
      def rotate_if_needed
        return unless File.exist?(@log_file)

        begin
          return if File.size(@log_file) < @max_size
        rescue SystemCallError
          return
        end

        # Delete the oldest rotated file if it exists
        oldest = "#{@log_file}.#{@keep}"
        File.delete(oldest) if File.exist?(oldest)

        # Shift existing rotated files: .{n} → .{n+1}
        (@keep - 1).downto(1) do |n|
          src = "#{@log_file}.#{n}"
          dst = "#{@log_file}.#{n + 1}"
          File.rename(src, dst) if File.exist?(src)
        end

        # Rename current log to .1
        File.rename(@log_file, "#{@log_file}.1") rescue nil
      end
    end
  end
end
