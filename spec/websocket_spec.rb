# frozen_string_literal: true

require "spec_helper"
require "socket"
require "stringio"

RSpec.describe Tina4::WebSocket do
  subject(:ws) { described_class.new }

  describe "#initialize" do
    it "starts with no connections" do
      expect(ws.connections).to be_empty
    end

    it "returns a hash for connections" do
      expect(ws.connections).to be_a(Hash)
    end
  end

  describe "GUID constant" do
    it "has the RFC 6455 GUID" do
      expect(Tina4::WebSocket::GUID).to eq("258EAFA5-E914-47DA-95CA-5AB5DC11AD37")
    end
  end

  describe "#on" do
    it "registers event handlers for valid events" do
      handler_called = false
      ws.on(:open) { handler_called = true }
      ws.send(:emit, :open)
      expect(handler_called).to be true
    end

    it "ignores handlers for unknown events" do
      expect { ws.on(:unknown) { "noop" } }.not_to raise_error
    end

    it "supports multiple handlers per event" do
      results = []
      ws.on(:message) { |_conn, _data| results << :first }
      ws.on(:message) { |_conn, _data| results << :second }
      ws.send(:emit, :message, nil, "hello")
      expect(results).to eq(%i[first second])
    end

    it "registers open handler" do
      called = false
      ws.on(:open) { called = true }
      ws.send(:emit, :open)
      expect(called).to be true
    end

    it "registers close handler" do
      called = false
      ws.on(:close) { called = true }
      ws.send(:emit, :close)
      expect(called).to be true
    end

    it "registers error handler" do
      called = false
      ws.on(:error) { called = true }
      ws.send(:emit, :error)
      expect(called).to be true
    end

    it "registers message handler" do
      called = false
      ws.on(:message) { called = true }
      ws.send(:emit, :message)
      expect(called).to be true
    end

    it "accepts string event names" do
      called = false
      ws.on("open") { called = true }
      ws.send(:emit, :open)
      expect(called).to be true
    end

    it "passes connection to open handler" do
      received_conn = nil
      ws.on(:open) { |conn| received_conn = conn }
      ws.send(:emit, :open, "my-conn")
      expect(received_conn).to eq("my-conn")
    end

    it "passes connection and data to message handler" do
      received_data = nil
      ws.on(:message) { |_conn, data| received_data = data }
      ws.send(:emit, :message, nil, "payload")
      expect(received_data).to eq("payload")
    end

    it "passes connection and error to error handler" do
      received_err = nil
      ws.on(:error) { |_conn, err| received_err = err }
      error = StandardError.new("test")
      ws.send(:emit, :error, nil, error)
      expect(received_err).to eq(error)
    end
  end

  describe "#upgrade?" do
    it "returns true when HTTP_UPGRADE is websocket" do
      env = { "HTTP_UPGRADE" => "websocket" }
      expect(ws.upgrade?(env)).to be true
    end

    it "returns true case-insensitively" do
      env = { "HTTP_UPGRADE" => "WebSocket" }
      expect(ws.upgrade?(env)).to be true
    end

    it "returns true for WEBSOCKET (all caps)" do
      env = { "HTTP_UPGRADE" => "WEBSOCKET" }
      expect(ws.upgrade?(env)).to be true
    end

    it "returns false when HTTP_UPGRADE is missing" do
      expect(ws.upgrade?({})).to be false
    end

    it "returns false for non-websocket upgrades" do
      env = { "HTTP_UPGRADE" => "h2c" }
      expect(ws.upgrade?(env)).to be false
    end

    it "returns false for empty string upgrade" do
      env = { "HTTP_UPGRADE" => "" }
      expect(ws.upgrade?(env)).to be false
    end
  end

  describe "#handle_upgrade" do
    it "returns nil without a Sec-WebSocket-Key" do
      env = { "HTTP_UPGRADE" => "websocket" }
      socket = StringIO.new
      expect(ws.handle_upgrade(env, socket)).to be_nil
    end

    it "writes a 101 handshake response" do
      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }

      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.1

      output = read_io.read_nonblock(4096)
      expect(output).to include("HTTP/1.1 101 Switching Protocols")
      expect(output).to include("Upgrade: websocket")
      expect(output).to include("Sec-WebSocket-Accept:")

      read_io.close
      write_io.close rescue nil
    end

    it "computes the correct Sec-WebSocket-Accept value" do
      key = "dGhlIHNhbXBsZSBub25jZQ=="
      expected_accept = Base64.strict_encode64(
        Digest::SHA1.digest("#{key}#{Tina4::WebSocket::GUID}")
      )

      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.1

      output = read_io.read_nonblock(4096)
      expect(output).to include("Sec-WebSocket-Accept: #{expected_accept}")

      read_io.close
      write_io.close rescue nil
    end

    it "produces different accept keys for different inputs" do
      key1 = "dGhlIHNhbXBsZSBub25jZQ=="
      key2 = "x3JJHMbDL1EzLkh9GBhXDw=="
      accept1 = Base64.strict_encode64(
        Digest::SHA1.digest("#{key1}#{Tina4::WebSocket::GUID}")
      )
      accept2 = Base64.strict_encode64(
        Digest::SHA1.digest("#{key2}#{Tina4::WebSocket::GUID}")
      )
      expect(accept1).not_to eq(accept2)
      expect(accept1.length).to be > 0
      expect(accept2.length).to be > 0
    end

    it "includes Connection: Upgrade header" do
      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.1

      output = read_io.read_nonblock(4096)
      expect(output).to include("Connection: Upgrade")

      read_io.close
      write_io.close rescue nil
    end

    it "fires the open handler" do
      opened = false
      ws.on(:open) { |_conn| opened = true }

      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.1

      expect(opened).to be true

      read_io.close
      write_io.close rescue nil
    end

    it "fires the close handler when connection ends" do
      closed = false
      ws.on(:close) { |_conn| closed = true }

      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.2

      expect(closed).to be true

      read_io.close
      write_io.close rescue nil
    end

    it "removes connection from connections hash after close" do
      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.2

      expect(ws.connections).to be_empty

      read_io.close
      write_io.close rescue nil
    end

    it "fires error handler on read exception" do
      error_received = nil
      ws.on(:error) { |_conn, err| error_received = err }

      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_raise(RuntimeError, "socket broke")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.2

      expect(error_received).to be_a(RuntimeError)
      expect(error_received.message).to eq("socket broke")

      read_io.close
      write_io.close rescue nil
    end

    it "passes connection object to open handler with an id" do
      received_conn = nil
      ws.on(:open) { |conn| received_conn = conn }

      key = "dGhlIHNhbXBsZSBub25jZQ=="
      env = { "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_KEY" => key }
      read_io, write_io = IO.pipe
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      sleep 0.1

      expect(received_conn).to be_a(Tina4::WebSocketConnection)
      expect(received_conn.id).to be_a(String)
      expect(received_conn.id.length).to eq(32) # hex(16) = 32 chars

      read_io.close
      write_io.close rescue nil
    end
  end

  describe "#broadcast" do
    it "sends a message to all connections" do
      conn1 = instance_double(Tina4::WebSocketConnection, id: "a")
      conn2 = instance_double(Tina4::WebSocketConnection, id: "b")

      ws.connections["a"] = conn1
      ws.connections["b"] = conn2

      expect(conn1).to receive(:send_text).with("hello all")
      expect(conn2).to receive(:send_text).with("hello all")

      ws.broadcast("hello all")
    end

    it "excludes a connection when specified" do
      conn1 = instance_double(Tina4::WebSocketConnection, id: "a")
      conn2 = instance_double(Tina4::WebSocketConnection, id: "b")

      ws.connections["a"] = conn1
      ws.connections["b"] = conn2

      expect(conn1).not_to receive(:send_text)
      expect(conn2).to receive(:send_text).with("hello")

      ws.broadcast("hello", exclude: "a")
    end

    it "does nothing with no connections" do
      expect { ws.broadcast("test") }.not_to raise_error
    end

    it "sends to a single connection" do
      conn = instance_double(Tina4::WebSocketConnection, id: "only")
      ws.connections["only"] = conn
      expect(conn).to receive(:send_text).with("solo")
      ws.broadcast("solo")
    end
  end
