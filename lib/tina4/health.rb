# frozen_string_literal: true

require "json"

module Tina4
  module Health
    START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The path used when TINA4_HEALTH_PATH is unset. Identical in all four
    # frameworks; the under-prefix keeps it clear of an application route that
    # happens to be called /health.
    DEFAULT_PATH = "/__health"

    # Always registered as well, whatever the configured path, so a probe
    # written before TINA4_HEALTH_PATH existed keeps working. Setting the env
    # var adds a path, it never takes one away.
    LEGACY_PATH = "/health"

    class << self
      # Return the configured health endpoint path.
      # TINA4_HEALTH_PATH overrides the default, kept consistent across all 4 frameworks.
      def path
        configured = ENV["TINA4_HEALTH_PATH"]
        return DEFAULT_PATH if configured.nil? || configured.empty?
        configured.start_with?("/") ? configured : "/#{configured}"
      end

      def register!
        # Unconditional, and idempotent for free: Router.add REPLACES a repeated
        # (method, path) in place rather than appending, so calling this twice
        # cannot duplicate and a Router.clear! is self-healing on the next call.
        #
        # There used to be a guard here -- `return if find_route("/health",
        # "GET")` -- whose arguments were swapped: the signature is
        # find_route(METHOD, PATH). It usually matched nothing and did nothing,
        # but an ANY route matches any path, so an app with an ordinary
        # catch-all made the guard fire and health was never registered at all.
        # A probe then received the application's catch-all response instead of
        # the health payload. Correcting the order would not have fixed it,
        # because find_route("GET", path) matches that catch-all too; asking the
        # router "does something answer here" can never distinguish "health is
        # registered" from "something else happens to match".
        #
        # The legacy "/health" is always registered alongside the configured
        # path so an existing probe keeps working when TINA4_HEALTH_PATH is set.
        Tina4::Router.add("GET", path, method(:handle))
        Tina4::Router.add("GET", LEGACY_PATH, method(:handle)) unless path == LEGACY_PATH
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
