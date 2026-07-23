# frozen_string_literal: true
require "fileutils"

module Tina4
  module ScssCompiler
    SCSS_DIRS = %w[src/scss scss src/styles styles].freeze
    CSS_OUTPUT = "src/public/css"

    # Flags that may trail a variable declaration's value. `!default` means
    # "assign only if this variable is not already set" -- the flag that makes a
    # variable themeable. `!global` is the scope flag. Both are compiler
    # directives: they are consumed at the declaration and must never reach the
    # CSS, because `padding: 1.5rem !default` is invalid CSS and browsers drop
    # the whole declaration. Sass flag names are case-SENSITIVE (`!DEFAULT` is an
    # error in Dart Sass), so the match is deliberately case-sensitive.
    VARIABLE_FLAG = /\s*!(default|global)\s*\z/

    # Module-level state for import paths and variables
    @import_paths = []
    @variables = {}

    class << self
      # Add a search path for @import resolution.
      def add_import_path(path)
        @import_paths ||= []
        @import_paths << path
      end

      # Set a variable that will be available during compilation.
      def set_variable(name, value)
        @variables ||= {}
        name = name.sub(/^\$/, "")
        @variables[name] = value
      end

      # Compile an SCSS string to CSS.
      def compile(source)
        @variables ||= {}
        @import_paths ||= []
        # Inject preset variables
        unless @variables.empty?
          var_block = @variables.map { |k, v| "$#{k}: #{v};" }.join("\n")
          source = "#{var_block}\n#{source}"
        end
        basic_compile(source, @import_paths.first || Dir.pwd)
      end

      # Compile all .scss files from known directories.
      def compile_all(root_dir = Dir.pwd)
        output_dir = File.join(root_dir, CSS_OUTPUT)
        FileUtils.mkdir_p(output_dir)

        SCSS_DIRS.each do |dir|
          scss_dir = File.join(root_dir, dir)
          next unless Dir.exist?(scss_dir)

          Dir.glob(File.join(scss_dir, "**/*.scss")).each do |scss_file|
            next if File.basename(scss_file).start_with?("_") # Skip partials
            compile_file(scss_file, output_dir, scss_dir)
          end
        end
      end

      # Compile a single SCSS file. If output_dir is provided, writes CSS there.
      # Always returns the compiled CSS string.
      def compile_file(scss_file, output_dir = nil, base_dir = nil)
        base_dir ||= File.dirname(scss_file)
        scss_content = File.read(scss_file)
        css_content = compile_scss(scss_content, File.dirname(scss_file))

        if output_dir
          relative = scss_file.sub(base_dir, "").sub(/\.scss$/, ".css")
          css_file = File.join(output_dir, relative)
          FileUtils.mkdir_p(File.dirname(css_file))
          existing = File.exist?(css_file) ? File.read(css_file) : nil
          if existing != css_content
            File.write(css_file, css_content)
            Tina4::Log.debug("Compiled SCSS: #{scss_file} -> #{css_file}")
          end
        end

        css_content
      rescue => e
        Tina4::Log.error("SCSS compilation failed: #{scss_file} - #{e.message}")
        ""
      end

      # Compile an SCSS content string with a base directory for import resolution.
      def compile_scss(content, base_dir)
        # Try sassc gem first
        begin
          require "sassc"
          return SassC::Engine.new(content, style: :expanded, load_paths: [base_dir]).render
        rescue LoadError
          # Fall through to basic compiler
        end

        # Basic SCSS to CSS conversion (handles common patterns)
        basic_compile(content, base_dir)
      end

      private

      # Split trailing !default / !global flags off a variable declaration value.
      # Returns [value_without_flags, declares_default].
      #
      # Only ever called on the value of a `$name: value;` declaration, so a
      # literal !default anywhere else -- inside a quoted string
      # (`content: "x !default y"`) or a function argument -- is left untouched,
      # exactly as Dart Sass leaves it. A blanket strip would corrupt real string
      # content, and would silently turn `rgba(#000 !default, 0.1)` (a syntax
      # error in Dart Sass) into valid-looking CSS that Sass would never emit.
      #
      # NOTE: this runs a regex, so it clobbers the caller's match globals --
      # callers must capture their own groups first.
      def strip_variable_flags(value)
        declares_default = false
        loop do
          match = VARIABLE_FLAG.match(value)
          break unless match

          declares_default = true if match[1] == "default"
          value = value[0, match.begin(0)]
        end
        [value.strip, declares_default]
      end

      def basic_compile(content, base_dir)
        # Handle @import
        content = process_imports(content, base_dir)

        # Handle variables. The /m flag makes the value span newlines, matching
        # the Python master's `[^;]+`: without it a MULTI-LINE declaration (a map
        # literal with its closing `) !default;` on its own line -- exactly what
        # tina4-css's _variables.scss uses) was never extracted, and the raw SCSS
        # was dumped verbatim into the CSS.
        variables = {}
        content = content.gsub(/\$([a-zA-Z_][\w-]*)\s*:\s*(.+?);/m) do
          # Capture BOTH groups before calling strip_variable_flags -- it runs a
          # regex, which clobbers the match globals this block relies on.
          name = Regexp.last_match(1)
          raw = Regexp.last_match(2).strip
          value, declares_default = strip_variable_flags(raw)
          # !default must not overwrite a value that is already set.
          next "" if declares_default && variables.fetch(name, "null") != "null"

          variables[name] = value
          ""
        end

        # Resolve #{ ... } interpolation (before $var substitution + nesting).
        content = resolve_interpolation(content, variables)

        # Replace variable references
        variables.each do |name, value|
          content = content.gsub("$#{name}", value)
        end

        # Resolve color functions (lighten/darken/rgba/rgb/mix) — after variable
        # substitution so a $colour arg is already a hex literal (issue #124).
        content = resolve_color_functions(content)

        # Handle nesting (basic single-level)
        content = flatten_nesting(content)

        # Handle & parent selector
        content = content.gsub(/&/, "")

        content
      end

      # Resolve lighten/darken/rgba/rgb/mix color functions. rgba(<hex>, a) is
      # the damaging case (issue #124): the functional rgba() notation cannot
      # take a hex, so rgba(#0f3460, 0.12) is invalid CSS and browsers drop the
      # whole declaration. Convert the hex to its r,g,b components. hex_to_rgb /
      # adjust_lightness are regex-free so they never clobber the match globals.
      def resolve_color_functions(content)
        content = content.gsub(/lighten\(\s*([^,]+)\s*,\s*([^)]+)\s*\)/) do
          adjust_lightness(Regexp.last_match(1).strip, Regexp.last_match(2).strip.chomp("%").to_f / 100)
        end
        content = content.gsub(/darken\(\s*([^,]+)\s*,\s*([^)]+)\s*\)/) do
          adjust_lightness(Regexp.last_match(1).strip, -(Regexp.last_match(2).strip.chomp("%").to_f / 100))
        end
        # rgba(<hex>, <alpha>) — only the two-arg hex form; leave rgba(r,g,b,a).
        content = content.gsub(/rgba\(\s*(#[0-9a-fA-F]{3,8})\s*,\s*([\d.]+)\s*\)/) do
          hex = Regexp.last_match(1)
          alpha = Regexp.last_match(2).strip
          whole = Regexp.last_match(0)
          rgb = hex_to_rgb(hex)
          rgb ? "rgba(#{rgb[0]}, #{rgb[1]}, #{rgb[2]}, #{alpha})" : whole
        end
        content = content.gsub(/rgb\(\s*(#[0-9a-fA-F]{3,8})\s*\)/) do
          hex = Regexp.last_match(1)
          whole = Regexp.last_match(0)
          rgb = hex_to_rgb(hex)
          rgb ? "rgb(#{rgb[0]}, #{rgb[1]}, #{rgb[2]})" : whole
        end
        # mix(<c1>, <c2>[, <weight>]) — Sass weight is c1's proportion (default 50%).
        content.gsub(/mix\(\s*(#[0-9a-fA-F]{3,8})\s*,\s*(#[0-9a-fA-F]{3,8})\s*(?:,\s*([\d.]+%?)\s*)?\)/) do
          hex1 = Regexp.last_match(1)
          hex2 = Regexp.last_match(2)
          weight = Regexp.last_match(3)
          whole = Regexp.last_match(0)
          c1 = hex_to_rgb(hex1)
          c2 = hex_to_rgb(hex2)
          if c1 && c2
            w = weight ? weight.chomp("%").to_f / 100 : 0.5
            mixed = (0..2).map { |i| (c1[i] * w + c2[i] * (1 - w)).round }
            format("#%02x%02x%02x", *mixed)
          else
            whole
          end
        end
      end

      # Parse a #rgb / #rrggbb hex string into an [r, g, b] int array, or nil.
      # Regex-free (uses Integer()) so it never touches the match globals.
      def hex_to_rgb(color)
        c = color.strip.delete_prefix("#")
        c = c.chars.map { |ch| ch * 2 }.join if c.length == 3
        return nil unless c.length == 6

        [Integer(c[0, 2], 16), Integer(c[2, 2], 16), Integer(c[4, 2], 16)]
      rescue ArgumentError
        nil
      end

      # Adjust the HSL lightness of a hex color by `amount` (-1..1), return hex.
      # Truncates (to_i) to match the Python master's int(x*255) byte-for-byte.
      def adjust_lightness(color, amount)
        rgb = hex_to_rgb(color)
        return color if rgb.nil?

        r, g, b = rgb.map { |v| v / 255.0 }
        max = [r, g, b].max
        min = [r, g, b].min
        l = (max + min) / 2.0
        d = max - min
        h = 0.0
        s = 0.0
        if d != 0.0
          s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
          h = if max == r
                (g - b) / d + (g < b ? 6 : 0)
              elsif max == g
                (b - r) / d + 2
              else
                (r - g) / d + 4
              end
          h /= 6.0
        end
        l = [0.0, [1.0, l + amount].min].max
        if s.zero?
          r = g = b = l
        else
          q = l < 0.5 ? l * (1 + s) : l + s - l * s
          p = 2 * l - q
          r = _hue_to_rgb(p, q, h + 1.0 / 3)
          g = _hue_to_rgb(p, q, h)
          b = _hue_to_rgb(p, q, h - 1.0 / 3)
        end
        format("#%02x%02x%02x", (r * 255).to_i, (g * 255).to_i, (b * 255).to_i)
      end

      def _hue_to_rgb(p, q, t)
        t += 1 if t < 0
        t -= 1 if t > 1
        return p + (q - p) * 6 * t if t < 1.0 / 6
        return q if t < 1.0 / 2
        return p + (q - p) * (2.0 / 3 - t) * 6 if t < 2.0 / 3

        p
      end

      # Resolve SCSS #{ ... } interpolation. Each #{ expr } is replaced by its
      # resolved inner text: a $variable inside the braces resolves to its value,
      # anything else is inlined verbatim (trimmed). Lets a value carry a
      # variable inside a string context plain $var substitution can't reach --
      # e.g. calc(100% - #{$gap}) -> calc(100% - 20px) -- and lets a variable
      # appear in a selector (.icon-#{$name} -> .icon-home). Run BEFORE nesting
      # flatten so the literal braces never confuse the block matcher.
      def resolve_interpolation(content, variables)
        names = variables.keys.sort_by { |k| -k.length }
        content.gsub(/#\{([^{}]*)\}/) do
          inner = Regexp.last_match(1).strip
          names.each { |name| inner = inner.gsub("$#{name}", variables[name]) }
          inner
        end
      end

      def process_imports(content, base_dir)
        content.gsub(/@import\s+["'](.+?)["']\s*;/) do
          import_path = Regexp.last_match(1)
          candidates = [
            File.join(base_dir, "#{import_path}.scss"),
            File.join(base_dir, "_#{import_path}.scss"),
            File.join(base_dir, import_path)
          ]
          # Also search additional import paths
          (@import_paths || []).each do |search_path|
            candidates << File.join(search_path, "#{import_path}.scss")
            candidates << File.join(search_path, "_#{import_path}.scss")
            candidates << File.join(search_path, import_path)
          end
          found = candidates.find { |c| File.exist?(c) }
          if found
            imported = File.read(found)
            process_imports(imported, File.dirname(found))
          else
            "/* import not found: #{import_path} */"
          end
        end
      end

      def flatten_nesting(content)
        # Very basic nesting flattener - handles single level
        result = ""
        content.scan(/([^{]+)\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}/m) do |selector, body|
          selector = selector.strip
          # Check for nested rules
          if body =~ /\{/
            # Has nested content
            props = ""
            nested = ""
            body.scan(/([^{;]+(?:\{[^}]*\}|;))/m) do |part_arr|
              part = part_arr[0].strip
              if part.include?("{")
                # Nested rule
                if part =~ /\A(.+?)\s*\{(.*?)\}\s*\z/m
                  nested_sel = Regexp.last_match(1).strip
                  nested_body = Regexp.last_match(2).strip
                  full_sel = "#{selector} #{nested_sel}"
                  nested += "#{full_sel} { #{nested_body} }\n"
                end
              else
                props += "  #{part}\n" unless part.empty?
              end
            end
            result += "#{selector} {\n#{props}}\n" unless props.strip.empty?
            result += nested
          else
            result += "#{selector} {\n#{body}\n}\n"
          end
        end
        result.empty? ? content : result
      end
    end
  end
end