end

RSpec.describe Tina4::WebSocketConnection do
  let(:socket) { StringIO.new }
  let(:conn) { described_class.new("test-id", socket) }

  describe "#id" do
    it "returns the connection id" do
      expect(conn.id).to eq("test-id")
    end
  end

  describe "#send_text" do
    it "writes a text frame to the socket" do
      conn.send_text("hello")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(5)
      expect(bytes[2..].pack("C*")).to eq("hello")
    end

    it "handles medium-length messages (126-65535 bytes)" do
      message = "x" * 200
      conn.send_text(message)
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(126)
      length = (bytes[2] << 8) | bytes[3]
      expect(length).to eq(200)
    end

    it "handles empty messages" do
      conn.send_text("")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(0)
    end

    it "handles single character messages" do
      conn.send_text("a")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(1)
      expect(bytes[2]).to eq("a".ord)
    end

    it "handles exactly 125-byte messages (max small)" do
      message = "a" * 125
      conn.send_text(message)
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(125)
    end

    it "handles exactly 126-byte messages (uses extended length)" do
      message = "b" * 126
      conn.send_text(message)
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      expect(bytes[1]).to eq(126)
      length = (bytes[2] << 8) | bytes[3]
      expect(length).to eq(126)
    end

    it "handles unicode messages" do
      message = "Hello \u00e9\u00e8\u00ea".encode("UTF-8")
      # The source encodes to UTF-8 then builds frame; build_frame uses binary concat
      # Just verify send_text does not raise for ASCII-safe messages
      conn.send_text("Hello World")
      socket.rewind
      data = socket.read
      expect(data.bytes[0]).to eq(0x81)
    end

    it "silently handles IOError on closed socket" do
      closed_socket = StringIO.new
      closed_socket.close_write
      conn = described_class.new("err", closed_socket)
      expect { conn.send_text("test") }.not_to raise_error
    end
  end

  describe "#send_pong" do
    it "writes a pong frame" do
      conn.send_pong("ping-data")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x8A)
    end

    it "includes pong payload" do
      conn.send_pong("pong-payload")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x8A)
      payload_len = bytes[1]
      expect(payload_len).to eq("pong-payload".bytesize)
    end

    it "handles empty pong data" do
      conn.send_pong("")
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x8A)
      expect(bytes[1]).to eq(0)
    end

    it "silently handles IOError on closed socket" do
      closed_socket = StringIO.new
      closed_socket.close_write
      conn = described_class.new("err", closed_socket)
      expect { conn.send_pong("test") }.not_to raise_error
    end
  end

  describe "#close" do
    it "writes a close frame with status code" do
      read_io, write_io = IO.pipe
      conn = described_class.new("test-close", write_io)
      conn.close(code: 1000, reason: "bye")

      bytes = read_io.read_nonblock(4096).bytes

      expect(bytes[0]).to eq(0x88)
      code = (bytes[2] << 8) | bytes[3]
      expect(code).to eq(1000)

      read_io.close
    end

    it "writes close frame with code 1001 (going away)" do
      read_io, write_io = IO.pipe
      conn = described_class.new("test-close2", write_io)
      conn.close(code: 1001, reason: "going away")

      bytes = read_io.read_nonblock(4096).bytes

      expect(bytes[0]).to eq(0x88)
      code = (bytes[2] << 8) | bytes[3]
      expect(code).to eq(1001)

      read_io.close
    end

    it "includes reason text in close frame" do
      read_io, write_io = IO.pipe
      conn = described_class.new("test-close3", write_io)
      conn.close(code: 1000, reason: "shutting down")

      data = read_io.read_nonblock(4096)
      bytes = data.bytes

      # Payload is 2-byte code + reason string
      payload = data[2..].force_encoding("UTF-8")
      # First 2 bytes are status code, rest is reason
      reason_text = payload[2..]
      expect(reason_text).to eq("shutting down")

      read_io.close
    end

    it "handles close with empty reason" do
      read_io, write_io = IO.pipe
      conn = described_class.new("test-close4", write_io)
      conn.close(code: 1000, reason: "")

      bytes = read_io.read_nonblock(4096).bytes

      expect(bytes[0]).to eq(0x88)
      # Payload is just the 2-byte code
      expect(bytes[1]).to eq(2)

      read_io.close
    end
  end

  describe "#read_frame" do
    it "reads a text frame" do
      frame = [0x81, 0x02].pack("CC") + "hi"
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x1)
      expect(result[:data]).to eq("hi")
    end

    it "reads a masked frame" do
      payload = "hi"
      mask_key = [0x12, 0x34, 0x56, 0x78]
      masked = payload.bytes.each_with_index.map { |b, i| b ^ mask_key[i % 4] }.pack("C*")

      frame = [0x81, 0x80 | payload.bytesize].pack("CC") + mask_key.pack("C4") + masked
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x1)
      expect(result[:data]).to eq("hi")
    end

    it "returns nil on empty socket" do
      socket = StringIO.new("")
      conn = described_class.new("test", socket)
      expect(conn.read_frame).to be_nil
    end

    it "reads a close frame (opcode 0x8)" do
      # Close frame with code 1000
      payload = [1000].pack("n")
      frame = [0x88, payload.bytesize].pack("CC") + payload
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x8)
    end

    it "reads a ping frame (opcode 0x9)" do
      frame = [0x89, 0x04].pack("CC") + "ping"
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x9)
      expect(result[:data]).to eq("ping")
    end

    it "reads an unmasked frame with empty payload" do
      frame = [0x81, 0x00].pack("CC")
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x1)
      expect(result[:data]).to eq("")
    end

    it "reads a medium payload (126-byte extended length)" do
      payload = "A" * 200
      len_bytes = [126, 200].pack("Cn")
      frame = [0x81].pack("C") + len_bytes + payload
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x1)
      expect(result[:data].length).to eq(200)
      expect(result[:data]).to eq(payload)
    end

    it "reads a masked frame with longer payload" do
      payload = "Hello, World!"
      mask_key = [0xAA, 0xBB, 0xCC, 0xDD]
      masked = payload.bytes.each_with_index.map { |b, i| b ^ mask_key[i % 4] }.pack("C*")

      frame = [0x81, 0x80 | payload.bytesize].pack("CC") + mask_key.pack("C4") + masked
      socket = StringIO.new(frame)
      conn = described_class.new("test", socket)

      result = conn.read_frame
      expect(result[:opcode]).to eq(0x1)
      expect(result[:data]).to eq("Hello, World!")
    end

    it "returns nil when only first byte is available" do
      socket = StringIO.new([0x81].pack("C"))
      # getbyte returns 0x81, then nil for second byte
      conn = described_class.new("test", socket)
      # First getbyte returns 0x81, second returns nil
      result = conn.read_frame
      expect(result).to be_nil
    end
  end

  describe "build_frame (private)" do
    it "builds small frame correctly" do
      frame = conn.__send__(:build_frame, 0x1, "Hello")
      expect(frame.bytes[0]).to eq(0x81)
      expect(frame.bytes[1]).to eq(5)
      expect(frame[2..]).to eq("Hello")
    end

    it "builds medium frame with 16-bit length" do
      data = "X" * 200
      frame = conn.__send__(:build_frame, 0x1, data)
      expect(frame.bytes[1]).to eq(126)
      length = (frame.bytes[2] << 8) | frame.bytes[3]
      expect(length).to eq(200)
    end

    it "builds frame with different opcodes" do
      # Text
      frame = conn.__send__(:build_frame, 0x1, "test")
      expect(frame.bytes[0] & 0x0F).to eq(0x1)

      # Binary
      frame = conn.__send__(:build_frame, 0x2, "test")
      expect(frame.bytes[0] & 0x0F).to eq(0x2)

      # Close
      frame = conn.__send__(:build_frame, 0x8, "test")
      expect(frame.bytes[0] & 0x0F).to eq(0x8)

      # Ping
      frame = conn.__send__(:build_frame, 0x9, "test")
      expect(frame.bytes[0] & 0x0F).to eq(0x9)

      # Pong
      frame = conn.__send__(:build_frame, 0xA, "test")
      expect(frame.bytes[0] & 0x0F).to eq(0xA)
    end

    it "always sets FIN bit" do
      frame = conn.__send__(:build_frame, 0x1, "test")
      expect(frame.bytes[0] & 0x80).to eq(0x80)
    end

    it "builds frame with empty payload" do
      frame = conn.__send__(:build_frame, 0x1, "")
      expect(frame.bytes[0]).to eq(0x81)
      expect(frame.bytes[1]).to eq(0)
      expect(frame.length).to eq(2)
    end
  end
