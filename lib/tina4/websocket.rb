# frozen_string_literal: true
require "socket"
require "digest"
require "base64"

module Tina4
  class WebSocket
    GUID = "258EAFA5-E914-47DA-95CA-5AB5DC11AD37"

    attr_reader :connections

    def initialize
      @connections = {}
      @handlers = {
        open: [],
        message: [],
        close: [],
        error: []
      }
    end

    def on(event, &block)
      @handlers[event.to_sym] << block if @handlers.key?(event.to_sym)
    end

    def upgrade?(env)
      upgrade = env["HTTP_UPGRADE"] || ""
      upgrade.downcase == "websocket"
    end

    def handle_upgrade(env, socket)
      key = env["HTTP_SEC_WEBSOCKET_KEY"]
      return unless key

      accept = Base64.strict_encode64(
        Digest::SHA1.digest("#{key}#{GUID}")
      )

      response = "HTTP/1.1 101 Switching Protocols\r\n" \
                 "Upgrade: websocket\r\n" \
                 "Connection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n"

      socket.write(response)

      conn_id = SecureRandom.hex(16)
      connection = WebSocketConnection.new(conn_id, socket)
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
          emit(:close, connection)
          socket.close rescue nil
        end
      end
    end

    def broadcast(message, exclude: nil)
      @connections.each do |id, conn|
        next if exclude && id == exclude
        conn.send_text(message)
      end
    end

    private

    def emit(event, *args)
      @handlers[event]&.each { |h| h.call(*args) }
    end
  end

  class WebSocketConnection
    attr_reader :id

    def initialize(id, socket)
      @id = id
      @socket = socket
    end

    def send_text(message)
      data = message.encode("UTF-8")
      frame = build_frame(0x1, data)
      @socket.write(frame)
    rescue IOError
      # Connection closed
    end

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

    private

    def build_frame(opcode, data)
      frame = [0x80 | opcode].pack("C")
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
  end
end
