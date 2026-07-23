# Tina4 Test Client — Test routes without starting a server.
#
# Usage:
#
#   client = Tina4::TestClient.new
#
#   response = client.get("/api/users")
#   assert_equal 200, response.status
#   assert response.json["users"]
#
#   response = client.post("/api/users", json: { name: "Alice" })
#   assert_equal 201, response.status
#
#   response = client.get("/api/users/1", headers: { "Authorization" => "Bearer token123" })
#
require "stringio" # rack.input is a StringIO; require it here so a clean `require "tina4"` boot never NameErrors

module Tina4
  class TestResponse
    attr_reader :status, :body, :headers, :content_type

    # Build from a Rack response tuple [status, headers, body_array]
    def initialize(rack_response)
      @status = rack_response[0]
      @headers = rack_response[1] || {}
      @content_type = @headers["content-type"] || ""
      raw_body = rack_response[2]
      @body = raw_body.is_a?(Array) ? raw_body.join : raw_body.to_s
    end

    # Parse body as JSON.
    def json
      return nil if @body.nil? || @body.empty?
      JSON.parse(@body)
    rescue JSON::ParserError
      nil
    end

    # Return body as a string.
    def text
      @body.to_s
    end

    def inspect
      "<TestResponse status=#{@status} content_type=#{@content_type.inspect}>"
    end
  end

  class TestClient
    # +app+ — the Rack app every request is dispatched through. Defaults to the
    # process-wide Tina4::RackApp (RackApp.current): inside a running server that
    # IS the app serving traffic, so an in-process test request and a live request
    # go through the same object. With no app yet (a bare spec process) one is
    # built lazily, rooted at +root_dir+ / Tina4.root_dir / Dir.pwd.
    #
    # Mirrors Node's `new TestClient(router?)` optional-collaborator constructor.
    def initialize(app = nil, root_dir: nil)
      @app = app
      @root_dir = root_dir
    end

    def app
      @app ||= Tina4::RackApp.current ||
               Tina4::RackApp.new(root_dir: @root_dir || Tina4.root_dir || Dir.pwd)
    end

    # Send a GET request.
    def get(path, headers: nil)
      request("GET", path, headers: headers)
    end

    # Send a POST request.
    def post(path, json: nil, body: nil, headers: nil)
      request("POST", path, json: json, body: body, headers: headers)
    end

    # Send a PUT request.
    def put(path, json: nil, body: nil, headers: nil)
      request("PUT", path, json: json, body: body, headers: headers)
    end

    # Send a PATCH request.
    def patch(path, json: nil, body: nil, headers: nil)
      request("PATCH", path, json: json, body: body, headers: headers)
    end

    # Send a DELETE request.
    def delete(path, headers: nil)
      request("DELETE", path, headers: headers)
    end

    private

    # Build a Rack env and dispatch it through the REAL Tina4::RackApp — the same
    # front controller a live HTTP request goes through.
    #
    # This used to call Tina4::Router.match directly and invoke the handler
    # itself, which made everything RackApp does around route matching invisible
    # to tests: global middleware never ran, and static files, /swagger,
    # /swagger/openapi.json, the bundled framework assets, /__dev, /__feedback,
    # CORS preflight, the RFC 9110 OPTIONS/405 Allow responses and HEAD
    # body-stripping all came back as a hand-built 404 {"error":"Not found"} while
    # the live server served them 200. Any spec asserting framework endpoint
    # behaviour through TestClient was asserting nothing. (feature-recount D6 —
    # the same shape as the #PY2 auth fix: the in-process test client must route
    # through the real pipeline, not a re-implementation of it.)
    def request(method, path, json: nil, body: nil, headers: nil)
      # Build raw body
      raw_body = ""
      content_type = ""

      if json
        raw_body = JSON.generate(json)
        content_type = "application/json"
      elsif body
        raw_body = body.to_s
      end

      # Split path and query string
      clean_path, query_string = path.include?("?") ? path.split("?", 2) : [path, ""]

      # Build Rack env hash
      env = {
        "REQUEST_METHOD" => method.upcase,
        "PATH_INFO" => clean_path,
        "QUERY_STRING" => query_string || "",
        "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "7145",
        "HTTP_HOST" => "localhost:7145",
        "REMOTE_ADDR" => "127.0.0.1",
        "SERVER_PROTOCOL" => "HTTP/1.1",
        "rack.input" => StringIO.new(raw_body),
        "rack.errors" => $stderr,
        "rack.url_scheme" => "http"
      }

      # Add content type
      env["CONTENT_TYPE"] = content_type unless content_type.empty?
      env["CONTENT_LENGTH"] = raw_body.bytesize.to_s unless raw_body.empty?

      # Add custom headers (convert to Rack format: X-Custom → HTTP_X_CUSTOM)
      if headers
        headers.each do |key, value|
          rack_key = "HTTP_#{key.upcase.tr('-', '_')}"
          env[rack_key] = value
        end
      end

      # Dispatch through the real front controller. Everything the live server
      # does — the secure-by-default auth gate (#PY2), global + per-route
      # middleware, route matching and handler invocation, template rendering,
      # response auto-detection, static files, /swagger, /__dev, /__feedback, the
      # RFC 9110 OPTIONS/405 responses, HEAD body-stripping, session save and the
      # 500 handler — is now exercised exactly once, in one place.
      TestResponse.new(app.call(env))
    end
  end
end
