# frozen_string_literal: true
require "socket"
require "digest"
require "base64"
require "json"
require "set"
require "securerandom"

module Tina4
  WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-5AB5DC11AD37"

  # Shared pub/sub channel name + envelope shape for the WebSocket backplane.
  # MUST stay byte-identical across all four frameworks (Python/PHP/Ruby/Node)
  # so a broadcast published by one framework's instance is relayed by another.
  WEBSOCKET_BACKPLANE_CHANNEL = "tina4:ws"

  # Compute Sec-WebSocket-Accept from Sec-WebSocket-Key per RFC 6455.
  def self.compute_accept_key(key)
    Base64.strict_encode64(Digest::SHA1.digest("#{key}#{WEBSOCKET_GUID}"))
  end

  # Return true if the request's Origin is permitted to upgrade to a WebSocket.
  #
  # Controlled by TINA4_WS_ALLOWED_ORIGINS (comma-separated exact origins, e.g.
  # "https://app.example.com,https://admin.example.com").
  #
  # Empty/unset = allow ALL origins (current behaviour, non-breaking). When set,
  # only requests whose Origin exactly matches a listed value are allowed; a
  # missing Origin header is rejected once the allow-list is active.
  #
  # +headers+ is a Hash. The Origin is looked up case-insensitively across both
  # the Rack-style "HTTP_ORIGIN" key and a plain "origin"/"Origin" key so the
  # same helper serves the rack_app upgrade path and direct callers/tests.
  def self.websocket_origin_allowed?(headers)
    raw = (ENV["TINA4_WS_ALLOWED_ORIGINS"] || "").strip
    return true if raw.empty? # No allow-list configured — permit everything.

    allowed = raw.split(",").map(&:strip).reject(&:empty?)
    return true if allowed.empty?

    origin = headers["HTTP_ORIGIN"] || headers["origin"] || headers["Origin"]
    allowed.include?(origin)
  end

  # Extract a bearer token from a WebSocket upgrade handshake.
  #
  # Order (mirrors Python's tina4_python.websocket.ws_token):
  #   1. the Authorization: Bearer <jwt> header (server/CLI/mobile clients)
  #   2. the Sec-WebSocket-Protocol subprotocol in the form "bearer, <jwt>"
  #      (the only way a *browser* can pass a token — new WebSocket() cannot set
  #      headers, but it CAN offer subprotocols)
  #   3. a ?token=<jwt> query-string param
  # Returns the token String, or nil.
  #
  # +headers+ is a Hash. Lookups are case-insensitive across both the Rack-style
  # "HTTP_AUTHORIZATION"/"HTTP_SEC_WEBSOCKET_PROTOCOL" keys and plain
  # "authorization"/"Authorization"/"sec-websocket-protocol" keys so the same
  # helper serves the rack_app upgrade path and direct callers/tests.
  def self.ws_token(headers, query_string = "", subprotocol = "")
    headers ||= {}
    auth = headers["HTTP_AUTHORIZATION"] || headers["authorization"] || headers["Authorization"] || ""
    if auth[0, 7].to_s.downcase == "bearer "
      tok = auth[7..].to_s.strip
      return tok.empty? ? nil : tok
    end

    proto = subprotocol.to_s
    proto = headers["HTTP_SEC_WEBSOCKET_PROTOCOL"] || headers["sec-websocket-protocol"] ||
            headers["Sec-WebSocket-Protocol"] || "" if proto.empty?
    parts = proto.to_s.split(",").map(&:strip).reject(&:empty?)
    if parts.length >= 2 && parts[0].downcase == "bearer"
      return parts[1].empty? ? nil : parts[1]
    end

    qs = query_string.to_s
    qs = headers["QUERY_STRING"].to_s if qs.empty?
    unless qs.empty?
      tok = qs.split("&").each_with_object(nil) do |pair, _acc|
        k, v = pair.split("=", 2)
        break v if k == "token"
      end
      return tok unless tok.nil? || tok.to_s.empty?
    end

    nil
  end

  # Per-route WebSocket authentication, checked on the upgrade.
  #
  # A route is secured when it requires auth (the WebSocketRoute's #auth_required
  # is truthy — set by .secure on the route or by Tina4.secure_websocket). Public
  # routes (the default) always pass. A secured route needs a valid JWT via the
  # Authorization header, the "bearer" subprotocol, or ?token=.
  #
  # Returns [payload, ok] — the verified token payload (or nil) and whether the
  # upgrade may proceed. Mirrors Python's ws_authorized.
  def self.ws_authorized(auth_required, headers, query_string = "", subprotocol = "")
    return [nil, true] unless auth_required

    token = ws_token(headers, query_string, subprotocol)
    return [nil, false] unless token

    payload = Tina4::Auth.valid_token(token)
    [payload, !payload.nil?]
  end

  # Whether the client offered the "bearer" subprotocol — in which case the
  # handshake response must echo "bearer" as the accepted subprotocol (browsers
  # reject a 101 that doesn't echo back a subprotocol they offered).
  def self.ws_bearer_subprotocol_offered?(headers)
    headers ||= {}
    proto = headers["HTTP_SEC_WEBSOCKET_PROTOCOL"] || headers["sec-websocket-protocol"] ||
            headers["Sec-WebSocket-Protocol"] || ""
    parts = proto.to_s.split(",").map(&:strip).reject(&:empty?)
    !parts.empty? && parts[0].downcase == "bearer"
  end

  # Build a WebSocket frame (server→client, never masked).
  def self.build_frame(opcode, data, fin: true)
    first_byte = (fin ? 0x80 : 0x00) | opcode
    frame = [first_byte].pack("C")
    length = data.bytesize

    if length < 126
      frame += [length].pack("C")
    elsif length < 65536
      frame += [126, length].pack("Cn")
    else
      frame += [127, length].pack("CQ>")
    end

    frame + data
  end

  class WebSocket
    GUID = WEBSOCKET_GUID

    # Process-wide handle to the live route-serving WebSocket engine. RackApp
    # sets this on construction so framework code (Frond.push_live, background
    # tasks) can broadcast without threading an engine reference through every
    # call site. Mirrors PHP's \Tina4\Server::getInstance(). Nil until a RackApp
    # is built (e.g. in unit specs) — best-effort callers degrade silently.
    @current = nil
    class << self
      attr_accessor :current
    end

    attr_reader :connections

    def initialize
      @connections = {}
      @handlers = {
        open: [],
        message: [],
        close: [],
        error: []
      }
      @rooms = {}  # room_name => Set of conn_ids

      # ── Backplane (multi-instance scaling) ──────────────────────
      # Lazily wired on first broadcast (see ensure_backplane). Each instance
      # owns a stable id so it can ignore its own echoes coming back over the
      # shared pub/sub channel (the origin guard). The backplane listener runs
      # in its own Ruby thread, so the connections structure is guarded by a
      # mutex shared with the broadcast path.
      @backplane = nil
      @backplane_started = false
      @instance_id = SecureRandom.hex(8)
      @backplane_channel = Tina4::WEBSOCKET_BACKPLANE_CHANNEL
      @conn_mutex = Mutex.new
    end

    # Stable per-process id used as the backplane envelope "src" so an instance
    # drops its own echoes. Exposed for tests / introspection.
    attr_reader :instance_id, :backplane_channel

    def on(event, &block)
      @handlers[event.to_sym] << block if @handlers.key?(event.to_sym)
    end

    def upgrade?(env)
      upgrade = env["HTTP_UPGRADE"] || ""
      upgrade.downcase == "websocket"
    end

    def get_clients
      @connections
    end

    def start(host: "0.0.0.0", port: 7147)
      require "socket"
      @server_socket = TCPServer.new(host, port)
      @running = true
      @server_thread = Thread.new do
        while @running
          begin
            client = @server_socket.accept
            env = {}
            handle_upgrade(env, client)
          rescue => e
            break unless @running
          end
        end
      end
      self
    end

    def stop
      @running = false
      @server_socket&.close rescue nil
      @server_thread&.join(1)
      @connections.each_value { |conn| conn.close rescue nil }
      @connections.clear
    end

    def broadcast(message, exclude: nil, path: nil)
      ensure_backplane
      targets = @conn_mutex.synchronize do
        @connections.select do |id, conn|
          !(exclude && id == exclude) && !(path && conn.path != path)
        end.values
      end
      deliver_resilient(targets, message)
      publish_envelope(path ? "path" : "all", message, path: path, exclude: exclude)
    end

    # Send to ALL connections (no path filter). Resilient + backplane-fanned.
    def broadcast_all(message, exclude: nil)
      ensure_backplane
      targets = @conn_mutex.synchronize do
        @connections.reject { |id, _| exclude && id == exclude }.values
      end
      deliver_resilient(targets, message)
      publish_envelope("all", message, exclude: exclude)
    end

    def send_to(conn_id, message)
      conn = @conn_mutex.synchronize { @connections[conn_id] }
      return unless conn

      prune(conn) unless safe_send(conn, message)
    end

    def close(conn_id, code: 1000, reason: "")
      conn = @connections[conn_id]
      conn&.close(code: code, reason: reason)
    end

    # ── Rooms ──────────────────────────────────────────────────

    # Internal: add connection ID to a room (called by WebSocketConnection#join_room).
    # Mirrors Python's WebSocketManager._join_room — not part of the public API.
    def _join_room(conn_id, room_name)
      @rooms[room_name] ||= Set.new
      @rooms[room_name].add(conn_id)
    end

    # Internal: remove connection ID from a room (called by WebSocketConnection#leave_room).
    # Mirrors Python's WebSocketManager._leave_room — not part of the public API.
    def _leave_room(conn_id, room_name)
      @rooms[room_name]&.delete(conn_id)
    end

    def room_count(room_name)
      (@rooms[room_name] || Set.new).size
    end

    # Return list of room names a given client/connection id belongs to.
    # Matches PHP Tina4\WebSocket::getClientRooms($clientId).
    def get_client_rooms(client_id)
      @rooms.each_with_object([]) do |(name, members), acc|
        acc << name if members.include?(client_id)
      end
    end

    def get_room_connections(room_name)
      ids = @rooms[room_name] || Set.new
      ids.filter_map { |id| @connections[id] }
    end

    def broadcast_to_room(room_name, message, exclude: nil)
      ensure_backplane
      targets = get_room_connections(room_name).reject { |conn| exclude && conn.id == exclude }
      deliver_resilient(targets, message)
      publish_envelope("room", message, room: room_name, exclude: exclude)
    end

    # Register an open connection on this manager (thread-safe).
    def register_connection(connection)
      @conn_mutex.synchronize { @connections[connection.id] = connection }
    end

    # Drop a connection on close (thread-safe) and remove it from all rooms.
    def unregister_connection(conn_id)
      @conn_mutex.synchronize { @connections.delete(conn_id) }
      remove_from_all_rooms(conn_id)
    end

    # ── Broadcast resilience ──────────────────────────────────
    #
    # One dead/slow client must never abort delivery to the rest. deliver_resilient
    # walks the target list, wraps each send, logs+prunes anything that throws,
    # and keeps going.

    # Send to ONE connection without letting a single dead client abort a
    # broadcast loop. Returns true if delivered, false if the connection looks
    # dead (the caller then prunes it). A failed send is logged, never silent.
    # A connection whose own #send swallowed a write error and flipped #closed?
    # is treated as dead too (mirrors Python's `return not ws._closed`).
    def safe_send(conn, message)
      conn.send_text(message)
      # If the connection's own #send swallowed a write error it flips #closed?;
      # treat that as dead. Probe defensively so a stub/double that doesn't
      # define #closed? is simply treated as alive.
      dead = begin
        conn.respond_to?(:closed?) && conn.closed?
      rescue StandardError
        false
      end
      !dead
    rescue StandardError => e
      Tina4::Log.warning("WebSocket send to #{conn.id} failed, pruning: #{e.message}") if defined?(Tina4::Log)
      false
    end

    # Deliver +message+ to every connection in +targets+, pruning any that fail.
    def deliver_resilient(targets, message)
      dead = targets.reject { |conn| safe_send(conn, message) }
      dead.each { |conn| prune(conn) }
    end

    # Remove a (presumed dead) connection from the manager + all rooms.
    def prune(conn)
      id = conn.respond_to?(:id) ? conn.id : nil
      return unless id

      @conn_mutex.synchronize { @connections.delete(id) }
      remove_from_all_rooms(id)
    end

    # ── Idle reaper ───────────────────────────────────────────
    #
    # Opt-in via TINA4_WS_IDLE_TIMEOUT (seconds; 0/unset = disabled = current
    # behaviour). Tracks last_activity per connection (bumped on every inbound
    # frame in handle_upgrade); reap_idle closes/prunes anything idle past the
    # timeout.

    # Close connections whose last inbound frame is older than +timeout+ seconds.
    # Returns the number reaped. timeout <= 0 is a no-op. Connections without a
    # last_activity are skipped.
    def reap_idle(timeout)
      return 0 if timeout.to_f <= 0

      now = Time.now.to_f
      stale = @conn_mutex.synchronize do
        @connections.values.select do |conn|
          la = conn.respond_to?(:last_activity) ? conn.last_activity : nil
          la && (now - la) > timeout
        end
      end
      stale.each do |conn|
        conn.close(code: 1001, reason: "idle timeout") rescue nil
        prune(conn)
      end
      Tina4::Log.info("WebSocket idle reaper closed #{stale.size} connection(s)") if stale.any? && defined?(Tina4::Log)
      stale.size
    end

    # Read the configured idle timeout (seconds). 0 = disabled.
    def idle_timeout
      Float(ENV["TINA4_WS_IDLE_TIMEOUT"] || "0")
    rescue ArgumentError, TypeError
      0.0
    end

    # Spin up a background reaper thread when an idle timeout is configured.
    # Opt-in and non-breaking — unset/0 means no thread is created.
    def start_idle_reaper
      timeout = idle_timeout
      return if timeout <= 0 || @reaper_thread&.alive?

      interval = [1.0, timeout / 2.0].max
      @reaper_running = true
      @reaper_thread = Thread.new do
        while @reaper_running
          sleep interval
          begin
            reap_idle(timeout)
          rescue StandardError => e
            Tina4::Log.error("WebSocket idle reaper sweep failed: #{e.message}") if defined?(Tina4::Log)
          end
        end
      end
    end

    def stop_idle_reaper
      @reaper_running = false
      @reaper_thread&.kill
      @reaper_thread = nil
    end

    # ── Backplane (multi-instance scaling) ────────────────────
    #
    # When TINA4_WS_BACKPLANE is configured, every broadcast is ALSO published
    # to a shared pub/sub channel so sibling instances relay it to their own
    # local connections. Flow:
    #
    #   instance A: broadcast → deliver locally → publish_envelope → channel
    #                                                                   │
    #   instance B: backplane bg-THREAD → on_backplane_message ─────────┘
    #                 │ (origin guard drops A's echoes by src id)
    #                 └→ relay_local → B's LOCAL connections only (no re-publish)
    #
    # The subscribe callback runs in the backplane's background Ruby thread, so
    # it touches @connections under @conn_mutex (shared with the broadcast path).
    # The relay NEVER re-publishes (that would loop the cluster).

    # Lazily wire the configured backplane. Idempotent and best-effort — a
    # failure logs and leaves the manager local-only; it must NEVER crash a
    # broadcast.
    def ensure_backplane
      return if @backplane_started

      # Set immediately so we only ever attempt the wiring once, even on failure
      # (no retry storm on every broadcast).
      @backplane_started = true
      begin
        backplane = Tina4::WebSocketBackplane.create_backplane
        return if backplane.nil? # No backplane configured — stay local-only.

        @backplane = backplane
        @backplane.subscribe(@backplane_channel) { |raw| on_backplane_message(raw) }
        Tina4::Log.info("WebSocket backplane active (instance #{@instance_id}, channel '#{@backplane_channel}')") if defined?(Tina4::Log)
      rescue StandardError => e
        @backplane = nil
        Tina4::Log.error("WebSocket backplane wiring failed, continuing local-only: #{e.message}") if defined?(Tina4::Log)
      end
    end

    # Receive a raw envelope from the backplane. Runs in the backplane's
    # BACKGROUND THREAD.
    def on_backplane_message(raw)
      env = begin
        JSON.parse(raw)
      rescue JSON::ParserError, TypeError
        return
      end
      return unless env.is_a?(Hash)

      # Origin guard: ignore our own broadcasts echoed back over the channel.
      # We already delivered them locally; relaying again would double-send.
      return if env["src"] == @instance_id

      relay_local(env)
    end

    # Deliver a remote-originated envelope to LOCAL connections only. NEVER
    # re-publishes (that would loop the message around the cluster). Dispatches
    # by "kind": room / path / all.
    def relay_local(env)
      message = decode_envelope_message(env)
      return if message.nil?

      exclude = env["exclude"]
      targets =
        case env["kind"]
        when "room"
          room = env["room"]
          room ? get_room_connections(room) : []
        when "path"
          path = env["path"]
          path ? @conn_mutex.synchronize { @connections.values.select { |c| c.path == path } } : []
        else # "all" (and anything unknown) → every local connection
          @conn_mutex.synchronize { @connections.values }
        end
      targets = targets.reject { |conn| exclude && conn.id == exclude }
      deliver_resilient(targets, message)
    end

    # Publish a broadcast to the shared channel for sibling instances. No-op
    # when no backplane is configured. Best-effort — a publish failure logs and
    # is swallowed so the local broadcast that already happened is never undone
    # by a flaky message bus.
    def publish_envelope(kind, message, room: nil, path: nil, exclude: nil)
      return unless @backplane

      envelope = {
        "src" => @instance_id,
        "kind" => kind,
        "exclude" => exclude,
        "room" => room,
        "path" => path
      }
      # JSON can't carry raw bytes — encode binary as base64, text as text.
      if binary_payload?(message)
        envelope["b64"] = Base64.strict_encode64(message.b)
      else
        envelope["text"] = message
      end
      begin
        @backplane.publish(@backplane_channel, JSON.generate(envelope))
      rescue StandardError => e
        Tina4::Log.warning("WebSocket backplane publish failed: #{e.message}") if defined?(Tina4::Log)
      end
    end

    # Reconstruct the original str/bytes message from an envelope. JSON can't
    # carry bytes, so text → {"text": ...} and bytes → {"b64": base64(...)}.
    def decode_envelope_message(env)
      return env["text"] if env.key?("text")
      return Base64.strict_decode64(env["b64"]).b if env.key?("b64")

      nil
    end

    # A message is "binary" when it is an ASCII-8BIT (BINARY-encoded) string.
    # Ruby has no separate bytes type, so a caller's choice of the BINARY
    # encoding is the signal to treat the payload as bytes: it goes through
    # base64 so it survives the JSON envelope AND arrives with its binary
    # encoding intact on the relaying instance (a JSON "text" value would come
    # back as UTF-8, silently re-encoding binary data).
    def binary_payload?(message)
      message.is_a?(String) && message.encoding == Encoding::ASCII_8BIT
    end

    # Register a WebSocket handler for a path (class method, matching Python's
    # WebSocketServer.route). The block receives a WebSocketConnection and should
    # call conn.on_message / conn.on_close to wire up event callbacks.
    #
    # Registers on the Router so routes work in integrated (Rack) mode.
    #
    #   Tina4::WebSocket.route("/chat") do |conn|
    #     conn.on_message { |data| conn.send(data) }
    #     conn.on_close   { puts "bye" }
    #   end
    #
    # PUBLIC by default (mirrors GET). Pass secure: true to require a valid JWT
    # on the upgrade (or chain .secure on the returned route).
    def self.route(path, secure: false, &block)
      @route_handlers ||= {}
      @route_handlers[path] = block

      # Adapt to Router's (conn, event, data) style
      adapter = proc do |conn, event, data|
        case event
        when :open
          block.call(conn)
        when :message
          conn.on_message_handler&.call(data)
        when :close
          conn.on_close_handler&.call
        end
      end

      Tina4::Router.websocket(path, secure: secure, &adapter)
    end

    # Upgrade a raw socket to a WebSocket connection and run its frame loop.
    #
    # +manager+ is the engine that should OWN the connection (its @connections /
    # rooms / backplane / idle reaper). It defaults to +self+. In integrated
    # (Rack) mode the rack_app passes a process-wide shared engine here so that
    # broadcasts, rooms and the backplane span every route's connections even
    # though each upgrade keeps its own isolated event handlers on +self+.
    def handle_upgrade(env, socket, manager: self, auth_required: false)
      key = env["HTTP_SEC_WEBSOCKET_KEY"]
      return unless key

      # Origin allow-list (opt-in via TINA4_WS_ALLOWED_ORIGINS). Unset = allow
      # all, so this never breaks an existing deployment. When set, an upgrade
      # from a non-listed Origin is refused with a 403 before the handshake.
      unless Tina4.websocket_origin_allowed?(env)
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n") rescue nil
        socket.close rescue nil
        return
      end

      # Per-route auth — checked AFTER the origin allow-list and BEFORE we accept
      # the handshake. A PUBLIC route (the default, mirrors GET) always passes; a
      # secured route (auth_required) needs a valid JWT via the Authorization
      # header, the "bearer" subprotocol, or ?token=. Missing/invalid → reject
      # the upgrade with a 401 (close code 1008 equivalent) and never accept.
      payload, ok = Tina4.ws_authorized(auth_required, env, env["QUERY_STRING"].to_s)
      unless ok
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n") rescue nil
        socket.close rescue nil
        return
      end

      accept = Tina4.compute_accept_key(key)

      # When the client offered the "bearer" subprotocol (the browser transport,
      # since new WebSocket() can't set headers), echo "bearer" back as the
      # accepted subprotocol — browsers reject a 101 that doesn't echo a
      # subprotocol they offered. Mirrors Python's accept-subprotocol behaviour.
      subproto_header = Tina4.ws_bearer_subprotocol_offered?(env) ? "Sec-WebSocket-Protocol: bearer\r\n" : ""

      response = "HTTP/1.1 101 Switching Protocols\r\n" \
                 "Upgrade: websocket\r\n" \
                 "Connection: Upgrade\r\n" \
                 "#{subproto_header}" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n"

      socket.write(response)

      conn_id = SecureRandom.hex(16)
      ws_path = env["REQUEST_PATH"] || env["PATH_INFO"] || "/"
      connection = WebSocketConnection.new(conn_id, socket, ws_server: manager, path: ws_path)
      # Expose the verified token payload on the connection (nil on public
      # routes). Mirrors Python's connection.auth = payload.
      connection.auth = payload
      manager.register_connection(connection)

      # Start the idle reaper lazily once we actually have a connection (opt-in
      # via TINA4_WS_IDLE_TIMEOUT; a no-op when unset/0).
      manager.start_idle_reaper

      emit(:open, connection)

      Thread.new do
        begin
          loop do
            frame = connection.read_frame
            break unless frame

            connection.touch # mark activity for the idle reaper

            case frame[:opcode]
            when 0x1 # Text
              emit(:message, connection, frame[:data])
            when 0x8 # Close
              break
            when 0x9 # Ping
              connection.send_pong(frame[:data])
            end
          end
        rescue => e
          emit(:error, connection, e)
        ensure
          manager.unregister_connection(conn_id)
          emit(:close, connection)
          socket.close rescue nil
        end
      end
    end

    def emit(event, *args)
      @handlers[event]&.each { |h| h.call(*args) }
    end

    def remove_from_all_rooms(conn_id)
      @rooms.each_value { |members| members.delete(conn_id) }
    end
  end

  class WebSocketConnection
    attr_reader :id, :rooms, :last_activity
    attr_accessor :params, :path, :on_message_handler, :on_close_handler, :on_error_handler,
                  :auth

    def initialize(id, socket, ws_server: nil, path: "/")
      @id = id
      @socket = socket
      @params = {}
      @ws_server = ws_server
      @path = path
      # Verified JWT payload on a secured WS route, else nil (public route).
      # Mirrors Python's connection.auth.
      @auth = nil
      @rooms = Set.new
      @on_message_handler = nil
      @on_close_handler = nil
      @on_error_handler = nil
      # Updated on every inbound frame; the idle reaper closes connections that
      # have been silent longer than TINA4_WS_IDLE_TIMEOUT (opt-in).
      @last_activity = Time.now.to_f
    end

    # Mark inbound activity for the idle reaper.
    def touch
      @last_activity = Time.now.to_f
    end

    # Register a message handler (decorator style, matching Python).
    def on_message(&block)
      @on_message_handler = block
    end

    # Register a close handler (decorator style, matching Python).
    def on_close(&block)
      @on_close_handler = block
    end

    def join_room(room_name)
      @rooms.add(room_name)
      @ws_server&._join_room(@id, room_name)
    end

    def leave_room(room_name)
      @rooms.delete(room_name)
      @ws_server&._leave_room(@id, room_name)
    end

    def broadcast_to_room(room_name, message, exclude_self: false)
      return unless @ws_server

      exclude = exclude_self ? @id : nil
      @ws_server.broadcast_to_room(room_name, message, exclude: exclude)
    end

    # Broadcast a message to all other connections on the same path
    def broadcast(message, include_self: false)
      return unless @ws_server

      @ws_server.connections.each do |cid, conn|
        next if !include_self && cid == @id
        next if conn.path != @path
        conn.send_text(message)
      end
    end

    # True once a write has failed (broken pipe / closed socket). The manager's
    # resilient broadcast path uses this to prune dead connections.
    def closed?
      @closed == true
    end

    def send(message)
      data = message.is_a?(String) ? message : message.to_s
      # Text frames must be valid UTF-8; binary payloads are sent verbatim.
      data = data.encode("UTF-8") if data.encoding != Encoding::ASCII_8BIT
      frame = build_frame(0x1, data)
      @socket.write(frame)
    rescue IOError
      # Connection closed — mark dead so the broadcast path prunes it.
      @closed = true
    end

    alias_method :send_text, :send

    # Serialize a Hash/Array (or any JSON-coercible value) and send as a text frame.
    # Matches Python/PHP send_json.
    def send_json(data)
      send_text(JSON.generate(data))
    end

    def send_pong(data)
      frame = build_frame(0xA, data || "")
      @socket.write(frame)
    rescue IOError
      @closed = true
    end

    def close(code: 1000, reason: "")
      payload = [code].pack("n") + reason
      frame = build_frame(0x8, payload)
      @socket.write(frame) rescue nil
      @socket.close rescue nil
    end

    def read_frame
      first_byte = @socket.getbyte
      return nil unless first_byte

      opcode = first_byte & 0x0F
      second_byte = @socket.getbyte
      return nil unless second_byte

      masked = (second_byte & 0x80) != 0
      length = second_byte & 0x7F

      if length == 126
        length = @socket.read(2).unpack1("n")
      elsif length == 127
        length = @socket.read(8).unpack1("Q>")
      end

      mask_key = masked ? @socket.read(4).bytes : nil
      data = @socket.read(length) || ""

      if masked && mask_key
        data = data.bytes.each_with_index.map { |b, i| b ^ mask_key[i % 4] }.pack("C*")
      end

      { opcode: opcode, data: data }
    rescue IOError, EOFError
      nil
    end

    def build_frame(opcode, data)
      Tina4.build_frame(opcode, data)
    end
  end

  # Shared, process-wide manager for the dev-reload channel (/__dev_reload).
  #
  # Every browser that loads a page in debug mode opens a WebSocket here and
  # keeps it open. POST /__dev/api/reload (issued by the tina4 Rust CLI on a
  # file change) calls Tina4::DevReload.broadcast(...) to push an instant
  # {type, file, mtime} message to every connected client — no respawn, no
  # poll. Mirrors Python's single `_ws_manager` holding /__dev_reload
  # connections by path; in Ruby each route upgrade otherwise spins its own
  # isolated WebSocket engine, so a dedicated shared manager is what makes a
  # broadcast reach all clients.
  module DevReload
    @manager = nil
    @mutex = Mutex.new

    class << self
      # The shared WebSocket manager that holds every /__dev_reload connection.
      def manager
        @mutex.synchronize { @manager ||= Tina4::WebSocket.new }
      end

      # Register an open connection so a later broadcast reaches it.
      def add(connection)
        manager.connections[connection.id] = connection
      end

      # Drop a connection on close.
      def remove(connection)
        manager.connections.delete(connection.id)
      end

      # Number of live dev-reload clients (used by tests / introspection).
      def count
        manager.connections.size
      end

      # Push a text frame to every connected dev-reload client. Best-effort:
      # a dead socket or zero clients must never raise into the caller (the
      # /__dev/api/reload endpoint), so failures are swallowed per-connection.
      def broadcast(message)
        manager.connections.values.each do |conn|
          conn.send_text(message)
        rescue StandardError
          next
        end
      end
    end
  end
end
