# frozen_string_literal: true

module Tina4
  class Middleware
    class << self
      def before_handlers
        @before_handlers ||= []
      end

      def after_handlers
        @after_handlers ||= []
      end

      def before(pattern = nil, &block)
        before_handlers << { pattern: pattern, handler: block }
      end

      def after(pattern = nil, &block)
        after_handlers << { pattern: pattern, handler: block }
      end

      def clear!
        @before_handlers = []
        @after_handlers = []
      end

      def run_before(request, response)
        before_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])
          result = entry[:handler].call(request, response)
          # If handler returns false, halt the request
          return false if result == false
        end
        true
      end

      def run_after(request, response)
        after_handlers.each do |entry|
          next unless matches_pattern?(request.path, entry[:pattern])
          entry[:handler].call(request, response)
        end
      end

      private

      def matches_pattern?(path, pattern)
        return true if pattern.nil?
        case pattern
        when String
          path.start_with?(pattern)
        when Regexp
          pattern.match?(path)
        else
          true
        end
      end
    end
  end
end
