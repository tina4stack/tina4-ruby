# frozen_string_literal: true

require_relative "port_takeover"

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

      require "webrick"
      require "stringio"
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

      Tina4.print_banner(host: @host, port: @port)
      Tina4::Log.info("Starting Tina4 WEBrick server on http://#{@host}:#{@port}")
      @server = WEBrick::HTTPServer.new(
        BindAddress: @host,
        Port: @port,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )

      # Record THIS process as the Tina4 dev server on the main port, so a later
      # `tina4 serve` can identify it as reclaimable (TAKEOVER-DEC-01).
      Tina4::PortTakeover.write_pidfile(@port)

      # Setup graceful shutdown with WEBrick server reference
      Tina4::Shutdown.setup(server: @server)

      # Use a custom servlet that passes ALL methods (including OPTIONS) to Rack
      rack_app = @app
      servlet = build_rack_servlet(@host, @port.to_s)

      @server.mount("/", servlet, rack_app)

      # Test port (port + 1000) — stable, no-browser
      @ai_server = nil
      @ai_thread = nil
      no_ai_port = %w[true 1 yes].include?(ENV.fetch("TINA4_NO_AI_PORT", "").downcase)
      is_debug   = %w[true 1 yes].include?(ENV.fetch("TINA4_DEBUG", "").downcase)

      if is_debug && !no_ai_port
        ai_port = @port + 1000
        begin
          test = TCPServer.new("0.0.0.0", ai_port)
          test.close

          @ai_server = WEBrick::HTTPServer.new(
            BindAddress: @host,
            Port: ai_port,
            Logger: WEBrick::Log.new(File::NULL),
            AccessLog: []
          )

          # Wrap the rack app so AI-port requests are tagged
          ai_rack_app = Tina4::AiPortRackApp.new(@app)

          # Same servlet as the main port, bound to the AI port's host/port.
          ai_servlet = build_rack_servlet(@host, ai_port.to_s)

          @ai_server.mount("/", ai_servlet, ai_rack_app)
          @ai_thread = Thread.new { @ai_server.start }
          puts "  Test Port: http://localhost:#{ai_port} (stable — no hot-reload)"
        rescue Errno::EADDRINUSE
          puts "  Test Port: SKIPPED (port #{ai_port} in use)"
        end
      end

      @server.start

      # Shutdown closes the listener FIRST, so #start returns as soon as the
      # in-flight workers are joined - potentially while the signal handler's
      # thread is still stopping background tasks and closing the database.
      # Wait for that teardown instead of exiting out from under it.
      Tina4::Shutdown.wait_for_completion
    end

    def stop
      @ai_server&.shutdown
      @ai_thread&.join(5)
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

    private

    # Build the Rack->WEBrick servlet class bound to a specific host/port.
    # The main port and the debug AI port mount an identical servlet; the ONLY
    # difference is the host/port reported in the Rack env, bound below via
    # define_method. Extracted from two verbatim-identical copies.
    def build_rack_servlet(host, port)
      servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
        define_method(:initialize) do |server, app|
          super(server)
          @app = app
        end

        %w[GET POST PUT DELETE PATCH HEAD OPTIONS].each do |http_method|
          define_method("do_#{http_method}") do |webrick_req, webrick_res|
            handle_request(webrick_req, webrick_res)
          end
        end

        define_method(:handle_request) do |webrick_req, webrick_res|
          # Belt-and-braces, NOT the primary mechanism. Shutdown closes the
          # listening socket FIRST, so a connection arriving after the signal is
          # refused by the kernel and never reaches here. What is left is a
          # genuine race: WEBrick accepts a connection and parses its request in
          # a worker thread, and the @shutting_down flag can flip in the gap
          # before that worker reaches this line.
          #
          # Measured (macOS 26.5.2, Ruby 4.0.2, webrick 1.9.2, 48 threads
          # hammering across a real SIGTERM): the window is the ~10-90ms between
          # the flag flip and the listener actually closing, and 0-2 requests per
          # run land in it out of ~2000. Every request after that is
          # ECONNREFUSED. Rare, but reachable - so the guard stays.
          if Tina4::Shutdown.shutting_down?
            webrick_res.status = 503
            webrick_res.body = '{"error":"Service shutting down"}'
            webrick_res["content-type"] = "application/json"
            return
          end

          Tina4::Shutdown.track_request do
            env = build_rack_env(webrick_req)
            status, headers, body = @app.call(env)

            webrick_res.status = status
            headers.each do |key, value|
              if key.downcase == "set-cookie"
                Array(value.split("\n")).each { |c| webrick_res.cookies << WEBrick::Cookie.parse_set_cookie(c) }
              else
                webrick_res[key] = value
              end
            end

            response_body = ""
            body.each { |chunk| response_body += chunk }
            webrick_res.body = response_body
          end
        end

        define_method(:build_rack_env) do |req|
          input = StringIO.new(req.body || "")
          env = {
            "REQUEST_METHOD" => req.request_method,
            "PATH_INFO" => req.path,
            "QUERY_STRING" => req.query_string || "",
            "SERVER_NAME" => webrick_req_host,
            "SERVER_PORT" => webrick_req_port,
            "CONTENT_TYPE" => req.content_type || "",
            "CONTENT_LENGTH" => (req.content_length rescue 0).to_s,
            "REMOTE_ADDR" => req.peeraddr&.last || "127.0.0.1",
            "rack.input" => input,
            "rack.errors" => $stderr,
            "rack.url_scheme" => "http",
            "rack.version" => [1, 3],
            "rack.multithread" => true,
            "rack.multiprocess" => false,
            "rack.run_once" => false
          }

          req.header.each do |key, values|
            env_key = "HTTP_#{key.upcase.gsub('-', '_')}"
            env[env_key] = values.join(", ")
          end

          env
        end
      end

      # Bind the per-server host/port the Rack env reports (the ONLY thing that
      # differs between the main port and the AI port).
      servlet.define_method(:webrick_req_host) { host }
      servlet.define_method(:webrick_req_port) { port }
      servlet
    end
  end
end
