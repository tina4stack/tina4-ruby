module Tina4
  # In-memory TTL cache with tag-based invalidation.
  #
  # Matches the Python / PHP / Node.js QueryCache API for cross-framework
  # parity. Thread-safe via an internal Mutex.
  #
  # Usage:
  #   cache = Tina4::QueryCache.new(default_ttl: 60, max_size: 1000)
  #   cache.set("key", "value", ttl: 30, tags: ["users"])
  #   cache.get("key")  # => "value"
  #   cache.clear_tag("users")
  #
  class QueryCache
    CacheEntry = Struct.new(:value, :expires_at, :tags)

    # @param default_ttl [Integer] default TTL in seconds (default: 300)
    # @param max_size [Integer] maximum number of cache entries (default: 1000)
    def initialize(default_ttl: 300, max_size: 1000)
      @default_ttl = default_ttl
      @max_size = max_size
      @store = {}
      @mutex = Mutex.new
    end

    # Store a value with optional TTL and tags.
    #
    # @param key [String]
    # @param value [Object]
    # @param ttl [Integer, nil] TTL in seconds (nil uses default)
    # @param tags [Array<String>] optional tags for grouped invalidation
    def set(key, value, ttl: nil, tags: [])
      ttl ||= @default_ttl
      expires_at = Time.now.to_f + ttl

      @mutex.synchronize do
        # Evict oldest if at capacity
        if @store.size >= @max_size && !@store.key?(key)
          oldest_key = @store.keys.first
          @store.delete(oldest_key)
        end
        @store[key] = CacheEntry.new(value, expires_at, tags)
      end
    end

    # Retrieve a cached value. Returns nil if expired or missing.
    #
    # @param key [String]
    # @param default [Object] value to return if key is missing
    # @return [Object, nil]
    def get(key, default = nil)
      @mutex.synchronize do
        entry = @store[key]
        return default unless entry

        if Time.now.to_f > entry.expires_at
          @store.delete(key)
          return default
        end

        entry.value
      end
    end

    # Check if a key exists and is not expired.
    #
    # @param key [String]
    # @return [Boolean]
    def has?(key)
      @mutex.synchronize do
        entry = @store[key]
        return false unless entry

        if Time.now.to_f > entry.expires_at
          @store.delete(key)
          return false
        end

        true
      end
    end

    # Delete a key from the cache.
    #
    # @param key [String]
    # @return [Boolean] true if the key was present
    def delete(key)
      @mutex.synchronize do
        !@store.delete(key).nil?
      end
    end

    # Clear all entries from the cache.
    def clear
      @mutex.synchronize { @store.clear }
    end

    # Clear all entries with a given tag.
    #
    # @param tag [String]
    # @return [Integer] number of entries removed
    def clear_tag(tag)
      @mutex.synchronize do
        keys_to_remove = @store.select { |_k, v| v.tags.include?(tag) }.keys
        keys_to_remove.each { |k| @store.delete(k) }
        keys_to_remove.size
      end
    end

    # Remove all expired entries.
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

    # Fetch from cache, or compute and store.
    #
    # @param key [String]
    # @param ttl [Integer] TTL in seconds
    # @param block [Proc] factory to compute the value if not cached
    # @return [Object]
    def remember(key, ttl, &block)
      cached = get(key)
      return cached unless cached.nil?

      value = block.call
      set(key, value, ttl: ttl)
      value
    end

    # Current number of entries in the cache.
    #
    # @return [Integer]
    def size
      @mutex.synchronize { @store.size }
    end

    # Generate a stable cache key from a SQL query and params.
    # Mirrors SQLTranslator.query_key for direct use on QueryCache.
    #
    # @param sql [String]
    # @param params [Array, nil]
    # @return [String]
    def self.query_key(sql, params = nil)
      raw = params ? "#{sql}|#{params.inspect}" : sql
      "query:#{Digest::SHA256.hexdigest(raw)}"
    end
  end
end
