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
      # The SHARED namespace generation counter. clear bumps it; every real key
      # carries it, so a bump invalidates every instance at once.
      GENERATION_KEY = "#{PREFIX}generation".freeze

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

      # Invalidate EVERY entry this cache can serve, on EVERY instance.
      #
      # Two wrong answers were shipped before this one. +flush_all+ wipes EVERY
      # key on the instance including every other application's - cache_clear is
      # public API, so calling it destroyed other tenants' data. Deleting only
      # the keys THIS process wrote fixed that but broke the contract the other
      # way: a second instance kept serving rows the first had just invalidated,
      # because it had never seen those keys.
      #
      # The namespace generation does both. Bumping the shared counter orphans
      # every previously-written entry for every instance at once, and touches
      # nothing outside our own prefix. The orphans are reclaimed by memcached's
      # own TTL and LRU - unreachable is what "removed" means for a cache.
      #
      # The local write log is still cleared so stats reports honestly, and its
      # keys are deleted eagerly so the space comes back immediately rather than
      # waiting for eviction.
      def clear
        @hits = 0
        @misses = 0
        (@own || {}).each_key { |k| command("delete #{k}\r\n", "\r\n") }
        @own = {}
        # incr is atomic, so two instances clearing at once still both advance.
        return if command("incr #{GENERATION_KEY} 1\r\n", "\r\n").strip.match?(/\A\d+\z/)

        # No counter yet: create it. `add` fails harmlessly if another instance
        # created it in the gap, and the incr then applies.
        command("add #{GENERATION_KEY} 0 0 1\r\n1\r\n", "\r\n")
        command("incr #{GENERATION_KEY} 1\r\n", "\r\n")
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

      # Read the SHARED namespace generation from the server.
      #
      # memcached has no KEYS scan and no prefix delete, so the only way to
      # invalidate globally without destroying other tenants is the documented
      # namespace idiom: every real key carries a generation, and clear bumps
      # it. Every instance then computes a different key and the old entries
      # become unreachable at once, expiring under the server's own TTL/LRU.
      #
      # The generation is read from the server on every operation, deliberately.
      # Caching it in-process would reintroduce exactly the bug this fixes: an
      # instance holding a stale generation keeps computing the OLD key, and the
      # old key still holds the old value, so it serves a stale hit after
      # another instance cleared. One extra round trip on a sub-millisecond
      # local service is the price of cross-instance invalidation.
      def generation
        resp = command("get #{GENERATION_KEY}\r\n", "END\r\n")
        if resp.start_with?("VALUE")
          begin
            header, rest = resp.split("\r\n", 2)
            nbytes = header.split[3].to_i
            return rest[0, nbytes] if rest
          rescue StandardError
            nil
          end
        end
        "0"
      end

      # Hash to a safe, bounded key (memcached keys: no spaces/control, <= 250
      # chars). The generation sits IN the key so a clear on ANY instance
      # orphans it for every instance at once.
      def mc_key(key)
        "#{PREFIX}#{generation}:#{Digest::SHA256.hexdigest(key)}"
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
