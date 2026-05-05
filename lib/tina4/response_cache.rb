# frozen_string_literal: true

module Tina4
  # Multi-backend response cache for GET requests.
  #
  # Public surface (parity with Python tina4_python.cache):
  #   - Tina4::ResponseCache — middleware class
  #   - Tina4.cache_stats     — module function returning cache stats
  #   - Tina4.clear_cache     — module function flushing all cached entries
  #   - Tina4.cache_get / cache_set / cache_delete — module-level KV API
  #
  # The internal lookup/store of GET responses is performed by the middleware
  # hooks (before_cache, after_cache) and is NOT exposed publicly. Use the
  # middleware by attaching ResponseCache to your route, not by calling
  # the (private) internal_lookup / internal_store directly.
  #
  # Backends are selected via the TINA4_CACHE_BACKEND env var:
  #   memory — in-process LRU cache (default, zero deps)
  #   redis  — Redis / Valkey (uses `redis` gem or raw RESP over TCP)
  #   file   — JSON files in data/cache/
  #
  # Environment:
  #   TINA4_CACHE_BACKEND      — memory | redis | file  (default: memory)
  #   TINA4_CACHE_URL           — redis://localhost:6379  (redis only)
  #   TINA4_CACHE_TTL           — default TTL in seconds  (default: 0 = disabled)
  #   TINA4_CACHE_MAX_ENTRIES   — maximum cache entries   (default: 1000)
  #
  class ResponseCache
    CacheEntry = Struct.new(:body, :content_type, :status_code, :expires_at)

    # @param ttl [Integer] default TTL in seconds (0 = disabled)
    # @param max_entries [Integer] maximum cache entries
    # @param status_codes [Array<Integer>] only cache these status codes
    # @param backend [String, nil] cache backend: memory|redis|file
    # @param cache_url [String, nil] Redis URL
    # @param cache_dir [String, nil] File cache directory
    def initialize(ttl: nil, max_entries: nil, status_codes: [200],
                   backend: nil, cache_url: nil, cache_dir: nil)
      @ttl = ttl || (ENV["TINA4_CACHE_TTL"] ? ENV["TINA4_CACHE_TTL"].to_i : 0)
      @max_entries = max_entries || (ENV["TINA4_CACHE_MAX_ENTRIES"] ? ENV["TINA4_CACHE_MAX_ENTRIES"].to_i : 1000)
      @status_codes = status_codes
      @backend_name = backend || ENV.fetch("TINA4_CACHE_BACKEND", "memory").downcase.strip
      @cache_url = cache_url || ENV.fetch("TINA4_CACHE_URL", "redis://localhost:6379")
      @cache_dir = cache_dir || ENV.fetch("TINA4_CACHE_DIR", "data/cache")
      @store = {}
      @mutex = Mutex.new
      @hits = 0
      @misses = 0

      # Initialize backend
      init_backend
    end

    # Check if caching is enabled.
    #
    # @return [Boolean]
    def enabled?
      @ttl > 0
    end

    # ── Middleware hooks ────────────────────────────────────────────

    # Middleware hook — checks for a cached entry before the route handler runs.
    # If a cached entry exists for this GET request, short-circuits by replacing
    # the response. Otherwise tags the request so after_cache can capture the
    # response.
    def before_cache(request, response)
      return [request, response] unless enabled?

      method = (request.respond_to?(:method) ? request.method : "GET").to_s.upcase
      return [request, response] unless method == "GET"

      url = request.respond_to?(:url) ? request.url : (request.respond_to?(:path) ? request.path : "/")
      hit = internal_lookup(method, url)
      if hit
        if response.respond_to?(:call)
          new_response = response.call(hit.body, hit.status_code, hit.content_type)
          return [request, new_response]
        end
      end

      # Tag for after_cache
      if request.respond_to?(:[]=)
        request[:_cache_method] = method
        request[:_cache_url] = url
      else
        request.instance_variable_set(:@_cache_method, method)
        request.instance_variable_set(:@_cache_url, url)
      end
      [request, response]
    end

    # Middleware hook — captures the response body and stores it after the
    # route handler runs.
    def after_cache(request, response)
      return [request, response] unless enabled?

      method = if request.respond_to?(:[])
                 request[:_cache_method]
               else
                 request.instance_variable_get(:@_cache_method)
               end
      url = if request.respond_to?(:[])
              request[:_cache_url]
            else
              request.instance_variable_get(:@_cache_url)
            end
      return [request, response] if method.nil? || url.nil?

      status = if response.respond_to?(:status_code)
                 response.status_code
               elsif response.respond_to?(:status)
                 response.status
               else
                 200
               end
      content_type = if response.respond_to?(:content_type)
                       response.content_type
                     else
                       "application/json"
                     end
      body = if response.respond_to?(:body)
               response.body.to_s
             else
               response.to_s
             end

      internal_store(method, url, status.to_i, content_type.to_s, body)
      [request, response]
    end

    # ── Direct Cache API (same across all 4 languages) ──────────

    # Get a value from the cache by key.
    #
    # @param key [String]
    # @return [Object, nil]
    def cache_get(key)
      full_key = "direct:#{key}"
      raw = backend_get(full_key)

      if raw.nil?
        @mutex.synchronize { @misses += 1 }
        return nil
      end

      if raw.is_a?(Hash)
        expires_at = raw["expires_at"] || raw[:expires_at] || 0
        if expires_at > 0 && Time.now.to_f > expires_at
          backend_delete(full_key)
          @mutex.synchronize { @misses += 1 }
          return nil
        end
        @mutex.synchronize { @hits += 1 }
        raw["value"] || raw[:value]
      else
        @mutex.synchronize { @hits += 1 }
        raw
      end
    end

    # Store a value in the cache with optional TTL.
    #
    # @param key [String]
    # @param value [Object]
    # @param ttl [Integer] TTL in seconds (0 uses default)
    def cache_set(key, value, ttl: 0)
      effective_ttl = ttl > 0 ? ttl : @ttl
      effective_ttl = 60 if effective_ttl <= 0 # fallback for direct API
      full_key = "direct:#{key}"
      entry = {
        "value" => value,
        "expires_at" => Time.now.to_f + effective_ttl
      }
      backend_set(full_key, entry, effective_ttl)
    end

    # Delete a key from the cache.
    #
    # @param key [String]
    # @return [Boolean]
    def cache_delete(key)
      backend_delete("direct:#{key}")
    end

    # Get cache statistics.
    #
    # @return [Hash] with :hits, :misses, :size, :backend, :keys
    def cache_stats
      @mutex.synchronize do
        case @backend_name
        when "memory"
          now = Time.now.to_f
          @store.reject! { |_k, v| v.is_a?(CacheEntry) && now > v.expires_at }
          { hits: @hits, misses: @misses, size: @store.size, backend: @backend_name, keys: @store.keys.dup }
        when "file"
          sweep
          files = Dir.glob(File.join(@cache_dir, "*.json"))
          { hits: @hits, misses: @misses, size: files.size, backend: @backend_name, keys: [] }
        when "redis"
          size = 0
          if @redis_client
            begin
              keys = @redis_client.keys("tina4:cache:*")
              size = keys.size
            rescue StandardError
            end
          end
          { hits: @hits, misses: @misses, size: size, backend: @backend_name, keys: [] }
        else
          { hits: @hits, misses: @misses, size: @store.size, backend: @backend_name, keys: @store.keys.dup }
        end
      end
    end

    # Clear all cached responses.
    def clear_cache
      @mutex.synchronize do
        @hits = 0
        @misses = 0

        case @backend_name
        when "memory"
          @store.clear
        when "file"
          Dir.glob(File.join(@cache_dir, "*.json")).each { |f| File.delete(f) rescue nil }
        when "redis"
          if @redis_client
            begin
              keys = @redis_client.keys("tina4:cache:*")
              @redis_client.del(*keys) unless keys.empty?
            rescue StandardError
            end
          end
        end
      end
    end

    # Remove expired entries.
    #
    # @return [Integer] number of entries removed
    def sweep
      case @backend_name
      when "memory"
        @mutex.synchronize do
          now = Time.now.to_f
          keys_to_remove = @store.select { |_k, v| v.is_a?(CacheEntry) && now > v.expires_at }.keys
          keys_to_remove += @store.select { |_k, v| v.is_a?(Hash) && (v["expires_at"] || 0) > 0 && now > (v["expires_at"] || 0) }.keys
          keys_to_remove.each { |k| @store.delete(k) }
          keys_to_remove.size
        end
      when "file"
        removed = 0
        now = Time.now.to_f
        Dir.glob(File.join(@cache_dir, "*.json")).each do |f|
          begin
            data = JSON.parse(File.read(f))
            if data["expires_at"] && now > data["expires_at"]
              File.delete(f)
              removed += 1
            end
          rescue StandardError
          end
        end
        removed
      else
        0
      end
    end

    # Current TTL setting.
    attr_reader :ttl

    # Maximum entries setting.
    attr_reader :max_entries

    # Active backend name.
    def backend_name
      @backend_name
    end

    # @internal Test seam — exercises the same path the middleware uses.
    # Public for parity tests only; do not use in application code.
    def _internal_lookup(method, url)
      internal_lookup(method, url)
    end

    # @internal Test seam — exercises the same path the middleware uses.
    # Public for parity tests only; do not use in application code.
    def _internal_store(method, url, status_code, content_type, body, ttl: nil)
      internal_store(method, url, status_code, content_type, body, ttl: ttl)
    end

    private

    # Build a cache key from method and URL.
    def cache_key(method, url)
      "#{method}:#{url}"
    end

    # Internal: retrieve a cached response. Used by middleware hooks only.
    def internal_lookup(method, url)
      return nil unless enabled?
      return nil unless method == "GET"

      key = cache_key(method, url)
      entry = backend_get(key)

      if entry.nil?
        @mutex.synchronize { @misses += 1 }
        return nil
      end

      # For memory backend, entry is a CacheEntry; for others, reconstruct
      if entry.is_a?(CacheEntry)
        if Time.now.to_f > entry.expires_at
          backend_delete(key)
          @mutex.synchronize { @misses += 1 }
          return nil
        end
        @mutex.synchronize { @hits += 1 }
        entry
      elsif entry.is_a?(Hash)
        expires_at = entry["expires_at"] || entry[:expires_at] || 0
        if Time.now.to_f > expires_at
          backend_delete(key)
          @mutex.synchronize { @misses += 1 }
          return nil
        end
        @mutex.synchronize { @hits += 1 }
        CacheEntry.new(
          entry["body"] || entry[:body],
          entry["content_type"] || entry[:content_type],
          entry["status_code"] || entry[:status_code],
          expires_at
        )
      end
    end

    # Internal: store a response in the cache. Used by middleware hooks only.
    def internal_store(method, url, status_code, content_type, body, ttl: nil)
      return unless enabled?
      return unless method == "GET"
      return unless @status_codes.include?(status_code)

      effective_ttl = ttl || @ttl
      key = cache_key(method, url)
      expires_at = Time.now.to_f + effective_ttl

      entry_data = {
        "body" => body,
        "content_type" => content_type,
        "status_code" => status_code,
        "expires_at" => expires_at
      }

      case @backend_name
      when "memory"
        @mutex.synchronize do
          if @store.size >= @max_entries && !@store.key?(key)
            oldest_key = @store.keys.first
            @store.delete(oldest_key)
          end
          @store[key] = CacheEntry.new(body, content_type, status_code, expires_at)
        end
      else
        backend_set(key, entry_data, effective_ttl)
      end
    end

    # ── Backend initialization ─────────────────────────────────

    def init_backend
      case @backend_name
      when "redis"
        init_redis
      when "file"
        init_file_dir
      end
    end

    def init_redis
      @redis_client = nil
      begin
        require "redis"
        parsed = parse_redis_url(@cache_url)
        @redis_client = Redis.new(host: parsed[:host], port: parsed[:port], db: parsed[:db], timeout: 5)
        @redis_client.ping
      rescue LoadError, StandardError
        @redis_client = nil
      end
    end

    def parse_redis_url(url)
      cleaned = url.sub(%r{^redis://}, "")
      parts = cleaned.split(":")
      host = parts[0].empty? ? "localhost" : parts[0]
      port_and_db = parts[1] ? parts[1].split("/") : ["6379"]
      port = port_and_db[0].to_i
      port = 6379 if port == 0
      db = port_and_db[1] ? port_and_db[1].to_i : 0
      { host: host, port: port, db: db }
    end

    def init_file_dir
      require "json"
      require "fileutils"
      FileUtils.mkdir_p(@cache_dir)
    end

    # ── Backend operations ─────────────────────────────────────

    def backend_get(key)
      case @backend_name
      when "memory"
        @mutex.synchronize { @store[key] }
      when "redis"
        redis_get(key)
      when "file"
        file_get(key)
      else
        @mutex.synchronize { @store[key] }
      end
    end

    def backend_set(key, entry, ttl)
      case @backend_name
      when "memory"
        @mutex.synchronize do
          if @store.size >= @max_entries && !@store.key?(key)
            oldest_key = @store.keys.first
            @store.delete(oldest_key)
          end
          @store[key] = entry
        end
      when "redis"
        redis_set(key, entry, ttl)
      when "file"
        file_set(key, entry)
      end
    end

    def backend_delete(key)
      case @backend_name
      when "memory"
        @mutex.synchronize do
          !@store.delete(key).nil?
        end
      when "redis"
        redis_delete(key)
      when "file"
        file_delete(key)
      end
    end

    # ── Redis operations ───────────────────────────────────────

    def redis_get(key)
      full_key = "tina4:cache:#{key}"
      if @redis_client
        begin
          raw = @redis_client.get(full_key)
          return nil if raw.nil?
          JSON.parse(raw)
        rescue StandardError
          nil
        end
      else
        resp_get(full_key)
      end
    end

    def redis_set(key, entry, ttl)
      full_key = "tina4:cache:#{key}"
      serialized = JSON.generate(entry)
      if @redis_client
        begin
          if ttl > 0
            @redis_client.setex(full_key, ttl, serialized)
          else
            @redis_client.set(full_key, serialized)
          end
        rescue StandardError
        end
      else
        if ttl > 0
          resp_command("SETEX", full_key, ttl.to_s, serialized)
        else
          resp_command("SET", full_key, serialized)
        end
      end
    end

    def redis_delete(key)
      full_key = "tina4:cache:#{key}"
      if @redis_client
        begin
          @redis_client.del(full_key) > 0
        rescue StandardError
          false
        end
      else
        result = resp_command("DEL", full_key)
        result == "1"
      end
    end

    def resp_get(key)
      result = resp_command("GET", key)
      return nil if result.nil?
      JSON.parse(result) rescue nil
    end

    def resp_command(*args)
      parsed = parse_redis_url(@cache_url)
      cmd = "*#{args.size}\r\n"
      args.each { |arg| s = arg.to_s; cmd += "$#{s.bytesize}\r\n#{s}\r\n" }

      sock = TCPSocket.new(parsed[:host], parsed[:port])
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [5, 0].pack("l_2"))
      if parsed[:db] > 0
        select_cmd = "*2\r\n$6\r\nSELECT\r\n$#{parsed[:db].to_s.bytesize}\r\n#{parsed[:db]}\r\n"
        sock.write(select_cmd)
        sock.recv(1024)
      end
      sock.write(cmd)
      response = sock.recv(65536)
      sock.close

      if response.start_with?("+")
        response[1..].strip
      elsif response.start_with?("$-1")
        nil
      elsif response.start_with?("$")
        lines = response.split("\r\n")
        lines[1]
      elsif response.start_with?(":")
        response[1..].strip
      else
        nil
      end
    rescue StandardError
      nil
    end

    # ── File operations ────────────────────────────────────────

    def file_key_path(key)
      require "digest"
      safe = Digest::SHA256.hexdigest(key)
      File.join(@cache_dir, "#{safe}.json")
    end

    def file_get(key)
      path = file_key_path(key)
      return nil unless File.exist?(path)
      begin
        data = JSON.parse(File.read(path))
        if data["expires_at"] && Time.now.to_f > data["expires_at"]
          File.delete(path) rescue nil
          return nil
        end
        data
      rescue StandardError
        nil
      end
    end

    def file_set(key, entry)
      init_file_dir
      files = Dir.glob(File.join(@cache_dir, "*.json")).sort_by { |f| File.mtime(f) }
      while files.size >= @max_entries
        File.delete(files.shift) rescue nil
      end
      path = file_key_path(key)
      File.write(path, JSON.generate(entry))
    rescue StandardError
    end

    def file_delete(key)
      path = file_key_path(key)
      if File.exist?(path)
        File.delete(path) rescue nil
        true
      else
        false
      end
    end
  end

  # ── Module-level convenience (singleton, parity with Python) ───

  @default_cache = nil

  class << self
    # Lazy module-level singleton for cache_stats / clear_cache.
    def cache_instance
      @default_cache ||= ResponseCache.new(ttl: ENV["TINA4_CACHE_TTL"] ? ENV["TINA4_CACHE_TTL"].to_i : 60)
    end

    # Module-level KV API (parity with Python tina4_python.cache).
    def cache_get(key)
      cache_instance.cache_get(key)
    end

    def cache_set(key, value, ttl: 0)
      cache_instance.cache_set(key, value, ttl: ttl)
    end

    def cache_delete(key)
      cache_instance.cache_delete(key)
    end

    # Module-level cache stats (parity with Python tina4_python.cache.cache_stats()).
    def cache_stats
      cache_instance.cache_stats
    end

    # Module-level cache clear (parity with Python tina4_python.cache.clear_cache()).
    def clear_cache
      cache_instance.clear_cache
    end

    # Backward-compat alias for cache_clear (deprecated — use clear_cache).
    def cache_clear
      cache_instance.clear_cache
    end
  end
end
