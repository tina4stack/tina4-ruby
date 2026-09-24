# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require_relative "port_takeover"
require_relative "http_server"

module Tina4
  class WebServer
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 7147

    # Bind address and port, when the caller does not pass host:/port:.
    #
    # Both go through Tina4.resolve_bind_* so this and Tina4.start! cannot
    # drift apart - they already had: this file read TINA4_PORT first while
    # tina4.rb read bare PORT first, so the same variable meant different
    # things depending which entry point you came through.
    def initialize(app, host: nil, port: nil)
      @app = app
      @host = host || Tina4.resolve_bind_host(DEFAULT_HOST)
      @port = port || Tina4.resolve_bind_port(DEFAULT_PORT)
    end

    # Reclaim *port* from a stale Tina4 dev server via the shared, guarded path.
    #
    # This is the runtime bind-failure fallback. It used to SIGTERM whatever held
    # the port with NONE of the CLI's guards -- no identity check, no container
    # guard, no PID-safety filter -- so a foreign holder (another dev server, a
    # database) was killed on any bind failure. It now routes through the SAME
    # identity-checked helper the CLI uses (TAKEOVER-DEC-02), so only a
    # PID-file-confirmed Tina4 dev server is ever signalled.
    #
    # Raises RuntimeError when the port is held by a non-Tina4 process (or
    # takeover is opted out / disabled outside dev), so the bind fails loudly with
    # a clear message instead of killing an innocent process.
    def free_port(port)
      result = Tina4::PortTakeover.take_over_port(
        port, dev: Tina4::PortTakeover.dev?, no_takeover: Tina4::PortTakeover.no_takeover_opted_out?
      )
      if result.reclaimed?
        puts "  #{result.message}"
        return
      end
      raise result.message if result.refused?

      # NOTHING / container: nothing to reclaim -- let the real bind decide.
    end

    def start
      # Refuse to boot with v3.11 / v2 era un-prefixed env vars set.
      Tina4.check_legacy_env_vars!

      is_managed = ARGV.include?('--managed')
      unless is_managed || ENV['TINA4_OVERRIDE_CLIENT'] == 'true'
        puts
        puts '=' * 60
        puts
        puts '  Tina4 must be started with the tina4 CLI:'
        puts
        puts '    tina4 serve              (development)'
        puts '    tina4 serve --production (production)'
        puts
        puts '  Install: cargo install tina4'
        puts '  Docs:    https://tina4.com'
        puts
        puts '  To run directly, add to .env:'
        puts '    TINA4_OVERRIDE_CLIENT=true'
        puts
        puts '=' * 60
        puts
        exit 1
      end

      require "socket"

      # Ensure the main port is available — kill whatever is on it if needed
      begin
        test = TCPServer.new("0.0.0.0", @port)
        test.close
      rescue Errno::EADDRINUSE
        free_port(@port)
        # Verify the port is now free; raise if still occupied
        begin
          test = TCPServer.new("0.0.0.0", @port)
          test.close
        rescue Errno::EADDRINUSE
          raise "Could not free port #{@port}"
        end
      end

      Tina4.print_banner(host: @host, port: @port, server_name: Tina4::HttpServer::SOFTWARE)
      display = (@host == "0.0.0.0" || @host == "::") ? "localhost" : @host
      Tina4::Log.info("Server started http://#{display}:#{@port} (#{Tina4::HttpServer::SOFTWARE})")
      @server = Tina4::HttpServer.new(server_name: @host)
      @server.listen(@host, @port, @app)

      # Dual-stack loopback: ALSO listen on the sibling loopback family on the
      # MAIN port, so `localhost` reaches this server whether the OS resolves it
      # to IPv4 (127.0.0.1) or IPv6 (::1). On Windows `localhost` resolves to
      # ::1 first, so a server bound only to 127.0.0.1 -- or to 0.0.0.0, the
      # IPv4 wildcard, which does NOT cover IPv6 -- refuses the browser with
      # ERR_CONNECTION_REFUSED even though it is serving. The primary bind above
      # is unchanged (keeps its fail-closed throw + port-takeover); each sibling
      # is BEST-EFFORT: a family that is unavailable, or that the primary bind
      # already answers, raises and is skipped -- a sibling failure NEVER fails
      # the boot. Main port only (mirrors tina4-php PR #206); the AI/debug port
      # is left alone.
      self.class.loopback_bind_hosts(@host).each do |sibling_host|
        begin
          @server.listen(sibling_host, @port, @app)
        rescue Errno::EADDRINUSE, Errno::EADDRNOTAVAIL, SocketError, Errno::EAFNOSUPPORT => e
          Tina4::Log.debug("Dual-stack loopback: skipped #{sibling_host}:#{@port} (#{e.class})")
        end
      end

      # Record THIS process as the Tina4 dev server on the main port, so a later
      # `tina4 serve` can identify it as reclaimable (TAKEOVER-DEC-01).
      Tina4::PortTakeover.write_pidfile(@port)

      # Graceful shutdown: Tina4::Shutdown closes the listeners first, then
      # drains in-flight requests (bounded by TINA4_SHUTDOWN_TIMEOUT).
      Tina4::Shutdown.setup(server: @server)

      # Test port (port + 1000) — stable, no-browser
      no_ai_port = %w[true 1 yes].include?(ENV.fetch("TINA4_NO_AI_PORT", "").downcase)
      is_debug   = %w[true 1 yes].include?(ENV.fetch("TINA4_DEBUG", "").downcase)

      if is_debug && !no_ai_port
        ai_port = @port + 1000
        begin
          # Tagged so the pipeline suppresses live reload on this port.
          @server.listen(@host, ai_port, Tina4::AiPortRackApp.new(@app))
          puts "  Test Port: http://localhost:#{ai_port} (stable — no hot-reload)"
        rescue Errno::EADDRINUSE
          puts "  Test Port: SKIPPED (port #{ai_port} in use)"
        end
      end

      @server.start

      # Shutdown closes the listener FIRST, so #start returns as soon as the
      # accept loop stops - potentially while the signal handler's thread is
      # still draining requests, stopping background tasks and closing the
      # database. Wait for that teardown instead of exiting out from under it.
      Tina4::Shutdown.wait_for_completion
    end

    def stop
      @server&.shutdown
      # Drop our identity marker so a later takeover does not match a dead PID.
      Tina4::PortTakeover.remove_pidfile(@port)
    end

    # Dispatch a Rack-style env through the Tina4 app and return [status, headers, body].
    #
    # Useful for testing and embedding — does not require a running server.
    # Cross-framework parity with Python and Node.js.
    #
    # @param env [Hash] A Rack environment hash
    # @return [Array] Rack-style response triple [status, headers, body]
    def handle(env)
      @app.call(env)
    end

    # Sibling loopback addresses to ALSO listen on, so `localhost` reaches this
    # server whether the OS resolves it to IPv4 (127.0.0.1) or IPv6 (::1).
    #
    # Returns only the families a direct bind of *host* does not already cover;
    # a host that is neither loopback nor a wildcard yields an empty list -- an
    # explicit LAN address is bound exactly as asked, with no sibling. The host
    # is normalised (downcased, surrounding whitespace and brackets stripped) so
    # "[::1]", " ::1 " and "::1" all resolve alike.
    #
    # Mirrors the tina4-php Server::loopbackBindHosts mapping exactly. Ruby
    # binds "::1" WITHOUT brackets (PHP's stream URL needed "[::1]"; the brackets
    # are not carried into Ruby).
    #
    # @param host [String] the host the main socket binds
    # @return [Array<String>] extra bind addresses (possibly empty)
    def self.loopback_bind_hosts(host)
      normalized = host.to_s.strip.downcase.gsub(/\A\[+|\]+\z/, "")
      case normalized
      when "localhost"            then ["127.0.0.1", "::1"]
      when "127.0.0.1", "0.0.0.0" then ["::1"]
      when "::1", "::"            then ["127.0.0.1"]
      else []
      end
    end
  end
end
