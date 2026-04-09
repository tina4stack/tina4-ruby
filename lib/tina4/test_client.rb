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

    # Build a mock Rack env, match the route, execute the handler.
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
        "rack.input" => StringIO.new(raw_body),
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

      # Match route
      result = Tina4::Router.match(method.upcase, clean_path)

      unless result
        return TestResponse.new([404, { "content-type" => "application/json" }, ['{"error":"Not found"}']])
      end

      route, path_params = result

      # Create request and response
      req = Tina4::Request.new(env, path_params || {})
      res = Tina4::Response.new

      # Build handler args (same logic as RackApp.handle_route)
      handler_params = route.handler.parameters.map(&:last)
      route_params = path_params || {}
      args = handler_params.map do |name|
        if route_params.key?(name)
          route_params[name]
        elsif name == :request || name == :req
          req
        else
          res
        end
      end

      # Execute handler
      handler_result = args.empty? ? route.handler.call : route.handler.call(*args)

      # Auto-detect response type
      if handler_result.is_a?(Tina4::Response)
        final = handler_result
      elsif route.respond_to?(:template) && route.template && handler_result.is_a?(Hash)
        html = Tina4::Template.render(route.template, handler_result)
        res.html(html)
        final = res
      else
        final = Tina4::Response.auto_detect(handler_result, res)
      end

      TestResponse.new(final.to_rack)
    end
  end
end
