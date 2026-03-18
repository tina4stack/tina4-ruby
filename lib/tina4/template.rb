# frozen_string_literal: true

module Tina4
  module Template
    TEMPLATE_DIRS = %w[templates src/templates src/views views].freeze

    class << self
      def globals
        @globals ||= {}
      end

      def add_global(key, value)
        globals[key.to_s] = value
      end

      def render(template_path, data = {})
        full_path = resolve_path(template_path)
        unless full_path && File.exist?(full_path)
          raise "Template not found: #{template_path}"
        end

        content = File.read(full_path)
        ext = File.extname(full_path).downcase
        context = globals.merge(data.transform_keys(&:to_s))

        case ext
        when ".twig", ".html", ".tina4"
          TwigEngine.new(context, File.dirname(full_path)).render(content)
        when ".erb"
          ErbEngine.render(content, context)
        else
          TwigEngine.new(context, File.dirname(full_path)).render(content)
        end
      end

      def render_error(code)
        error_dirs = TEMPLATE_DIRS.map { |d| File.join(Dir.pwd, d, "errors") }
        error_dirs << File.join(File.dirname(__FILE__), "templates", "errors")

        error_dirs.each do |dir|
          %w[.twig .html .erb].each do |ext|
            path = File.join(dir, "#{code}#{ext}")
            if File.exist?(path)
              content = File.read(path)
              return TwigEngine.new({ "code" => code }, dir).render(content)
            end
          end
        end
        default_error_html(code)
      end

      private

      def resolve_path(template_path)
        return template_path if File.exist?(template_path)
        TEMPLATE_DIRS.each do |dir|
          full = File.join(Dir.pwd, dir, template_path)
          return full if File.exist?(full)
        end
        gem_templates = File.join(File.dirname(__FILE__), "templates")
        full = File.join(gem_templates, template_path)
        return full if File.exist?(full)
        nil
      end

      def default_error_html(code)
        messages = { 403 => "Forbidden", 404 => "Not Found", 500 => "Internal Server Error" }
        msg = messages[code] || "Error"
        "<!DOCTYPE html><html><head><title>#{code} #{msg}</title></head>" \
        "<body style='font-family:sans-serif;text-align:center;padding:50px;'>" \
        "<h1>#{code}</h1><p>#{msg}</p><hr>" \
        "<p style='color:#999;'>Tina4 Ruby v#{Tina4::VERSION}</p></body></html>"
      end
    end

    class TwigEngine
      FILTERS = {
        "upper" => ->(v) { v.to_s.upcase },
        "lower" => ->(v) { v.to_s.downcase },
        "capitalize" => ->(v) { v.to_s.capitalize },
        "title" => ->(v) { v.to_s.split.map(&:capitalize).join(" ") },
        "trim" => ->(v) { v.to_s.strip },
        "length" => ->(v) { v.respond_to?(:length) ? v.length : v.to_s.length },
        "reverse" => ->(v) { v.respond_to?(:reverse) ? v.reverse : v.to_s.reverse },
        "first" => ->(v) { v.respond_to?(:first) ? v.first : v.to_s[0] },
        "last" => ->(v) { v.respond_to?(:last) ? v.last : v.to_s[-1] },
        "join" => ->(v, sep) { v.respond_to?(:join) ? v.join(sep || ", ") : v.to_s },
        "default" => ->(v, d) { (v.nil? || v.to_s.empty?) ? d : v },
        "escape" => ->(v) { TwigEngine.escape_html(v.to_s) },
        "e" => ->(v) { TwigEngine.escape_html(v.to_s) },
        "nl2br" => ->(v) { v.to_s.gsub("\n", "<br>") },
        "number_format" => ->(v, d) { format("%.#{d || 0}f", v.to_f) },
        "raw" => ->(v) { v },
        "striptags" => ->(v) { v.to_s.gsub(/<[^>]+>/, "") },
        "sort" => ->(v) { v.respond_to?(:sort) ? v.sort : v },
        "keys" => ->(v) { v.respond_to?(:keys) ? v.keys : [] },
        "values" => ->(v) { v.respond_to?(:values) ? v.values : [v] },
        "abs" => ->(v) { v.to_f.abs },
        "round" => ->(v, p) { v.to_f.round(p&.to_i || 0) },
        "url_encode" => ->(v) { URI.encode_www_form_component(v.to_s) },
        "json_encode" => ->(v) { JSON.generate(v) rescue v.to_s },
        "slice" => ->(v, s, e) { v.to_s[(s.to_i)..(e ? e.to_i : -1)] },
        "merge" => ->(v, o) { v.respond_to?(:merge) ? v.merge(o || {}) : v },
        "batch" => ->(v, s) { v.respond_to?(:each_slice) ? v.each_slice(s.to_i).to_a : [v] },
        "date" => ->(v, fmt) { TwigEngine.format_date(v, fmt) }
      }.freeze

      def initialize(context = {}, base_dir = nil)
        @context = context
        @base_dir = base_dir || Dir.pwd
        @blocks = {}
        @parent_template = nil
      end

      def render(content)
        content = process_extends(content)
        content = process_blocks(content)
        content = process_includes(content)
        content = process_for_loops(content)
        content = process_conditionals(content)
        content = process_set(content)
        content = process_expressions(content)
        content = content.gsub(/\{%.*?%\}/m, "")
        content = content.gsub(/\{#.*?#\}/m, "")
        content
      end

      HTML_ESCAPE = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;" }.freeze
      HTML_ESCAPE_PATTERN = /[&<>"']/

      def self.escape_html(str)
        str.gsub(HTML_ESCAPE_PATTERN, HTML_ESCAPE)
      end

      def self.format_date(value, fmt)
        require "date"
        d = value.is_a?(String) ? DateTime.parse(value) : value
        d.respond_to?(:strftime) ? d.strftime(fmt || "%Y-%m-%d") : value.to_s
      rescue
        value.to_s
      end

      private

      def process_extends(content)
        if content =~ /\{%\s*extends\s+["'](.+?)["']\s*%\}/
          parent_path = Regexp.last_match(1)
          full_parent = resolve_template(parent_path)
          if full_parent && File.exist?(full_parent)
            @parent_template = File.read(full_parent)
            content.scan(/\{%\s*block\s+(\w+)\s*%\}(.*?)\{%\s*endblock\s*%\}/m) do |name, body|
              @blocks[name] = body
            end
            content = @parent_template
          end
        end
        content
      end

      def process_blocks(content)
        content.gsub(/\{%\s*block\s+(\w+)\s*%\}(.*?)\{%\s*endblock\s*%\}/m) do
          name = Regexp.last_match(1)
          default_body = Regexp.last_match(2)
          @blocks[name] || default_body
        end
      end

      def process_includes(content)
        content.gsub(/\{%\s*include\s+["'](.+?)["'](?:\s+with\s+(.+?))?\s*%\}/) do
          inc_path = Regexp.last_match(1)
          full_path = resolve_template(inc_path)
          if full_path && File.exist?(full_path)
            inc_content = File.read(full_path)
            TwigEngine.new(@context.dup, File.dirname(full_path)).render(inc_content)
          else
            "<!-- include not found: #{inc_path} -->"
          end
        end
      end

      def process_for_loops(content)
        max_depth = 10
        depth = 0
        while content =~ /\{%\s*for\s+/ && depth < max_depth
          content = content.gsub(/\{%\s*for\s+(\w+)(?:\s*,\s*(\w+))?\s+in\s+(.+?)\s*%\}(.*?)\{%\s*endfor\s*%\}/m) do
            key_or_val = Regexp.last_match(1)
            val_name = Regexp.last_match(2)
            collection_expr = Regexp.last_match(3)
            body = Regexp.last_match(4)
            collection = evaluate_expression(collection_expr)
            output = +""
            items = case collection
                    when Array then collection
                    when Hash then collection.to_a
                    when Range then collection.to_a
                    when Integer then (0...collection).to_a
                    else []
                    end
            items.each_with_index do |item, index|
              loop_context = @context.dup
              loop_context["loop"] = {
                "index" => index + 1, "index0" => index,
                "first" => index == 0, "last" => index == items.length - 1,
                "length" => items.length,
                "revindex" => items.length - index,
                "revindex0" => items.length - index - 1
              }
              if val_name
                loop_context[key_or_val] = item.is_a?(Array) ? item[0] : index
                loop_context[val_name] = item.is_a?(Array) ? item[1] : item
              else
                loop_context[key_or_val] = item
              end
              sub_engine = TwigEngine.new(loop_context, @base_dir)
              output << sub_engine.render(body)
            end
            output
          end
          depth += 1
        end
        content
      end

      def process_conditionals(content)
        max_depth = 10
        depth = 0
        while content =~ /\{%\s*if\s+/ && depth < max_depth
          content = content.gsub(
            /\{%\s*if\s+(.+?)\s*%\}(.*?)(?:\{%\s*else\s*%\}(.*?))?\{%\s*endif\s*%\}/m
          ) do
            condition = Regexp.last_match(1)
            true_body = Regexp.last_match(2)
            false_body = Regexp.last_match(3) || ""

            if true_body =~ /\{%\s*elseif\s+/
              segments = true_body.split(/\{%\s*elseif\s+/)
              if evaluate_condition(condition)
                segments[0]
              else
                resolved = false
                result = ""
                segments[1..].each do |seg|
                  next if resolved
                  if seg =~ /\A(.+?)\s*%\}(.*)\z/m
                    if evaluate_condition(Regexp.last_match(1))
                      result = Regexp.last_match(2)
                      resolved = true
                    end
                  end
                end
                resolved ? result : false_body
              end
            elsif evaluate_condition(condition)
              true_body
            else
              false_body
            end
          end
          depth += 1
        end
        content
      end

      def process_set(content)
        content.gsub(/\{%\s*set\s+(\w+)\s*=\s*(.+?)\s*%\}/) do
          var_name = Regexp.last_match(1)
          expr = Regexp.last_match(2)
          @context[var_name] = evaluate_expression(expr)
          ""
        end
      end

      def process_expressions(content)
        content.gsub(/\{\{\s*(.+?)\s*\}\}/) do
          expr = Regexp.last_match(1)
          evaluate_piped_expression(expr).to_s
        end
      end

      def evaluate_piped_expression(expr)
        parts = expr.split("|").map(&:strip)
        value = evaluate_expression(parts[0])
        parts[1..].each do |filter_expr|
          if filter_expr =~ /\A(\w+)(?:\((.+?)\))?\z/
            filter_name = Regexp.last_match(1)
            args_str = Regexp.last_match(2)
            args = args_str ? parse_filter_args(args_str) : []
            filter = FILTERS[filter_name]
            value = args.empty? ? filter.call(value) : filter.call(value, *args) if filter
          end
        end
        value
      end

      def parse_filter_args(args_str)
        args = []
        current = +""
        in_quote = nil
        args_str.each_char do |ch|
          if in_quote
            if ch == in_quote
              current << ch
              in_quote = nil
            else
              current << ch
            end
          elsif ch == '"' || ch == "'"
            in_quote = ch
            current << ch
          elsif ch == ","
            args << current.strip
            current = +""
          else
            current << ch
          end
        end
        args << current.strip unless current.strip.empty?

        args.map do |arg|
          if arg =~ /\A["'](.*)["']\z/
            Regexp.last_match(1)
          elsif arg =~ /\A\d+\z/
            arg.to_i
          elsif arg =~ /\A\d+\.\d+\z/
            arg.to_f
          else
            evaluate_expression(arg)
          end
        end
      end

      def evaluate_expression(expr)
        expr = expr.strip
        return Regexp.last_match(1) if expr =~ /\A"([^"]*)"\z/ || expr =~ /\A'([^']*)'\z/
        return expr.to_i if expr =~ /\A-?\d+\z/
        return expr.to_f if expr =~ /\A-?\d+\.\d+\z/
        return true if expr == "true"
        return false if expr == "false"
        return nil if expr == "null" || expr == "none" || expr == "nil"
        if expr =~ /\A\[(.+)\]\z/
          return Regexp.last_match(1).split(",").map { |i| evaluate_expression(i.strip) }
        end
        if expr =~ /\A(\d+)\.\.(\d+)\z/
          return (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i)
        end
        if expr.include?("~")
          parts = expr.split("~").map { |p| evaluate_expression(p.strip) }
          return parts.map(&:to_s).join
        end
        if expr =~ /\A(.+?)\s*(\+|-|\*|\/|%)\s*(.+)\z/
          left = evaluate_expression(Regexp.last_match(1))
          op = Regexp.last_match(2)
          right = evaluate_expression(Regexp.last_match(3))
          return apply_math(left, op, right)
        end
        resolve_variable(expr)
      end

      def resolve_variable(expr)
        parts = expr.split(".")
        value = @context
        parts.each do |part|
          if part =~ /\A(\w+)\[(.+?)\]\z/
            base = Regexp.last_match(1)
            index = Regexp.last_match(2)
            value = access_value(value, base)
            if index =~ /\A\d+\z/
              value = value[index.to_i] if value.respond_to?(:[])
            else
              index = index.gsub(/["']/, "")
              value = access_value(value, index)
            end
          else
            value = access_value(value, part)
          end
          return nil if value.nil?
        end
        value
      end

      def access_value(obj, key)
        return nil if obj.nil?
        if obj.is_a?(Hash)
          obj[key] || obj[key.to_sym] || obj[key.to_s]
        elsif obj.respond_to?(key.to_sym)
          obj.send(key.to_sym)
        elsif obj.respond_to?(:[])
          obj[key] rescue nil
        end
      end

      def evaluate_condition(expr)
        expr = expr.strip
        return !evaluate_condition(Regexp.last_match(1)) if expr =~ /\Anot\s+(.+)\z/
        if expr.include?(" and ")
          return expr.split(/\s+and\s+/).all? { |p| evaluate_condition(p) }
        end
        if expr.include?(" or ")
          return expr.split(/\s+or\s+/).any? { |p| evaluate_condition(p) }
        end
        if expr =~ /\A(.+?)\s*(==|!=|>=|<=|>|<)\s*(.+)\z/
          left = evaluate_expression(Regexp.last_match(1).strip)
          op = Regexp.last_match(2).strip
          right = evaluate_expression(Regexp.last_match(3).strip)
          return compare(left, op, right)
        end
        if expr =~ /\A(.+?)\s+in\s+(.+)\z/
          needle = evaluate_expression(Regexp.last_match(1).strip)
          haystack = evaluate_expression(Regexp.last_match(2).strip)
          return haystack.respond_to?(:include?) ? haystack.include?(needle) : false
        end
        if expr =~ /\A(.+?)\s+is\s+defined\z/
          return !evaluate_expression(Regexp.last_match(1).strip).nil?
        end
        if expr =~ /\A(.+?)\s+is\s+empty\z/
          val = evaluate_expression(Regexp.last_match(1).strip)
          return val.nil? || (val.respond_to?(:empty?) && val.empty?)
        end
        truthy?(evaluate_expression(expr))
      end

      def compare(left, op, right)
        case op
        when "==" then left == right
        when "!=" then left != right
        when ">"  then left.to_f > right.to_f
        when "<"  then left.to_f < right.to_f
        when ">=" then left.to_f >= right.to_f
        when "<=" then left.to_f <= right.to_f
        else false
        end
      end

      def apply_math(left, op, right)
        l = left.to_f
        r = right.to_f
        case op
        when "+" then l + r
        when "-" then l - r
        when "*" then l * r
        when "/" then r != 0 ? l / r : 0
        when "%" then l % r
        else 0
        end
      end

      def truthy?(val)
        return false if val.nil? || val == false || val == 0 || val == ""
        return false if val.respond_to?(:empty?) && val.empty?
        true
      end

      def resolve_template(path)
        full = File.join(@base_dir, path)
        return full if File.exist?(full)
        Tina4::Template::TEMPLATE_DIRS.each do |dir|
          candidate = File.join(Dir.pwd, dir, path)
          return candidate if File.exist?(candidate)
        end
        nil
      end
    end

    class ErbEngine
      def self.render(content, context)
        require "erb"
        binding_obj = create_binding(context)
        ERB.new(content, trim_mode: "-").result(binding_obj)
      end

      def self.create_binding(context)
        b = binding
        context.each do |key, value|
          b.local_variable_set(key.to_sym, value)
        end
        b
      end
    end
  end
end
