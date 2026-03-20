# frozen_string_literal: true

module Tina4
  class WebServer
    def initialize(app, host: "0.0.0.0", port: 7145)
      @app = app
      @host = host
      @port = port
    end

    def start
      require "webrick"
      require "stringio"
      Tina4.print_banner
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
      @server.start
    end

    def stop
      @server&.shutdown
    end
  end
end
