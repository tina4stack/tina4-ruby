# frozen_string_literal: true

require "json"

module Tina4
  module Health
    START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
      # Return the configured health endpoint path.
      # TINA4_HEALTH_PATH overrides the default "/__health" — kept consistent across all 4 frameworks.
      def path
        configured = ENV["TINA4_HEALTH_PATH"]
        return "/__health" if configured.nil? || configured.empty?
        configured.start_with?("/") ? configured : "/#{configured}"
      end

      def register!
        # Register at the configured path. The legacy "/health" path stays
        # registered for backward-compat.
        Tina4::Router.add("GET", path, method(:handle))
        Tina4::Router.add("GET", "/health", method(:handle)) unless path == "/health"
      end

      def handle(_request, response)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        uptime = (now - START_TIME).round(2)

        payload = {
          status: "ok",
          version: Tina4::VERSION,
          uptime: uptime,
          framework: "tina4-ruby"
        }

        response.json(payload)
      end

      def status
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        {
          status: "ok",
          version: Tina4::VERSION,
          uptime: (now - START_TIME).round(2),
          framework: "tina4-ruby"
        }
      end
    end
  end
end
