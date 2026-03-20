# frozen_string_literal: true

module Tina4
  # In-memory response cache for GET requests.
  #
  # Caches serialized responses by method + URL.
  # Designed to be used as Rack middleware or integrated into the Tina4 middleware chain.
  #
  # Usage:
  #   cache = Tina4::ResponseCache.new(ttl: 60, max_entries: 1000)
  #   cache.cache_response("GET", "/api/users", 200, "application/json", '{"users":[]}')
  #   hit = cache.get("GET", "/api/users")
  #
  # Environment:
  #   TINA4_CACHE_TTL -- default TTL in seconds (default: 0 = disabled)
  #
  class ResponseCache
    CacheEntry = Struct.new(:body, :content_type, :status_code, :expires_at)

    # @param ttl [Integer] default TTL in seconds (0 = disabled)
    # @param max_entries [Integer] maximum cache entries
    # @param status_codes [Array<Integer>] only cache these status codes
    def initialize(ttl: nil, max_entries: 1000, status_codes: [200])
      @ttl = ttl || (ENV["TINA4_CACHE_TTL"] ? ENV["TINA4_CACHE_TTL"].to_i : 0)
      @max_entries = max_entries
      @status_codes = status_codes
      @store = {}
      @mutex = Mutex.new
    end

    # Check if caching is enabled.
    #
    # @return [Boolean]
    def enabled?
      @ttl > 0
    end

    # Build a cache key from method and URL.
    #
    # @param method [String]
    # @param url [String]
    # @return [String]
    def cache_key(method, url)
      "#{method}:#{url}"
    end

    # Retrieve a cached response. Returns nil on miss or expired entry.
    #
    # @param method [String]
    # @param url [String]
    # @return [CacheEntry, nil]
    def get(method, url)
      return nil unless enabled?
      return nil unless method == "GET"

      key = cache_key(method, url)
      @mutex.synchronize do
        entry = @store[key]
        return nil unless entry

        if Time.now.to_f > entry.expires_at
          @store.delete(key)
          return nil
        end

        entry
      end
    end

    # Store a response in the cache.
    #
    # @param method [String]
    # @param url [String]
    # @param status_code [Integer]
    # @param content_type [String]
    # @param body [String]
    # @param ttl [Integer, nil] override default TTL
    def cache_response(method, url, status_code, content_type, body, ttl: nil)
      return unless enabled?
      return unless method == "GET"
      return unless @status_codes.include?(status_code)

      effective_ttl = ttl || @ttl
      key = cache_key(method, url)
      expires_at = Time.now.to_f + effective_ttl

      @mutex.synchronize do
        # Evict oldest if at capacity
        if @store.size >= @max_entries && !@store.key?(key)
          oldest_key = @store.keys.first
          @store.delete(oldest_key)
        end

        @store[key] = CacheEntry.new(body, content_type, status_code, expires_at)
      end
    end

    # Get cache statistics.
    #
    # @return [Hash] with :size and :keys
    def cache_stats
      @mutex.synchronize do
        { size: @store.size, keys: @store.keys.dup }
      end
    end

    # Clear all cached responses.
    def clear_cache
      @mutex.synchronize { @store.clear }
    end

    # Remove expired entries.
    #
    # @return [Integer] number of entries removed
    def sweep
      @mutex.synchronize do
        now = Time.now.to_f
        keys_to_remove = @store.select { |_k, v| now > v.expires_at }.keys
        keys_to_remove.each { |k| @store.delete(k) }
        keys_to_remove.size
      end
    end

    # Current TTL setting.
    #
    # @return [Integer]
    attr_reader :ttl

    # Maximum entries setting.
    #
    # @return [Integer]
    attr_reader :max_entries
  end
end
