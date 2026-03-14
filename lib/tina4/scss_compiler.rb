# frozen_string_literal: true
require "fileutils"

module Tina4
  module ScssCompiler
    SCSS_DIRS = %w[src/scss scss src/styles styles].freeze
    CSS_OUTPUT = "public/css"

    class << self
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

      def compile_file(scss_file, output_dir, base_dir)
        relative = scss_file.sub(base_dir, "").sub(/\.scss$/, ".css")
        css_file = File.join(output_dir, relative)
        FileUtils.mkdir_p(File.dirname(css_file))

        scss_content = File.read(scss_file)
        css_content = compile_scss(scss_content, File.dirname(scss_file))
        File.write(css_file, css_content)

        Tina4::Debug.debug("Compiled SCSS: #{scss_file} -> #{css_file}")
      rescue => e
        Tina4::Debug.error("SCSS compilation failed: #{scss_file} - #{e.message}")
      end

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

      def basic_compile(content, base_dir)
        # Handle @import
        content = process_imports(content, base_dir)

        # Handle variables
        variables = {}
        content = content.gsub(/\$([a-zA-Z_][\w-]*)\s*:\s*(.+?);/) do
          variables[Regexp.last_match(1)] = Regexp.last_match(2).strip
          ""
        end

        # Replace variable references
        variables.each do |name, value|
          content = content.gsub("$#{name}", value)
        end

        # Handle nesting (basic single-level)
        content = flatten_nesting(content)

        # Handle & parent selector
        content = content.gsub(/&/, "")

        content
      end

      def process_imports(content, base_dir)
        content.gsub(/@import\s+["'](.+?)["']\s*;/) do
          import_path = Regexp.last_match(1)
          candidates = [
            File.join(base_dir, "#{import_path}.scss"),
            File.join(base_dir, "_#{import_path}.scss"),
            File.join(base_dir, import_path)
          ]
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
