# frozen_string_literal: true

module Tina4
  module DevReload
    WATCH_EXTENSIONS = %w[.rb .twig .html .erb .scss .css .js].freeze
    WATCH_DIRS = %w[src routes lib templates public].freeze
    IGNORE_DIRS = %w[.git node_modules vendor logs sessions .queue .keys].freeze

    class << self
      def start(root_dir: Dir.pwd, &on_change)
        require "listen"

        dirs = WATCH_DIRS
          .map { |d| File.join(root_dir, d) }
          .select { |d| Dir.exist?(d) }

        # Also watch root for .rb files
        dirs << root_dir

        Tina4::Debug.info("Dev reload watching: #{dirs.join(', ')}")

        @listener = Listen.to(*dirs, only: /\.(#{WATCH_EXTENSIONS.map { |e| e.delete('.') }.join('|')})$/, ignore: build_ignore_regex) do |modified, added, removed|
          changes = { modified: modified, added: added, removed: removed }
          all_files = modified + added + removed
          next if all_files.empty?

          Tina4::Debug.info("File changes detected:")
          modified.each { |f| Tina4::Debug.debug("  Modified: #{f}") }
          added.each { |f| Tina4::Debug.debug("  Added: #{f}") }
          removed.each { |f| Tina4::Debug.debug("  Removed: #{f}") }

          # Reload Ruby files
          modified.select { |f| f.end_with?(".rb") }.each do |file|
            begin
              load file
              Tina4::Debug.info("Reloaded: #{file}")
            rescue => e
              Tina4::Debug.error("Reload failed: #{file} - #{e.message}")
            end
          end

          # Recompile SCSS
          scss_changes = all_files.select { |f| f.end_with?(".scss") }
          if scss_changes.any?
            Tina4::ScssCompiler.compile_all(root_dir)
          end

          on_change&.call(changes)
        end

        @listener.start
        Tina4::Debug.info("Dev reload started")
      end

      def stop
        @listener&.stop
        Tina4::Debug.info("Dev reload stopped")
      end

      private

      def build_ignore_regex
        pattern = IGNORE_DIRS.map { |d| Regexp.escape(d) }.join("|")
        /#{pattern}/
      end
    end
  end
end
