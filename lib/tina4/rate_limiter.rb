# frozen_string_literal: true

module Tina4
  class RateLimiter
    DEFAULT_LIMIT = 100
    DEFAULT_WINDOW = 60 # seconds

    attr_reader :limit, :window

    def initialize(limit: nil, window: nil)
      @limit = (limit || ENV["TINA4_RATE_LIMIT"] || DEFAULT_LIMIT).to_i
      @window = (window || ENV["TINA4_RATE_WINDOW"] || DEFAULT_WINDOW).to_i
      @store = {}    # ip => [timestamps]
      @mutex = Mutex.new
      @last_cleanup = Time.now
    end

    # Check if the given IP is rate limited.
    # Returns a hash with rate limit info:
    #   { allowed: true/false, limit:, remaining:, reset:, retry_after: }
    def check(ip)
      now = Time.now
      cleanup_if_needed(now)

      @mutex.synchronize do
        @store[ip] ||= []
        entries = @store[ip]

        # Remove expired entries (sliding window)
        cutoff = now - @window
        entries.reject! { |t| t < cutoff }

        if entries.length >= @limit
          # Rate limited
          oldest = entries.first
          reset_at = (oldest + @window).to_i
          retry_after = [(oldest + @window - now).ceil, 1].max

          {
            allowed: false,
            limit: @limit,
            remaining: 0,
            reset: reset_at,
            retry_after: retry_after
          }
        else
          entries << now

          {
            allowed: true,
            limit: @limit,
            remaining: @limit - entries.length,
            reset: (now + @window).to_i,
            retry_after: nil
          }
        end
      end
    end

    # Convenience predicate
    def rate_limited?(ip)
      !check(ip)[:allowed]
    end

    # Apply rate limit headers to a response object and return 429 if exceeded.
    # Returns [status, headers_hash] or nil if allowed.
    def apply(ip, response)
      result = check(ip)

      # Always set rate limit headers
      response.headers["X-RateLimit-Limit"] = result[:limit].to_s
      response.headers["X-RateLimit-Remaining"] = result[:remaining].to_s
      response.headers["X-RateLimit-Reset"] = result[:reset].to_s

      unless result[:allowed]
        response.headers["Retry-After"] = result[:retry_after].to_s
        response.status_code = 429
        response.headers["content-type"] = "application/json; charset=utf-8"
        response.body = JSON.generate({
          error: "Too Many Requests",
          retry_after: result[:retry_after]
        })
        return false
      end

      true
    end

    # Reset tracking for a specific IP (useful for testing)
    def reset!(ip = nil)
      @mutex.synchronize do
        if ip
          @store.delete(ip)
        else
          @store.clear
        end
      end
    end

    # Returns current entry count (for monitoring)
    def entry_count
      @mutex.synchronize { @store.length }
    end

    private

    # Clean up expired entries periodically (every window interval)
    def cleanup_if_needed(now)
      return if now - @last_cleanup < @window

      @mutex.synchronize do
        return if now - @last_cleanup < @window

        cutoff = now - @window
        @store.delete_if do |_ip, entries|
          entries.reject! { |t| t < cutoff }
          entries.empty?
        end
        @last_cleanup = now
      end
    end
  end
end
