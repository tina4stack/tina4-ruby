# frozen_string_literal: true
require "socket"
require "digest"
require "base64"
require "set"

module Tina4
  WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-5AB5DC11AD37"

  # Compute Sec-WebSocket-Accept from Sec-WebSocket-Key per RFC 6455.
  def self.compute_accept_key(key)
    Base64.strict_encode64(Digest::SHA1.digest("#{key}#{WEBSOCKET_GUID}"))
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
    end

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
      @connections.each do |id, conn|
        next if exclude && id == exclude
        next if path && conn.path != path
        conn.send_text(message)
      end
    end

    def send_to(conn_id, message)
      conn = @connections[conn_id]
      conn&.send_text(message)
    end

    def close(conn_id, code: 1000, reason: "")
      conn = @connections[conn_id]
      conn&.close(code: code, reason: reason)
    end

    # ── Rooms ──────────────────────────────────────────────────

    def join_room_for(conn_id, room_name)
      @rooms[room_name] ||= Set.new
      @rooms[room_name].add(conn_id)
    end

    def leave_room_for(conn_id, room_name)
      @rooms[room_name]&.delete(conn_id)
    end

    def room_count(room_name)
      (@rooms[room_name] || Set.new).size
    end

    def get_room_connections(room_name)
      ids = @rooms[room_name] || Set.new
      ids.filter_map { |id| @connections[id] }
    end

    def broadcast_to_room(room_name, message, exclude: nil)
      (get_room_connections(room_name)).each do |conn|
        next if exclude && conn.id == exclude
        conn.send_text(message)
      end
    end

    def handle_upgrade(env, socket)
      key = env["HTTP_SEC_WEBSOCKET_KEY"]
      return unless key

      accept = Tina4.compute_accept_key(key)

      response = "HTTP/1.1 101 Switching Protocols\r\n" \
                 "Upgrade: websocket\r\n" \
                 "Connection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n"

      socket.write(response)

      conn_id = SecureRandom.hex(16)
      ws_path = env["REQUEST_PATH"] || env["PATH_INFO"] || "/"
      connection = WebSocketConnection.new(conn_id, socket, ws_server: self, path: ws_path)
      @connections[conn_id] = connection

      emit(:open, connection)

      Thread.new do
        begin
          loop do
            frame = connection.read_frame
            break unless frame

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
          @connections.delete(conn_id)
          remove_from_all_rooms(conn_id)
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
    attr_reader :id, :rooms
    attr_accessor :params, :path

    def initialize(id, socket, ws_server: nil, path: "/")
      @id = id
      @socket = socket
      @params = {}
      @ws_server = ws_server
      @path = path
      @rooms = Set.new
    end

    def join_room(room_name)
      @rooms.add(room_name)
      @ws_server&.join_room_for(@id, room_name)
    end

    def leave_room(room_name)
      @rooms.delete(room_name)
      @ws_server&.leave_room_for(@id, room_name)
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

    def send(message)
      data = message.encode("UTF-8")
      frame = build_frame(0x1, data)
      @socket.write(frame)
    rescue IOError
      # Connection closed
    end

    alias_method :send_text, :send

    def send_pong(data)
      frame = build_frame(0xA, data || "")
      @socket.write(frame)
    rescue IOError
      # Connection closed
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
end
