# frozen_string_literal: true

require "logger"
require "fileutils"
require "json"
require "zlib"

module Tina4
  module Log
    LEVELS = {
      "[TINA4_LOG_ALL]" => Logger::DEBUG,
      "[TINA4_LOG_DEBUG]" => Logger::DEBUG,
      "[TINA4_LOG_INFO]" => Logger::INFO,
      "[TINA4_LOG_WARNING]" => Logger::WARN,
      "[TINA4_LOG_ERROR]" => Logger::ERROR,
      "[TINA4_LOG_NONE]" => Logger::FATAL
    }.freeze

    COLORS = {
      reset: "\e[0m", red: "\e[31m", green: "\e[32m",
      yellow: "\e[33m", blue: "\e[34m", magenta: "\e[35m",
      cyan: "\e[36m", gray: "\e[90m"
    }.freeze

    # Default max log file size: 10 MB
    DEFAULT_MAX_SIZE = 10 * 1024 * 1024

    # Number of rotated files to keep before gzip
    DEFAULT_KEEP_FILES = 10

    class << self
      attr_reader :log_dir

      def setup(root_dir = Dir.pwd)
        @log_dir = File.join(root_dir, "logs")
        FileUtils.mkdir_p(@log_dir)

        @max_size = (ENV["TINA4_LOG_MAX_SIZE"] || DEFAULT_MAX_SIZE).to_i
        @json_mode = production?

        log_file = File.join(@log_dir, "debug.log")
        @file_logger = Logger.new(log_file, DEFAULT_KEEP_FILES, @max_size)
        @file_logger.level = Logger::DEBUG
        @file_logger.formatter = method(:file_formatter)

        @console_logger = Logger.new($stdout)
        @console_logger.level = resolve_level
        @console_logger.formatter = @json_mode ? method(:json_formatter) : method(:color_formatter)

        @request_id = nil
        @current_context = {}
        @mutex = Mutex.new
        @initialized = true

        # Compress old rotated log files on startup
        compress_old_logs
      end

      def set_request_id(id)
        @mutex.synchronize { @request_id = id }
      end

      def clear_request_id
        @mutex.synchronize { @request_id = nil }
      end

      def request_id
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
        setup unless @initialized
        @current_context = context.is_a?(Hash) ? context : {}
        @console_logger.send(level, message.to_s)
        @file_logger.send(level, message.to_s)
        @current_context = {}
      end

      def resolve_level
        env_level = ENV["TINA4_DEBUG_LEVEL"] || "[TINA4_LOG_ALL]"
        LEVELS[env_level] || Logger::DEBUG
      end

      def severity_to_level(severity)
        severity == "WARN" ? "WARNING" : severity
      end

      def utc_timestamp
        now = Time.now.utc
        now.strftime("%Y-%m-%dT%H:%M:%S.") + format("%03d", now.usec / 1000) + "Z"
      end

      def color_formatter(severity, _datetime, _progname, message)
        level = severity_to_level(severity)
        color = case level
                when "DEBUG"   then COLORS[:cyan]
                when "INFO"    then COLORS[:green]
                when "WARNING" then COLORS[:yellow]
                when "ERROR"   then COLORS[:red]
                else COLORS[:reset]
                end
        ts = utc_timestamp
        rid = request_id
        rid_str = rid ? " [#{rid}]" : ""
        ctx = @current_context && !@current_context.empty? ? " #{JSON.generate(@current_context)}" : ""
        "#{color}#{ts} [#{level.ljust(7)}]#{rid_str} #{message}#{ctx}#{COLORS[:reset]}\n"
      end

      def json_formatter(severity, _datetime, _progname, message)
        level = severity_to_level(severity)
        entry = {
          timestamp: utc_timestamp,
          level: level,
          message: message
        }
        rid = request_id
        entry[:request_id] = rid if rid
        entry[:context] = @current_context if @current_context && !@current_context.empty?
        "#{JSON.generate(entry)}\n"
      end

      def file_formatter(severity, _datetime, _progname, message)
        if @json_mode
          json_formatter(severity, _datetime, nil, message)
        else
          level = severity_to_level(severity)
          ts = utc_timestamp
          rid = request_id
          rid_str = rid ? " [#{rid}]" : ""
          ctx = @current_context && !@current_context.empty? ? " #{JSON.generate(@current_context)}" : ""
          "#{ts} [#{level.ljust(7)}]#{rid_str} #{message}#{ctx}\n"
        end
      end

      def compress_old_logs
        return unless @log_dir && Dir.exist?(@log_dir)

        Dir.glob(File.join(@log_dir, "debug.log.*")).each do |rotated|
          next if rotated.end_with?(".gz")
          next unless File.file?(rotated)

          gz_path = "#{rotated}.gz"
          next if File.exist?(gz_path)

          begin
            Zlib::GzipWriter.open(gz_path) do |gz|
              File.open(rotated, "rb") do |f|
                while (chunk = f.read(65_536))
                  gz.write(chunk)
                end
              end
            end
            File.delete(rotated)
          rescue => e
            # Don't crash on compression failure
            $stderr.puts "Log compression failed for #{rotated}: #{e.message}"
          end
        end
      end
    end
  end
end
