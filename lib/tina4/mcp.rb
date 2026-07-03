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
require "open3"
require "securerandom"

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

  # Informational only — whether the CONFIGURED host looks local.
  #
  # NOT the security gate. This reads TINA4_HOST_NAME (the configured bind
  # address), which on a 0.0.0.0 bind looks "local" while still accepting
  # remote clients. Trust decisions use {request_allowed?} with the RAW
  # socket peer instead. Kept for diagnostics / back-compat.
  def self.is_localhost?
    host = ENV.fetch("TINA4_HOST_NAME", "localhost:7145").split(":").first
    ["localhost", "127.0.0.1", "0.0.0.0", "::1", ""].include?(host)
  end

  # Whether an address is a loopback (in-process / same-host) peer.
  #
  # Operates on the RAW socket peer, never X-Forwarded-For. Empty means an
  # in-process / synthetic request (no socket) and is trusted. The `::ffff:`
  # IPv4-mapped prefix is stripped. NOTE: 0.0.0.0 is a BIND address, never a
  # client address, so it is deliberately NOT loopback.
  #
  # Python master parity: tina4_python.mcp.is_loopback.
  def self.is_loopback?(ip)
    return true if ip.nil? || ip.to_s.empty?

    addr = ip.to_s.strip.downcase
    addr = addr[7..] if addr.start_with?("::ffff:")
    addr == "::1" || addr == "localhost" || addr.start_with?("127.")
  end

  # Capability gate — whether the MCP subsystem may run at all.
  #
  # Pure capability, host-INDEPENDENT (Python master parity):
  #   1. TINA4_MCP set explicitly → use it (sysadmin override, any host).
  #   2. Else TINA4_DEBUG truthy → MCP is a capability of this deployment.
  #   3. Otherwise off.
  #
  # This NO LONGER consults the host. A debug box bound to 0.0.0.0 still "has"
  # the capability, but {request_allowed?} is what decides whether a given
  # CALLER may use it — loopback always, remote only with an explicit opt-in
  # plus a valid token. Splitting capability from per-request authorisation
  # closes the hole where a 0.0.0.0 bind auto-exposed DB/file tools to remote
  # unauthenticated callers (pre-3.13.40 is_localhost? treated 0.0.0.0 local).
  def self.mcp_enabled?
    explicit = ENV["TINA4_MCP"]
    if explicit && !explicit.empty?
      return truthy?(explicit)
    end

    truthy?(ENV["TINA4_DEBUG"])
  end

  # Per-request authorisation — whether THIS caller may use MCP.
  #
  # @param remote_ip [String] raw socket peer (env["REMOTE_ADDR"]), never XFF.
  # @param has_valid_token [Boolean] true when the request carried a token
  #   matching TINA4_MCP_TOKEN.
  #
  # Rules (Python master parity, tina4_python.mcp.is_request_allowed):
  #   - Capability off ({mcp_enabled?} false) → deny.
  #   - Loopback peer → allow.
  #   - Remote peer → only when TINA4_MCP_REMOTE is truthy AND a valid token
  #     was presented. No configured token ⇒ remote can never pass.
  def self.request_allowed?(remote_ip, has_valid_token: false)
    return false unless mcp_enabled?
    return true if is_loopback?(remote_ip)

    truthy?(ENV["TINA4_MCP_REMOTE"]) && has_valid_token
  end

  # Case-insensitive truthiness for env values: true/1/yes/on.
  def self.truthy?(val)
    %w[true 1 yes on].include?(val.to_s.strip.downcase)
  end

  # Resolve the dedicated MCP port. Defaults to (server port + 2000) — keeps
  # MCP tooling reachable on a stable, predictable channel separate from the
  # main HTTP port and the AI test port (port + 1000).
  def self.mcp_port
    explicit = ENV["TINA4_MCP_PORT"]
    return explicit.to_i if explicit && !explicit.empty? && explicit.to_i > 0

    base_port = (ENV["TINA4_PORT"] || ENV["PORT"] || "7147").to_i
    base_port + 2000
  end

  # ── McpServer ─────────────────────────────────────────────────────
  class McpServer
    # MCP protocol versions this server can speak, newest first. The 2025-*
    # versions are the Streamable HTTP era; 2024-11-05 is the legacy HTTP+SSE
    # transport we still accept for older clients (Claude Desktop et al.).
    SUPPORTED_PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS.first

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
      # Streamable HTTP sessions: id => opened-at epoch. `initialize` mints one
      # (returned in the Mcp-Session-Id header); a request bearing an unknown id
      # gets a 404 so the client re-initializes.
      @sessions    = {}
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

    # ── Streamable HTTP transport ─────────────────────────────────────
    # Session lifecycle + protocol negotiation shared by every transport
    # entry point so the wire behaviour is identical across all 4 frameworks.

    # Mint a new session id and remember it. Called on `initialize`.
    def open_session
      sid = SecureRandom.hex(16)
      @sessions[sid] = Time.now.to_f
      sid
    end

    # True when +session_id+ was issued by this server and is still open.
    def is_valid_session(session_id)
      !session_id.to_s.empty? && @sessions.key?(session_id)
    end

    # Forget a session (client DELETE or SSE stream close). Returns true when a
    # live session was actually removed.
    def close_session(session_id)
      !@sessions.delete(session_id).nil?
    end

    # Pick the protocol version to run on. Echo the client's requested version
    # when we support it (proper negotiation), else fall back to the newest
    # version we speak so an unversioned/old client still connects.
    def negotiate_protocol_version(requested)
      return requested if SUPPORTED_PROTOCOL_VERSIONS.include?(requested)

      LATEST_PROTOCOL_VERSION
    end

    # Transport-agnostic Streamable HTTP POST handler. Every transport calls
    # this so the wire behaviour stays identical:
    #   - `initialize` mints a session id, returned in the Mcp-Session-Id header.
    #   - a non-initialize request carrying an unknown session id is a 404
    #     (JSON-RPC error) so the client knows to re-initialize.
    #   - a notification / response-only POST (no id) yields 202 with an empty
    #     body.
    #   - anything else returns 200 with the JSON-RPC response as
    #     application/json (the MCP Streamable HTTP spec permits a POST that
    #     resolves to a single response to answer inline).
    # Returns { status:, headers:, body: }.
    def dispatch_http(raw_data, session_id = "")
      is_init = peek_method(raw_data) == "initialize"
      if !is_init && !session_id.to_s.empty? && !is_valid_session(session_id)
        return {
          status: 404,
          headers: {},
          body: McpProtocol.encode_error(nil, McpProtocol::INVALID_REQUEST, "session not found")
        }
      end

      body = handle_message(raw_data)
      headers = {}
      headers["Mcp-Session-Id"] = open_session if is_init
      return { status: 202, headers: headers, body: "" } if body.nil? || body.empty?

      { status: 200, headers: headers, body: body }
    end

    # Register HTTP routes for this MCP server on the Tina4 router. Custom
    # (developer-created) MCP servers use this; the built-in dev server mounts
    # the same transport via DevAdmin's dispatcher.
    def register_routes(router = nil)
      server    = self
      base_path = @path
      msg_path  = "#{@path}/message"
      sse_path  = "#{@path}/sse"

      # Streamable HTTP (current transport) — single POST endpoint.
      Tina4::Router.post(base_path) do |request, response|
        out = server.dispatch_http(request.body, (request.header("mcp-session-id") || "").to_s)
        out[:headers].each { |k, v| response.header(k, v) }
        response.call(out[:body], out[:status], "application/json")
      end

      # DELETE terminates the session (Streamable HTTP spec).
      Tina4::Router.delete(base_path) do |request, response|
        server.close_session((request.header("mcp-session-id") || "").to_s)
        response.call("", 204)
      end

      # GET on the endpoint is a server->client stream we do not open here.
      Tina4::Router.get(base_path) do |_request, response|
        response.header("allow", "POST, DELETE")
        response.call({ "error" => "Method Not Allowed" }, 405, "application/json")
      end

      # Legacy HTTP+SSE POST target — inline, session-lenient.
      Tina4::Router.post(msg_path) do |request, response|
        out = server.dispatch_http(request.body, "")
        out[:headers].each { |k, v| response.header(k, v) }
        response.call(out[:body], out[:status], "application/json")
      end

      # Legacy HTTP+SSE handshake — one-shot endpoint event.
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
        "type" => "http",
        "url"  => "http://localhost:#{port}#{@path}"
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

    # Read the JSON-RPC `method` from a raw request without dispatching. Used by
    # the transport to spot `initialize` (mint a session) before handing the
    # message to handle_message. Accepts a parsed Hash or a raw JSON string.
    def peek_method(raw_data)
      obj = if raw_data.is_a?(Hash)
              raw_data
            else
              str = raw_data.to_s
              str.empty? ? {} : (JSON.parse(str) rescue nil)
            end
      obj.is_a?(Hash) ? obj["method"] : nil
    end

    def _handle_initialize(params)
      @initialized = true
      requested = params.is_a?(Hash) ? params["protocolVersion"] : nil
      {
        "protocolVersion" => negotiate_protocol_version(requested),
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

  # The default dev MCP server, mounted at /__dev/mcp. Built lazily on first
  # access and pre-loaded with the built-in dev tools (database_query,
  # file_read, route_list, …) so both the REST shim (/__dev/api/mcp/*) and
  # the JSON-RPC + SSE endpoints (/__dev/mcp[/message], /__dev/mcp/sse)
  # share one fully-populated tool registry.
  def self._default_mcp_server
    @_default_mcp_server ||= begin
      server = McpServer.new("/__dev/mcp", name: "Tina4 Dev Tools")
      McpDevTools.register(server)
      server
    end
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
      # Append a structured line to `.tina4/agent.log` AND echo to STDERR.
      # Mirrors the Python `_agent_log` helper so a single log file
      # captures every agent action regardless of which side of the
      # stack performed it. Cheap — never blocks the caller on I/O
      # failure.
      agent_log = lambda do |category, message|
        begin
          log_dir = File.join(project_root, ".tina4")
          FileUtils.mkdir_p(log_dir)
          log_path = File.join(log_dir, "agent.log")
          ts = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
          File.open(log_path, "a") { |f| f.write("#{ts} [#{category}] #{message}\n") }
        rescue
          # logging must never fail the actual call
        end
        warn "  [agent #{category}] #{message}"
      end

      # Paths that look like prose rather than filesystem paths. AI
      # agents occasionally pass natural language ("The plan requires
      # implementing...") as `path` to file_write and produce folders
      # with prose for names. Returns an error string on rejection,
      # nil on acceptance.
      sane_path_segment = /\A[A-Za-z0-9._\-]+\z/
      looks_like_prose = lambda do |rel_path|
        if rel_path.nil? || rel_path.strip.empty?
          break "path is empty"
        end
        if rel_path.length > 300
          break "path too long (#{rel_path.length} chars); use a real filename"
        end
        bad_sequences = ["`", "\n", "\t", "  ", " — ", " (", " [", "?", "*", "<", ">", "|"]
        bad_hit = bad_sequences.find { |bad| rel_path.include?(bad) }
        if bad_hit
          break "path contains illegal character sequence #{bad_hit.inspect} — looks like prose, not a filename"
        end
        segment_error = nil
        rel_path.split("/").each do |seg|
          next if seg.empty? || seg == "." || seg == ".."
          if seg.length > 80
            segment_error = "path segment too long: #{seg[0, 60].inspect}… — use a short filename"
            break
          end
          unless sane_path_segment.match?(seg)
            segment_error = "path segment #{seg.inspect} contains disallowed characters — stick to [A-Za-z0-9._-]"
            break
          end
        end
        segment_error
      end

      # Rewrite bare top-level Tina4-conventional directories into
      # their `src/<dir>/` canonical form. The framework's
      # auto-discovery only scans `src/`, so a file at
      # `templates/foo.twig` is dead weight — the framework never
      # loads it. Mirrors normalize_coder_path() in the Python agent.
      normalize_coder_path = lambda do |rel_path|
        passthrough_prefixes = ["src/", "migrations/", "plan/", "tests/",
                                "test/", ".tina4/"]
        passthrough_files = %w[app.py app.ts app.rb index.php composer.json
                               package.json Gemfile pyproject.toml
                               requirements.txt .env .env.example]
        if passthrough_prefixes.any? { |p| rel_path.start_with?(p) }
          next rel_path
        end
        if passthrough_files.include?(rel_path)
          next rel_path
        end
        %w[routes orm templates seeds controllers models middleware].each do |d|
          if rel_path.start_with?("#{d}/")
            rewritten = "src/#{rel_path}"
            agent_log.call("write.path_normalized", "#{rel_path} → #{rewritten}")
            return rewritten
          end
        end
        rel_path
      end

      # Copy `target` into `.tina4/backups/` with a timestamped name.
      # Returns the relative backup path on success, nil on failure.
      agent_backup = lambda do |target|
        begin
          next nil unless File.file?(target)
          backup_dir = File.join(project_root, ".tina4", "backups")
          FileUtils.mkdir_p(backup_dir)
          rel = if target.start_with?("#{project_root}/")
                  target.sub("#{project_root}/", "")
                else
                  File.basename(target)
                end
          safe = rel.gsub("/", "__").gsub("\\", "__")
          ts = Time.now.utc.strftime("%Y-%m-%dT%H-%M-%SZ")
          backup_name = "#{safe}.#{ts}.bak"
          backup_path = File.join(backup_dir, backup_name)
          File.binwrite(backup_path, File.binread(target))
          ".tina4/backups/#{backup_name}"
        rescue => e
          agent_log.call("write.backup_failed", "#{target}: #{e.message}")
          nil
        end
      end

      safe_path = lambda do |rel_path|
        err = looks_like_prose.call(rel_path)
        raise ArgumentError, "Invalid path #{rel_path.inspect}: #{err}" if err
        resolved = File.expand_path(rel_path, project_root)
        # Compare against root + separator, not a bare prefix: a plain
        # start_with?(project_root) would also accept a sibling like
        # "<root>-evil". expand_path already resolves ".." so a climb-out
        # lands outside root and is rejected here.
        root_prefix = "#{project_root.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
        unless resolved == project_root || resolved.start_with?(root_prefix)
          raise ArgumentError, "Path escapes project directory: #{rel_path}"
        end
        # Belt-and-braces against symlink escapes: if the path already exists,
        # canonicalise it and re-check containment. A symlink inside the tree
        # pointing outside would otherwise slip past the textual check. New
        # paths (parent not created yet) have no realpath and rely on the
        # expand_path containment above.
        if File.exist?(resolved)
          real = File.realpath(resolved)
          real_root = File.realpath(project_root)
          real_prefix = "#{real_root.chomp(File::SEPARATOR)}#{File::SEPARATOR}"
          unless real == real_root || real.start_with?(real_prefix)
            raise ArgumentError, "Path escapes project directory: #{rel_path}"
          end
        end
        resolved
      end

      # Try `ruby -c` on a freshly-written Ruby file to catch syntax
      # errors BEFORE the next request hits the broken handler.
      # Mirrors _verify_python_import() in tina4_python/mcp/tools.py.
      #
      # Returns nil on success (or when verification is skipped), or
      # the captured error string on failure. Only checks files under
      # src/ that end in .rb — skips spec_helper.rb, *_spec.rb, and
      # test_*.rb because those have their own loading patterns
      # (mirrors Python's skip of __init__.py / conftest.py / test_*.py).
      #
      # Why this matters: the AI coder repeatedly produces Ruby with
      # unclosed blocks, missing `end`, dangling parens. Running
      # `ruby -c` right after write catches it inline and surfaces
      # the real Ruby error in the file_write response — the LLM
      # sees the error on its next turn and can retry with context.
      verify_ruby_syntax = lambda do |rel_path|
        next nil unless rel_path.end_with?(".rb")
        next nil unless rel_path.start_with?("src/")
        base = File.basename(rel_path)
        next nil if base == "spec_helper.rb"
        next nil if base.end_with?("_spec.rb")
        next nil if base.start_with?("test_")

        abs_path = File.expand_path(rel_path, project_root)
        begin
          stdout, stderr, status = Open3.capture3("ruby", "-c", abs_path)
        rescue StandardError => e
          next "verification subprocess failed: #{e.message}"
        end

        next nil if status.success?

        # Pull the first meaningful stderr line — ruby -c emits
        # "<file>:<line>: syntax error, ...". Strip the absolute
        # path prefix for readability.
        err_lines = (stderr || "").strip.split("\n")
        if err_lines.empty?
          next "syntax check failed (exit #{status.exitstatus}, no stderr)"
        end
        line = err_lines.first.strip
        # Strip the absolute project_root prefix so the error reads
        # as "src/routes/foo.rb:3: syntax error, ..." instead of the
        # full /Users/... path. Use gsub because Ruby 3.2's MRI parser
        # double-prints the path — once as the file label prefix and
        # once inside the (SyntaxError) reference — and the test asserts
        # the absolute path appears nowhere in import_error.
        # See: spec/mcp_spec.rb defensive file_write test (CI Ruby 3.2).
        line.gsub("#{project_root}/", "")
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
        param_list = [] unless param_list.is_a?(Array)
        # Defense-in-depth: this tool is read-only. Strip comments, reject
        # multiple statements, and require a leading SELECT/WITH so it can
        # never mutate data even if reached (database_execute is the write
        # surface, gated separately). Mirrors the Python master.
        cleaned = sql.to_s.gsub(/--[^\r\n]*/, " ").gsub(%r{/\*.*?\*/}m, " ")
        cleaned = cleaned.strip.sub(/[;\s]+\z/, "")
        return { "error" => "database_query rejects multiple statements" } if cleaned.include?(";")
        unless cleaned =~ /\A(select|with)\b/i
          return { "error" => "database_query is read-only (SELECT/WITH only)" }
        end
        begin
          result = db.fetch(cleaned, param_list)
        rescue => e
          return { "error" => (db.get_error rescue nil) || e.message }
        end
        { "records" => result.to_a, "count" => result.count }
      }, "Execute a read-only SQL query (SELECT)")

      server.register_tool("database_execute", lambda { |sql:, params: "[]"|
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        param_list = params.is_a?(String) ? JSON.parse(params) : params
        # db.execute() now RAISES on a SQL error (it no longer returns false).
        # Catch it and return a clean { error: } payload instead of letting the
        # exception escape the tool handler.
        begin
          result = db.execute(sql, param_list)
          db.commit rescue nil
          { "success" => true, "affected_rows" => (result.respond_to?(:count) ? result.count : 0) }
        rescue => e
          { "error" => db.get_error || e.message }
        end
      }, "Execute arbitrary SQL (INSERT/UPDATE/DELETE/DDL)")

      server.register_tool("database_tables", lambda {
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        db.tables
      }, "List all database tables")

      server.register_tool("database_columns", lambda { |table:|
        db = Tina4.database
        return { "error" => "No database connection" } if db.nil?
        # Constrain the table name to a safe identifier (optionally
        # schema-qualified) — defense-in-depth so it can never be abused for
        # injection even if an adapter interpolates it. Parity with Python/PHP.
        unless table.to_s =~ /\A[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*)?\z/
          return { "error" => "Invalid table name" }
        end
        db.columns(table)
      }, "Get column definitions for a table")

      # ── Route Tools ───────────────────────────────────
      server.register_tool("route_list", lambda {
        # Tina4::Router.routes returns Route objects (attr_readers), not
        # Hashes — use accessors, never [] subscript.
        Tina4::Router.routes.map do |route|
          {
            "method"        => route.method.to_s,
            "path"          => route.path.to_s,
            "auth_required" => route.auth_required ? true : false
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
        # 1. Coder-path normalization — rewrite bare top-level Tina4
        #    directories (templates/, routes/, orm/, ...) into their
        #    src/ canonical form before resolving.
        path = normalize_coder_path.call(path)
        # 2. safe_path runs looks_like_prose then sandbox check.
        p = safe_path.call(path)

        old_bytes = File.file?(p) ? File.binread(p) : ""
        old_size = old_bytes.bytesize
        old_lines = old_bytes.count("\n")
        new_bytes = content.to_s
        new_size = new_bytes.bytesize
        new_lines = new_bytes.count("\n")
        rel = p.start_with?("#{project_root}/") ? p.sub("#{project_root}/", "") : path

        # 3. Truncation guard — refuse suspicious shrinkage on
        #    non-trivial files (>200B → <30% of size).
        if old_size > 200 && (new_size * 100) < (old_size * 30)
          msg = "REFUSED #{rel} (would shrink #{old_size} → #{new_size} bytes / " \
                "#{old_lines} → #{new_lines} lines, looks truncated)"
          agent_log.call("write.refused", msg)
          next { "error" => msg, "refused" => true, "old_bytes" => old_size, "new_bytes" => new_size }
        end

        # 4. Backup before overwrite.
        backup_rel = old_size > 0 ? agent_backup.call(p) : nil

        FileUtils.mkdir_p(File.dirname(p))
        File.write(p, new_bytes, encoding: "utf-8")

        # 5. Audit log.
        agent_log.call("write.ok",
                       "#{rel} (#{old_size}B/#{old_lines}L → #{new_size}B/#{new_lines}L, " \
                       "backup: #{backup_rel || '(no prior file)'})")

        result = { "written" => rel, "bytes" => new_size }
        result["backup"] = backup_rel if backup_rel

        # 6. Post-write syntax check — catch hallucinated Ruby
        #    (missing `end`, unclosed parens, etc.) before the next
        #    request hits the broken handler.
        err = verify_ruby_syntax.call(rel)
        if err
          result["import_error"] = err
          agent_log.call("write.import_failed", "#{rel}: #{err}")
        end

        result
      }, "Write or update a project file (with backup, truncation guard, audit log)")

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

      # ── File patch ────────────────────────────────────
      server.register_tool("file_patch", lambda { |path:, old_string:, new_string:, count: 1|
        # 1. Normalize, 2. safe_path (which runs the prose check).
        path = normalize_coder_path.call(path)
        p = safe_path.call(path)

        # 3. Existence check.
        next { "error" => "File not found: #{path}" } unless File.file?(p)

        original = File.read(p, encoding: "utf-8")
        occurrences = original.scan(old_string).size

        # 4. Match-count guard (already-existing behaviour).
        next { "error" => "old_string not found in #{path}" } if occurrences.zero?
        if occurrences != count.to_i
          next({ "error" => "old_string appears #{occurrences} times, expected #{count}. Expand old_string to make it unique, or set count explicitly." })
        end

        updated = original.sub(old_string, new_string)
        # Ruby String#sub replaces first; if count > 1, do N replacements
        if count.to_i > 1
          updated = original.dup
          count.to_i.times { updated.sub!(old_string, new_string) }
        end

        rel = p.start_with?("#{project_root}/") ? p.sub("#{project_root}/", "") : path

        # 5. Backup before overwrite — same path layout as file_write
        #    so recovery is uniform regardless of which tool touched
        #    the file.
        backup_rel = agent_backup.call(p)

        File.write(p, updated, encoding: "utf-8")

        Tina4::Plan.record_action("patched", rel) if defined?(Tina4::Plan)

        old_size = original.bytesize
        new_size = updated.bytesize
        agent_log.call("patch.ok",
                       "#{rel} (replaced #{count.to_i}× old_string, " \
                       "#{old_size}B → #{new_size}B, backup: #{backup_rel || '(none)'})")

        result = { "patched" => rel, "replacements" => count.to_i, "bytes" => new_size }
        result["backup"] = backup_rel if backup_rel

        # Post-patch syntax check — same rationale as file_write.
        err = verify_ruby_syntax.call(rel)
        if err
          result["import_error"] = err
          agent_log.call("patch.import_failed", "#{rel}: #{err}")
        end

        result
      }, "Targeted edit: replace old_string with new_string in a file (with backup + audit log)")

      # ── Docs tools ────────────────────────────────────
      framework_doc_paths = lambda do
        gem_root = File.expand_path("..", File.dirname(__FILE__))
        candidates = [
          File.join(gem_root, "..", "CLAUDE.md"),
          File.join(gem_root, "..", "AGENTS.md"),
          File.join(gem_root, "..", "CONVENTIONS.md"),
          File.join(gem_root, "..", "README.md"),
          File.join(Dir.pwd, "CLAUDE.md")
        ]
        candidates.map { |p| File.expand_path(p) }.uniq.select { |p| File.file?(p) }
      end

      server.register_tool("docs_list", lambda {
        framework_doc_paths.call.map { |p| { "name" => File.basename(p), "bytes" => File.size(p) } }
      }, "List framework documentation files")

      server.register_tool("docs_search", lambda { |query:, limit: 5, context_lines: 4|
        return { "error" => "query must be at least 2 characters" } if query.to_s.length < 2
        needle = query.to_s.downcase
        hits = []
        framework_doc_paths.call.each do |p|
          begin
            lines = File.read(p, encoding: "utf-8", invalid: :replace, undef: :replace).split("\n")
          rescue StandardError
            next
          end
          lines.each_with_index do |line, i|
            next unless line.downcase.include?(needle)
            start_i = [0, i - context_lines.to_i].max
            end_i   = [lines.size, i + context_lines.to_i + 1].min
            score = 1
            score += 1 if line.include?(query.to_s)
            score += 2 if line.lstrip.start_with?("#")
            hits << {
              "file" => File.basename(p),
              "line" => i + 1,
              "score" => score,
              "snippet" => lines[start_i...end_i].join("\n")
            }
          end
        end
        hits.sort_by! { |h| -h["score"] }
        hits.first([1, limit.to_i].max)
      }, "Search Tina4 framework docs for a query string")

      server.register_tool("docs_section", lambda { |file:, heading:|
        match = framework_doc_paths.call.find { |p| File.basename(p) == file }
        return { "error" => "Unknown doc file: #{file}. Try docs_list() first." } unless match
        text = File.read(match, encoding: "utf-8", invalid: :replace, undef: :replace)
        lines = text.split("\n")
        heading_lc = heading.to_s.downcase.strip
        start_i = -1
        start_level = 0
        lines.each_with_index do |line, i|
          stripped = line.lstrip
          next unless stripped.start_with?("#")
          level = stripped.length - stripped.sub(/\A#+/, "").length
          title = stripped[level..].to_s.strip.downcase
          if title.include?(heading_lc)
            start_i = i
            start_level = level
            break
          end
        end
        return { "error" => "Heading '#{heading}' not found in #{file}" } if start_i < 0
        end_i = lines.size
        (start_i + 1).upto(lines.size - 1) do |j|
          stripped = lines[j].lstrip
          next unless stripped.start_with?("#")
          level = stripped.length - stripped.sub(/\A#+/, "").length
          if level <= start_level
            end_i = j
            break
          end
        end
        { "file" => file, "heading" => lines[start_i].strip, "body" => lines[start_i...end_i].join("\n") }
      }, "Return a full markdown section from a framework doc file")

      # ── Git / deps / project ──────────────────────────
      server.register_tool("git_status", lambda {
        Tina4::DevAdmin.send(:git_status_payload)
      }, "Show git branch, modified/untracked files, recent commits")

      server.register_tool("deps_list", lambda {
        gemfile = File.join(Dir.pwd, "Gemfile")
        return { "error" => "No Gemfile at project root" } unless File.file?(gemfile)
        deps = File.read(gemfile).scan(/^\s*gem\s+["']([^"']+)["']/).flatten
        { "name" => File.basename(Dir.pwd), "dependencies" => deps }
      }, "List this project's declared Ruby dependencies")

      server.register_tool("project_overview", lambda {
        { "system" => { "framework" => "tina4-ruby", "version" => (defined?(Tina4::VERSION) ? Tina4::VERSION : "unknown"), "ruby" => RUBY_DESCRIPTION, "cwd" => project_root } }
      }, "One-shot snapshot: system + project info")

      # ── Project index ─────────────────────────────────
      server.register_tool("index_rebuild", lambda {
        Tina4::ProjectIndex.refresh
      }, "Refresh the persistent project index (lazy, mtime-based)")

      server.register_tool("index_search", lambda { |query:, limit: 20|
        Tina4::ProjectIndex.search(query, limit.to_i)
      }, "Find files by path, symbol, route, or summary")

      server.register_tool("index_file", lambda { |path:|
        Tina4::ProjectIndex.file_entry(path)
      }, "Full index entry for one file")

      server.register_tool("index_overview", lambda {
        Tina4::ProjectIndex.overview
      }, "Project shape: files by language, routes, models, recent edits")

      # ── Plan management ───────────────────────────────
      server.register_tool("plan_current", lambda {
        Tina4::Plan.current
      }, "The active plan: title, steps (done/not), next step, progress")

      server.register_tool("plan_list", lambda {
        Tina4::Plan.list_plans
      }, "All plans in plan/ with progress and which one is active")

      server.register_tool("plan_create", lambda { |title:, goal: "", steps: nil, make_current: true|
        Tina4::Plan.create(title, goal: goal, steps: steps, make_current: make_current)
      }, "Create a new markdown plan in plan/ and make it active")

      server.register_tool("plan_switch_to", lambda { |name:|
        Tina4::Plan.set_current(name)
      }, "Make a different plan the active one")

      server.register_tool("plan_complete_step", lambda { |index:|
        Tina4::Plan.complete_step(index.to_i)
      }, "Tick a step as done (call the moment the step finishes)")

      server.register_tool("plan_add_step", lambda { |text:|
        Tina4::Plan.add_step(text)
      }, "Append a new unchecked step to the current plan")

      server.register_tool("plan_note", lambda { |text:|
        Tina4::Plan.append_note(text)
      }, "Append a timestamped note/breadcrumb to the current plan")

      server.register_tool("plan_archive", lambda { |name: ""|
        Tina4::Plan.archive(name)
      }, "Move a finished plan to plan/done/")

      server.register_tool("plan_read", lambda { |name:|
        Tina4::Plan.read(name)
      }, "Full structured view of any plan by filename")

      server.register_tool("plan_flesh", lambda { |name: "", prompt: ""|
        Tina4::Plan.flesh(name, prompt)
      }, "Auto-generate concrete build steps via AI and append them to an existing plan")

      # ── Live API Docs (Live API RAG) ──────────────────
      server.register_tool("api_search", lambda { |query:, k: 5, source: "all", include_private: false|
        Tina4::Docs.cached(project_root).search(
          query.to_s, k: k.to_i, source: source.to_s, include_private: include_private == true || include_private.to_s == "true"
        )
      }, "Search the live API index (framework + user code) for ranked hits")

      server.register_tool("api_class", lambda { |name:|
        Tina4::Docs.cached(project_root).class_spec(name.to_s)
      }, "Full class reflection (methods, file, line) from the live API index")

      server.register_tool("api_method", lambda { |class_name:, name:|
        Tina4::Docs.cached(project_root).method_spec(class_name.to_s, name.to_s)
      }, "Single method spec (signature, summary, file, line) from the live API index")

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
