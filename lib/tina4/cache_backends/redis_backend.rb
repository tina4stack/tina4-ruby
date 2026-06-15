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

      def clear
        @hits = 0
        @misses = 0
        if @client
          begin
            keys = @client.keys("#{PREFIX}*")
            @client.del(*keys) unless keys.empty?
          rescue StandardError
          end
        elsif @use_raw
          # Raw RESP doesn't support pattern delete easily; rely on TTL.
        end
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

      # Send a command using the raw RESP protocol over TCP. Returns the simple
      # string / bulk string / integer as a String, or nil on miss/error.
      def resp_command(*args)
        cmd = +"*#{args.size}\r\n"
        args.each do |arg|
          s = arg.to_s
          cmd << "$#{s.bytesize}\r\n#{s}\r\n"
        end

        sock = TCPSocket.new(@host, @port)
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack("l_2"))

        if @password
          auth = if @username
                   "*3\r\n$4\r\nAUTH\r\n$#{@username.bytesize}\r\n#{@username}\r\n" \
                   "$#{@password.bytesize}\r\n#{@password}\r\n"
                 else
                   "*2\r\n$4\r\nAUTH\r\n$#{@password.bytesize}\r\n#{@password}\r\n"
                 end
          sock.write(auth)
          unless sock.recv(1024).start_with?("+")
            sock.close
            return nil
          end
        end

        if @db != 0
          select_cmd = "*2\r\n$6\r\nSELECT\r\n$#{@db.to_s.bytesize}\r\n#{@db}\r\n"
          sock.write(select_cmd)
          sock.recv(1024)
        end

        sock.write(cmd)
        response = sock.recv(65_536)
        sock.close

        if response.nil? || response.empty?
          nil
        elsif response.start_with?("+")
          response[1..].strip
        elsif response.start_with?("$-1")
          nil
        elsif response.start_with?("$")
          lines = response.split("\r\n")
          lines[1]
        elsif response.start_with?(":")
          response[1..].strip
        elsif response.start_with?("-")
          nil
        else
          response.strip
        end
      rescue StandardError
        nil
      end
    end
  end
end
