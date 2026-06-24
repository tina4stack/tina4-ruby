# frozen_string_literal: true

require "socket"

module Tina4
  module SessionHandlers
    # A RESP error reply (`-ERR ...`) surfaced as an exception so the handler can
    # tell a protocol error apart from a genuine nil/miss.
    class RespError < StandardError; end

    # Zero-dependency synchronous RESP client over a TCP socket. Used by the Redis
    # and Valkey session handlers as the fallback when the optional `redis` gem is
    # not installed, so a Tina4 app talks to Redis/Valkey for sessions with NO
    # third-party gem. Parity with the Python (redis-py + raw RESP) and Node
    # (redis npm + raw respClient) session handlers, and with the framework's own
    # cache backends, which already speak raw RESP this way.
    #
    # One short-lived connection per command (open -> AUTH? -> SELECT? -> command
    # -> close), matching the cache backends. Ruby's blocking sockets make the
    # reply reader straightforward: read the header line up to CRLF, then read the
    # bulk body by its exact byte count (so a large session value spanning several
    # TCP segments is read in full, not truncated to one recv()).
    class RespClient
      def initialize(host:, port:, password: nil, db: 0, timeout: 5)
        @host = host
        @port = port
        @password = password
        @db = (db || 0).to_i
        @timeout = timeout
      end

      def get(key)
        command("GET", key)
      end

      def set(key, value)
        command("SET", key, value)
      end

      def setex(key, ttl, value)
        command("SETEX", key, ttl.to_s, value)
      end

      def del(key)
        command("DEL", key)
      end

      # Send one RESP command and return its reply: a String for a simple/bulk
      # string or integer, an Array for a multi-bulk reply, or nil for a nil bulk
      # ($-1) / miss. A transport failure (server unreachable, rejected AUTH or
      # SELECT, timeout, connection closed mid-reply) RAISES so the Session
      # boundary can log-loud + degrade (a real op never silently no-ops).
      def command(*args)
        sock = Socket.tcp(@host, @port, connect_timeout: @timeout)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [@timeout, 0].pack("l_2"))
        begin
          if @password && !@password.empty?
            write_command(sock, "AUTH", @password)
            reply = read_reply(sock)
            raise RespError, "AUTH rejected: #{reply.message}" if reply.is_a?(RespError)
          end
          if @db != 0
            write_command(sock, "SELECT", @db.to_s)
            reply = read_reply(sock)
            raise RespError, "SELECT rejected: #{reply.message}" if reply.is_a?(RespError)
          end
          write_command(sock, *args)
          reply = read_reply(sock)
          raise reply if reply.is_a?(RespError)
          reply
        ensure
          begin
            sock.close
          rescue StandardError
            # already closed / never opened — nothing to do
          end
        end
      end

      private

      def write_command(sock, *args)
        cmd = +"*#{args.size}\r\n"
        args.each do |arg|
          s = arg.to_s
          cmd << "$#{s.bytesize}\r\n#{s}\r\n"
        end
        sock.write(cmd)
      end

      def read_reply(sock)
        line = sock.gets("\r\n")
        raise RespError, "connection closed before reply" if line.nil?
        line = line.chomp("\r\n")
        type = line[0]
        rest = line[1..] || ""
        case type
        when "+", ":" then rest                         # simple string / integer
        when "-" then RespError.new(rest)               # error reply
        when "$"                                         # bulk string
          len = rest.to_i
          return nil if len.negative?                   # $-1 = nil
          data = read_exact(sock, len)
          read_exact(sock, 2)                           # trailing CRLF
          data
        when "*"                                         # array (multi-bulk)
          len = rest.to_i
          return nil if len.negative?
          Array.new(len) { read_reply(sock) }
        else
          line
        end
      end

      def read_exact(sock, count)
        buf = +""
        while buf.bytesize < count
          chunk = sock.read(count - buf.bytesize)
          raise RespError, "connection closed mid-reply" if chunk.nil? || chunk.empty?
          buf << chunk
        end
        buf
      end
    end
  end
end
