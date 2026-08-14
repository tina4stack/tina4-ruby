# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'

module Tina4
  class MetricsEngineError < StandardError; end

  # Thin dev-admin adapter for the native `tina4 metrics` engine (ADR-0054).
  module Metrics
    INSTALL_HINT = 'update the native tina4 CLI: https://tina4.com/cli'
    SUMMARY_KEYS = %w[files_analyzed total_functions avg_complexity avg_maintainability].freeze
    FILE_KEYS = %w[path loc avg_complexity maintainability has_tests].freeze
    FUNCTION_KEYS = %w[name file line complexity loc].freeze

    def self.resolve_target(root = 'src')
      source = Pathname.new(root)
      resolved, mode = if source.directory? && !Dir.glob(source.join('**/*.rb').to_s).empty?
                         [source.expand_path, 'project']
                       else
                         [Pathname.new(__dir__).expand_path, 'framework']
                       end
      @last_scan_root = resolved.to_s
      [resolved.to_s, mode]
    end

    def self.engine_path
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |directory|
        %w[tina4 tina4.exe].each do |name|
          candidate = File.join(directory, name)
          next unless File.file?(candidate) && File.executable?(candidate)
          next if File.binread(candidate, 2) == '#!'

          return candidate
        rescue StandardError
          next
        end
      end
      nil
    end

    def self.run_engine(path)
      binary = engine_path
      raise MetricsEngineError, "tina4 not found on PATH - #{INSTALL_HINT}" unless binary

      stdout, stderr, status = Open3.capture3(binary, 'metrics', '--path', path.to_s, '--json')
      unless status.success?
        detail = (stderr.empty? ? stdout : stderr).strip.lines.first || "exit code #{status.exitstatus}"
        raise MetricsEngineError, "tina4 metrics failed on #{path}: #{detail.strip}"
      end
      payload = JSON.parse(stdout)
      raise MetricsEngineError, 'tina4 metrics returned a non-object payload' unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError => error
      raise MetricsEngineError, "tina4 metrics returned unreadable JSON: #{error.message}"
    rescue SystemCallError => error
      raise MetricsEngineError, "could not run #{binary}: #{error.message}"
    end

    def self.require_array(payload, key)
      value = payload[key]
      return value if value.is_a?(Array)

      raise MetricsEngineError, "engine payload has no usable '#{key}' - #{INSTALL_HINT}"
    end

    def self.full_analysis(root = 'src')
      resolved, scan_mode = resolve_target(root)
      payload = run_engine(resolved)
      summary = payload['summary']
      raise MetricsEngineError, "engine payload has no usable 'summary' - #{INSTALL_HINT}" unless summary.is_a?(Hash)

      files = require_array(payload, 'file_metrics')
      functions = require_array(payload, 'most_complex_functions')
      missing = SUMMARY_KEYS.reject { |key| summary.key?(key) }
      raise MetricsEngineError, "engine summary is missing #{missing.join(', ')}" unless missing.empty?
      unless files.empty?
        missing = FILE_KEYS.reject { |key| files.first.key?(key) }
        raise MetricsEngineError, "engine file_metrics is missing #{missing.join(', ')}" unless missing.empty?
      end
      unless functions.empty?
        missing = FUNCTION_KEYS.reject { |key| functions.first.key?(key) }
        raise MetricsEngineError, "engine function metrics are missing #{missing.join(', ')}" unless missing.empty?
      end

      SUMMARY_KEYS.to_h { |key| [key, summary[key]] }.merge(
        'file_metrics' => files,
        'most_complex_functions' => functions.first(15),
        'dependency_graph' => payload['dependency_graph'] || {},
        'scan_mode' => scan_mode,
        'scan_root' => resolved,
        'engine' => 'tina4-cli'
      )
    end

    def self.file_detail(file_path)
      raise MetricsEngineError, 'file_detail needs a path' if file_path.to_s.empty?

      target = Pathname.new(file_path.to_s)
      target = Pathname.new(@last_scan_root).join(file_path.to_s) if !target.exist? && @last_scan_root
      raise MetricsEngineError, "no such file: #{file_path}" unless target.exist?
      raise MetricsEngineError, "not a file: #{file_path}" if target.directory?

      payload = run_engine(target.to_s)
      files = require_array(payload, 'file_metrics')
      raise MetricsEngineError, "engine reported no metrics for #{file_path}" if files.empty?

      files.first.merge(
        'function_count' => files.first.fetch('functions', 0),
        'functions' => require_array(payload, 'most_complex_functions'),
        'engine' => 'tina4-cli'
      )
    end
  end
end
