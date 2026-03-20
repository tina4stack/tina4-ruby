# frozen_string_literal: true

require "digest"

module Tina4
  # Cross-engine SQL translator.
  #
  # Each database adapter calls the rules it needs. Rules are composable
  # and stateless -- just string transforms.
  #
  # Also includes query caching with TTL support.
  #
  # Usage:
  #   translated = Tina4::SQLTranslator.limit_to_rows("SELECT * FROM users LIMIT 10 OFFSET 5")
  #   # => "SELECT * FROM users ROWS 6 TO 15"
  #
  class SQLTranslator
    class << self
      # Convert LIMIT/OFFSET to Firebird ROWS...TO syntax.
      #
      # LIMIT 10 OFFSET 5  =>  ROWS 6 TO 15
      # LIMIT 10           =>  ROWS 1 TO 10
      #
      # @param sql [String]
      # @return [String]
      def limit_to_rows(sql)
        # Try LIMIT X OFFSET Y first
        if (m = sql.match(/\bLIMIT\s+(\d+)\s+OFFSET\s+(\d+)\s*$/i))
          limit = m[1].to_i
          offset = m[2].to_i
          start_row = offset + 1
          end_row = offset + limit
          return sql[0...m.begin(0)] + "ROWS #{start_row} TO #{end_row}"
        end

        # Then try LIMIT X only
        if (m = sql.match(/\bLIMIT\s+(\d+)\s*$/i))
          limit = m[1].to_i
          return sql[0...m.begin(0)] + "ROWS 1 TO #{limit}"
        end

        sql
      end

      # Convert LIMIT to MSSQL TOP syntax.
      #
      # SELECT ... LIMIT 10  =>  SELECT TOP 10 ...
      # OFFSET queries are left unchanged (not supported by TOP).
      #
      # @param sql [String]
      # @return [String]
      def limit_to_top(sql)
        if (m = sql.match(/\bLIMIT\s+(\d+)\s*$/i)) && !sql.match?(/\bOFFSET\b/i)
          limit = m[1].to_i
          body = sql[0...m.begin(0)].strip
          return body.sub(/^(SELECT)\b/i, "\\1 TOP #{limit}")
        end

        sql
      end

      # Convert || concatenation to CONCAT() for MySQL/MSSQL.
      #
      # 'a' || 'b' || 'c'  =>  CONCAT('a', 'b', 'c')
      #
      # @param sql [String]
      # @return [String]
      def concat_pipes_to_func(sql)
        return sql unless sql.include?("||")

        parts = sql.split("||")
        if parts.length > 1
          "CONCAT(#{parts.map(&:strip).join(', ')})"
        else
          sql
        end
      end

      # Convert TRUE/FALSE to 1/0 for engines without boolean type.
      #
      # @param sql [String]
      # @return [String]
      def boolean_to_int(sql)
        sql.gsub(/\bTRUE\b/i, "1").gsub(/\bFALSE\b/i, "0")
      end

      # Convert ILIKE to LOWER() LIKE LOWER() for engines without ILIKE.
      #
      # @param sql [String]
      # @return [String]
      def ilike_to_like(sql)
        sql.gsub(/(\S+)\s+ILIKE\s+(\S+)/i) do
          col = ::Regexp.last_match(1).strip
          val = ::Regexp.last_match(2).strip
          "LOWER(#{col}) LIKE LOWER(#{val})"
        end
      end

      # Translate AUTOINCREMENT across engines in DDL.
      #
      # @param sql [String]
      # @param engine [String] one of: mysql, postgresql, mssql, firebird, sqlite
      # @return [String]
      def auto_increment_syntax(sql, engine)
        case engine
        when "mysql"
          sql.gsub("AUTOINCREMENT", "AUTO_INCREMENT")
        when "postgresql"
          sql.gsub(/INTEGER\s+PRIMARY\s+KEY\s+AUTOINCREMENT/i, "SERIAL PRIMARY KEY")
        when "mssql"
          sql.gsub(/AUTOINCREMENT/i, "IDENTITY(1,1)")
        when "firebird"
          sql.gsub(/\s*AUTOINCREMENT\b/i, "")
        else
          sql
        end
      end

      # Convert ? placeholders to engine-specific style.
      #
      # ?  =>  %s       (MySQL, PostgreSQL)
      # ?  =>  :1, :2   (Oracle, Firebird)
      #
      # @param sql [String]
      # @param style [String] target placeholder style: "%s" or ":"
      # @return [String]
      def placeholder_style(sql, style)
        case style
        when "%s"
          sql.gsub("?", "%s")
        when ":"
          count = 0
          sql.chars.map do |ch|
            if ch == "?"
              count += 1
              ":#{count}"
            else
              ch
            end
          end.join
        else
          sql
        end
      end

      # Generate a cache key for a query and its parameters.
      #
      # @param sql [String]
      # @param params [Array, nil]
      # @return [String]
      def query_key(sql, params = nil)
        raw = params ? "#{sql}|#{params.inspect}" : sql
        "query:#{Digest::SHA256.hexdigest(raw)}"
      end
    end
  end

  # In-memory cache with TTL support for query results.
  #
  # Usage:
  #   cache = Tina4::QueryCache.new(default_ttl: 60, max_size: 1000)
  #   cache.set("key", "value", ttl: 30)
  #   cache.get("key")  # => "value"
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
  end
end
