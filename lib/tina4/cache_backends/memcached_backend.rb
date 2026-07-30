# frozen_string_literal: true

require "json"
require "socket"
require "digest"
require_relative "base_backend"

module Tina4
  module CacheBackends
    # Memcached backend using the zero-dependency text protocol over TCP
    # (parity with Python _MemcachedBackend). Keys are SHA-256 hashed to stay
    # within memcached's 250-char / no-space key constraints. Memcached has no
    # auth, so credentials are ignored.
    class MemcachedBackend < BaseBackend
      PREFIX = "tina4:cache:"

      def initialize(url: "memcached://localhost:11211", max_entries: 1000)
        cleaned = url.sub(%r{^memcached://}, "").sub(%r{^memcache://}, "")
        parts = cleaned.split("/").first.to_s.split(":")
        @host = parts[0].nil? || parts[0].empty? ? "localhost" : parts[0]
        @port = parts[1] && !parts[1].empty? ? parts[1].to_i : 11_211
        @max_entries = max_entries
        @hits = 0
        @misses = 0
        @available = command("version\r\n", "\r\n").start_with?("VERSION")
      end

      def available?
        @available
      end

      def get(key)
        resp = command("get #{mc_key(key)}\r\n", "END\r\n")
        if resp.start_with?("VALUE")
          begin
            header, rest = resp.split("\r\n", 2)
            nbytes = header.split[3].to_i
            @hits += 1
            return JSON.parse(rest[0, nbytes])
          rescue StandardError
          end
        end
        @misses += 1
        nil
      end

      def set(key, value, ttl)
        data = JSON.generate(value)
        exptime = ttl > 0 ? ttl : 0
        k = mc_key(key)
        payload = "set #{k} 0 #{exptime} #{data.bytesize}\r\n#{data}\r\n"
        command(payload, "\r\n")
        # Keys THIS backend wrote, mapped to the moment each expires (0 = never).
        @own ||= {}
        @own[k] = exptime.positive? ? (Time.now.to_f + exptime) : 0.0
      end

      def delete(key)
        k = mc_key(key)
        result = command("delete #{k}\r\n", "\r\n").start_with?("DELETED")
        (@own ||= {}).delete(k)
        result
      end

      # Remove OUR entries, not the whole server's.
      #
      # This used to send +flush_all+, which wipes EVERY key on the memcached
      # instance - including every other application sharing it. cache_clear is
      # public API, so calling it destroyed other tenants' data. No other
      # backend does that: they each clear only what they own.
      #
      # Now that the backend tracks the keys it wrote, it deletes exactly those.
      # A key it never wrote is not its to remove.
      def clear
        @hits = 0
        @misses = 0
        (@own || {}).each_key { |k| command("delete #{k}\r\n", "\r\n") }
        @own = {}
      end

      # Report OUR entries, not the whole server's.
      #
      # This used to read memcached's +curr_items+, which is a GLOBAL counter:
      # it includes every key written by every other tenant of that server. On a
      # shared memcached (the normal deployment) +size+ was reporting somebody
      # else's data, and every other backend here is scoped - memory counts its
      # own hash, redis/valkey scan their own prefix, file counts its own
      # directory, mongo its own collection, database its own table. Memcached
      # was the only one leaking.
      #
      # It cannot be fixed by asking the server: memcached has no KEYS or
      # prefix-scan command. So the count comes from our own write log, filtered
      # by the TTLs we set. That is exact for the keys this process wrote; a key
      # EVICTED early under memory pressure is invisible to us and would be
      # over-counted, which is a far smaller and more honest error than counting
      # another application's keys.
      def stats
        now = Time.now.to_f
        # Drop the expired ones so the log cannot grow without bound.
        @own = (@own || {}).select { |_k, expires| expires.zero? || expires > now }
        { hits: @hits, misses: @misses, size: @own.size, backend: "memcached" }
      end

      def name
        "memcached"
      end

      private

      def mc_key(key)
        PREFIX + Digest::SHA256.hexdigest(key)
      end

      def command(payload, terminator)
        sock = TCPSocket.new(@host, @port)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack("l_2"))
        sock.write(payload)
        buf = +""
        until buf.include?(terminator)
          chunk = sock.recv(4096)
          break if chunk.nil? || chunk.empty?

          buf << chunk
        end
        sock.close
        buf
      rescue StandardError
        ""
      end
    end
  end
end
