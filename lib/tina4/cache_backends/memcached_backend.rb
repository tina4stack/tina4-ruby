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
        payload = "set #{mc_key(key)} 0 #{exptime} #{data.bytesize}\r\n#{data}\r\n"
        command(payload, "\r\n")
      end

      def delete(key)
        command("delete #{mc_key(key)}\r\n", "\r\n").start_with?("DELETED")
      end

      def clear
        @hits = 0
        @misses = 0
        command("flush_all\r\n", "\r\n")
      end

      def stats
        size = 0
        resp = command("stats\r\n", "END\r\n")
        resp.split("\r\n").each do |line|
          if line.start_with?("STAT curr_items ")
            size = line.split[2].to_i
          end
        end
        { hits: @hits, misses: @misses, size: size, backend: "memcached" }
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
