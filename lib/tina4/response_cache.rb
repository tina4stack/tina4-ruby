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
  # Backends are selected via the TINA4_CACHE_BACKEND env var and built by the
  # unified factory (Tina4::CacheBackends.create_backend):
  #   memory    — in-process LRU cache (default, zero deps)
  #   file      — JSON files in data/cache/
  #   redis     — Redis (redis gem or raw RESP over TCP)
  #   valkey    — Valkey (Redis wire protocol; reports "valkey")
  #   memcached — Memcached (zero-dep text protocol over TCP)
  #   mongodb   — MongoDB TTL collection (requires the mongo gem)
  #   database  — tina4_cache table in any Tina4-supported database
  #
  # A configured network/driver backend that is unreachable degrades to the
  # file backend (a real working cache), never a silent no-op.
  #
  # Environment:
  #   TINA4_CACHE_BACKEND      — memory|file|redis|valkey|memcached|mongodb|database
  #   TINA4_CACHE_URL           — connection URL (redis/valkey/memcached/mongo) OR
  #                               SQL URL for database (falls back to TINA4_DATABASE_URL)
  #   TINA4_CACHE_TTL           — default TTL in seconds  (default: 60)
  #   TINA4_CACHE_MAX_ENTRIES   — maximum cache entries   (default: 1000)
  #   TINA4_CACHE_DIR           — file backend directory  (default: data/cache)
  #   TINA4_CACHE_USERNAME / TINA4_CACHE_PASSWORD — credentials when not in the URL
  #
  class ResponseCache
    # vary / vary_values carry the RFC 9111 s4.1 bookkeeping: the field names
    # the origin nominated, and the values they had on the request that caused
    # this response to be stored.
    CacheEntry = Struct.new(:body, :content_type, :status_code, :expires_at, :vary, :vary_values)

    # @param ttl [Integer] default TTL in seconds (0 = disabled)
    # @param max_entries [Integer] maximum cache entries
    # @param status_codes [Array<Integer>] only cache these status codes
    # @param backend [String, nil] cache backend: memory|redis|file
    # @param cache_url [String, nil] Redis URL
    # @param cache_dir [String, nil] File cache directory
    def initialize(ttl: nil, max_entries: nil, status_codes: [200],
                   backend: nil, cache_url: nil, cache_dir: nil)
      @ttl = ttl || (ENV["TINA4_CACHE_TTL"] ? ENV["TINA4_CACHE_TTL"].to_i : 60)
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
      hit = internal_lookup(method, url, request)
      if hit
        if response.respond_to?(:call)
          new_response = response.call(hit.body, hit.status_code, hit.content_type)
          set_cache_headers(new_response, "HIT", remaining_ttl(hit.expires_at))
          # Returning the Response OBJECT is what short-circuits. Returning the
          # [request, response] pair only REBINDS and continues, so the handler
          # ran anyway and the cache never saved a single call -- while still
          # stamping X-Cache: HIT, which made the header a lie.
          return new_response
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

      # Read the tags using the SAME mechanism before_cache wrote them with.
      # before_cache keys the write on respond_to?(:[]=), so read the same way:
      # a Tina4::Request responds to #[] (read-only param lookup) but NOT #[]=,
      # so the tags live on instance variables, not the param hash.
      if request.respond_to?(:[]=)
        method = request[:_cache_method]
        url = request[:_cache_url]
      else
        method = request.instance_variable_get(:@_cache_method)
        url = request.instance_variable_get(:@_cache_url)
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

      # This response came OUT of the cache; re-storing it would also overwrite
      # its X-Cache: HIT header with MISS.
      return [request, response] if header_value(response, "X-Cache") == "HIT"

      internal_store(method, url, status.to_i, content_type.to_s, body, request: request, response: response)
      # The handler ran (cache miss) — annotate the response so clients can
      # see this was a fresh response and how long it will be cached.
      set_cache_headers(response, "MISS", @ttl)
      [request, response]
    end

    # ── Class-level hooks, so `middleware: [Tina4::ResponseCache]` works ──

    class << self
      # Middleware.discover_methods walks klass.singleton_class and calls
      # klass.send(name, ...) -- it finds CLASS methods only. before_cache and
      # after_cache are INSTANCE methods, so attaching the class discovered no
      # hooks at all and the cache was a SILENT no-op: no warning, no header,
      # no caching. These two delegate to the module-level singleton (the same
      # instance Tina4.cache_get uses), which reads TTL and backend from ENV.
      #
      # @param request [Object]
      # @param response [Object]
      # @return [Tina4::Response, Array] the Response on a HIT (short-circuit),
      #   otherwise the [request, response] pair
      def before_response_cache(request, response)
        Tina4.cache_instance.before_cache(request, response)
      end

      # @param request [Object]
      # @param response [Object]
      # @return [Array] the [request, response] pair
      def after_response_cache(request, response)
        Tina4.cache_instance.after_cache(request, response)
      end
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
      if memory_backend?
        @mutex.synchronize do
          now = Time.now.to_f
          @store.reject! { |_k, v| v.is_a?(CacheEntry) && now > v.expires_at }
          { hits: @hits, misses: @misses, size: @store.size, backend: @backend_name, keys: @store.keys.dup }
        end
      else
        st = @backend.stats
        { hits: @hits, misses: @misses, size: st[:size], backend: @backend_name, keys: [] }
      end
    end

    # Clear all cached responses.
    def clear_cache
      if memory_backend?
        @mutex.synchronize do
          @hits = 0
          @misses = 0
          @store.clear
        end
      else
        @mutex.synchronize do
          @hits = 0
          @misses = 0
        end
        @backend.clear
      end
    end

    # Remove expired entries.
    #
    # @return [Integer] number of entries removed
    def sweep
      if memory_backend?
        @mutex.synchronize do
          now = Time.now.to_f
          keys_to_remove = @store.select { |_k, v| v.is_a?(CacheEntry) && now > v.expires_at }.keys
          keys_to_remove += @store.select { |_k, v| v.is_a?(Hash) && (v["expires_at"] || 0) > 0 && now > (v["expires_at"] || 0) }.keys
          keys_to_remove.each { |k| @store.delete(k) }
          keys_to_remove.size
        end
      else
        # Every backend answers sweep now - the base class returns 0 for the
        # providers that expire server-side, and memory/file/database return a
        # real count. The respond_to?(:sweep) guard that used to be here could
        # not tell "not supported" from "evicted nothing".
        @backend.sweep
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

    # Stamp X-Cache / X-Cache-TTL on a response. `state` is "HIT" or "MISS";
    # `ttl` is the remaining (HIT) or configured (MISS) TTL in seconds.
    # Parity with Python/PHP/Node ResponseCache, which set the same two
    # headers (no Cache-Control). No-op for responses that don't carry a
    # mutable headers hash (e.g. test doubles).
    def set_cache_headers(response, state, ttl)
      return unless response.respond_to?(:headers) && response.headers.is_a?(Hash)

      response.headers["X-Cache"] = state
      response.headers["X-Cache-TTL"] = ttl.to_i.to_s
    end

    # Remaining whole seconds until `expires_at` (a monotonic-ish Time.now.to_f
    # epoch), floored at 0 so an entry on the cusp of expiry never reports a
    # negative TTL.
    def remaining_ttl(expires_at)
      remaining = (expires_at || 0) - Time.now.to_f
      remaining.positive? ? remaining : 0
    end

    # Internal: retrieve a cached response. Used by middleware hooks only.
    def internal_lookup(method, url, request = nil)
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
        if Time.now.to_f > entry.expires_at || !vary_matches?(entry, request)
          backend_delete(key) if Time.now.to_f > entry.expires_at
          @mutex.synchronize { @misses += 1 }
          return nil
        end
        @mutex.synchronize { @hits += 1 }
        entry
      elsif entry.is_a?(Hash)
        expires_at = entry["expires_at"] || entry[:expires_at] || 0
        rebuilt = CacheEntry.new(
          entry["body"] || entry[:body],
          entry["content_type"] || entry[:content_type],
          entry["status_code"] || entry[:status_code],
          expires_at,
          entry["vary"] || entry[:vary] || [],
          entry["vary_values"] || entry[:vary_values] || {}
        )
        if Time.now.to_f > expires_at || !vary_matches?(rebuilt, request)
          backend_delete(key) if Time.now.to_f > expires_at
          @mutex.synchronize { @misses += 1 }
          return nil
        end
        @mutex.synchronize { @hits += 1 }
        rebuilt
      end
    end

    # Internal: store a response in the cache. Used by middleware hooks only.
    def internal_store(method, url, status_code, content_type, body, ttl: nil, request: nil, response: nil)
      return unless enabled?
      return unless method == "GET"
      return unless @status_codes.include?(status_code)
      return unless may_store?(request, response)

      effective_ttl = ttl || @ttl
      key = cache_key(method, url)
      expires_at = Time.now.to_f + effective_ttl
      vary = vary_fields(response)
      vary_values = vary.each_with_object({}) { |f, h| h[f] = header_value(request, f) }

      entry_data = {
        "body" => body,
        "content_type" => content_type,
        "status_code" => status_code,
        "expires_at" => expires_at,
        "vary" => vary,
        "vary_values" => vary_values
      }

      case @backend_name
      when "memory"
        @mutex.synchronize do
          if @store.size >= @max_entries && !@store.key?(key)
            oldest_key = @store.keys.first
            @store.delete(oldest_key)
          end
          @store[key] = CacheEntry.new(body, content_type, status_code, expires_at, vary, vary_values)
        end
      else
        backend_set(key, entry_data, effective_ttl)
      end
    end

    # ── RFC 9111 conformance (shared-cache rules) ──────────────

    # Response directives that let a SHARED cache store a response to a request
    # carrying Authorization (RFC 9111 s3.5).
    SHARED_CACHE_DIRECTIVES = %w[public s-maxage must-revalidate].freeze

    # Case-insensitive header lookup on a request or response.
    #
    # @param carrier [Object, nil]
    # @param name [String]
    # @return [String, nil]
    def header_value(carrier, name)
      return nil if carrier.nil?
      return nil unless carrier.respond_to?(:headers)

      headers = carrier.headers
      return nil unless headers.respond_to?(:each)

      target = name.downcase
      headers.each do |key, value|
        return value.to_s if key.to_s.downcase == target
      end
      nil
    end

    # The lower-cased field names in a response's Vary header.
    #
    # @param response [Object, nil]
    # @return [Array<String>]
    def vary_fields(response)
      raw = header_value(response, "Vary")
      return [] if raw.nil? || raw.strip.empty?

      raw.split(",").map { |f| f.strip.downcase }.reject(&:empty?)
    end

    # May a SHARED cache store this response? (RFC 9111 s3, s4.1)
    #
    # s3 -- "if the cache is shared: the Authorization header field is not
    # present in the request ... or a response directive is present that
    # explicitly allows shared caching". The key is method + URL only, so
    # without this one authenticated caller's body is replayed to the next.
    #
    # s4.1 -- a stored response whose Vary contains "*" "always fails to
    # match", so storing one is pointless.
    #
    # @param request [Object, nil]
    # @param response [Object, nil]
    # @return [Boolean]
    def may_store?(request, response)
      return false if vary_fields(response).include?("*")
      return true if header_value(request, "Authorization").nil?

      cache_control = header_value(response, "Cache-Control").to_s.downcase
      SHARED_CACHE_DIRECTIVES.any? { |directive| cache_control.include?(directive) }
    end

    # Do the nominated request headers match the ones recorded on the entry?
    #
    # RFC 9111 s4.1 -- the cache MUST NOT use a stored response unless every
    # request header field nominated by its Vary value matches. An absent field
    # only matches an absent field.
    #
    # @param entry [CacheEntry]
    # @param request [Object, nil]
    # @return [Boolean]
    def vary_matches?(entry, request)
      vary = entry.respond_to?(:vary) ? (entry.vary || []) : []
      return true if vary.empty?

      recorded = entry.vary_values || {}
      vary.all? { |field| header_value(request, field) == (recorded[field] || recorded[field.to_sym]) }
    end

    # ── Backend initialization ─────────────────────────────────

    # Build the storage backend. Memory keeps an in-process LRU store on the
    # ResponseCache itself (for direct CacheEntry access + per-instance stats);
    # every other backend delegates to a Tina4::CacheBackends object, which
    # also handles graceful file-fallback when a network backend is
    # unreachable. @backend_name is reconciled to the ACTUAL backend so a
    # degraded redis correctly reports "file".
    def init_backend
      if @backend_name == "memory"
        @backend = nil
        return
      end

      @backend = Tina4::CacheBackends.create_backend(
        backend: @backend_name,
        url: @cache_url,
        max_entries: @max_entries,
        cache_dir: @cache_dir
      )
      # Reconcile reported name with reality (e.g. redis → file on fallback).
      @backend_name = @backend.name
    end

    def memory_backend?
      @backend.nil?
    end

    # ── Backend operations ─────────────────────────────────────
    #
    # The middleware stores response entries as a Hash (entry_data) and the
    # direct KV API stores its own wrapper Hash. Both round-trip through the
    # unified backend's get/set/delete; for memory we keep the in-process
    # store with LRU eviction (parity with the previous behaviour and the
    # response-cache CacheEntry path).

    def backend_get(key)
      if memory_backend?
        @mutex.synchronize { @store[key] }
      else
        @backend.get(key)
      end
    end

    def backend_set(key, entry, ttl)
      if memory_backend?
        @mutex.synchronize do
          if @store.size >= @max_entries && !@store.key?(key)
            oldest_key = @store.keys.first
            @store.delete(oldest_key)
          end
          @store[key] = entry
        end
      else
        @backend.set(key, entry, ttl)
      end
    end

    def backend_delete(key)
      if memory_backend?
        @mutex.synchronize { !@store.delete(key).nil? }
      else
        @backend.delete(key)
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
