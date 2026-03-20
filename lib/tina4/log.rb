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

      def info(message, *args)
        log(:info, message, *args)
      end

      def debug(message, *args)
        log(:debug, message, *args)
      end

      def warning(message, *args)
        log(:warn, message, *args)
      end

      def error(message, *args)
        log(:error, message, *args)
      end

      private

      def production?
        env = ENV["TINA4_ENV"] || ENV["RACK_ENV"] || ENV["RUBY_ENV"] || "development"
        env.downcase == "production"
      end

      def log(level, message, *args)
        setup unless @initialized
        full_message = args.empty? ? message.to_s : "#{message} #{args.map(&:to_s).join(' ')}"
        @console_logger.send(level, full_message)
        @file_logger.send(level, full_message)
      end

      def resolve_level
        env_level = ENV["TINA4_DEBUG_LEVEL"] || "[TINA4_LOG_ALL]"
        LEVELS[env_level] || Logger::DEBUG
      end

      def color_formatter(severity, datetime, _progname, message)
        color = case severity
                when "DEBUG" then COLORS[:gray]
                when "INFO"  then COLORS[:green]
                when "WARN"  then COLORS[:yellow]
                when "ERROR" then COLORS[:red]
                else COLORS[:reset]
                end
        ts = datetime.strftime("%Y-%m-%d %H:%M:%S")
        rid = request_id
        rid_str = rid ? " #{COLORS[:cyan]}[#{rid}]#{COLORS[:reset]}" : ""
        "#{COLORS[:gray]}[#{ts}]#{COLORS[:reset]} #{color}[#{severity}]#{COLORS[:reset]}#{rid_str} #{message}\n"
      end

      def json_formatter(severity, datetime, _progname, message)
        entry = {
          timestamp: datetime.iso8601(3),
          level: severity.downcase,
          message: message,
          framework: "tina4-ruby",
          version: Tina4::VERSION
        }
        rid = request_id
        entry[:request_id] = rid if rid
        "#{JSON.generate(entry)}\n"
      end

      def file_formatter(severity, datetime, _progname, message)
        if @json_mode
          json_formatter(severity, datetime, nil, message)
        else
          rid = request_id
          rid_str = rid ? " [#{rid}]" : ""
          "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}]#{rid_str} #{message}\n"
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
