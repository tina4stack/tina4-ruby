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
  end

  describe "#on" do
    it "registers event handlers for valid events" do
      handler_called = false
      ws.on(:open) { handler_called = true }
      # Trigger via send to test the private emit
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

    it "returns false when HTTP_UPGRADE is missing" do
      expect(ws.upgrade?({})).to be false
    end

    it "returns false for non-websocket upgrades" do
      env = { "HTTP_UPGRADE" => "h2c" }
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
      # Stub getbyte to return close frame so the read loop exits
      allow(write_io).to receive(:getbyte).and_return(0x88, 0x00)
      allow(write_io).to receive(:read).and_return("")
      allow(write_io).to receive(:close)

      ws.handle_upgrade(env, write_io)
      # Allow the thread to start and finish
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

      # First byte: FIN + text opcode (0x81)
      expect(bytes[0]).to eq(0x81)
      # Second byte: length (5)
      expect(bytes[1]).to eq(5)
      # Payload
      expect(bytes[2..].pack("C*")).to eq("hello")
    end

    it "handles medium-length messages (126-65535 bytes)" do
      message = "x" * 200
      conn.send_text(message)
      socket.rewind
      bytes = socket.read.bytes

      expect(bytes[0]).to eq(0x81)
      # Extended length marker
      expect(bytes[1]).to eq(126)
      # 16-bit length
      length = (bytes[2] << 8) | bytes[3]
      expect(length).to eq(200)
    end
  end

  describe "#send_pong" do
    it "writes a pong frame" do
      conn.send_pong("ping-data")
      socket.rewind
      bytes = socket.read.bytes

      # First byte: FIN + pong opcode (0x8A)
      expect(bytes[0]).to eq(0x8A)
    end
  end

  describe "#close" do
    it "writes a close frame with status code" do
      read_io, write_io = IO.pipe
      conn = described_class.new("test-close", write_io)
      conn.close(code: 1000, reason: "bye")

      bytes = read_io.read_nonblock(4096).bytes

      # First byte: FIN + close opcode (0x88)
      expect(bytes[0]).to eq(0x88)
      # Payload starts with 2-byte status code
      code = (bytes[2] << 8) | bytes[3]
      expect(code).to eq(1000)

      read_io.close
    end
  end

  describe "#read_frame" do
    it "reads a text frame" do
      # Build an unmasked text frame: "hi"
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
  end
end
