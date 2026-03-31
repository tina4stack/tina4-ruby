# frozen_string_literal: true

# Tina4 MCP Server -- Model Context Protocol for AI tool integration.
#
# Built-in MCP server for dev tools + developer API for custom MCP servers.
#
# Usage (developer):
#
#     mcp = Tina4::McpServer.new("/my-mcp", name: "My App Tools")
#
#     Tina4.mcp_tool("lookup_invoice", description: "Find invoice by number", server: mcp) do |invoice_no:|
#       db.fetch_one("SELECT * FROM invoices WHERE invoice_no = ?", [invoice_no])
#     end
#
#     Tina4.mcp_resource("app://schema", description: "Database schema", server: mcp) do
#       db.tables
#     end
#
# Built-in dev tools auto-register when TINA4_DEBUG=true and running on localhost.

require "json"
require "socket"
require "fileutils"

module Tina4
  # ── JSON-RPC 2.0 codec ────────────────────────────────────────────
  module McpProtocol
    # Standard JSON-RPC 2.0 error codes
    PARSE_ERROR       = -32_700
    INVALID_REQUEST   = -32_600
    METHOD_NOT_FOUND  = -32_601
    INVALID_PARAMS    = -32_602
    INTERNAL_ERROR    = -32_603

    # Encode a successful JSON-RPC 2.0 response.
    def self.encode_response(request_id, result)
      JSON.generate({
        "jsonrpc" => "2.0",
        "id"      => request_id,
        "result"  => result
      })
    end

    # Encode a JSON-RPC 2.0 error response.
    def self.encode_error(request_id, code, message, data = nil)
      error = { "code" => code, "message" => message }
      error["data"] = data unless data.nil?
      JSON.generate({
        "jsonrpc" => "2.0",
        "id"      => request_id,
        "error"   => error
      })
    end

    # Encode a JSON-RPC 2.0 notification (no id).
    def self.encode_notification(method, params = nil)
      msg = { "jsonrpc" => "2.0", "method" => method }
      msg["params"] = params unless params.nil?
      JSON.generate(msg)
    end

    # Decode a JSON-RPC 2.0 request.
    #
    # @return [Array<(String, Hash, Object)>] method, params, request_id
    # @raise [ArgumentError] if the message is malformed
    def self.decode_request(data)
      case data
      when String
        begin
          msg = JSON.parse(data)
        rescue JSON::ParserError => e
          raise ArgumentError, "Invalid JSON: #{e.message}"
        end
      when Hash
        msg = data
      else
        raise ArgumentError, "Message must be a String or Hash"
      end

      raise ArgumentError, "Message must be a JSON object" unless msg.is_a?(Hash)
      raise ArgumentError, "Missing or invalid jsonrpc version" unless msg["jsonrpc"] == "2.0"

      method = msg["method"]
      raise ArgumentError, "Missing or invalid method" if method.nil? || !method.is_a?(String) || method.empty?

      params     = msg.fetch("params", {})
      request_id = msg["id"] # nil for notifications

      [method, params, request_id]
    end
  end

  # ── Type mapping ──────────────────────────────────────────────────
  TYPE_MAP = {
    "String"    => "string",
    "Integer"   => "integer",
    "Float"     => "number",
    "Numeric"   => "number",
    "TrueClass" => "boolean",
    "FalseClass"=> "boolean",
    "Array"     => "array",
    "Hash"      => "object"
  }.freeze

  # Extract JSON Schema input schema from a Ruby method's parameters.
  def self.schema_from_method(method_obj)
    properties = {}
    required   = []

    method_obj.parameters.each do |kind, name|
      next if name == :self
      name_s = name.to_s

      # Default type is "string" -- Ruby doesn't have inline type annotations
      prop = { "type" => "string" }

      case kind
      when :req, :keyreq
        required << name_s
      when :opt, :key
        # Has a default -- we cannot inspect the default value easily in Ruby,
        # so we just mark it as optional (no "default" key)
      end

      properties[name_s] = prop
    end

    schema = { "type" => "object", "properties" => properties }
    schema["required"] = required unless required.empty?
    schema
  end

  # Check if the server is running on localhost.
  def self.is_localhost?
    host = ENV.fetch("HOST_NAME", "localhost:7145").split(":").first
    ["localhost", "127.0.0.1", "0.0.0.0", "::1", ""].include?(host)
  end

  # ── McpServer ─────────────────────────────────────────────────────
  class McpServer
    attr_reader :path, :name, :version

    # Class-level registry of all MCP server instances
    @instances = []
    class << self
      attr_reader :instances
    end

    def initialize(path, name: "Tina4 MCP", version: "1.0.0")
      @path        = path.chomp("/")
      @name        = name
      @version     = version
      @tools       = {}
      @resources   = {}
      @initialized = false
      self.class.instances << self
    end

    # Register a tool callable.
    #
    # @param name [String]
    # @param handler [Method, Proc, #call] the callable
    # @param description [String]
    # @param schema [Hash, nil] override auto-detected schema
    def register_tool(name, handler, description = "", schema = nil)
      schema ||= Tina4.schema_from_method(handler)
      @tools[name] = {
        "name"        => name,
        "description" => description.empty? ? name : description,
        "inputSchema" => schema,
        "handler"     => handler
      }
    end

    # Register a resource URI.
    def register_resource(uri, handler, description = "", mime_type = "application/json")
      @resources[uri] = {
        "uri"         => uri,
        "name"        => description.empty? ? uri : description,
        "description" => description.empty? ? uri : description,
        "mimeType"    => mime_type,
        "handler"     => handler
      }
    end

    # Process an incoming JSON-RPC message and return the response string.
    def handle_message(raw_data)
      begin
        method, params, request_id = McpProtocol.decode_request(raw_data)
      rescue ArgumentError => e
        return McpProtocol.encode_error(nil, McpProtocol::PARSE_ERROR, e.message)
      end

      handler_method = {
        "initialize"                 => :_handle_initialize,
        "notifications/initialized"  => :_handle_initialized,
        "tools/list"                 => :_handle_tools_list,
        "tools/call"                 => :_handle_tools_call,
        "resources/list"             => :_handle_resources_list,
        "resources/read"             => :_handle_resources_read,
        "ping"                       => :_handle_ping
      }[method]

      if handler_method.nil?
        return McpProtocol.encode_error(request_id, McpProtocol::METHOD_NOT_FOUND, "Method not found: #{method}")
      end

      begin
        result = send(handler_method, params)
        return "" if request_id.nil? # Notification -- no response
        McpProtocol.encode_response(request_id, result)
      rescue => e
        McpProtocol.encode_error(request_id, McpProtocol::INTERNAL_ERROR, e.message)
      end
    end

    # Register HTTP routes for this MCP server on the Tina4 router.
    def register_routes
      server   = self
      msg_path = "#{@path}/message"
      sse_path = "#{@path}/sse"

      Tina4::Router.post(msg_path) do |request, response|
        body = request.body
        raw  = body.is_a?(Hash) ? body : (body.is_a?(String) ? body : body.to_s)
        result = server.handle_message(raw)
        if result.nil? || result.empty?
          response.call("", 204)
        else
          response.call(JSON.parse(result))
        end
      end

      Tina4::Router.get(sse_path) do |request, response|
        endpoint_url = "#{request.url.sub(%r{/sse\z}, "")}/message"
        sse_data = "event: endpoint\ndata: #{endpoint_url}\n\n"
        response.call(sse_data, 200, "text/event-stream")
      end
    end

    # Write/update .claude/settings.json with this MCP server config.
    def write_claude_config(port = 7145)
      config_dir = File.join(Dir.pwd, ".claude")
      FileUtils.mkdir_p(config_dir)
      config_file = File.join(config_dir, "settings.json")

      config = {}
      if File.exist?(config_file)
        begin
          config = JSON.parse(File.read(config_file))
        rescue JSON::ParserError, IOError
          # ignore corrupt file
        end
      end

      config["mcpServers"] ||= {}
      server_key = @name.downcase.gsub(" ", "-")
      config["mcpServers"][server_key] = {
        "url" => "http://localhost:#{port}#{@path}/sse"
      }

      File.write(config_file, JSON.pretty_generate(config) + "\n")
    end

    # Access registered tools (for testing)
    def tools
      @tools
    end

    # Access registered resources (for testing)
    def resources
      @resources
    end

    private

    def _handle_initialize(_params)
      @initialized = true
      {
        "protocolVersion" => "2024-11-05",
        "capabilities"    => {
          "tools"     => { "listChanged" => false },
          "resources" => { "subscribe" => false, "listChanged" => false }
        },
        "serverInfo" => {
          "name"    => @name,
          "version" => @version
        }
      }
    end

    def _handle_initialized(_params)
      nil
    end

    def _handle_ping(_params)
      {}
    end

    def _handle_tools_list(_params)
      tools_list = @tools.values.map do |t|
        {
          "name"        => t["name"],
          "description" => t["description"],
          "inputSchema" => t["inputSchema"]
        }
      end
      { "tools" => tools_list }
    end

    def _handle_tools_call(params)
      tool_name = params["name"]
      raise ArgumentError, "Missing tool name" if tool_name.nil? || tool_name.empty?

      tool = @tools[tool_name]
      raise ArgumentError, "Unknown tool: #{tool_name}" if tool.nil?

      arguments = params.fetch("arguments", {})
      handler   = tool["handler"]

      # Call the handler -- support both keyword and positional args
      result = _invoke_handler(handler, arguments)

      # Format result as MCP content
      content = case result
                when String
                  [{ "type" => "text", "text" => result }]
                when Hash, Array
                  [{ "type" => "text", "text" => JSON.pretty_generate(result) }]
                else
                  [{ "type" => "text", "text" => result.to_s }]
                end

      { "content" => content }
    end

    def _handle_resources_list(_params)
      resources_list = @resources.values.map do |r|
        {
          "uri"         => r["uri"],
          "name"        => r["name"],
          "description" => r["description"],
          "mimeType"    => r["mimeType"]
        }
      end
      { "resources" => resources_list }
    end

    def _handle_resources_read(params)
      uri = params["uri"]
      raise ArgumentError, "Missing resource URI" if uri.nil? || uri.empty?

      resource = @resources[uri]
      raise ArgumentError, "Unknown resource: #{uri}" if resource.nil?

      result = resource["handler"].call

      text = case result
             when String then result
             when Hash, Array then JSON.pretty_generate(result)
             else result.to_s
             end

      {
        "contents" => [{
          "uri"      => uri,
          "mimeType" => resource["mimeType"],
          "text"     => text
        }]
      }
    end

    # Invoke a handler with arguments, supporting keyword args, positional args, and procs.
    def _invoke_handler(handler, arguments)
      if handler.is_a?(Proc) || handler.is_a?(Method)
        params = handler.parameters
        has_keywords = params.any? { |kind, _| [:key, :keyreq, :keyrest].include?(kind) }

        if has_keywords
          # Convert string keys to symbols for keyword args
          kwargs = arguments.transform_keys(&:to_sym)
          handler.call(**kwargs)
        elsif params.any? { |kind, _| [:req, :opt].include?(kind) }
          # Positional args -- pass values in parameter order
          args = params.select { |kind, _| [:req, :opt].include?(kind) }
                       .map { |_, name| arguments[name.to_s] }
          handler.call(*args)
        else
          handler.call
        end
      else
        handler.call(**arguments.transform_keys(&:to_sym))
      end
    end
  end

  # ── Decorator-style API ───────────────────────────────────────────

  @_default_mcp_server = nil

  def self._default_mcp_server
    @_default_mcp_server ||= McpServer.new("/__dev/mcp", name: "Tina4 Dev Tools")
  end

  # Register a block as an MCP tool.
  #
  #   Tina4.mcp_tool("lookup_invoice", description: "Find invoice by number") do |invoice_no:|
  #     db.fetch_one("SELECT * FROM invoices WHERE invoice_no = ?", [invoice_no])
  #   end
  def self.mcp_tool(name, description: "", server: nil, &block)
    target = server || _default_mcp_server
    handler = block
    tool_desc = description.empty? ? name : description
    target.register_tool(name, handler, tool_desc)
    handler
  end

  # Register a block as an MCP resource.
  #
  #   Tina4.mcp_resource("app://tables", description: "Database tables") do
  #     db.tables
  #   end
  def self.mcp_resource(uri, description: "", mime_type: "application/json", server: nil, &block)
    target = server || _default_mcp_server
    target.register_resource(uri, block, description, mime_type)
    block
  end

  # ── Built-in dev tools ────────────────────────────────────────────
  module McpDevTools
    # Register all 24 built-in dev tools on the given McpServer.
    def self.register(server)
      project_root = File.expand_path(Dir.pwd)

      # ── Helpers ────────────────────────────────────────
      safe_path = lambda do |rel_path|
        resolved = File.expand_path(rel_path, project_root)
        unless resolved.start_with?(project_root)
          raise ArgumentError, "Path escapes project directory: #{rel_path}"
        end
        resolved
      end

      redact_env = lambda do |key, value|
        sensitive = %w[secret password token key credential api_key]
        if sensitive.any? { |s| key.downcase.include?(s) }
          "***REDACTED***"
        else
          value
        end
      end

      # ── Database Tools ────────────────────────────────
      server.register_tool("database_query", lambda { |sql:, params: "[]"|
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        param_list = params.is_a?(String) ? JSON.parse(params) : params
        result = db.fetch(sql, param_list)
        { "records" => result.to_a, "count" => result.count }
      }, "Execute a read-only SQL query (SELECT)")

      server.register_tool("database_execute", lambda { |sql:, params: "[]"|
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        param_list = params.is_a?(String) ? JSON.parse(params) : params
        result = db.execute(sql, param_list)
        db.commit rescue nil
        { "success" => true, "affected_rows" => (result.respond_to?(:count) ? result.count : 0) }
      }, "Execute arbitrary SQL (INSERT/UPDATE/DELETE/DDL)")

      server.register_tool("database_tables", lambda {
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        db.tables
      }, "List all database tables")

      server.register_tool("database_columns", lambda { |table:|
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        db.columns(table)
      }, "Get column definitions for a table")

      # ── Route Tools ───────────────────────────────────
      server.register_tool("route_list", lambda {
        routes = Tina4::Router.routes
        routes.map do |route|
          {
            "method"        => route[:method].to_s,
            "path"          => route[:path].to_s,
            "auth_required" => !route[:auth_handler].nil?
          }
        end
      }, "List all registered routes")

      server.register_tool("route_test", lambda { |method:, path:, body: "", headers: "{}"|
        client = Tina4::TestClient.new
        header_hash = headers.is_a?(String) ? JSON.parse(headers) : headers
        m = method.upcase
        r = case m
            when "GET"    then client.get(path, headers: header_hash)
            when "POST"   then client.post(path, body: body, headers: header_hash)
            when "PUT"    then client.put(path, body: body, headers: header_hash)
            when "DELETE" then client.delete(path, headers: header_hash)
            else return { "error" => "Unsupported method: #{method}" }
            end
        { "status" => r.status, "body" => r.body, "content_type" => r.content_type }
      }, "Call a route and return the response")

      server.register_tool("swagger_spec", lambda {
        Tina4::Swagger.generate
      }, "Return the OpenAPI 3.0.3 JSON spec")

      # ── Template Tools ────────────────────────────────
      server.register_tool("template_render", lambda { |template:, data: "{}"|
        ctx = data.is_a?(String) ? JSON.parse(data) : data
        Tina4::Template.render_string(template, ctx)
      }, "Render a template string with data")

      # ── File Tools ────────────────────────────────────
      server.register_tool("file_read", lambda { |path:|
        p = safe_path.call(path)
        return "File not found: #{path}" unless File.exist?(p)
        return "Not a file: #{path}" unless File.file?(p)
        File.read(p, encoding: "utf-8")
      }, "Read a project file")

      server.register_tool("file_write", lambda { |path:, content:|
        p = safe_path.call(path)
        FileUtils.mkdir_p(File.dirname(p))
        File.write(p, content, encoding: "utf-8")
        rel = p.sub("#{project_root}/", "")
        { "written" => rel, "bytes" => content.bytesize }
      }, "Write or update a project file")

      server.register_tool("file_list", lambda { |path: "."|
        p = safe_path.call(path)
        return { "error" => "Directory not found: #{path}" } unless File.exist?(p)
        return { "error" => "Not a directory: #{path}" } unless File.directory?(p)
        Dir.children(p).sort.map do |entry|
          full = File.join(p, entry)
          {
            "name" => entry,
            "type" => File.directory?(full) ? "dir" : "file",
            "size" => File.file?(full) ? File.size(full) : 0
          }
        end
      }, "List files in a directory")

      server.register_tool("asset_upload", lambda { |filename:, content:, encoding: "utf-8"|
        target = safe_path.call("src/public/#{filename}")
        FileUtils.mkdir_p(File.dirname(target))
        if encoding == "base64"
          require "base64"
          File.binwrite(target, Base64.decode64(content))
        else
          File.write(target, content, encoding: "utf-8")
        end
        rel = target.sub("#{project_root}/", "")
        { "uploaded" => rel, "bytes" => File.size(target) }
      }, "Upload a file to src/public/")

      # ── Migration Tools ───────────────────────────────
      server.register_tool("migration_status", lambda {
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        migration = Tina4::Migration.new(db)
        migration.respond_to?(:status) ? migration.status : { "info" => "Migration status not available" }
      }, "List pending and completed migrations")

      server.register_tool("migration_create", lambda { |description:|
        migration = Tina4::Migration.new(nil)
        filename = migration.create(description)
        { "created" => filename }
      }, "Create a new migration file")

      server.register_tool("migration_run", lambda {
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        migration = Tina4::Migration.new(db)
        result = migration.run
        { "result" => result.to_s }
      }, "Run all pending migrations")

      # ── Queue Tools ───────────────────────────────────
      server.register_tool("queue_status", lambda { |topic: "default"|
        begin
          q = Tina4::Queue.new(topic: topic)
          {
            "topic"     => topic,
            "pending"   => q.size("pending"),
            "completed" => q.size("completed"),
            "failed"    => q.size("failed")
          }
        rescue => e
          { "error" => e.message }
        end
      }, "Get queue size by status")

      # ── Session/Cache Tools ───────────────────────────
      server.register_tool("session_list", lambda {
        session_dir = File.join("data", "sessions")
        return [] unless File.directory?(session_dir)
        Dir.glob(File.join(session_dir, "*.json")).map do |f|
          begin
            data = JSON.parse(File.read(f))
            { "id" => File.basename(f, ".json"), "data" => data }
          rescue JSON::ParserError, IOError
            { "id" => File.basename(f, ".json"), "error" => "corrupt" }
          end
        end
      }, "List active sessions")

      server.register_tool("cache_stats", lambda {
        begin
          if defined?(Tina4::ResponseCache)
            cache = Tina4::ResponseCache.new
            cache.cache_stats
          else
            { "error" => "Response cache not available" }
          end
        rescue => e
          { "error" => e.message }
        end
      }, "Get response cache statistics")

      # ── ORM Tools ─────────────────────────────────────
      server.register_tool("orm_describe", lambda {
        models = []
        Tina4::ORM.subclasses.each do |cls|
          fields = cls.field_definitions.map do |name, field|
            {
              "name"        => name.to_s,
              "type"        => field[:type].to_s,
              "primary_key" => field[:primary_key] == true
            }
          end
          models << {
            "class"  => cls.name,
            "table"  => cls.respond_to?(:table_name) ? cls.table_name : cls.name.downcase,
            "fields" => fields
          }
        end
        models
      }, "List all ORM models with fields and types")

      # ── Debugging Tools ───────────────────────────────
      server.register_tool("log_tail", lambda { |lines: 50|
        log_file = File.join("logs", "debug.log")
        return [] unless File.exist?(log_file)
        all_lines = File.read(log_file, encoding: "utf-8").split("\n")
        all_lines.last([lines.to_i, all_lines.length].min)
      }, "Read recent log entries")

      server.register_tool("error_log", lambda { |limit: 20|
        begin
          if defined?(Tina4::DevAdmin) && Tina4::DevAdmin.respond_to?(:message_log)
            log = Tina4::DevAdmin.message_log
            log.respond_to?(:get) ? log.get(category: "error").first(limit.to_i) : []
          else
            []
          end
        rescue
          []
        end
      }, "Recent errors and exceptions")

      server.register_tool("env_list", lambda {
        ENV.sort.to_h { |k, v| [k, redact_env.call(k, v)] }
      }, "List environment variables (secrets redacted)")

      # ── Data Tools ────────────────────────────────────
      server.register_tool("seed_table", lambda { |table:, count: 10|
        begin
          db = Tina4.database
          return { "error" => "No database connection" } if db.nil?
          inserted = Tina4.seed_table(table, db.columns(table), count: count.to_i)
          { "table" => table, "inserted" => inserted }
        rescue => e
          { "error" => e.message }
        end
      }, "Seed a table with fake data")

      # ── System Tools ──────────────────────────────────
      server.register_tool("system_info", lambda {
        {
          "framework" => "tina4-ruby",
          "version"   => (defined?(Tina4::VERSION) ? Tina4::VERSION : "unknown"),
          "ruby"      => RUBY_DESCRIPTION,
          "platform"  => RUBY_PLATFORM,
          "cwd"       => project_root,
          "debug"     => ENV.fetch("TINA4_DEBUG", "false")
        }
      }, "Framework version, Ruby version, project info")
    end
  end
end
