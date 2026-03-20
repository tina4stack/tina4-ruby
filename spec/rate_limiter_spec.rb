# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::RateLimiter do
  let(:limiter) { Tina4::RateLimiter.new(limit: 5, window: 10) }

  after { limiter.reset! }

  describe "#check" do
    it "allows requests under the limit" do
      result = limiter.check("192.168.1.1")
      expect(result[:allowed]).to be true
      expect(result[:remaining]).to eq(4)
      expect(result[:limit]).to eq(5)
    end

    it "tracks requests per IP" do
      3.times { limiter.check("192.168.1.1") }
      result = limiter.check("192.168.1.1")
      expect(result[:remaining]).to eq(1)
    end

    it "blocks when limit is exceeded" do
      5.times { limiter.check("192.168.1.1") }
      result = limiter.check("192.168.1.1")
      expect(result[:allowed]).to be false
      expect(result[:remaining]).to eq(0)
      expect(result[:retry_after]).to be > 0
    end

    it "tracks IPs independently" do
      5.times { limiter.check("192.168.1.1") }
      result = limiter.check("192.168.1.2")
      expect(result[:allowed]).to be true
      expect(result[:remaining]).to eq(4)
    end

    it "includes reset timestamp" do
      result = limiter.check("192.168.1.1")
      expect(result[:reset]).to be_a(Integer)
      expect(result[:reset]).to be > Time.now.to_i
    end
  end

  describe "#rate_limited?" do
    it "returns false when under limit" do
      expect(limiter.rate_limited?("10.0.0.1")).to be false
    end

    it "returns true when over limit" do
      5.times { limiter.check("10.0.0.1") }
      expect(limiter.rate_limited?("10.0.0.1")).to be true
    end
  end

  describe "#apply" do
    it "adds rate limit headers and allows request" do
      response = Tina4::Response.new
      result = limiter.apply("10.0.0.1", response)

      expect(result).to be true
      expect(response.headers["X-RateLimit-Limit"]).to eq("5")
      expect(response.headers["X-RateLimit-Remaining"]).to eq("4")
      expect(response.headers["X-RateLimit-Reset"]).not_to be_nil
    end

    it "returns 429 when rate limited" do
      5.times { limiter.check("10.0.0.1") }

      response = Tina4::Response.new
      result = limiter.apply("10.0.0.1", response)

      expect(result).to be false
      expect(response.status).to eq(429)
      expect(response.headers["Retry-After"]).not_to be_nil

      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Too Many Requests")
    end
  end

  describe "#reset!" do
    it "resets tracking for a specific IP" do
      5.times { limiter.check("10.0.0.1") }
      limiter.reset!("10.0.0.1")

      result = limiter.check("10.0.0.1")
      expect(result[:allowed]).to be true
      expect(result[:remaining]).to eq(4)
    end

    it "resets all tracking when called without args" do
      3.times { limiter.check("10.0.0.1") }
      3.times { limiter.check("10.0.0.2") }
      limiter.reset!

      expect(limiter.entry_count).to eq(0)
    end
  end

  describe "#entry_count" do
    it "returns the number of tracked IPs" do
      limiter.check("10.0.0.1")
      limiter.check("10.0.0.2")
      expect(limiter.entry_count).to eq(2)
    end
  end

  describe "thread safety" do
    it "handles concurrent access without errors" do
      threads = 10.times.map do |i|
        Thread.new do
          20.times { limiter.check("10.0.0.#{i}") }
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe "env var configuration" do
    it "reads TINA4_RATE_LIMIT from env" do
      ENV["TINA4_RATE_LIMIT"] = "200"
      l = Tina4::RateLimiter.new
      expect(l.limit).to eq(200)
      ENV.delete("TINA4_RATE_LIMIT")
    end

    it "reads TINA4_RATE_WINDOW from env" do
      ENV["TINA4_RATE_WINDOW"] = "120"
      l = Tina4::RateLimiter.new
      expect(l.window).to eq(120)
      ENV.delete("TINA4_RATE_WINDOW")
    end

    it "uses defaults when env vars not set" do
      l = Tina4::RateLimiter.new
      expect(l.limit).to eq(100)
      expect(l.window).to eq(60)
    end
  end
end
