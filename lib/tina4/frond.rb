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

      # Built-in global functions
      register_builtin_globals
    end

    # Render a template file with data.
    def render(template, data = {})
      context = @globals.merge(stringify_keys(data))
      source  = load_template(template)
      execute(source, context)
    end

    # Render a template string directly.
    def render_string(source, data = {})
      context = @globals.merge(stringify_keys(data))
      execute(source, context)
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

    def execute(source, context)
      # Handle extends first
      if source =~ /\{%-?\s*extends\s+["'](.+?)["']\s*-?%\}/
        parent_name = Regexp.last_match(1)
        parent_source = load_template(parent_name)
        child_blocks = extract_blocks(source)
        return render_with_blocks(parent_source, context, child_blocks)
      end

      render_tokens(tokenize(source), context)
    end

    def extract_blocks(source)
      blocks = {}
      source.scan(/\{%-?\s*block\s+(\w+)\s*-?%\}(.*?)\{%-?\s*endblock\s*-?%\}/m) do
        blocks[Regexp.last_match(1)] = Regexp.last_match(2)
      end
      blocks
    end

    def render_with_blocks(parent_source, context, child_blocks)
      result = parent_source.gsub(/\{%-?\s*block\s+(\w+)\s*-?%\}(.*?)\{%-?\s*endblock\s*-?%\}/m) do
        name = Regexp.last_match(1)
        default_content = Regexp.last_match(2)
        block_source = child_blocks.fetch(name, default_content)
        render_tokens(tokenize(block_source), context)
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
      var_name, filters = parse_filter_chain(expr)

      # Sandbox: check variable access
      if @sandbox && @allowed_vars
        root_var = var_name.split(".")[0].split("[")[0].strip
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
      return Regexp.last_match(1) if arg =~ /\A["'](.*)["']\z/
      return arg.to_i if arg =~ /\A-?\d+\z/
      return arg.to_f if arg =~ /\A-?\d+\.\d+\z/
      eval_expr(arg, context)
    end

    # -----------------------------------------------------------------------
    # Filter chain parser
    # -----------------------------------------------------------------------

    def parse_filter_chain(expr)
      parts = split_on_pipe(expr)
      variable = parts[0].strip
      filters = []

      parts[1..].each do |f|
        f = f.strip
        if f =~ /\A(\w+)\s*\((.*)\)\z/m
          name = Regexp.last_match(1)
          raw_args = Regexp.last_match(2).strip
          args = raw_args.empty? ? [] : parse_args(raw_args)
          filters << [name, args]
        else
          filters << [f.strip, []]
        end
      end

      [variable, filters]
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

    def eval_expr(expr, context)
      expr = expr.strip
      return nil if expr.empty?

      # String literal
      if (expr.start_with?('"') && expr.end_with?('"')) ||
         (expr.start_with?("'") && expr.end_with?("'"))
        return expr[1..-2]
      end

      # Numeric
      return expr.to_i if expr =~ /\A-?\d+\z/
      return expr.to_f if expr =~ /\A-?\d+\.\d+\z/

      # Boolean/null
      return true  if expr == "true"
      return false if expr == "false"
      return nil   if expr == "null" || expr == "none" || expr == "nil"

      # Array literal [a, b, c]
      if expr =~ /\A\[(.+)\]\z/m
        inner = Regexp.last_match(1)
        return split_args_toplevel(inner).map { |item| eval_expr(item.strip, context) }
      end

      # Hash literal { key: value, ... }
      if expr =~ /\A\{(.+)\}\z/m
        inner = Regexp.last_match(1)
        hash = {}
        split_args_toplevel(inner).each do |pair|
          if pair =~ /\A\s*["']?(\w+)["']?\s*:\s*(.+)\z/
            hash[Regexp.last_match(1)] = eval_expr(Regexp.last_match(2).strip, context)
          end
        end
        return hash
      end

      # Range literal: 1..5
      if expr =~ /\A(\d+)\.\.(\d+)\z/
        return (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i).to_a
      end

      # Ternary: condition ? "yes" : "no"
      ternary = expr.match(/\A(.+?)\s*\?\s*(.+?)\s*:\s*(.+)\z/)
      if ternary
        cond = eval_expr(ternary[1], context)
        return truthy?(cond) ? eval_expr(ternary[2], context) : eval_expr(ternary[3], context)
      end

      # Jinja2-style inline if: value if condition else other_value
      inline_if = expr.match(/\A(.+?)\s+if\s+(.+?)\s+else\s+(.+)\z/)
      if inline_if
        cond = eval_expr(inline_if[2], context)
        return truthy?(cond) ? eval_expr(inline_if[1], context) : eval_expr(inline_if[3], context)
      end

      # Null coalescing: value ?? "default"
      if expr.include?("??")
        left, _, right = expr.partition("??")
        val = eval_expr(left.strip, context)
        return val.nil? ? eval_expr(right.strip, context) : val
      end

      # String concatenation with ~
      if expr.include?("~")
        parts = expr.split("~")
        return parts.map { |p| (eval_expr(p.strip, context) || "").to_s }.join
      end

      # Check for comparison / logical operators -- delegate
      if has_comparison?(expr)
        return eval_comparison(expr, context)
      end

      # Arithmetic: +, -, *, /, %
      if expr =~ /\A(.+?)\s*(\+|-|\*|\/|%)\s*(.+)\z/
        left  = eval_expr(Regexp.last_match(1), context)
        op    = Regexp.last_match(2)
        right = eval_expr(Regexp.last_match(3), context)
        return apply_math(left, op, right)
      end

      # Function call: name(arg1, arg2)
      if expr =~ /\A(\w+)\s*\((.*)\)\z/m
        fn_name  = Regexp.last_match(1)
        raw_args = Regexp.last_match(2).strip
        fn = context[fn_name]
        if fn.respond_to?(:call)
          if raw_args.empty?
            return fn.call
          else
            args = split_args_toplevel(raw_args).map { |a| eval_expr(a.strip, context) }
            return fn.call(*args)
          end
        end
      end

      resolve(expr, context)
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

    def eval_comparison(expr, context)
      expr = expr.strip

      # Handle 'not' prefix
      if expr.start_with?("not ")
        return !eval_comparison(expr[4..], context)
      end

      # 'or' (lowest precedence)
      or_parts = expr.split(/\s+or\s+/)
      if or_parts.length > 1
        return or_parts.any? { |p| eval_comparison(p, context) }
      end

      # 'and'
      and_parts = expr.split(/\s+and\s+/)
      if and_parts.length > 1
        return and_parts.all? { |p| eval_comparison(p, context) }
      end

      # 'is not' test
      if expr =~ /\A(.+?)\s+is\s+not\s+(\w+)(.*)\z/
        return !eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                          Regexp.last_match(3).strip, context)
      end

      # 'is' test
      if expr =~ /\A(.+?)\s+is\s+(\w+)(.*)\z/
        return eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                         Regexp.last_match(3).strip, context)
      end

      # 'not in'
      if expr =~ /\A(.+?)\s+not\s+in\s+(.+)\z/
        val = eval_expr(Regexp.last_match(1).strip, context)
        collection = eval_expr(Regexp.last_match(2).strip, context)
        return !(collection.respond_to?(:include?) && collection.include?(val))
      end

      # 'in'
      if expr =~ /\A(.+?)\s+in\s+(.+)\z/
        val = eval_expr(Regexp.last_match(1).strip, context)
        collection = eval_expr(Regexp.last_match(2).strip, context)
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
          l = eval_expr(left.strip, context)
          r = eval_expr(right.strip, context)
          begin
            return fn.call(l, r)
          rescue
            return false
          end
        end
      end

      # Fall through to simple eval
      val = eval_expr(expr, context)
      truthy?(val)
    end

    # -----------------------------------------------------------------------
    # Tests ('is' expressions)
    # -----------------------------------------------------------------------

    def eval_test(value_expr, test_name, args_str, context)
      val = eval_expr(value_expr, context)

      # 'divisible by(n)'
      if test_name == "divisible"
        if args_str =~ /\s*by\s*\(\s*(\d+)\s*\)/
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
      parts = expr.split(/\.|\[([^\]]+)\]/).reject(&:empty?)
      value = context

      parts.each do |part|
        part = part.strip.gsub(/\A["']|["']\z/, "") # strip quotes from bracket access
        if value.is_a?(Hash)
          value = value[part] || value[part.to_sym]
        elsif value.is_a?(Array) && part =~ /\A\d+\z/
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
      l = left.to_f
      r = right.to_f
      result = case op
               when "+" then l + r
               when "-" then l - r
               when "*" then l * r
               when "/" then r != 0 ? l / r : 0
               when "%" then l % r
               else 0
               end
      result == result.to_i ? result.to_i : result
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
        if cond.nil? || eval_comparison(cond, context)
          return [render_tokens(branch_tokens.dup, context), i]
        end
      end

      ["", i]
    end

    # {% for item in items %}...{% else %}...{% endfor %}
    def handle_for(tokens, start, context)
      content, _, strip_a_open = strip_tag(tokens[start][1])
      m = content.match(/\Afor\s+(\w+)(?:\s*,\s*(\w+))?\s+in\s+(.+)\z/)
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
        loop_ctx = context.dup
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
      if content =~ /\Aset\s+(\w+)\s*=\s*(.+)\z/m
        name = Regexp.last_match(1)
        expr = Regexp.last_match(2).strip
        context[name] = eval_expr(expr, context)
      end
    end

    # {% include "file.html" %}
    def handle_include(content, context)
      ignore_missing = content.include?("ignore missing")
      content = content.gsub("ignore missing", "").strip

      m = content.match(/\Ainclude\s+["'](.+?)["'](?:\s+with\s+(.+))?\z/)
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
      m = content.match(/\Amacro\s+(\w+)\s*\(([^)]*)\)/)
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
        engine.send(:render_tokens, captured_body.dup, macro_ctx)
      }

      i
    end

    # {% from "file" import macro1, macro2 %}
    def handle_from_import(content, context)
      m = content.match(/\Afrom\s+["'](.+?)["']\s+import\s+(.+)/)
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
            macro_m = tag_content.match(/\Amacro\s+(\w+)\s*\(([^)]*)\)/)
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
        engine.send(:render_tokens, body_tokens.dup, macro_ctx)
      }
    end

    # {% cache "key" ttl %}...{% endcache %}
    def handle_cache(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = content.match(/\Acache\s+["'](.+?)["']\s*(\d+)?/)
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
      rendered = rendered.gsub(/>\s+</, "><")
      [rendered, i]
    end

    def handle_autoescape(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      mode_match = content.match(/\Aautoescape\s+(false|true)/)
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
        "striptags"  => ->(v, *_a) { v.to_s.gsub(/<[^>]+>/, "") },

        # -- Encoding --
        "escape"        => ->(v, *_a) { Frond.escape_html(v.to_s) },
        "e"             => ->(v, *_a) { Frond.escape_html(v.to_s) },
        "raw"           => ->(v, *_a) { v },
        "safe"          => ->(v, *_a) { v },
        "json_encode"   => ->(v, *_a) { JSON.generate(v) rescue v.to_s },
        "json_decode"   => ->(v, *_a) { v.is_a?(String) ? (JSON.parse(v) rescue v) : v },
        "base64_encode" => ->(v, *_a) { Base64.strict_encode64(v.to_s) },
        "base64_decode" => ->(v, *_a) { Base64.decode64(v.to_s) },
        "url_encode"    => ->(v, *_a) { CGI.escape(v.to_s) },

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
          parts[0] = parts[0].gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
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
        "slug"   => ->(v, *_a) { v.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "") },
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
    end

    # Generate a JWT form token and return a hidden input element.
    #
    # @param descriptor [String] Optional string to enrich the token payload.
    #   - Empty: payload is {"type" => "form"}
    #   - "admin_panel": payload is {"type" => "form", "context" => "admin_panel"}
    #   - "checkout|order_123": payload is {"type" => "form", "context" => "checkout", "ref" => "order_123"}
    #
    # @return [String] <input type="hidden" name="formToken" value="TOKEN">
    def self.generate_form_token(descriptor = "")
      require_relative "log"
      require_relative "auth"

      payload = { "type" => "form" }
      if descriptor && !descriptor.empty?
        if descriptor.include?("|")
          parts = descriptor.split("|", 2)
          payload["context"] = parts[0]
          payload["ref"] = parts[1]
        else
          payload["context"] = descriptor
        end
      end

      ttl_minutes = (ENV["TINA4_TOKEN_LIMIT"] || "30").to_i
      expires_in = ttl_minutes * 60
      token = Tina4::Auth.create_token(payload, expires_in: expires_in)
      Tina4::SafeString.new(%(<input type="hidden" name="formToken" value="#{CGI.escapeHTML(token)}">))
    end
  end
end
