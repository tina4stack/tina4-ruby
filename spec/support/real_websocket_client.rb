# frozen_string_literal: true

require "socket"
require "securerandom"
require_relative "../../lib/tina4/base64"

# A REAL WebSocket peer for the specs: a TCP socket that performs the RFC 6455
# client handshake, masks what it sends and decodes what the server sends. It is
# the other end of a real connection, not a stand-in for the framework: every
# byte it sees went through the framework's real server socket.
#
#   read: true   a reader thread records every frame (text, binary, close)
#   read: false  the peer never reads, so the server's writes back up for real
#   vanish!      the peer disappears with a TCP reset and no close frame
class Tina4SpecWebSocketClient
  attr_reader :socket, :path

  def self.connect(port, path = "/", read: true, receive_buffer: nil, headers: {})
    socket = Socket.new(:INET, :STREAM)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, receive_buffer) if receive_buffer
    socket.connect(Socket.sockaddr_in(port, "127.0.0.1"))
    new(socket, path, read: read, headers: headers)
  end

  # The raw status line the server answered the handshake with, without
  # raising: for the refusal cases (403 / 401).
  def self.handshake_status(port, path = "/", headers: {})
    socket = TCPSocket.new("127.0.0.1", port)
    extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    socket.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n#{extra}\r\n")
    socket.wait_readable(5) ? socket.readpartial(4096).lines.first.to_s.strip : ""
  rescue EOFError
    ""
  ensure
    socket&.close
  end

  def initialize(socket, path, read:, headers: {})
    @socket = socket
    @path = path
    @headers = headers
    @frames = []
    @lock = Mutex.new
    @close_received = false
    @eof = false
    handshake
    @reader = Thread.new { read_loop } if read
  end

  def messages
    @lock.synchronize { @frames.map { |frame| frame[:data] } }
  end

  def frames
    @lock.synchronize { @frames.dup }
  end

  def close_received?
    @lock.synchronize { @close_received }
  end

  def gone?
    @lock.synchronize { @close_received || @eof }
  end

  # A masked text frame, as every client must send.
  def send_text(text)
    payload = text.b
    mask = SecureRandom.random_bytes(4).bytes
    masked = payload.bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }.pack("C*")
    header = [0x81].pack("C")
    header << if payload.bytesize < 126
                [0x80 | payload.bytesize].pack("C")
              elsif payload.bytesize < 65_536
                [0x80 | 126, payload.bytesize].pack("Cn")
              else
                [0x80 | 127, payload.bytesize].pack("CQ>")
              end
    @socket.write(header + mask.pack("C*") + masked)
  end

  # Leave with a TCP reset: no close frame, no FIN handshake.
  def vanish!
    @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
    @socket.close
    @reader&.kill
  end

  def close
    @reader&.kill
    @socket.close unless @socket.closed?
  rescue IOError, SystemCallError
    nil
  end

  private

  def handshake
    key = Tina4::Base64.strict_encode64(SecureRandom.random_bytes(16))
    extra = @headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    @socket.write("GET #{@path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                  "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n#{extra}\r\n")
    head = +""
    deadline = Time.now + 5
    until head.end_with?("\r\n\r\n")
      raise "no handshake answer from 127.0.0.1 for #{@path}: #{head.inspect}" if Time.now > deadline
      raise "no handshake answer for #{@path}" unless @socket.wait_readable(deadline - Time.now)

      head << @socket.readpartial(1)
    end
    raise "handshake refused for #{@path}: #{head.lines.first.inspect}" unless head.start_with?("HTTP/1.1 101")
  end

  def read_loop
    loop do
      first = @socket.getbyte
      break if first.nil?

      second = @socket.getbyte
      break if second.nil?

      length = second & 0x7F
      length = @socket.read(2).unpack1("n") if length == 126
      length = @socket.read(8).unpack1("Q>") if length == 127
      data = length.zero? ? "".b : @socket.read(length)
      break if data.nil?

      opcode = first & 0x0F
      if opcode == 0x8
        @lock.synchronize { @close_received = true }
        break
      end
      data = data.dup.force_encoding(Encoding::UTF_8) if opcode == 0x1
      @lock.synchronize { @frames << { opcode: opcode, data: data } }
    end
  rescue IOError, SystemCallError
    nil
  ensure
    @lock.synchronize { @eof = true }
  end
end
