# frozen_string_literal: true

# Tina4 Code Metrics — the native engine (ADR-0002) plus an instant file census.
#
# Two-tier analysis:
#   1. Quick metrics (instant): LOC, file counts, class/function counts
#   2. Full analysis (on-demand, cached): cyclomatic complexity, maintainability
#      index, coupling, Halstead metrics, violations
#
# Zero dependencies. The census is pure Ruby; the analysis is `tina4 metrics --json`.

require 'json'
require 'digest'
require 'pathname'

module Tina4
  # The native metrics engine could not produce a payload.
  #
  # Raised instead of falling back to a second implementation: two engines is
  # exactly the condition that made the four frameworks' numbers incomparable.
  class MetricsEngineError < StandardError; end

  module Metrics
    # ── Cache ───────────────────────────────────────────────────
    @full_cache_hash = ""
    @full_cache_data = nil
    @full_cache_time = 0
    CACHE_TTL = 60

    # Stores the resolved scan root so file_detail can locate framework files.
    @last_scan_root = ""

    # ── Root Resolution ──────────────────────────────────────────

    # Pick the right directory to scan.
    #
    # If the root dir has Ruby files, scan the user's project code.
    # Otherwise, scan the framework itself — so the bubble chart is never empty.
    def self._resolve_root(root = 'src')
      root_path = Pathname.new(root)
      if root_path.directory? && !Dir.glob(root_path.join('**', '*.rb')).empty?
        @last_scan_root = File.expand_path(root)
        return root
      end
      # Fallback: scan the framework package itself
      fw_dir = File.dirname(__FILE__)
      @last_scan_root = fw_dir
      fw_dir
    end

    def self.last_scan_root
      @last_scan_root
    end

    # Return [directory to scan, scan_mode] for any metrics producer.
    #
    # The CLI engine is language-agnostic and cannot know which directory holds a
    # framework package, so root resolution and the "framework" label stay here,
    # shared by the census and the engine adapter so the two never disagree about
    # what was measured.
    def self.resolve_scan_target(root = 'src')
      resolved = _resolve_root(root)
      framework_dir = File.dirname(__FILE__)
      resolved_real = File.expand_path(resolved)
      scanning_framework = resolved_real == framework_dir || resolved_real.start_with?(framework_dir)
      [resolved, scanning_framework ? 'framework' : 'project']
    end

    # ── Quick Metrics ───────────────────────────────────────────

    def self.quick_metrics(root = 'src')
      # Check if the requested directory exists before falling back
      root_path = Pathname.new(root)
      return { "error" => "Directory not found: #{root}" } unless root_path.directory?

      root = _resolve_root(root)
      root_path = Pathname.new(root)

      rb_files = Dir.glob(root_path.join('**', '*.rb'))
      twig_files = Dir.glob(root_path.join('**', '*.twig')) + Dir.glob(root_path.join('**', '*.erb'))

      migrations_path = Pathname.new('migrations')
      sql_files = if migrations_path.directory?
                    Dir.glob(migrations_path.join('**', '*.sql')) + Dir.glob(migrations_path.join('**', '*.rb'))
                  else
                    []
                  end

      scss_files = Dir.glob(root_path.join('**', '*.scss')) + Dir.glob(root_path.join('**', '*.css'))

      total_loc = 0
      total_blank = 0
      total_comment = 0
      total_classes = 0
      total_functions = 0
      file_details = []

      rb_files.each do |f|
        source = begin
          File.read(f, encoding: 'utf-8')
        rescue StandardError
          next
        end

        lines = source.lines.map(&:chomp)
        loc = 0
        blank = 0
        comment = 0
        in_heredoc = false
        heredoc_id = nil
        in_block_comment = false

        lines.each do |line|
          stripped = line.strip

          if stripped.empty?
            blank += 1
            next
          end

          # =begin/=end block comments
          if in_block_comment
            comment += 1
            in_block_comment = false if stripped.start_with?('=end')
            next
          end

          if stripped.start_with?('=begin')
            comment += 1
            in_block_comment = true
            next
          end

          # Heredoc tracking (simplified)
          if in_heredoc
            if stripped == heredoc_id
              in_heredoc = false
            end
            loc += 1
            next
          end

          if stripped.match?(/<<[~-]?['"]?(\w+)['"]?/)
            m = stripped.match(/<<[~-]?['"]?(\w+)['"]?/)
            heredoc_id = m[1]
            in_heredoc = true unless stripped.include?(heredoc_id + stripped[-1].to_s)
            loc += 1
            next
          end

          if stripped.start_with?('#')
            comment += 1
            next
          end

          loc += 1
        end

        # Count classes and methods via simple pattern matching
        classes = lines.count { |l| l.strip.match?(/\A(class|module)\s+/) }
        functions = lines.count { |l| l.strip.match?(/\Adef\s+/) }

        total_loc += loc
        total_blank += blank
        total_comment += comment
        total_classes += classes
        total_functions += functions

        rel_path = begin
          Pathname.new(f).relative_path_from(root_path).to_s
        rescue ArgumentError
          f
        end

        file_details << {
          "path" => rel_path,
          "loc" => loc,
          "blank" => blank,
          "comment" => comment,
          "classes" => classes,
          "functions" => functions
        }
      end

      file_details.sort_by! { |d| -d["loc"] }

      # Route and ORM counts
      route_count = 0
      orm_count = 0
      begin
        if defined?(Tina4::Router) && Tina4::Router.respond_to?(:routes)
          route_count = Tina4::Router.routes.length
        elsif defined?(Tina4::Router) && Tina4::Router.instance_variable_defined?(:@routes)
          route_count = Tina4::Router.instance_variable_get(:@routes).length
        end
      rescue StandardError
        # ignore
      end

      begin
        if defined?(Tina4::ORM)
          orm_count = ObjectSpace.each_object(Class).count { |c| c < Tina4::ORM }
        end
      rescue StandardError
        # ignore
      end

      breakdown = {
        "ruby" => rb_files.length,
        "templates" => twig_files.length,
        "migrations" => sql_files.length,
        "stylesheets" => scss_files.length
      }

      {
        "file_count" => rb_files.length,
        "total_loc" => total_loc,
        "total_blank" => total_blank,
        "total_comment" => total_comment,
        "lloc" => total_loc,
        "classes" => total_classes,
        "functions" => total_functions,
        "route_count" => route_count,
        "orm_count" => orm_count,
        "template_count" => twig_files.length,
        "migration_count" => sql_files.length,
        "avg_file_size" => rb_files.empty? ? 0 : (total_loc.to_f / rb_files.length).round(1),
        "largest_files" => file_details.first(10),
        "breakdown" => breakdown
      }
    end

    # ── Full Analysis (Ripper-based) ────────────────────────────
    # ── The native engine (ADR-0002) ─────────────────────────────
    #
    # The Ripper-based analyzer that used to live below here is gone. Everything
    # except the instant file census now comes from `tina4 metrics --json`, so a
    # number measured in Ruby is comparable with the same number measured in
    # Python, PHP or Node. There is deliberately NO fallback: a second engine is
    # exactly the condition that made the four frameworks' numbers incomparable.

    TIMEOUT_SECONDS = 60

    INSTALL_HINT = <<~HINT.strip
      the tina4 CLI provides the metrics engine (ADR-0002). Install it with
        curl -fsSL https://tina4.com/install.sh | sh
      or see https://tina4.com/cli
    HINT

    # Fields the dashboard renders. Checking for the DATA is honest where checking
    # a version string is not: a user may run any CLI build, and the payload is
    # what tells us what that build can actually do.
    SUMMARY_KEYS = %w[files_analyzed total_functions avg_complexity avg_maintainability].freeze
    FILE_KEYS = %w[path loc avg_complexity maintainability has_tests].freeze
    FUNCTION_KEYS = %w[name file line complexity loc].freeze

    # Absolute path to the tina4 CLI binary, or nil when it is not installed.
    #
    # Skips shebang scripts. The engine is a COMPILED Rust binary, but `bundle
    # exec` prepends RubyGems' bin directory to PATH, and a gem executable named
    # `tina4` sits there as a Ruby shim. Taking the first PATH hit found that
    # shim and running it died with "can't find executable tina4 for gem" -- so
    # every metrics call failed under the ordinary `bundle exec` workflow. The
    # same guard also steps over rbenv/asdf shims and any gem squatting the name.
    def self.engine_path
      ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        %w[tina4 tina4.exe].each do |name|
          candidate = File.join(dir, name)
          next unless File.file?(candidate) && File.executable?(candidate)
          next if _shebang_script?(candidate)

          return candidate
        end
      end
      nil
    end

    # True when the file begins with `#!` -- a script, never the native engine.
    def self._shebang_script?(path)
      File.binread(path, 2) == '#!'
    rescue StandardError
      false
    end

    # Run `tina4 metrics --json` over path and return the raw payload.
    #
    # Raises MetricsEngineError naming the actual cause: a caller that cannot get
    # metrics needs to know whether the binary is missing, the run failed, or the
    # output was unreadable.
    def self._run_engine(path)
      binary = engine_path
      raise MetricsEngineError, "tina4 not found on PATH - #{INSTALL_HINT}" if binary.nil?

      stdout = nil
      status = nil
      stderr = nil
      begin
        require 'open3'
        stdout, stderr, status = Open3.capture3(
          binary, 'metrics', '--path', path.to_s, '--json'
        )
        # capture3 tags the output with the LOCALE's encoding, so under a
        # minimal locale (LANG=C / LANG unset, common on CI runners and in slim
        # containers) the engine's UTF-8 JSON arrives labelled US-ASCII and the
        # first String#strip raises Encoding::CompatibilityError. The bytes were
        # always UTF-8; only the label was wrong.
        stdout = stdout.to_s.dup.force_encoding(Encoding::UTF_8)
        stderr = stderr.to_s.dup.force_encoding(Encoding::UTF_8)
      rescue StandardError => e
        raise MetricsEngineError, "could not run #{binary}: #{e.message}"
      end

      unless status.success?
        detail = (stderr.to_s.strip.empty? ? stdout.to_s : stderr.to_s).strip.lines.first
        first = detail ? detail.strip : "exit code #{status.exitstatus}"
        raise MetricsEngineError, "tina4 metrics failed on #{path}: #{first}"
      end

      raise MetricsEngineError, "tina4 metrics produced no output for #{path}" if stdout.to_s.strip.empty?

      begin
        payload = JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise MetricsEngineError, "tina4 metrics returned unreadable JSON: #{e.message}"
      end

      raise MetricsEngineError, 'tina4 metrics returned a non-object payload' unless payload.is_a?(Hash)

      payload
    end

    # Pull a key out of the payload or raise naming what the engine is missing.
    def self._require(payload, key, kind)
      value = payload[key]
      unless value.is_a?(kind)
        raise MetricsEngineError,
              "engine payload has no usable '#{key}' - the installed tina4 CLI predates " \
              "a field the dashboard renders. Update it: #{INSTALL_HINT}"
      end
      value
    end

    # Full code analysis from the native engine, shaped for the dashboard.
    def self.full_analysis(root = 'src')
      resolved, scan_mode = resolve_scan_target(root)
      payload = _run_engine(resolved)

      summary = _require(payload, 'summary', Hash)
      file_metrics = _require(payload, 'file_metrics', Array)
      functions = _require(payload, 'most_complex_functions', Array)

      missing = SUMMARY_KEYS.reject { |k| summary.key?(k) }
      unless missing.empty?
        raise MetricsEngineError,
              "engine summary is missing #{missing.join(', ')} - update the CLI: #{INSTALL_HINT}"
      end
      unless file_metrics.empty?
        absent = FILE_KEYS.reject { |k| file_metrics.first.key?(k) }
        raise MetricsEngineError, "engine file_metrics is missing #{absent.join(', ')}" unless absent.empty?
      end
      unless functions.empty?
        absent = FUNCTION_KEYS.reject { |k| functions.first.key?(k) }
        raise MetricsEngineError, "engine function metrics are missing #{absent.join(', ')}" unless absent.empty?
      end

      result = SUMMARY_KEYS.each_with_object({}) { |k, h| h[k] = summary[k] }
      result['file_metrics'] = file_metrics
      # Display cap only. offenders reads the engine's own uncapped list, so a
      # 16th over-threshold function is never hidden from the gate.
      result['most_complex_functions'] = functions.first(15)
      result['dependency_graph'] = payload['dependency_graph'] || {}
      # The framework owns these two: the engine always reports "project" because
      # it cannot know which directory is a framework package.
      result['scan_mode'] = scan_mode
      result['scan_root'] = File.expand_path(resolved)
      result['engine'] = 'tina4-cli'
      result
    end

    # Top code-health offenders from the native engine.
    #
    # The engine ranks and severity-tags them, and its own --fail-on gate reads
    # the same list, so the CLI and the dashboard can never disagree about what
    # counts as an offender.
    def self.offenders(root = 'src', top = 20)
      resolved, scan_mode = resolve_scan_target(root)
      payload = _run_engine(resolved)

      found = _require(payload, 'offenders', Array)
      summary = _require(payload, 'summary', Hash).dup
      summary['scan_mode'] = scan_mode
      summary['scan_root'] = File.expand_path(resolved)
      summary['engine'] = 'tina4-cli'
      summary['total_offenders'] ||= found.length
      { 'offenders' => found.first(top), 'summary' => summary }
    end

    # Per-file metrics from the native engine.
    #
    # The engine accepts a single file for --path, so one code path serves both
    # the whole-tree scan and one file.
    def self.file_detail(file_path)
      raise MetricsEngineError, 'file_detail needs a path' if file_path.nil? || file_path.to_s.empty?

      target = Pathname.new(file_path.to_s)
      unless target.exist?
        # Try it relative to whatever the census last resolved, so the dashboard
        # can pass a path taken straight out of file_metrics.
        unless @last_scan_root.to_s.empty?
          candidate = Pathname.new(@last_scan_root).join(file_path.to_s)
          target = candidate if candidate.exist?
        end
      end
      raise MetricsEngineError, "no such file: #{file_path}" unless target.exist?
      raise MetricsEngineError, "not a file: #{file_path}" if target.directory?

      payload = _run_engine(target.to_s)
      file_metrics = _require(payload, 'file_metrics', Array)
      raise MetricsEngineError, "engine reported no metrics for #{file_path}" if file_metrics.empty?

      file_metrics.first.dup.merge('engine' => 'tina4-cli')
    end
  end
end
