# frozen_string_literal: true
require "logger"
require "fileutils"

module Tina4
  module Debug
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

    class << self
      def setup(root_dir = Dir.pwd)
        log_dir = File.join(root_dir, "logs")
        FileUtils.mkdir_p(log_dir)
        log_file = File.join(log_dir, "debug.log")
        @file_logger = Logger.new(log_file, 10, 5 * 1024 * 1024)
        @file_logger.level = Logger::DEBUG
        @console_logger = Logger.new($stdout)
        @console_logger.level = resolve_level
        @console_logger.formatter = method(:color_formatter)
        @file_logger.formatter = method(:plain_formatter)
        @initialized = true
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
        "#{COLORS[:gray]}[#{ts}]#{COLORS[:reset]} #{color}[#{severity}]#{COLORS[:reset]} #{message}\n"
      end

      def plain_formatter(severity, datetime, _progname, message)
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] #{message}\n"
      end
    end
  end
end