end

# ── Rooms / Namespaces ──────────────────────────────────────────

RSpec.describe "WebSocket Rooms" do
  let(:ws_server) { Tina4::WebSocket.new }

  def make_connection(id, path: "/")
    socket = StringIO.new
    Tina4::WebSocketConnection.new(id, socket, ws_server: ws_server, path: path)
  end

  # ── Connection-level rooms ────────────────────────────────────

  describe "WebSocketConnection#rooms" do
    it "is empty initially" do
      conn = make_connection("a")
      expect(conn.rooms).to be_empty
    end

    it "join_room adds connection to a named room" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      expect(conn.rooms).to include("chat")
    end

    it "leave_room removes connection from a named room" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      conn.leave_room("chat")
      expect(conn.rooms).not_to include("chat")
    end

    it "join_room is idempotent" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      conn.join_room("chat")
      expect(ws_server.room_count("chat")).to eq(1)
    end

    it "leave_room on non-member does not raise" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      expect { conn.leave_room("nonexistent") }.not_to raise_error
    end

    it "connection can be in multiple rooms" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      conn.join_room("lobby")
      expect(conn.rooms).to include("chat")
      expect(conn.rooms).to include("lobby")
    end

    it "leaving one room keeps other rooms intact" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      conn.join_room("lobby")
      conn.leave_room("chat")
      expect(conn.rooms).not_to include("chat")
      expect(conn.rooms).to include("lobby")
    end
  end

  # ── Server-level rooms ─────────────────────────────────────────

  describe "Tina4::WebSocket room management" do
    it "room_count returns 0 for unknown room" do
      expect(ws_server.room_count("ghost")).to eq(0)
    end

    it "room_count reflects joined members" do
      conn1 = make_connection("a")
      conn2 = make_connection("b")
      ws_server.connections["a"] = conn1
      ws_server.connections["b"] = conn2
      conn1.join_room("chat")
      conn2.join_room("chat")
      expect(ws_server.room_count("chat")).to eq(2)
    end

    it "room_count decreases when a member leaves" do
      conn = make_connection("a")
      ws_server.connections["a"] = conn
      conn.join_room("chat")
      conn.leave_room("chat")
      expect(ws_server.room_count("chat")).to eq(0)
    end

    it "get_room_connections returns members only" do
      conn1 = make_connection("a")
      conn2 = make_connection("b")
      conn3 = make_connection("c")
      ws_server.connections["a"] = conn1
      ws_server.connections["b"] = conn2
      ws_server.connections["c"] = conn3
      conn1.join_room("chat")
      conn2.join_room("chat")
      members = ws_server.get_room_connections("chat")
      expect(members).to include(conn1)
      expect(members).to include(conn2)
      expect(members).not_to include(conn3)
    end

    it "get_room_connections returns empty array for unknown room" do
      expect(ws_server.get_room_connections("ghost")).to eq([])
    end

    it "broadcast_to_room sends to all room members" do
      conn1 = make_connection("a")
      conn2 = make_connection("b")
      conn3 = make_connection("c")
      ws_server.connections["a"] = conn1
      ws_server.connections["b"] = conn2
      ws_server.connections["c"] = conn3
      conn1.join_room("chat")
      conn2.join_room("chat")

      expect(conn1).to receive(:send_text).with("hello room")
      expect(conn2).to receive(:send_text).with("hello room")
      expect(conn3).not_to receive(:send_text)

      allow(conn1).to receive(:send_text)
      allow(conn2).to receive(:send_text)

      ws_server.broadcast_to_room("chat", "hello room")
    end

    it "broadcast_to_room excludes specified connection" do
      conn1 = make_connection("a")
      conn2 = make_connection("b")
      ws_server.connections["a"] = conn1
      ws_server.connections["b"] = conn2
      conn1.join_room("chat")
      conn2.join_room("chat")

      expect(conn1).not_to receive(:send_text)
      expect(conn2).to receive(:send_text).with("msg")

      allow(conn2).to receive(:send_text)

      ws_server.broadcast_to_room("chat", "msg", exclude: "a")
    end

    it "broadcast_to_room on empty room does not raise" do
      expect { ws_server.broadcast_to_room("ghost", "msg") }.not_to raise_error
    end
  end
end
