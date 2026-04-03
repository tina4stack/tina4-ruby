# frozen_string_literal: true

# Tina4 Code Metrics — Ripper-based static analysis for the dev dashboard.
#
# Two-tier analysis:
#   1. Quick metrics (instant): LOC, file counts, class/function counts
#   2. Full analysis (on-demand, cached): cyclomatic complexity, maintainability
#      index, coupling, Halstead metrics, violations
#
# Zero dependencies — uses Ruby's built-in Ripper module.

require 'ripper'
require 'digest'
require 'pathname'

module Tina4
  module Metrics
    # ── Cache ───────────────────────────────────────────────────
    @full_cache_hash = ""
    @full_cache_data = nil
    @full_cache_time = 0
    CACHE_TTL = 60

    # ── Root Resolution ──────────────────────────────────────────

    # Pick the right directory to scan.
    #
    # If the root dir has Ruby files, scan the user's project code.
    # Otherwise, scan the framework itself — so the bubble chart is never empty.
    def self._resolve_root(root = 'src')
      root_path = Pathname.new(root)
      if root_path.directory? && !Dir.glob(root_path.join('**', '*.rb')).empty?
        return root
      end
      # Fallback: scan the framework package itself
      File.dirname(__FILE__)
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
          Pathname.new(f).relative_path_from(Pathname.new('.')).to_s
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

    def self.full_analysis(root = 'src')
      # Check if the requested directory exists before falling back
      root_path = Pathname.new(root)
      return { "error" => "Directory not found: #{root}" } unless root_path.directory?

      root = _resolve_root(root)
      root_path = Pathname.new(root)

      current_hash = _files_hash(root)
      now = Time.now.to_f

      if @full_cache_hash == current_hash && !@full_cache_data.nil? && (now - @full_cache_time) < CACHE_TTL
        return @full_cache_data
      end

      rb_files = Dir.glob(root_path.join('**', '*.rb'))

      all_functions = []
      file_metrics = []
      import_graph = {}
      reverse_graph = {}

      rb_files.each do |f|
        source = begin
          File.read(f, encoding: 'utf-8')
        rescue StandardError
          next
        end

        tokens = begin
          Ripper.lex(source)
        rescue StandardError
          next
        end

        rel_path = begin
          Pathname.new(f).relative_path_from(Pathname.new('.')).to_s
        rescue ArgumentError
          f
        end

        lines = source.lines.map(&:chomp)
        loc = lines.count { |l| !l.strip.empty? && !l.strip.start_with?('#') }

        # Extract imports (require/require_relative)
        imports = _extract_imports(lines)
        import_graph[rel_path] = imports

        imports.each do |imp|
          reverse_graph[imp] ||= []
          reverse_graph[imp] << rel_path
        end

        # Parse functions/methods and their complexity
        file_functions = _extract_functions(source, tokens, lines)
        file_complexity = 0

        file_functions.each do |func_info|
          func_info["file"] = rel_path
          all_functions << func_info
          file_complexity += func_info["complexity"]
        end

        # Halstead metrics from tokens
        halstead = _count_halstead(tokens)
        n1 = halstead[:unique_operators].length
        n2 = halstead[:unique_operands].length
        n_total_1 = halstead[:operators]
        n_total_2 = halstead[:operands]
        vocabulary = n1 + n2
        length = n_total_1 + n_total_2
        volume = vocabulary > 0 ? length * Math.log2(vocabulary) : 0.0

        # Maintainability index
        avg_cc = file_functions.empty? ? 0 : file_complexity.to_f / file_functions.length
        mi = _maintainability_index(volume, avg_cc, loc)

        # Coupling
        ce = imports.length
        ca = (reverse_graph[rel_path] || []).length
        instability = (ca + ce) > 0 ? ce.to_f / (ca + ce) : 0.0

        file_metrics << {
          "path" => rel_path,
          "loc" => loc,
          "complexity" => file_complexity,
          "avg_complexity" => avg_cc.round(2),
          "functions" => file_functions.length,
          "maintainability" => mi.round(1),
          "halstead_volume" => volume.round(1),
          "coupling_afferent" => ca,
          "coupling_efferent" => ce,
          "instability" => instability.round(3),
          "has_tests" => _has_matching_test(rel_path),
          "dep_count" => imports.length
        }
      end

      # Update afferent coupling now that all files are processed
      file_metrics.each do |fm|
        fm["coupling_afferent"] = (reverse_graph[fm["path"]] || []).length
        ca = fm["coupling_afferent"]
        ce = fm["coupling_efferent"]
        fm["instability"] = (ca + ce) > 0 ? (ce.to_f / (ca + ce)).round(3) : 0.0
      end

      all_functions.sort_by! { |f| -f["complexity"] }
      file_metrics.sort_by! { |f| f["maintainability"] }

      violations = _detect_violations(all_functions, file_metrics)

      total_cc = all_functions.sum { |f| f["complexity"] }
      avg_cc = all_functions.empty? ? 0 : total_cc.to_f / all_functions.length
      total_mi = file_metrics.sum { |f| f["maintainability"] }
      avg_mi = file_metrics.empty? ? 0 : total_mi.to_f / file_metrics.length

      # Detect if we're scanning framework or project
      framework_dir = File.expand_path(File.dirname(__FILE__))
      resolved_root = File.expand_path(root_path.to_s)
      scanning_framework = resolved_root == framework_dir || resolved_root.start_with?(framework_dir + '/')

      result = {
        "files_analyzed" => file_metrics.length,
        "total_functions" => all_functions.length,
        "avg_complexity" => avg_cc.round(2),
        "avg_maintainability" => avg_mi.round(1),
        "most_complex_functions" => all_functions.first(15),
        "file_metrics" => file_metrics,
        "violations" => violations,
        "dependency_graph" => import_graph,
        "scan_mode" => scanning_framework ? "framework" : "project",
        "scan_root" => resolved_root
      }

      @full_cache_hash = current_hash
      @full_cache_data = result
      @full_cache_time = now

      result
    end

    # ── File Detail ─────────────────────────────────────────────

    def self.file_detail(file_path)
      unless File.exist?(file_path)
        return { "error" => "File not found: #{file_path}" }
      end

      source = begin
        File.read(file_path, encoding: 'utf-8')
      rescue StandardError => e
        return { "error" => "Read error: #{e.message}" }
      end

      tokens = begin
        Ripper.lex(source)
      rescue StandardError => e
        return { "error" => "Syntax error: #{e.message}" }
      end

      lines = source.lines.map(&:chomp)
      loc = lines.count { |l| !l.strip.empty? && !l.strip.start_with?('#') }

      functions = _extract_functions(source, tokens, lines)
      functions.sort_by! { |f| -f["complexity"] }

      classes = lines.count { |l| l.strip.match?(/\A(class|module)\s+/) }
      imports = _extract_imports(lines)

      warnings = []
      functions.each do |f|
        if f["loc"] <= 1
          warnings << { "type" => "empty_method", "message" => "Method '#{f["name"]}' appears to be empty", "line" => f["line"] }
        end
      end
      if classes > 0 && functions.empty? && loc <= 1
        warnings << { "type" => "empty_class", "message" => "Class/module appears to be empty", "line" => 1 }
      end

      {
        "path" => file_path,
        "loc" => loc,
        "total_lines" => lines.length,
        "classes" => classes,
        "functions" => functions.map { |f|
          {
            "name" => f["name"],
            "line" => f["line"],
            "complexity" => f["complexity"],
            "loc" => f["loc"],
            "args" => f["args"]
          }
        },
        "imports" => imports,
        "warnings" => warnings
      }
    end

    # ── Private Helpers ─────────────────────────────────────────

    private_class_method

    def self._has_matching_test(rel_path)
      require 'set'

      name = File.basename(rel_path, '.rb')
      # Parent directory name (e.g. "database" from "database/sqlite3_adapter.rb")
      parent_dir = File.dirname(rel_path)
      parent_module = (parent_dir != '.' && !parent_dir.empty?) ? File.basename(parent_dir) : ''

      # Stage 1: Filename matching — name_spec, name_test, test_name patterns
      test_dirs = ['spec', 'spec/tina4', 'test', 'tests']
      test_dirs.each do |td|
        patterns = [
          "#{td}/#{name}_spec.rb",
          "#{td}/#{name}s_spec.rb",
          "#{td}/#{name}_test.rb",
          "#{td}/test_#{name}.rb",
        ]
        # Also check parent-named tests (spec/database_spec.rb covers database/sqlite3_adapter.rb)
        if parent_module && !parent_module.empty? && parent_module != name
          patterns << "#{td}/#{parent_module}_spec.rb"
          patterns << "#{td}/#{parent_module}s_spec.rb"
          patterns << "#{td}/#{parent_module}_test.rb"
          patterns << "#{td}/test_#{parent_module}.rb"
        end
        return true if patterns.any? { |p| File.exist?(p) }
      end

      # Build a dotted/slashed require path for import matching
      # e.g. "lib/tina4/database/sqlite3_adapter.rb" → "tina4/database/sqlite3_adapter"
      path_without_ext = rel_path.sub(/\.rb$/, '')
      # Strip leading lib/ prefix if present
      require_path = path_without_ext.sub(%r{^lib/}, '')

      # Build CamelCase class name from snake_case module name
      # e.g. "sqlite3_adapter" → "Sqlite3Adapter"
      class_name = name.split('_').map(&:capitalize).join

      # Stage 2+3: Content scan — check if any spec/test file references this module
      scan_dirs = ['spec', 'test', 'tests']
      scan_dirs.each do |td|
        next unless Dir.exist?(td)
        Dir.glob(File.join(td, '**', '*.rb')).each do |test_file|
          content = begin
            File.read(test_file, encoding: 'utf-8')
          rescue StandardError
            next
          end
          # Stage 2: require/require_relative path matching
          return true if !require_path.empty? && content.include?(require_path)
          # Stage 3: class name or module name mention
          return true if content.match?(/\b#{Regexp.escape(class_name)}\b/)
          return true if content.match?(/\b#{Regexp.escape(name)}\b/i)
        end
      end

      false
    end

    def self._files_hash(root)
      md5 = Digest::MD5.new
      root_path = Pathname.new(root)
      if root_path.directory?
        Dir.glob(root_path.join('**', '*.rb')).sort.each do |f|
          begin
            md5.update("#{f}:#{File.mtime(f).to_f}")
          rescue StandardError
            # ignore
          end
        end
      end
      md5.hexdigest
    end

    def self._extract_imports(lines)
      imports = []
      lines.each do |line|
        stripped = line.strip
        if stripped.match?(/\Arequire\s+/)
          m = stripped.match(/\Arequire\s+['"]([^'"]+)['"]/)
          imports << m[1] if m
        elsif stripped.match?(/\Arequire_relative\s+/)
          m = stripped.match(/\Arequire_relative\s+['"]([^'"]+)['"]/)
          imports << m[1] if m
        end
      end
      imports
    end

    def self._extract_functions(source, tokens, lines)
      functions = []
      # Track class/module nesting for method names
      context_stack = []
      i = 0

      while i < lines.length
        stripped = lines[i].strip

        # Track class/module context
        if stripped.match?(/\A(class|module)\s+(\S+)/)
          m = stripped.match(/\A(class|module)\s+(\S+)/)
          class_name = m[2].to_s.split('<').first.to_s.strip
          context_stack.push(class_name) unless class_name.empty?
        end

        # Detect method definitions
        if stripped.match?(/\Adef\s+/)
          method_match = stripped.match(/\Adef\s+(self\.)?(\S+?)(\(.*\))?\s*$/)
          if method_match
            prefix = method_match[1] ? 'self.' : ''
            method_name = prefix + method_match[2]

            # Build full name with class context
            full_name = if context_stack.any?
                          "#{context_stack.last}.#{method_name}"
                        else
                          method_name
                        end

            # Extract arguments
            args = []
            if method_match[3]
              arg_str = method_match[3].gsub(/[()]/, '')
              arg_str.split(',').each do |arg|
                arg = arg.strip.split('=').first.strip.gsub(/^[*&]+/, '')
                args << arg unless arg == 'self' || arg.empty?
              end
            end

            # Find method end and calculate LOC
            method_start = i
            method_end = _find_method_end(lines, i)
            method_loc = method_end - method_start + 1

            # Calculate complexity for this method's body
            method_lines = lines[method_start..method_end]
            method_source = method_lines.join("\n")
            cc = _cyclomatic_complexity_from_source(method_source)

            functions << {
              "name" => full_name,
              "line" => i + 1,
              "complexity" => cc,
              "loc" => method_loc,
              "args" => args
            }
          end
        end

        # Track end keywords for context popping
        if stripped == 'end'
          # Check if this closes a class/module
          # Simple heuristic: count def/class/module opens vs end closes
          # We only pop context when we're back at the class/module level
          indent = lines[i].length - lines[i].lstrip.length
          if indent == 0 && context_stack.any?
            context_stack.pop
          end
        end

        i += 1
      end

      functions
    end

    def self._find_method_end(lines, start_index)
      depth = 0
      i = start_index
      base_indent = lines[i].length - lines[i].lstrip.length

      while i < lines.length
        stripped = lines[i].strip

        unless stripped.empty? || stripped.start_with?('#')
          # Count block openers
          if stripped.match?(/\b(def|class|module|if|unless|case|while|until|for|begin|do)\b/) &&
             !stripped.match?(/\bend\b/) &&
             !stripped.end_with?(' if ', ' unless ', ' while ', ' until ') &&
             !(stripped.match?(/\bif\b|\bunless\b|\bwhile\b|\buntil\b/) && i != start_index && _is_modifier?(stripped))
            depth += 1
          end

          if stripped == 'end' || stripped.start_with?('end ') || stripped.start_with?('end;')
            depth -= 1
            return i if depth <= 0
          end
        end

        i += 1
      end

      # If we never found the end, return last line
      lines.length - 1
    end

    def self._is_modifier?(line)
      # A rough check: if the keyword is not at the start of the meaningful content,
      # it's likely a modifier (e.g., "return x if condition")
      stripped = line.strip
      !stripped.match?(/\A(if|unless|while|until)\b/)
    end

    def self._cyclomatic_complexity_from_source(source)
      cc = 1

      # Use Ripper tokens for accurate counting
      tokens = begin
        Ripper.lex(source)
      rescue StandardError
        return cc
      end

      tokens.each do |(_pos, type, token)|
        case type
        when :on_kw
          case token
          when 'if', 'elsif', 'unless', 'when', 'while', 'until', 'for', 'rescue'
            # Skip modifier forms by checking if it's the first keyword on the line
            # For simplicity, count all — modifiers still add a decision path
            cc += 1
          end
        when :on_op
          case token
          when '&&', '||'
            cc += 1
          when '?'
            # Ternary operator
            cc += 1
          end
        when :on_ident
          # 'and' and 'or' are parsed as identifiers in some contexts
          # but usually as keywords
        end

        # Check for 'and'/'or' as keywords
        if type == :on_kw && (token == 'and' || token == 'or')
          cc += 1
        end
      end

      cc
    end

    OPERATOR_TYPES = %i[
      on_op
    ].freeze

    OPERAND_TYPES = %i[
      on_ident on_int on_float on_tstring_content
      on_const on_symbeg on_rational on_imaginary
    ].freeze

    def self._count_halstead(tokens)
      stats = {
        operators: 0,
        operands: 0,
        unique_operators: Set.new,
        unique_operands: Set.new
      }

      # Need Set
      require 'set' unless defined?(Set)

      stats[:unique_operators] = Set.new
      stats[:unique_operands] = Set.new

      tokens.each do |(_pos, type, token)|
        case type
        when :on_op
          stats[:operators] += 1
          stats[:unique_operators].add(token)
        when :on_kw
          # Keywords that act as operators
          if %w[and or not defined? return yield raise].include?(token)
            stats[:operators] += 1
            stats[:unique_operators].add(token)
          end
        when :on_ident, :on_const
          stats[:operands] += 1
          stats[:unique_operands].add(token)
        when :on_int, :on_float, :on_rational, :on_imaginary
          stats[:operands] += 1
          stats[:unique_operands].add(token)
        when :on_tstring_content
          stats[:operands] += 1
          stats[:unique_operands].add(token[0, 50])
        end
      end

      stats
    end

    def self._maintainability_index(halstead_volume, avg_cc, loc)
      return 100.0 if loc <= 0

      v = [halstead_volume, 1].max
      mi = 171 - 5.2 * Math.log(v) - 0.23 * avg_cc - 16.2 * Math.log(loc)
      [[0.0, mi * 100.0 / 171].max, 100.0].min
    end

    def self._detect_violations(functions, file_metrics)
      violations = []

      functions.each do |f|
        if f["complexity"] > 20
          violations << {
            "type" => "error",
            "rule" => "high_complexity",
            "message" => "#{f['name']} has cyclomatic complexity #{f['complexity']} (max 20)",
            "file" => f["file"],
            "line" => f["line"]
          }
        elsif f["complexity"] > 10
          violations << {
            "type" => "warning",
            "rule" => "moderate_complexity",
            "message" => "#{f['name']} has cyclomatic complexity #{f['complexity']} (recommended max 10)",
            "file" => f["file"],
            "line" => f["line"]
          }
        end
      end

      file_metrics.each do |fm|
        if fm["loc"] > 500
          violations << {
            "type" => "warning",
            "rule" => "large_file",
            "message" => "#{fm['path']} has #{fm['loc']} LOC (recommended max 500)",
            "file" => fm["path"],
            "line" => 1
          }
        end

        if fm["functions"] > 20
          violations << {
            "type" => "warning",
            "rule" => "too_many_functions",
            "message" => "#{fm['path']} has #{fm['functions']} functions (recommended max 20)",
            "file" => fm["path"],
            "line" => 1
          }
        end

        if fm["maintainability"] < 20
          violations << {
            "type" => "error",
            "rule" => "low_maintainability",
            "message" => "#{fm['path']} has maintainability index #{fm['maintainability']} (min 20)",
            "file" => fm["path"],
            "line" => 1
          }
        elsif fm["maintainability"] < 40
          violations << {
            "type" => "warning",
            "rule" => "moderate_maintainability",
            "message" => "#{fm['path']} has maintainability index #{fm['maintainability']} (recommended min 40)",
            "file" => fm["path"],
            "line" => 1
          }
        end
      end

      violations.sort_by! { |v| [v["type"] == "error" ? 0 : 1, v["file"]] }
      violations
    end
  end
end
