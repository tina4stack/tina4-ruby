# frozen_string_literal: true

require "json"
require "socket"
require "uri"
require_relative "base_backend"

module Tina4
  module CacheBackends
    # Redis / Valkey backend (parity with Python _RedisBackend). Uses the
    # `redis` gem if it is installed, otherwise falls back to the raw RESP
    # protocol over a TCP socket — so it works with zero runtime dependencies.
    #
    # URL form: scheme://[user[:password]@]host[:port][/db]. Credentials may
    # also be supplied via TINA4_CACHE_USERNAME / TINA4_CACHE_PASSWORD (parity
    # with TINA4_DATABASE_USERNAME / TINA4_DATABASE_PASSWORD). Wrong credentials
    # cause available? to return false, so the factory falls back to file.
    class RedisBackend < BaseBackend
      PREFIX = "tina4:cache:"

      def initialize(url: "redis://localhost:6379", max_entries: 1000, name: "redis")
        @max_entries = max_entries
        @name = name
        @hits = 0
        @misses = 0
        @client = nil
        @use_raw = false

        parse_url(url)

        # Try the redis gem first.
        begin
          require "redis"
          kwargs = { host: @host, port: @port, db: @db, timeout: 5 }
          kwargs[:password] = @password if @password
          kwargs[:username] = @username if @username
          @client = Redis.new(**kwargs)
          @client.ping
          @available = true
        rescue LoadError, StandardError
          @client = nil
          @use_raw = true
          # No gem — usable only if the server answers (and authenticates).
          @available = probe
        end
      end

      def available?
        @available
      end

      def get(key)
        full_key = PREFIX + key
        raw = if @client
                begin
                  @client.get(full_key)
                rescue StandardError
                  nil
                end
              elsif @use_raw
                resp_command("GET", full_key)
              end

        if raw.nil?
          @misses += 1
          return nil
        end
        @hits += 1
        begin
          JSON.parse(raw)
        rescue JSON::ParserError, TypeError
          raw
        end
      end

      def set(key, value, ttl)
        full_key = PREFIX + key
        serialized = JSON.generate(value)
        if @client
          begin
            if ttl > 0
              @client.setex(full_key, ttl, serialized)
            else
              @client.set(full_key, serialized)
            end
          rescue StandardError
          end
        elsif @use_raw
          if ttl > 0
            resp_command("SETEX", full_key, ttl.to_s, serialized)
          else
            resp_command("SET", full_key, serialized)
          end
        end
      end

      def delete(key)
        full_key = PREFIX + key
        if @client
          begin
            @client.del(full_key) > 0
          rescue StandardError
            false
          end
        elsif @use_raw
          resp_command("DEL", full_key) == "1"
        else
          false
        end
      end

      # Remove EVERY entry this cache can serve - on BOTH transports.
      #
      # The raw RESP path used to be an empty branch with a comment: "no easy
      # pattern delete, rely on TTL". That made clear() a no-op on the
      # ZERO-DEPENDENCY default install, so a write never invalidated the
      # persistent DB query cache and every instance kept serving pre-write rows
      # until the TTL ran out (ADR-0024 rule 4: the default provider counts
      # double).
      #
      # SCAN, not KEYS: clear() runs on every write in persistent DB-cache mode,
      # and KEYS is O(N) and blocks the whole server for its duration. Redis's
      # own documentation says to prefer SCAN in production.
      #
      # The scan is scoped to our prefix, so another application sharing the
      # server is untouched. FLUSHALL/FLUSHDB would take their data with it and
      # is never used here.
      def clear
        @hits = 0
        @misses = 0
        return scan_delete_with_client if @client
        return unless @use_raw

        scan_delete_with_raw_resp
      end

      def stats
        size = 0
        if @client
          begin
            size = @client.keys("#{PREFIX}*").size
          rescue StandardError
          end
        end
        { hits: @hits, misses: @misses, size: size, backend: @name }
      end

      def name
        @name
      end

      private

      def parse_url(url)
        url = "redis://#{url}" unless url.include?("://")
        # Normalise valkey:// → redis:// so URI parses host/port/userinfo.
        normalised = url.sub(%r{^valkey://}, "redis://")
        uri = URI.parse(normalised)
        @host = uri.host || "localhost"
        @port = uri.port || 6379
        db_path = (uri.path || "").sub(%r{^/}, "")
        @db = db_path =~ /\A\d+\z/ ? db_path.to_i : 0
        url_user = uri.user && !uri.user.empty? ? URI.decode_www_form_component(uri.user) : nil
        url_pass = uri.password && !uri.password.empty? ? URI.decode_www_form_component(uri.password) : nil
        @username = url_user || (env_nonempty("TINA4_CACHE_USERNAME"))
        @password = url_pass || (env_nonempty("TINA4_CACHE_PASSWORD"))
      rescue URI::InvalidURIError
        @host = "localhost"
        @port = 6379
        @db = 0
        @username = env_nonempty("TINA4_CACHE_USERNAME")
        @password = env_nonempty("TINA4_CACHE_PASSWORD")
      end

      def env_nonempty(key)
        v = ENV[key]
        v && !v.empty? ? v : nil
      end

      # Real AUTH+PING handshake so wrong credentials also fall back to file.
      def probe
        resp_command("PING") == "PONG"
      rescue StandardError
        false
      end

      # Encode one command as a RESP array of bulk strings.
      def resp_encode(*args)
        out = +"*#{args.size}\r\n"
        args.each do |arg|
          value = arg.to_s
          out << "$#{value.bytesize}\r\n#{value}\r\n"
        end
        out
      end

      # Read ONE complete RESP reply and return String | nil | Array.
      #
      # Reads through the socket's BUFFERED gets/read so a reply larger than one
      # socket read is assembled in full. The previous implementation did a
      # single recv(65536) and string-split the result, which silently truncated
      # any bulk value or multi-bulk reply bigger than that buffer - so a large
      # cached entry came back corrupt and a key scan came back short.
      def resp_read(sock)
        line = sock.gets("\r\n")
        return nil if line.nil?

        prefix = line[0]
        body = line[1..].to_s.chomp
        case prefix
        when "+", ":" then body
        when "-" then nil
        when "$" then resp_read_bulk(sock, body.to_i)
        when "*" then resp_read_array(sock, body.to_i)
        else body
        end
      end

      # A bulk string: exactly `length` bytes, then the trailing CRLF.
      def resp_read_bulk(sock, length)
        return nil if length.negative?

        payload = sock.read(length + 2)
        return nil if payload.nil?

        payload[0, length].to_s.force_encoding(Encoding::UTF_8)
      end

      # A multi-bulk array: `count` complete replies, read recursively.
      def resp_read_array(sock, count)
        return nil if count.negative?

        Array.new(count) { resp_read(sock) }
      end

      # Open an authenticated RESP socket. The caller closes it.
      #
      # Kept separate from resp_command so a multi-step conversation (the SCAN
      # cursor loop in clear) runs over ONE connection instead of reconnecting
      # per command.
      def resp_session
        sock = TCPSocket.new(@host, @port)
        # SO_RCVTIMEO bounds the raw syscalls; IO#timeout (Ruby 3.2+) is the one
        # that bounds the BUFFERED gets/read this class now uses, so a server
        # that accepts the connection and never replies cannot hang a request.
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack("l_2"))
        sock.timeout = 5 if sock.respond_to?(:timeout=)

        if @password
          sock.write(@username ? resp_encode("AUTH", @username, @password) : resp_encode("AUTH", @password))
          unless resp_read(sock) == "OK"
            sock.close
            raise IOError, "redis AUTH rejected"
          end
        end

        if @db != 0
          sock.write(resp_encode("SELECT", @db))
          resp_read(sock)
        end
        sock
      end

      # Send one command using the raw RESP protocol over TCP. Returns the
      # decoded reply: a String for simple/bulk/integer replies, nil for a nil
      # reply or an error, and an Array for a multi-bulk reply.
      def resp_command(*args)
        sock = nil
        begin
          sock = resp_session
          sock.write(resp_encode(*args))
          resp_read(sock)
        rescue StandardError
          nil
        ensure
          close_quietly(sock)
        end
      end

      # SCAN cursor loop over the `redis` gem client. scan() (not keys()) so a
      # clear on the write path never blocks the server for an O(N) sweep.
      def scan_delete_with_client
        cursor = "0"
        loop do
          cursor, keys = @client.scan(cursor, match: "#{PREFIX}*", count: 500)
          @client.del(*keys) if keys && !keys.empty?
          break if cursor.nil? || cursor.to_s == "0"
        end
      rescue StandardError
        nil
      end

      # SCAN cursor loop over ONE raw RESP connection.
      def scan_delete_with_raw_resp
        sock = nil
        begin
          sock = resp_session
          cursor = "0"
          loop do
            sock.write(resp_encode("SCAN", cursor, "MATCH", "#{PREFIX}*", "COUNT", "500"))
            reply = resp_read(sock)
            break unless reply.is_a?(Array) && reply.size == 2

            cursor, keys = reply
            if keys.is_a?(Array) && !keys.empty?
              sock.write(resp_encode("DEL", *keys))
              resp_read(sock)
            end
            break if cursor.nil? || cursor == "0"
          end
        rescue StandardError
          nil
        ensure
          close_quietly(sock)
        end
      end

      def close_quietly(sock)
        sock&.close
      rescue StandardError
        nil
      end
    end
  end
end
