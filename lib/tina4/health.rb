# frozen_string_literal: true

require "json"

module Tina4
  module Health
    START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class << self
      def register!
        Tina4::Router.add("GET", "/health", method(:handle))
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
