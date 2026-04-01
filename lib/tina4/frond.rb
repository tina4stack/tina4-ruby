# frozen_string_literal: true

# Tina4 Frond Engine -- Lexer, parser, and runtime.
# Zero-dependency twig-like template engine.
# Supports: variables, filters, if/elseif/else/endif, for/else/endfor,
# extends/block, include, macro, set, comments, whitespace control, tests,
# fragment caching, sandboxing, auto-escaping, custom filters/tests/globals.

require "json"
require "digest"
require "base64"
require "cgi"
require "uri"
require "date"
require "time"
require "securerandom"

module Tina4
  # Marker class for strings that should not be auto-escaped in Frond.
  class SafeString < String
  end

  class Frond
    # -- Token types ----------------------------------------------------------
    TEXT    = :text
    VAR     = :var      # {{ ... }}
    BLOCK   = :block    # {% ... %}
    COMMENT = :comment  # {# ... #}

    # Regex to split template source into tokens
    TOKEN_RE = /(\{%-?\s*.*?\s*-?%\})|(\{\{-?\s*.*?\s*-?\}\})|(\{#.*?#\})/m

    # HTML escape table
    HTML_ESCAPE_MAP = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;",
                        '"' => "&quot;", "'" => "&#39;" }.freeze
    HTML_ESCAPE_RE  = /[&<>"']/

    # -- Compiled regex constants (optimization: avoid re-compiling in methods) --
    EXTENDS_RE      = /\{%-?\s*extends\s+["'](.+?)["']\s*-?%\}/
    BLOCK_RE        = /\{%-?\s*block\s+(\w+)\s*-?%\}(.*?)\{%-?\s*endblock\s*-?%\}/m
    STRING_LIT_RE   = /\A["'](.*)["']\z/
    INTEGER_RE      = /\A-?\d+\z/
    FLOAT_RE        = /\A-?\d+\.\d+\z/
    ARRAY_LIT_RE    = /\A\[(.+)\]\z/m
    HASH_LIT_RE     = /\A\{(.+)\}\z/m
    HASH_PAIR_RE    = /\A\s*["']?(\w+)["']?\s*:\s*(.+)\z/
    RANGE_LIT_RE    = /\A(\d+)\.\.(\d+)\z/
    ARITHMETIC_OPS  = [" + ", " - ", " * ", " // ", " / ", " % ", " ** "].freeze
    FUNC_CALL_RE    = /\A(\w+)\s*\((.*)\)\z/m
    FILTER_WITH_ARGS_RE = /\A(\w+)\s*\((.*)\)\z/m
    FILTER_CMP_RE   = /\A(\w+)\s*(!=|==|>=|<=|>|<)\s*(.+)\z/
    OR_SPLIT_RE     = /\s+or\s+/
    AND_SPLIT_RE    = /\s+and\s+/
    IS_NOT_RE       = /\A(.+?)\s+is\s+not\s+(\w+)(.*)\z/
    IS_RE           = /\A(.+?)\s+is\s+(\w+)(.*)\z/
    NOT_IN_RE       = /\A(.+?)\s+not\s+in\s+(.+)\z/
    IN_RE           = /\A(.+?)\s+in\s+(.+)\z/
    DIVISIBLE_BY_RE = /\s*by\s*\(\s*(\d+)\s*\)/
    RESOLVE_SPLIT_RE = /\.|\[([^\]]+)\]/
    RESOLVE_STRIP_RE = /\A["']|["']\z/
    DIGIT_RE        = /\A\d+\z/
    FOR_RE          = /\Afor\s+(\w+)(?:\s*,\s*(\w+))?\s+in\s+(.+)\z/
    SET_RE          = /\Aset\s+(\w+)\s*=\s*(.+)\z/m
    INCLUDE_RE      = /\Ainclude\s+["'](.+?)["'](?:\s+with\s+(.+))?\z/
    MACRO_RE        = /\Amacro\s+(\w+)\s*\(([^)]*)\)/
    FROM_IMPORT_RE  = /\Afrom\s+["'](.+?)["']\s+import\s+(.+)/
    CACHE_RE        = /\Acache\s+["'](.+?)["']\s*(\d+)?/
    SPACELESS_RE    = />\s+</
    AUTOESCAPE_RE   = /\Aautoescape\s+(false|true)/
    STRIPTAGS_RE    = /<[^>]+>/
    THOUSANDS_RE    = /(\d)(?=(\d{3})+(?!\d))/
    SLUG_CLEAN_RE   = /[^a-z0-9]+/
    SLUG_TRIM_RE    = /\A-|-\z/

    # Set of common no-arg filter names that can be inlined for speed
    INLINE_FILTERS = %w[upper lower length trim capitalize title string int escape e].each_with_object({}) { |f, h| h[f] = true }.freeze

    # -- Lazy context overlay for for-loops (avoids full Hash#dup) --
    class LoopContext
      def initialize(parent)
        @parent = parent
        @local = {}
      end

      def [](key)
        @local.key?(key) ? @local[key] : @parent[key]
      end

      def []=(key, value)
        @local[key] = value
      end

      def key?(key)
        @local.key?(key) || @parent.key?(key)
      end
      alias include? key?
      alias has_key? key?

      def fetch(key, *args, &block)
        if @local.key?(key)
          @local[key]
        elsif @parent.key?(key)
          @parent[key]
        elsif block
          yield key
        elsif !args.empty?
          args[0]
        else
          raise KeyError, "key not found: #{key.inspect}"
        end
      end

      def merge(other)
        dup_hash = to_h
        dup_hash.merge!(other)
        dup_hash
      end

      def merge!(other)
        other.each { |k, v| @local[k] = v }
        self
      end

      def dup
        copy = LoopContext.new(@parent)
        @local.each { |k, v| copy[k] = v }
        copy
      end

      def to_h
        h = @parent.is_a?(LoopContext) ? @parent.to_h : @parent.dup
        @local.each { |k, v| h[k] = v }
        h
      end

      def each(&block)
        to_h.each(&block)
      end

      def respond_to_missing?(name, include_private = false)
        @parent.respond_to?(name, include_private) || super
      end

      def is_a?(klass)
        klass == Hash || super
      end

      def keys
        (@parent.is_a?(LoopContext) ? @parent.keys : @parent.keys) | @local.keys
      end
    end

    # -----------------------------------------------------------------------
    # Public API
    # -----------------------------------------------------------------------

    attr_reader :template_dir

    def initialize(template_dir: "src/templates")
      @template_dir    = template_dir
      @filters         = default_filters
      @globals         = {}
      @tests           = default_tests
      @auto_escape     = true

      # Sandboxing
      @sandbox         = false
      @allowed_filters = nil
      @allowed_tags    = nil
      @allowed_vars    = nil

      # Fragment cache: key => [html, expires_at]
      @fragment_cache  = {}

      # Token pre-compilation cache
      @compiled         = {}  # {template_name => [tokens, mtime]}
      @compiled_strings = {}  # {md5_hash => tokens}

      # Parsed filter chain cache: expr_string => [variable, filters]
      @filter_chain_cache = {}

      # Resolved dotted-path split cache: expr_string => parts_array
      @resolve_cache = {}

      # Sandbox root-var split cache: var_name => root_var_string
      @dotted_split_cache = {}

      # Built-in global functions
      register_builtin_globals
    end

    # Render a template file with data. Uses token caching for performance.
    def render(template, data = {})
      context = @globals.merge(stringify_keys(data))

      path = File.join(@template_dir, template)
      raise "Template not found: #{path}" unless File.exist?(path)

      debug_mode = ENV.fetch("TINA4_DEBUG", "").downcase == "true"

      unless debug_mode
        # Production: use permanent cache (no filesystem checks)
        cached = @compiled[template]
        return execute_cached(cached[0], context) if cached
      end
      # Dev mode: skip cache entirely — always re-read and re-tokenize
      # so edits to partials and extended base templates are detected

      # Cache miss — load, tokenize, cache
      source = File.read(path, encoding: "utf-8")
      mtime = File.mtime(path)
      tokens = tokenize(source)
      @compiled[template] = [tokens, mtime]
      execute_with_tokens(source, tokens, context)
    end

    # Render a template string directly. Uses token caching for performance.
    def render_string(source, data = {})
      context = @globals.merge(stringify_keys(data))

      key = Digest::MD5.hexdigest(source)
      cached_tokens = @compiled_strings[key]

      if cached_tokens
        return execute_cached(cached_tokens, context)
      end

      tokens = tokenize(source)
      @compiled_strings[key] = tokens
      execute_cached(tokens, context)
    end

    # Clear all compiled template caches.
    def clear_cache
      @compiled.clear
      @compiled_strings.clear
      @filter_chain_cache.clear
      @resolve_cache.clear
      @dotted_split_cache.clear
    end

    # Register a custom filter.
    def add_filter(name, &blk)
      @filters[name.to_s] = blk
    end

    # Register a custom test.
    def add_test(name, &blk)
      @tests[name.to_s] = blk
    end

    # Register a global variable available in all templates.
    def add_global(name, value)
      @globals[name.to_s] = value
    end

    # Enable sandbox mode.
    def sandbox(filters: nil, tags: nil, vars: nil)
      @sandbox         = true
      @allowed_filters = filters ? filters.map(&:to_s) : nil
      @allowed_tags    = tags    ? tags.map(&:to_s)    : nil
      @allowed_vars    = vars    ? vars.map(&:to_s)    : nil
      self
    end

    # Disable sandbox mode.
    def unsandbox
      @sandbox         = false
      @allowed_filters = nil
      @allowed_tags    = nil
      @allowed_vars    = nil
      self
    end

    # Utility: HTML escape
    def self.escape_html(str)
      str.to_s.gsub(HTML_ESCAPE_RE, HTML_ESCAPE_MAP)
    end

    private

    # -----------------------------------------------------------------------
    # Tokenizer
    # -----------------------------------------------------------------------

    # Regex to extract {% raw %}...{% endraw %} blocks before tokenizing
    RAW_BLOCK_RE = /\{%-?\s*raw\s*-?%\}(.*?)\{%-?\s*endraw\s*-?%\}/m

    def tokenize(source)
      # 1. Extract raw blocks and replace with placeholders
      raw_blocks = []
      source = source.gsub(RAW_BLOCK_RE) do
        idx = raw_blocks.length
        raw_blocks << Regexp.last_match(1)
        "\x00RAW_#{idx}\x00"
      end

      # 2. Normal tokenization
      tokens = []
      pos = 0
      source.scan(TOKEN_RE) do
        m = Regexp.last_match
        start = m.begin(0)
        tokens << [TEXT, source[pos...start]] if start > pos

        raw = m[0]
        if raw.start_with?("{#")
          tokens << [COMMENT, raw]
        elsif raw.start_with?("{{")
          tokens << [VAR, raw]
        elsif raw.start_with?("{%")
          tokens << [BLOCK, raw]
        end
        pos = m.end(0)
      end
      tokens << [TEXT, source[pos..]] if pos < source.length

      # 3. Restore raw block placeholders as literal TEXT
      unless raw_blocks.empty?
        tokens = tokens.map do |ttype, value|
          if ttype == TEXT && value.include?("\x00RAW_")
            raw_blocks.each_with_index do |content, idx|
              value = value.gsub("\x00RAW_#{idx}\x00", content)
            end
          end
          [ttype, value]
        end
      end

      tokens
    end

    # Strip delimiters from a tag and detect whitespace control markers.
    # Returns [content, strip_before, strip_after].
    def strip_tag(raw)
      inner = raw[2..-3] # remove {{ }} or {% %} or {# #}
      strip_before = false
      strip_after  = false

      if inner.start_with?("-")
        strip_before = true
        inner = inner[1..]
      end
      if inner.end_with?("-")
        strip_after = true
        inner = inner[0..-2]
      end

      [inner.strip, strip_before, strip_after]
    end

    # -----------------------------------------------------------------------
    # Template loading
    # -----------------------------------------------------------------------

    def load_template(name)
      path = File.join(@template_dir, name)
      raise "Template not found: #{path}" unless File.exist?(path)

      File.read(path, encoding: "utf-8")
    end

    # -----------------------------------------------------------------------
    # Execution
    # -----------------------------------------------------------------------

    def execute_cached(tokens, context)
      # Check if first non-text token is an extends block
      tokens.each do |ttype, raw|
        next if ttype == TEXT && raw.strip.empty?
        if ttype == BLOCK
          content, _, _ = strip_tag(raw)
          if content.start_with?("extends ")
            # Extends requires source-based execution for block extraction
            source = tokens.map { |_, v| v }.join
            return execute(source, context)
          end
        end
        break
      end
      render_tokens(tokens, context)
    end

    def execute_with_tokens(source, tokens, context)
      # Handle extends first
      if source =~ EXTENDS_RE
        parent_name = Regexp.last_match(1)
        parent_source = load_template(parent_name)
        child_blocks = extract_blocks(source)
        return render_with_blocks(parent_source, context, child_blocks)
      end

      render_tokens(tokens, context)
    end

    def execute(source, context)
      # Handle extends first
      if source =~ EXTENDS_RE
        parent_name = Regexp.last_match(1)
        parent_source = load_template(parent_name)
        child_blocks = extract_blocks(source)
        return render_with_blocks(parent_source, context, child_blocks)
      end

      render_tokens(tokenize(source), context)
    end

    def extract_blocks(source)
      blocks = {}
      source.scan(BLOCK_RE) do
        blocks[Regexp.last_match(1)] = Regexp.last_match(2)
      end
      blocks
    end

    def render_with_blocks(parent_source, context, child_blocks)
      engine = self
      result = parent_source.gsub(BLOCK_RE) do
        name = Regexp.last_match(1)
        parent_content = Regexp.last_match(2)
        block_source = child_blocks.fetch(name, parent_content)

        # Make parent() and super() available inside child blocks
        rendered_parent = nil
        get_parent = lambda do
          rendered_parent ||= Tina4::SafeString.new(
            engine.send(:render_tokens, tokenize(parent_content), context)
          )
          rendered_parent
        end

        block_ctx = context.merge("parent" => get_parent, "super" => get_parent)
        render_tokens(tokenize(block_source), block_ctx)
      end
      render_tokens(tokenize(result), context)
    end

    # -----------------------------------------------------------------------
    # Token renderer
    # -----------------------------------------------------------------------

    def render_tokens(tokens, context)
      output = []
      i = 0

      while i < tokens.length
        ttype, raw = tokens[i]

        case ttype
        when TEXT
          output << raw
          i += 1

        when COMMENT
          i += 1

        when VAR
          content, strip_b, strip_a = strip_tag(raw)
          output[-1] = output[-1].rstrip if strip_b && !output.empty?

          result = eval_var(content, context)
          output << (result.nil? ? "" : result.to_s)

          if strip_a && i + 1 < tokens.length && tokens[i + 1][0] == TEXT
            tokens[i + 1] = [TEXT, tokens[i + 1][1].lstrip]
          end
          i += 1

        when BLOCK
          content, strip_b, strip_a = strip_tag(raw)
          output[-1] = output[-1].rstrip if strip_b && !output.empty?

          tag = content.split[0] || ""

          case tag
          when "if"
            result, i = handle_if(tokens, i, context)
            output << result
          when "for"
            result, i = handle_for(tokens, i, context)
            output << result
          when "set"
            handle_set(content, context)
            i += 1
          when "include"
            if @sandbox && @allowed_tags && !@allowed_tags.include?("include")
              i += 1
            else
              output << handle_include(content, context)
              i += 1
            end
          when "macro"
            i = handle_macro(tokens, i, context)
          when "from"
            handle_from_import(content, context)
            i += 1
          when "cache"
            result, i = handle_cache(tokens, i, context)
            output << result
          when "spaceless"
            result, i = handle_spaceless(tokens, i, context)
            output << result
          when "autoescape"
            result, i = handle_autoescape(tokens, i, context)
            output << result
          when "block", "endblock", "extends"
            i += 1
          else
            i += 1
          end

          if strip_a && i < tokens.length && tokens[i][0] == TEXT
            tokens[i] = [TEXT, tokens[i][1].lstrip]
          end
        else
          i += 1
        end
      end

      output.join
    end

    # -----------------------------------------------------------------------
    # Variable evaluation
    # -----------------------------------------------------------------------

    def eval_var(expr, context)
      # Check for top-level ternary BEFORE splitting filters so that
      # expressions like ``products|length != 1 ? "s" : ""`` work correctly.
      ternary_pos = find_ternary(expr)
      if ternary_pos != -1
        cond_part = expr[0...ternary_pos].strip
        rest = expr[(ternary_pos + 1)..]
        colon_pos = find_colon(rest)
        if colon_pos != -1
          true_part = rest[0...colon_pos].strip
          false_part = rest[(colon_pos + 1)..].strip
          cond = eval_var_raw(cond_part, context)
          return truthy?(cond) ? eval_var(true_part, context) : eval_var(false_part, context)
        end
      end

      eval_var_inner(expr, context)
    end

    def eval_var_raw(expr, context)
      var_name, filters = parse_filter_chain(expr)
      value = eval_expr(var_name, context)
      filters.each do |fname, args|
        next if fname == "raw" || fname == "safe"
        fn = @filters[fname]
        if fn
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = fn.call(value, *evaluated_args)
        else
          # The filter name may include a trailing comparison operator,
          # e.g. "length != 1".  Extract the real filter name and the
          # comparison suffix, apply the filter, then evaluate the comparison.
          m = fname.match(FILTER_CMP_RE)
          if m
            real_filter = m[1]
            op = m[2]
            right_expr = m[3].strip
            fn2 = @filters[real_filter]
            if fn2
              evaluated_args = args.map { |a| eval_filter_arg(a, context) }
              value = fn2.call(value, *evaluated_args)
            end
            right = eval_expr(right_expr, context)
            value = case op
                    when "!=" then value != right
                    when "==" then value == right
                    when ">=" then value >= right
                    when "<=" then value <= right
                    when ">"  then value > right
                    when "<"  then value < right
                    else false
                    end rescue false
          else
            value = eval_expr(fname, context)
          end
        end
      end
      value
    end

    def eval_var_inner(expr, context)
      var_name, filters = parse_filter_chain(expr)

      # Sandbox: check variable access
      if @sandbox && @allowed_vars
        root_var = @dotted_split_cache[var_name]
        unless root_var
          root_var = var_name.split(".")[0].split("[")[0].strip
          @dotted_split_cache[var_name] = root_var
        end
        return "" if !root_var.empty? && !@allowed_vars.include?(root_var) && root_var != "loop"
      end

      value = eval_expr(var_name, context)

      is_safe = false
      filters.each do |fname, args|
        if fname == "raw" || fname == "safe"
          is_safe = true
          next
        end

        # Sandbox: check filter access
        if @sandbox && @allowed_filters && !@allowed_filters.include?(fname)
          next
        end

        # Inline common no-arg filters for speed (skip generic dispatch)
        if args.empty? && INLINE_FILTERS.include?(fname)
          value = case fname
                  when "upper"      then value.to_s.upcase
                  when "lower"      then value.to_s.downcase
                  when "length"     then value.respond_to?(:length) ? value.length : value.to_s.length
                  when "trim"       then value.to_s.strip
                  when "capitalize" then value.to_s.capitalize
                  when "title"      then value.to_s.split.map(&:capitalize).join(" ")
                  when "string"     then value.to_s
                  when "int"        then value.to_i
                  when "escape", "e" then Frond.escape_html(value.to_s)
                  else value
                  end
          next
        end

        fn = @filters[fname]
        if fn
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = fn.call(value, *evaluated_args)
        end
      end

      # Auto-escape HTML unless marked safe or SafeString
      if @auto_escape && !is_safe && value.is_a?(String) && !value.is_a?(SafeString)
        value = Frond.escape_html(value)
      end

      value
    end

    def eval_filter_arg(arg, context)
      return Regexp.last_match(1) if arg =~ STRING_LIT_RE
      return arg.to_i if arg =~ INTEGER_RE
      return arg.to_f if arg =~ FLOAT_RE
      eval_expr(arg, context)
    end

    # Find the first occurrence of +needle+ that is not inside quotes or
    # parentheses.  Returns the index, or -1 if not found.
    def find_outside_quotes(expr, needle)
      in_q = nil
      depth = 0
      i = 0
      nlen = needle.length
      while i <= expr.length - nlen
        ch = expr[i]
        if (ch == '"' || ch == "'") && depth == 0
          if in_q.nil?
            in_q = ch
          elsif ch == in_q
            in_q = nil
          end
          i += 1
          next
        end
        if in_q
          i += 1
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        end
        if depth == 0 && expr[i, nlen] == needle
          return i
        end
        i += 1
      end
      -1
    end

    # Find the index of a top-level ``?`` that is part of a ternary operator.
    # Respects quoted strings, parentheses, and skips ``??`` (null coalesce).
    # Returns -1 if not found.
    def find_ternary(expr)
      depth = 0
      in_quote = nil
      i = 0
      len = expr.length
      while i < len
        ch = expr[i]
        if in_quote
          in_quote = nil if ch == in_quote
          i += 1
          next
        end
        if ch == '"' || ch == "'"
          in_quote = ch
          i += 1
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        elsif ch == "?" && depth == 0
          # Skip ``??`` (null coalesce)
          if i + 1 < len && expr[i + 1] == "?"
            i += 2
            next
          end
          return i
        end
        i += 1
      end
      -1
    end

    # Find the index of the top-level ``:`` that separates the true/false
    # branches of a ternary.  Respects quotes and parentheses.
    def find_colon(expr)
      depth = 0
      in_quote = nil
      expr.each_char.with_index do |ch, i|
        if in_quote
          in_quote = nil if ch == in_quote
          next
        end
        if ch == '"' || ch == "'"
          in_quote = ch
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        elsif ch == ":" && depth == 0
          return i
        end
      end
      -1
    end

    # -----------------------------------------------------------------------
    # Filter chain parser
    # -----------------------------------------------------------------------

    def parse_filter_chain(expr)
      cached = @filter_chain_cache[expr]
      return cached if cached

      parts = split_on_pipe(expr)
      variable = parts[0].strip
      filters = []

      parts[1..].each do |f|
        f = f.strip
        if f =~ FILTER_WITH_ARGS_RE
          name = Regexp.last_match(1)
          raw_args = Regexp.last_match(2).strip
          args = raw_args.empty? ? [] : parse_args(raw_args)
          filters << [name, args]
        else
          filters << [f.strip, []]
        end
      end

      result = [variable, filters].freeze
      @filter_chain_cache[expr] = result
      result
    end

    # Split expression on | but not inside quotes or parens.
    def split_on_pipe(expr)
      parts = []
      current = +""
      in_quote = nil
      depth = 0

      expr.each_char do |ch|
        if in_quote
          current << ch
          in_quote = nil if ch == in_quote
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "("
          depth += 1
          current << ch
        elsif ch == ")"
          depth -= 1
          current << ch
        elsif ch == "|" && depth == 0
          parts << current
          current = +""
        else
          current << ch
        end
      end
      parts << current unless current.empty?
      parts
    end

    def parse_args(raw)
      args = []
      current = +""
      in_quote = nil
      depth = 0

      raw.each_char do |ch|
        if in_quote
          if ch == in_quote
            in_quote = nil
          end
          current << ch
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "("
          depth += 1
          current << ch
        elsif ch == ")"
          depth -= 1
          current << ch
        elsif ch == "," && depth == 0
          args << current.strip
          current = +""
        else
          current << ch
        end
      end
      args << current.strip unless current.strip.empty?
      args
    end

    # -----------------------------------------------------------------------
    # Expression evaluator
    # -----------------------------------------------------------------------

    # ── Expression evaluator (dispatcher) ──────────────────────────────
    # Each expression type is handled by a focused helper method.
    # Helpers return :not_matched when the expression doesn't match their
    # type, so the dispatcher falls through to the next handler.

    def eval_expr(expr, context)
      expr = expr.strip
      return nil if expr.empty?

      result = eval_literal(expr)
      return result unless result == :not_literal

      result = eval_collection_literal(expr, context)
      return result unless result == :not_collection

      return eval_expr(expr[1..-2], context) if matched_parens?(expr)

      result = eval_ternary(expr, context)
      return result unless result == :not_ternary

      result = eval_inline_if(expr, context)
      return result unless result == :not_inline_if

      result = eval_null_coalesce(expr, context)
      return result unless result == :not_coalesce

      result = eval_concat(expr, context)
      return result unless result == :not_concat

      return eval_comparison(expr, context) if has_comparison?(expr)

      result = eval_arithmetic(expr, context)
      return result unless result == :not_arithmetic

      result = eval_function_call(expr, context)
      return result unless result == :not_function

      resolve(expr, context)
    end

    # ── Literal values: strings, numbers, booleans, null ──

    def eval_literal(expr)
      if (expr.start_with?('"') && expr.end_with?('"')) ||
         (expr.start_with?("'") && expr.end_with?("'"))
        return expr[1..-2]
      end
      return expr.to_i if expr =~ INTEGER_RE
      return expr.to_f if expr =~ FLOAT_RE
      return true  if expr == "true"
      return false if expr == "false"
      return nil   if expr == "null" || expr == "none" || expr == "nil"
      :not_literal
    end

    # ── Collection literals: arrays, hashes, ranges ──

    def eval_collection_literal(expr, context)
      if expr =~ ARRAY_LIT_RE
        inner = Regexp.last_match(1)
        return split_args_toplevel(inner).map { |item| eval_expr(item.strip, context) }
      end
      if expr =~ HASH_LIT_RE
        inner = Regexp.last_match(1)
        hash = {}
        split_args_toplevel(inner).each do |pair|
          if pair =~ HASH_PAIR_RE
            hash[Regexp.last_match(1)] = eval_expr(Regexp.last_match(2).strip, context)
          end
        end
        return hash
      end
      if expr =~ RANGE_LIT_RE
        return (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i).to_a
      end
      :not_collection
    end

    # ── Parenthesized sub-expression check ──

    def matched_parens?(expr)
      return false unless expr.start_with?("(") && expr.end_with?(")")
      depth = 0
      expr.each_char.with_index do |ch, pi|
        depth += 1 if ch == "("
        depth -= 1 if ch == ")"
        return false if depth == 0 && pi < expr.length - 1
      end
      true
    end

    # ── Ternary: condition ? "yes" : "no" ──

    def eval_ternary(expr, context)
      q_pos = find_outside_quotes(expr, "?")
      return :not_ternary unless q_pos && q_pos > 0
      cond_part = expr[0...q_pos].strip
      rest = expr[(q_pos + 1)..]
      c_pos = find_outside_quotes(rest, ":")
      return :not_ternary unless c_pos && c_pos >= 0
      true_part = rest[0...c_pos].strip
      false_part = rest[(c_pos + 1)..].strip
      cond = eval_expr(cond_part, context)
      truthy?(cond) ? eval_expr(true_part, context) : eval_expr(false_part, context)
    end

    # ── Inline if: value if condition else other_value ──

    def eval_inline_if(expr, context)
      if_pos = find_outside_quotes(expr, " if ")
      return :not_inline_if unless if_pos && if_pos >= 0
      else_pos = find_outside_quotes(expr, " else ")
      return :not_inline_if unless else_pos && else_pos > if_pos
      value_part = expr[0...if_pos].strip
      cond_part = expr[(if_pos + 4)...else_pos].strip
      else_part = expr[(else_pos + 6)..].strip
      cond = eval_expr(cond_part, context)
      truthy?(cond) ? eval_expr(value_part, context) : eval_expr(else_part, context)
    end

    # ── Null coalescing: value ?? "default" ──

    def eval_null_coalesce(expr, context)
      return :not_coalesce unless expr.include?("??")
      left, _, right = expr.partition("??")
      val = eval_expr(left.strip, context)
      val.nil? ? eval_expr(right.strip, context) : val
    end

    # ── String concatenation: a ~ b ──

    def eval_concat(expr, context)
      return :not_concat unless expr.include?("~")
      parts = expr.split("~")
      parts.map { |p| (eval_expr(p.strip, context) || "").to_s }.join
    end

    # ── Arithmetic: +, -, *, //, /, %, ** ──

    def eval_arithmetic(expr, context)
      ARITHMETIC_OPS.each do |op|
        pos = find_outside_quotes(expr, op)
        next unless pos && pos >= 0
        l_val = eval_expr(expr[0...pos].strip, context)
        r_val = eval_expr(expr[(pos + op.length)..].strip, context)
        return apply_math(l_val, op.strip, r_val)
      end
      :not_arithmetic
    end

    # ── Function call: name(arg1, arg2) ──

    def eval_function_call(expr, context)
      return :not_function unless expr =~ FUNC_CALL_RE
      fn_name = Regexp.last_match(1)
      raw_args = Regexp.last_match(2).strip
      fn = context[fn_name]
      return :not_function unless fn.respond_to?(:call)
      args = raw_args.empty? ? [] : split_args_toplevel(raw_args).map { |a| eval_expr(a.strip, context) }
      fn.call(*args)
    end

    def has_comparison?(expr)
      [" not in ", " in ", " is not ", " is ", "!=", "==", ">=", "<=", ">", "<",
       " and ", " or ", " not "].any? { |op| expr.include?(op) }
    end

    # Split comma-separated args at top level (not inside quotes/parens/brackets).
    def split_args_toplevel(str)
      parts = []
      current = +""
      in_quote = nil
      depth = 0

      str.each_char do |ch|
        if in_quote
          current << ch
          in_quote = nil if ch == in_quote
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "(" || ch == "[" || ch == "{"
          depth += 1
          current << ch
        elsif ch == ")" || ch == "]" || ch == "}"
          depth -= 1
          current << ch
        elsif ch == "," && depth == 0
          parts << current.strip
          current = +""
        else
          current << ch
        end
      end
      parts << current.strip unless current.strip.empty?
      parts
    end

    # -----------------------------------------------------------------------
    # Comparison / logical evaluator
    # -----------------------------------------------------------------------

    def eval_comparison(expr, context, eval_fn = nil)
      eval_fn ||= method(:eval_expr)
      expr = expr.strip

      # Handle 'not' prefix
      if expr.start_with?("not ")
        return !eval_comparison(expr[4..], context, eval_fn)
      end

      # 'or' (lowest precedence)
      or_parts = expr.split(OR_SPLIT_RE)
      if or_parts.length > 1
        return or_parts.any? { |p| eval_comparison(p, context, eval_fn) }
      end

      # 'and'
      and_parts = expr.split(AND_SPLIT_RE)
      if and_parts.length > 1
        return and_parts.all? { |p| eval_comparison(p, context, eval_fn) }
      end

      # 'is not' test
      if expr =~ IS_NOT_RE
        return !eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                          Regexp.last_match(3).strip, context, eval_fn)
      end

      # 'is' test
      if expr =~ IS_RE
        return eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                         Regexp.last_match(3).strip, context, eval_fn)
      end

      # 'not in'
      if expr =~ NOT_IN_RE
        val = eval_fn.call(Regexp.last_match(1).strip, context)
        collection = eval_fn.call(Regexp.last_match(2).strip, context)
        return !(collection.respond_to?(:include?) && collection.include?(val))
      end

      # 'in'
      if expr =~ IN_RE
        val = eval_fn.call(Regexp.last_match(1).strip, context)
        collection = eval_fn.call(Regexp.last_match(2).strip, context)
        return collection.respond_to?(:include?) ? collection.include?(val) : false
      end

      # Binary comparison operators
      [["!=", ->(a, b) { a != b }],
       ["==", ->(a, b) { a == b }],
       [">=", ->(a, b) { a.to_f >= b.to_f }],
       ["<=", ->(a, b) { a.to_f <= b.to_f }],
       [">",  ->(a, b) { a.to_f > b.to_f }],
       ["<",  ->(a, b) { a.to_f < b.to_f }]].each do |op, fn|
        if expr.include?(op)
          left, _, right = expr.partition(op)
          l = eval_fn.call(left.strip, context)
          r = eval_fn.call(right.strip, context)
          begin
            return fn.call(l, r)
          rescue
            return false
          end
        end
      end

      # Fall through to simple eval
      val = eval_fn.call(expr, context)
      truthy?(val)
    end

    # -----------------------------------------------------------------------
    # Tests ('is' expressions)
    # -----------------------------------------------------------------------

    def eval_test(value_expr, test_name, args_str, context, eval_fn = nil)
      eval_fn ||= method(:eval_expr)
      val = eval_fn.call(value_expr, context)

      # 'divisible by(n)'
      if test_name == "divisible"
        if args_str =~ DIVISIBLE_BY_RE
          n = Regexp.last_match(1).to_i
          return val.is_a?(Integer) && (val % n).zero?
        end
        return false
      end

      # Check custom tests first
      custom = @tests[test_name]
      return custom.call(val) if custom

      false
    end

    def default_tests
      {
        "defined"  => ->(v) { !v.nil? },
        "empty"    => ->(v) { v.nil? || (v.respond_to?(:empty?) && v.empty?) || v == 0 || v == false },
        "null"     => ->(v) { v.nil? },
        "none"     => ->(v) { v.nil? },
        "even"     => ->(v) { v.is_a?(Integer) && v.even? },
        "odd"      => ->(v) { v.is_a?(Integer) && v.odd? },
        "iterable" => ->(v) { v.respond_to?(:each) && !v.is_a?(String) },
        "string"   => ->(v) { v.is_a?(String) },
        "number"   => ->(v) { v.is_a?(Numeric) },
        "boolean"  => ->(v) { v.is_a?(TrueClass) || v.is_a?(FalseClass) },
      }
    end

    # -----------------------------------------------------------------------
    # Variable resolver
    # -----------------------------------------------------------------------

    def resolve(expr, context)
      parts = @resolve_cache[expr]
      unless parts
        parts = expr.split(RESOLVE_SPLIT_RE).reject(&:empty?)
        @resolve_cache[expr] = parts
      end

      value = context

      parts.each do |part|
        part = part.strip.gsub(RESOLVE_STRIP_RE, "") # strip quotes from bracket access
        if value.is_a?(Hash) || value.is_a?(LoopContext)
          value = value[part] || value[part.to_sym]
        elsif value.is_a?(Array) && part =~ DIGIT_RE
          value = value[part.to_i]
        elsif value.respond_to?(part.to_sym)
          value = value.send(part.to_sym)
        else
          return nil
        end
        return nil if value.nil?
      end

      value
    end

    # -----------------------------------------------------------------------
    # Math
    # -----------------------------------------------------------------------

    def apply_math(left, op, right)
      l = (left || 0).to_f
      r = (right || 0).to_f
      # Preserve int type when both operands are int-like (except for / which returns float)
      both_int = l == l.to_i && r == r.to_i && op != "/"
      result = case op
               when "+"  then l + r
               when "-"  then l - r
               when "*"  then l * r
               when "/"  then r != 0 ? l / r : 0
               when "//" then r != 0 ? (l / r).floor : 0
               when "%"  then r != 0 ? l % r : 0
               when "**" then l ** r
               else 0
               end
      both_int && result == result.to_i ? result.to_i : result.to_f == result.to_i ? result.to_i : result
    end

    # -----------------------------------------------------------------------
    # Block handlers
    # -----------------------------------------------------------------------

    # {% if %}...{% elseif %}...{% else %}...{% endif %}
    def handle_if(tokens, start, context)
      content, _, strip_a_open = strip_tag(tokens[start][1])
      condition_expr = content.sub(/\Aif\s+/, "").strip

      branches = []
      current_tokens = []
      current_cond = condition_expr
      depth = 0
      i = start + 1

      # If the opening {%- if -%} has strip_after, lstrip the first body text
      pending_lstrip = strip_a_open

      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, strip_b_tag, strip_a_tag = strip_tag(raw)
          tag = tag_content.split[0] || ""

          if tag == "if"
            depth += 1
            current_tokens << tokens[i]
          elsif tag == "endif" && depth > 0
            depth -= 1
            current_tokens << tokens[i]
          elsif tag == "endif" && depth == 0
            # Apply strip_before from endif to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            i += 1
            break
          elsif (tag == "elseif" || tag == "elif") && depth == 0
            # Apply strip_before from elseif to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            current_cond = tag_content.sub(/\A(?:elseif|elif)\s+/, "").strip
            current_tokens = []
            pending_lstrip = strip_a_tag
          elsif tag == "else" && depth == 0
            # Apply strip_before from else to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            current_cond = nil
            current_tokens = []
            pending_lstrip = strip_a_tag
          else
            current_tokens << tokens[i]
          end
        else
          tok = tokens[i]
          if pending_lstrip && ttype == TEXT
            tok = [TEXT, tok[1].lstrip]
            pending_lstrip = false
          end
          current_tokens << tok
        end
        i += 1
      end

      branches.each do |cond, branch_tokens|
        if cond.nil? || eval_comparison(cond, context, method(:eval_var_raw))
          return [render_tokens(branch_tokens.dup, context), i]
        end
      end

      ["", i]
    end

    # {% for item in items %}...{% else %}...{% endfor %}
    def handle_for(tokens, start, context)
      content, _, strip_a_open = strip_tag(tokens[start][1])
      m = content.match(FOR_RE)
      return ["", start + 1] unless m

      var1 = m[1]
      var2 = m[2]
      iterable_expr = m[3].strip

      body_tokens = []
      else_tokens = []
      in_else = false
      for_depth = 0
      if_depth = 0
      i = start + 1
      pending_lstrip = strip_a_open

      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, strip_b_tag, strip_a_tag = strip_tag(raw)
          tag = tag_content.split[0] || ""

          if tag == "for"
            for_depth += 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endfor" && for_depth > 0
            for_depth -= 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endfor" && for_depth == 0
            target = in_else ? else_tokens : body_tokens
            if strip_b_tag && !target.empty? && target[-1][0] == TEXT
              target[-1] = [TEXT, target[-1][1].rstrip]
            end
            i += 1
            break
          elsif tag == "if"
            if_depth += 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endif"
            if_depth -= 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "else" && for_depth == 0 && if_depth == 0
            if strip_b_tag && !body_tokens.empty? && body_tokens[-1][0] == TEXT
              body_tokens[-1] = [TEXT, body_tokens[-1][1].rstrip]
            end
            in_else = true
            pending_lstrip = strip_a_tag
          else
            (in_else ? else_tokens : body_tokens) << tokens[i]
          end
        else
          tok = tokens[i]
          if pending_lstrip && ttype == TEXT
            tok = [TEXT, tok[1].lstrip]
            pending_lstrip = false
          end
          (in_else ? else_tokens : body_tokens) << tok
        end
        i += 1
      end

      iterable = eval_expr(iterable_expr, context)

      if iterable.nil? || (iterable.respond_to?(:empty?) && iterable.empty?)
        if else_tokens.any?
          return [render_tokens(else_tokens.dup, context), i]
        end
        return ["", i]
      end

      output = []
      items = iterable.is_a?(Hash) ? iterable.to_a : Array(iterable)
      total = items.length

      items.each_with_index do |item, idx|
        loop_ctx = LoopContext.new(context)
        loop_ctx["loop"] = {
          "index"     => idx + 1,
          "index0"    => idx,
          "first"     => idx == 0,
          "last"      => idx == total - 1,
          "length"    => total,
          "revindex"  => total - idx,
          "revindex0" => total - idx - 1,
          "even"      => ((idx + 1) % 2).zero?,
          "odd"       => ((idx + 1) % 2) != 0,
        }

        if iterable.is_a?(Hash)
          key, value = item
          if var2
            loop_ctx[var1] = key
            loop_ctx[var2] = value
          else
            loop_ctx[var1] = key
          end
        else
          if var2
            loop_ctx[var1] = idx
            loop_ctx[var2] = item
          else
            loop_ctx[var1] = item
          end
        end

        output << render_tokens(body_tokens.dup, loop_ctx)
      end

      [output.join, i]
    end

    # {% set name = expr %}
    def handle_set(content, context)
      if content =~ SET_RE
        name = Regexp.last_match(1)
        expr = Regexp.last_match(2).strip
        context[name] = eval_var_raw(expr, context)
      end
    end

    # {% include "file.html" %}
    def handle_include(content, context)
      ignore_missing = content.include?("ignore missing")
      content = content.gsub("ignore missing", "").strip

      m = content.match(INCLUDE_RE)
      return "" unless m

      filename = m[1]
      with_expr = m[2]

      begin
        source = load_template(filename)
      rescue
        return "" if ignore_missing
        raise
      end

      inc_context = context.dup
      if with_expr
        extra = eval_expr(with_expr, context)
        inc_context.merge!(stringify_keys(extra)) if extra.is_a?(Hash)
      end

      execute(source, inc_context)
    end

    # {% macro name(args) %}...{% endmacro %}
    def handle_macro(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = content.match(MACRO_RE)
      unless m
        i = start + 1
        while i < tokens.length
          if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
            return i + 1
          end
          i += 1
        end
        return i
      end

      macro_name = m[1]
      param_names = m[2].split(",").map(&:strip).reject(&:empty?)

      body_tokens = []
      i = start + 1
      while i < tokens.length
        if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
          i += 1
          break
        end
        body_tokens << tokens[i]
        i += 1
      end

      engine = self
      captured_body = body_tokens.dup
      captured_context = context

      context[macro_name] = lambda { |*args|
        macro_ctx = captured_context.dup
        param_names.each_with_index do |pname, pi|
          macro_ctx[pname] = pi < args.length ? args[pi] : nil
        end
        Tina4::SafeString.new(engine.send(:render_tokens, captured_body.dup, macro_ctx))
      }

      i
    end

    # {% from "file" import macro1, macro2 %}
    def handle_from_import(content, context)
      m = content.match(FROM_IMPORT_RE)
      return unless m

      filename = m[1]
      names = m[2].split(",").map(&:strip).reject(&:empty?)

      source = load_template(filename)
      tokens = tokenize(source)

      i = 0
      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, _, _ = strip_tag(raw)
          tag = (tag_content.split[0] || "")
          if tag == "macro"
            macro_m = tag_content.match(MACRO_RE)
            if macro_m && names.include?(macro_m[1])
              macro_name = macro_m[1]
              param_names = macro_m[2].split(",").map(&:strip).reject(&:empty?)

              body_tokens = []
              i += 1
              while i < tokens.length
                if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
                  i += 1
                  break
                end
                body_tokens << tokens[i]
                i += 1
              end

              context[macro_name] = _make_macro_fn(body_tokens.dup, param_names.dup, context.dup)
              next
            end
          end
        end
        i += 1
      end
    end

    # Build an isolated lambda for a macro — avoids closure-in-loop variable sharing.
    def _make_macro_fn(body_tokens, param_names, ctx)
      engine = self
      lambda { |*args|
        macro_ctx = ctx.dup
        param_names.each_with_index do |pname, pi|
          macro_ctx[pname] = pi < args.length ? args[pi] : nil
        end
        Tina4::SafeString.new(engine.send(:render_tokens, body_tokens.dup, macro_ctx))
      }
    end

    # {% cache "key" ttl %}...{% endcache %}
    def handle_cache(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = content.match(CACHE_RE)
      cache_key = m ? m[1] : "default"
      ttl = m && m[2] ? m[2].to_i : 60

      # Check cache
      cached = @fragment_cache[cache_key]
      if cached
        html_content, expires_at = cached
        if Time.now.to_f < expires_at
          # Skip to endcache
          i = start + 1
          depth = 0
          while i < tokens.length
            if tokens[i][0] == BLOCK
              tc, _, _ = strip_tag(tokens[i][1])
              tag = tc.split[0] || ""
              if tag == "cache"
                depth += 1
              elsif tag == "endcache"
                return [html_content, i + 1] if depth == 0
                depth -= 1
              end
            end
            i += 1
          end
          return [html_content, i]
        end
      end

      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "cache"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endcache"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      rendered = render_tokens(body_tokens.dup, context)
      @fragment_cache[cache_key] = [rendered, Time.now.to_f + ttl]
      [rendered, i]
    end

    def handle_spaceless(tokens, start, context)
      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "spaceless"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endspaceless"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      rendered = render_tokens(body_tokens.dup, context)
      rendered = rendered.gsub(SPACELESS_RE, "><")
      [rendered, i]
    end

    def handle_autoescape(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      mode_match = content.match(AUTOESCAPE_RE)
      auto_escape_on = !(mode_match && mode_match[1] == "false")

      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "autoescape"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endautoescape"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      if !auto_escape_on
        old_auto_escape = @auto_escape
        @auto_escape = false
        rendered = render_tokens(body_tokens.dup, context)
        @auto_escape = old_auto_escape
      else
        rendered = render_tokens(body_tokens.dup, context)
      end

      [rendered, i]
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def truthy?(val)
      return false if val.nil? || val == false || val == 0 || val == ""
      return false if val.respond_to?(:empty?) && val.empty?
      true
    end

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    # -----------------------------------------------------------------------
    # Built-in filters (53 total)
    # -----------------------------------------------------------------------

    def default_filters
      {
        # -- Text --
        "upper"      => ->(v, *_a) { v.to_s.upcase },
        "lower"      => ->(v, *_a) { v.to_s.downcase },
        "capitalize" => ->(v, *_a) { v.to_s.capitalize },
        "title"      => ->(v, *_a) { v.to_s.split.map(&:capitalize).join(" ") },
        "trim"       => ->(v, *_a) { v.to_s.strip },
        "ltrim"      => ->(v, *_a) { v.to_s.lstrip },
        "rtrim"      => ->(v, *_a) { v.to_s.rstrip },
        "replace"    => ->(v, *a)  { a.length >= 2 ? v.to_s.gsub(a[0].to_s, a[1].to_s) : v.to_s },
        "striptags"  => ->(v, *_a) { v.to_s.gsub(STRIPTAGS_RE, "") },

        # -- Encoding --
        "escape"        => ->(v, *_a) { Frond.escape_html(v.to_s) },
        "e"             => ->(v, *_a) { Frond.escape_html(v.to_s) },
        "raw"           => ->(v, *_a) { v },
        "safe"          => ->(v, *_a) { v },
        "json_encode"   => ->(v, *_a) { JSON.generate(v) rescue v.to_s },
        "json_decode"   => ->(v, *_a) { v.is_a?(String) ? (JSON.parse(v) rescue v) : v },
        "base64_encode" => ->(v, *_a) { Base64.strict_encode64(v.is_a?(String) ? v : v.to_s) },
        "base64encode"  => ->(v, *_a) { Base64.strict_encode64(v.is_a?(String) ? v : v.to_s) },
        "base64_decode" => ->(v, *_a) { Base64.decode64(v.to_s) },
        "base64decode"  => ->(v, *_a) { Base64.decode64(v.to_s) },
        "data_uri" => ->(v, *_a) {
          if v.is_a?(Hash)
            ct = v[:type] || v["type"] || "application/octet-stream"
            raw = v[:content] || v["content"] || ""
            raw = raw.respond_to?(:read) ? raw.read : raw
            "data:#{ct};base64,#{Base64.strict_encode64(raw.to_s)}"
          else
            v.to_s
          end
        },
        "url_encode"    => ->(v, *_a) { CGI.escape(v.to_s) },

        # -- JSON / JS --
        "to_json" => ->(v, *a) {
          indent = a[0] ? a[0].to_i : nil
          json = indent ? JSON.pretty_generate(v) : JSON.generate(v)
          # Escape <, >, & for safe HTML embedding
          Tina4::SafeString.new(json.gsub("<", '\u003c').gsub(">", '\u003e').gsub("&", '\u0026'))
        },
        "tojson" => ->(v, *a) {
          indent = a[0] ? a[0].to_i : nil
          json = indent ? JSON.pretty_generate(v) : JSON.generate(v)
          Tina4::SafeString.new(json.gsub("<", '\u003c').gsub(">", '\u003e').gsub("&", '\u0026'))
        },
        "js_escape" => ->(v, *_a) {
          Tina4::SafeString.new(
            v.to_s.gsub("\\", "\\\\").gsub("'", "\\'").gsub('"', '\\"')
                  .gsub("\n", "\\n").gsub("\r", "\\r").gsub("\t", "\\t")
          )
        },

        # -- Hashing --
        "md5"    => ->(v, *_a) { Digest::MD5.hexdigest(v.to_s) },
        "sha256" => ->(v, *_a) { Digest::SHA256.hexdigest(v.to_s) },

        # -- Numbers --
        "abs"           => ->(v, *_a) { v.is_a?(Numeric) ? v.abs : v.to_f.abs },
        "round"         => ->(v, *a)  { v.to_f.round(a[0] ? a[0].to_i : 0) },
        "int"           => ->(v, *_a) { v.to_i },
        "float"         => ->(v, *_a) { v.to_f },
        "number_format" => ->(v, *a) {
          decimals = a[0] ? a[0].to_i : 0
          formatted = format("%.#{decimals}f", v.to_f)
          # Add comma thousands separator
          parts = formatted.split(".")
          parts[0] = parts[0].gsub(THOUSANDS_RE, '\\1,')
          parts.join(".")
        },

        # -- Date --
        "date" => ->(v, *a) {
          fmt = a[0] || "%Y-%m-%d"
          begin
            if v.is_a?(String)
              dt = DateTime.parse(v)
              dt.strftime(fmt)
            elsif v.respond_to?(:strftime)
              v.strftime(fmt)
            else
              v.to_s
            end
          rescue
            v.to_s
          end
        },

        # -- Arrays --
        "length"  => ->(v, *_a) { v.respond_to?(:length) ? v.length : v.to_s.length },
        "first"   => ->(v, *_a) { v.respond_to?(:first) ? v.first : (v.to_s[0] rescue nil) },
        "last"    => ->(v, *_a) { v.respond_to?(:last) ? v.last : (v.to_s[-1] rescue nil) },
        "reverse" => ->(v, *_a) { v.respond_to?(:reverse) ? v.reverse : v.to_s.reverse },
        "sort"    => ->(v, *_a) { v.respond_to?(:sort) ? v.sort : v },
        "shuffle" => ->(v, *_a) { v.respond_to?(:shuffle) ? v.shuffle : v },
        "unique"  => ->(v, *_a) { v.is_a?(Array) ? v.uniq : v },
        "join"    => ->(v, *a)  { v.respond_to?(:join) ? v.join(a[0] || ", ") : v.to_s },
        "split"   => ->(v, *a)  { v.to_s.split(a[0] || " ") },
        "slice"   => ->(v, *a) {
          if a.length >= 2
            s = a[0].to_i
            e = a[1].to_i
            if v.is_a?(Array)
              v[s...e]
            else
              v.to_s[s...e]
            end
          else
            v
          end
        },
        "batch"   => ->(v, *a) {
          if a[0] && v.respond_to?(:each_slice)
            v.each_slice(a[0].to_i).to_a
          else
            [v]
          end
        },
        "map"     => ->(v, *a) {
          if a[0] && v.is_a?(Array)
            v.map { |item| item.is_a?(Hash) ? (item[a[0]] || item[a[0].to_sym]) : nil }
          else
            v
          end
        },
        "filter"  => ->(v, *_a) { v.is_a?(Array) ? v.select { |item| item } : v },
        "column"  => ->(v, *a) {
          if a[0] && v.is_a?(Array)
            v.map { |row| row.is_a?(Hash) ? (row[a[0]] || row[a[0].to_sym]) : nil }
          else
            v
          end
        },

        # -- Dict --
        "keys"   => ->(v, *_a) { v.respond_to?(:keys) ? v.keys : [] },
        "values" => ->(v, *_a) { v.respond_to?(:values) ? v.values : [v] },
        "merge"  => ->(v, *a) {
          if v.respond_to?(:merge) && a[0].is_a?(Hash)
            v.merge(a[0])
          elsif v.is_a?(Array) && a[0].is_a?(Array)
            v + a[0]
          else
            v
          end
        },

        # -- Utility --
        "default"  => ->(v, *a) { (v.nil? || v.to_s.empty?) ? (a[0] || "") : v },
        "dump"     => ->(v, *_a) { v.inspect },
        "string"   => ->(v, *_a) { v.to_s },
        "truncate" => ->(v, *a) {
          len = a[0] ? a[0].to_i : 50
          str = v.to_s
          str.length > len ? str[0...len] + "..." : str
        },
        "wordwrap" => ->(v, *a) {
          width = a[0] ? a[0].to_i : 75
          words = v.to_s.split
          lines = []
          current = +""
          words.each do |word|
            if !current.empty? && current.length + 1 + word.length > width
              lines << current
              current = word
            else
              current = current.empty? ? word : "#{current} #{word}"
            end
          end
          lines << current unless current.empty?
          lines.join("\n")
        },
        "slug"   => ->(v, *_a) { v.to_s.downcase.gsub(SLUG_CLEAN_RE, "-").gsub(SLUG_TRIM_RE, "") },
        "nl2br"  => ->(v, *_a) { v.to_s.gsub("\n", "<br>\n") },
        "format" => ->(v, *a) {
          if a.any?
            v.to_s % a
          else
            v.to_s
          end
        },
        "form_token" => ->(_v, *_a) { Frond.generate_form_token(_v.to_s) },
      }
    end

    # -----------------------------------------------------------------------
    # Built-in globals
    # -----------------------------------------------------------------------

    def register_builtin_globals
      @globals["form_token"] = ->(descriptor = "") { Frond.generate_form_token(descriptor.to_s) }
      @globals["formTokenValue"] = ->(descriptor = "") { Frond.generate_form_token_value(descriptor.to_s) }
      @globals["form_token_value"] = ->(descriptor = "") { Frond.generate_form_token_value(descriptor.to_s) }
    end

    # Generate a JWT form token and return a hidden input element.
    #
    # @param descriptor [String] Optional string to enrich the token payload.
    #   - Empty: payload is {"type" => "form"}
    #   - "admin_panel": payload is {"type" => "form", "context" => "admin_panel"}
    #   - "checkout|order_123": payload is {"type" => "form", "context" => "checkout", "ref" => "order_123"}
    #
    # @return [String] <input type="hidden" name="formToken" value="TOKEN">
    # Session ID used by generate_form_token for CSRF session binding.
    # Set this before rendering templates to bind tokens to the current session.
    @form_token_session_id = ""

    class << self
      attr_accessor :form_token_session_id
    end

    # Generate a raw JWT form token string.
    #
    # @param descriptor [String] Optional string to enrich the token payload.
    #   - Empty: payload is {"type" => "form"}
    #   - "admin_panel": payload is {"type" => "form", "context" => "admin_panel"}
    #   - "checkout|order_123": payload is {"type" => "form", "context" => "checkout", "ref" => "order_123"}
    #
    # @return [String] The raw JWT token string.
    def self.generate_form_jwt(descriptor = "")
      require_relative "log"
      require_relative "auth"

      payload = { "type" => "form", "nonce" => SecureRandom.hex(8) }
      if descriptor && !descriptor.empty?
        if descriptor.include?("|")
          parts = descriptor.split("|", 2)
          payload["context"] = parts[0]
          payload["ref"] = parts[1]
        else
          payload["context"] = descriptor
        end
      end

      # Include session_id for CSRF session binding
      sid = form_token_session_id.to_s
      payload["session_id"] = sid unless sid.empty?

      ttl_minutes = (ENV["TINA4_TOKEN_LIMIT"] || "60").to_i
      expires_in = ttl_minutes * 60
      Tina4::Auth.create_token(payload, expires_in: expires_in)
    end

    def self.generate_form_token(descriptor = "")
      token = generate_form_jwt(descriptor)
      Tina4::SafeString.new(%(<input type="hidden" name="formToken" value="#{CGI.escapeHTML(token)}">))
    end

    # Return just the raw JWT form token string (no <input> wrapper).
    # Registered as both formTokenValue and form_token_value template globals.
    def self.generate_form_token_value(descriptor = "")
      Tina4::SafeString.new(generate_form_jwt(descriptor))
    end
  end
end
