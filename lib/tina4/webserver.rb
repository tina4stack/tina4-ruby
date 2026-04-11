# frozen_string_literal: true

module Tina4
  class WebServer
    def initialize(app, host: "0.0.0.0", port: 7147)
      @app = app
      @host = host
      @port = port
    end

    # Kill whatever process is listening on *port*.
    # Uses lsof on macOS/Linux and netstat + taskkill on Windows.
    # Raises RuntimeError if the port cannot be freed.
    def free_port(port)
      puts "  Port #{port} in use — killing existing process..."

      if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        output = `netstat -ano 2>&1`
        pid = nil
        output.each_line do |line|
          if line.include?(":#{port}") && (line.include?("LISTENING") || line.include?("ESTABLISHED"))
            parts = line.strip.split(/\s+/)
            candidate = parts.last
            if candidate =~ /^\d+$/
              pid = candidate
              break
            end
          end
        end
        if pid
          system("taskkill /PID #{pid} /F")
        else
          raise "Could not free port #{port}: no PID found"
        end
      else
        pids = `lsof -ti :#{port} 2>/dev/null`.strip.split("\n")
        if pids.empty?
          return # Nothing found — port may have freed itself
        end
        pids.each do |pid|
          pid = pid.strip
          next unless pid =~ /^\d+$/
          begin
            Process.kill("TERM", pid.to_i)
          rescue Errno::ESRCH
            # Process already gone
          end
        end
      end

      # Give the OS a moment to reclaim the port
      sleep(0.5)
      puts "  Port #{port} freed"
    end

    def start
      unless ENV['TINA4_CLI'] == 'true' || ENV['TINA4_OVERRIDE_CLIENT'] == 'true'
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

      # Setup graceful shutdown with WEBrick server reference
      Tina4::Shutdown.setup(server: @server)

      # Use a custom servlet that passes ALL methods (including OPTIONS) to Rack
      rack_app = @app
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
          # Reject new requests during shutdown
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

      # Store host/port for the servlet's build_rack_env
      host = @host
      port = @port.to_s
      servlet.define_method(:webrick_req_host) { host }
      servlet.define_method(:webrick_req_port) { port }

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

          # Build a servlet identical to the main one but bound to the AI port host/port
          ai_host = @host
          ai_port_str = ai_port.to_s
          ai_servlet = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
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
                "REQUEST_METHOD"  => req.request_method,
                "PATH_INFO"       => req.path,
                "QUERY_STRING"    => req.query_string || "",
                "SERVER_NAME"     => webrick_req_host,
                "SERVER_PORT"     => webrick_req_port,
                "CONTENT_TYPE"    => req.content_type || "",
                "CONTENT_LENGTH"  => (req.content_length rescue 0).to_s,
                "REMOTE_ADDR"     => req.peeraddr&.last || "127.0.0.1",
                "rack.input"      => input,
                "rack.errors"     => $stderr,
                "rack.url_scheme" => "http",
                "rack.version"    => [1, 3],
                "rack.multithread"  => true,
                "rack.multiprocess" => false,
                "rack.run_once"     => false
              }

              req.header.each do |key, values|
                env_key = "HTTP_#{key.upcase.gsub('-', '_')}"
                env[env_key] = values.join(", ")
              end

              env
            end
          end

          ai_servlet.define_method(:webrick_req_host) { ai_host }
          ai_servlet.define_method(:webrick_req_port) { ai_port_str }

          @ai_server.mount("/", ai_servlet, ai_rack_app)
          @ai_thread = Thread.new { @ai_server.start }
          puts "  Test Port: http://localhost:#{ai_port} (stable — no hot-reload)"
        rescue Errno::EADDRINUSE
          puts "  Test Port: SKIPPED (port #{ai_port} in use)"
        end
      end

      @server.start
    end

    def stop
      @ai_server&.shutdown
      @ai_thread&.join(5)
      @server&.shutdown
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
  end
end
