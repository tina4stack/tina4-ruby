# frozen_string_literal: true

require "digest"
require "json"
require "socket"

module Tina4
  module SessionHandlers
    # Memcached session handler - zero-dependency text protocol over TCP.
    #
    # Memcached was already one of the seven CACHE backends in all four
    # frameworks but was NOT a session backend in any of them, even though it is
    # the classic PHP session store. This closes that gap.
    #
    # Speaks the memcached TEXT protocol directly over a socket, so there is no
    # gem dependency - the same zero-dependency choice the Redis/Valkey handlers
    # make.
    #
    # BACKEND-FAILURE POLICY. A genuine key miss returns +{}+ silently (no
    # session yet is normal). A TRANSPORT failure - server unreachable,
    # connection dropped mid-reply, a protocol error - RAISES, so the Session
    # layer can log-loud and degrade. Collapsing the two is how a dead cache
    # silently logs every user out.
    #
    # Memcached has no persistence and no replication: a restart drops every
    # session. That is a deliberate trade (it is a cache), and it is why
    # file/database remain the defaults.
    #
    # Environment variables:
    #   TINA4_SESSION_MEMCACHED_HOST   - hostname (default: localhost)
    #   TINA4_SESSION_MEMCACHED_PORT   - port (default: 11211)
    #   TINA4_SESSION_MEMCACHED_PREFIX - key prefix (default: tina4:session:)
    #   TINA4_SESSION_TTL              - session TTL in seconds (default: 3600)
    class MemcachedHandler
      # Memcached rejects a key over 250 bytes or containing a space/control
      # character. A key that could break either rule is HASHED rather than
      # truncated - truncating would let two different sessions collide on one
      # key, handing one user another user's session.
      MAX_KEY_BYTES = 250

      # memcached's exptime field changes meaning at 30 days: at or below this
      # it is RELATIVE seconds, above it the server reads an ABSOLUTE UNIX
      # TIMESTAMP. See #exptime for why we convert instead of clamping.
      MAX_RELATIVE_EXPTIME = 2_592_000

      def initialize(options = {})
        options ||= {}
        @host = options[:host] || ENV["TINA4_SESSION_MEMCACHED_HOST"] || "localhost"
        @port = (options[:port] || ENV["TINA4_SESSION_MEMCACHED_PORT"] || 11_211).to_i
        @prefix = options[:prefix] || ENV["TINA4_SESSION_MEMCACHED_PREFIX"] || "tina4:session:"
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @timeout = (options[:timeout] || 5).to_f
      end

      # Read a session. Returns {} for a genuine miss; RAISES on a transport
      # failure so an outage is never mistaken for "no session yet".
      def read(session_id)
        resp = command("get #{key(session_id)}\r\n", ["END\r\n"])
        return {} unless resp.start_with?("VALUE")

        header, rest = resp.split("\r\n", 2)
        return {} if rest.nil?

        bytes = header.split[3].to_i
        parsed = JSON.parse(rest[0, bytes])
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        # A corrupt value is treated as no session rather than crashing the
        # request; the next write replaces it.
        {}
      end

      # Write a session with a TTL (0 falls back to the configured default).
      def write(session_id, data, ttl = 0)
        effective_ttl = exptime(ttl.to_i.positive? ? ttl.to_i : @ttl)
        payload = JSON.generate(data)
        cmd = "set #{key(session_id)} 0 #{effective_ttl} #{payload.bytesize}\r\n"
        resp = command("#{cmd}#{payload}\r\n",
                       ["STORED\r\n", "ERROR\r\n", "SERVER_ERROR", "CLIENT_ERROR"])
        return if resp.start_with?("STORED")

        raise "Memcached did not store the session: #{resp[0, 80].inspect}"
      end

      # Delete a session. A session that was already gone is not an error.
      def destroy(session_id)
        command("delete #{key(session_id)}\r\n", ["DELETED\r\n", "NOT_FOUND\r\n", "ERROR\r\n"])
        nil
      end

      # No-op - memcached expires its own keys via the TTL set on write.
      def cleanup
        nil
      end

      # Garbage-collect expired sessions. Memcached expires its own keys via the
      # TTL set on write, so there is genuinely nothing to sweep - but the
      # ARGUMENT still has to be accepted, because Session#gc calls
      # handler.gc(max_lifetime) with exactly one argument.
      #
      # This was `alias gc cleanup`, and #cleanup takes ZERO arguments, so
      # MemcachedHandler#gc.arity was 0 and EVERY session GC against a memcached
      # backend raised ArgumentError "wrong number of arguments (given 1,
      # expected 0)". Session#gc's rescue then reported it as a BACKEND failure -
      # "Session gc failed (...MemcachedHandler): wrong number of arguments" -
      # so an internal arity bug was misattributed to the operator's memcached,
      # and a perfectly healthy server logged an ERROR on every sweep.
      # FileHandler#gc(max_age = nil) and DatabaseHandler#gc(max_age) both take
      # the argument; memcached was the odd one out.
      #
      # @param max_age [Integer, nil] accepted for interface parity; memcached
      #   owns its own expiry, so nothing here consults it.
      def gc(_max_age = nil)
        cleanup
      end

      private

      # Convert a ttl in SECONDS to memcached's dual-meaning exptime field.
      #
      # memcached documents exptime as RELATIVE seconds up to 2592000 (30 days),
      # and as an ABSOLUTE UNIX TIMESTAMP for anything larger. Sending a raw ttl
      # of 2592001 therefore does not mean "30 days and one second" - it means
      # 1970-01-31, which is already past, so the item expires the instant it is
      # stored. memcached still replies STORED, so the write looks fine and the
      # very next read is a miss: a silent logout on every request.
      #
      # Measured against real memcached 1.6.45: ttl=2592000 survives, ttl=2592001
      # vanishes instantly.
      #
      # We CONVERT rather than CLAMP. Clamping a 60-day session down to 30 days
      # would silently shorten a lifetime the operator explicitly asked to be
      # longer, which is the same class of lie in the other direction.
      def exptime(ttl)
        return Time.now.to_i + ttl if ttl > MAX_RELATIVE_EXPTIME

        ttl
      end

      def key(session_id)
        candidate = "#{@prefix}#{session_id}"
        return candidate unless candidate.bytesize > MAX_KEY_BYTES || candidate.match?(/[\x00-\x20\x7f]/)

        "#{@prefix}#{Digest::SHA256.hexdigest(session_id.to_s)}"
      end

      # Run one memcached command and return the raw reply.
      #
      # RAISES on any transport failure. The cache backend swallows these and
      # returns an empty string - correct for a cache (a miss and an outage are
      # both "not cached"), wrong for a session, where an outage must be
      # distinguishable from "no session yet".
      def command(payload, terminators)
        sock = Socket.tcp(@host, @port, connect_timeout: @timeout)
        begin
          sock.write(payload)
          buffer = +""
          until terminators.any? { |t| buffer.include?(t) }
            chunk = begin
              sock.read_nonblock(4096)
            rescue IO::WaitReadable
              raise "timed out waiting for a reply" unless sock.wait_readable(@timeout)

              retry
            end
            raise "connection closed before a complete reply" if chunk.nil? || chunk.empty?

            buffer << chunk
          end
          buffer
        ensure
          begin
            sock&.close
          rescue IOError, SystemCallError
            nil
          end
        end
      rescue StandardError => e
        raise "Memcached session backend at #{@host}:#{@port} failed: #{e.message}"
      end
    end
  end
end
