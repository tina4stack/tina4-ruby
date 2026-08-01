# frozen_string_literal: true

# Feature 11 (rate limiter) - the client key must not be attacker-controlled.
#
# ADR-0019. X-Forwarded-For is written by whoever sends it, so reading it
# unconditionally let any client pick its own rate-limit bucket, and let it
# pick SOMEONE ELSE'S. Case names match tina4-python/tests/test_trusted_proxy.py,
# tina4-php/tests/TrustedProxyTest.php and tina4-nodejs/test/trustedProxy.test.ts.
#
# These drive a REAL Tina4::Request built from a REAL Rack env, and a REAL
# Tina4::RateLimiter. No doubles.

require "spec_helper"

RSpec.describe "Trusted proxy" do
  # The peer the fixture env presents, so "is the peer trusted?" is controlled
  # by listing (or not listing) this address.
  TEST_PEER = "127.0.0.1"

  def rack_env(peer: TEST_PEER, headers: {})
    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/trusted-proxy-probe",
      "QUERY_STRING" => "",
      "REMOTE_ADDR" => peer,
      "rack.input" => StringIO.new("")
    }
    headers.each { |k, v| env[k] = v }
    env
  end

  def client_ip(peer: TEST_PEER, headers: {})
    Tina4::Request.new(rack_env(peer: peer, headers: headers)).ip
  end

  around do |example|
    previous = ENV["TINA4_TRUSTED_PROXIES"]
    ENV.delete("TINA4_TRUSTED_PROXIES")
    example.run
    if previous.nil?
      ENV.delete("TINA4_TRUSTED_PROXIES")
    else
      ENV["TINA4_TRUSTED_PROXIES"] = previous
    end
  end

  describe "rate limit client key" do
    let(:limiter) { Tina4::RateLimiter.new(limit: 3, window: 60) }

    def statuses(&forwarded_for)
      (0...6).map do |i|
        ip = client_ip(headers: { "HTTP_X_FORWARDED_FOR" => forwarded_for.call(i) })
        response = Tina4::Response.new
        limiter.apply(ip, response)
        response.status_code
      end
    end

    it "rate limit ignores forwarded for from an untrusted peer" do
      # No TINA4_TRUSTED_PROXIES: the header is noise, the peer is the client.
      # A rotating X-Forwarded-For must NOT buy extra requests.
      result = statuses { |i| "203.0.113.#{i}" }
      expect(result).to eq([200, 200, 200, 429, 429, 429]),
        "rotating X-Forwarded-For bypassed the rate limiter - the client chose " \
        "its own bucket. Got #{result.inspect}"
    end

    it "rate limit honours forwarded for from a trusted proxy" do
      # The positive twin: once the peer IS a declared proxy, per-client
      # bucketing must still work, or the fix would just break real deployments.
      ENV["TINA4_TRUSTED_PROXIES"] = TEST_PEER
      result = statuses { |i| "203.0.113.#{i}" }
      expect(result).to eq([200] * 6),
        "behind a declared trusted proxy, distinct clients must get distinct " \
        "buckets. Got #{result.inspect}"
    end

    it "rate limit forged forwarded for cannot starve another client" do
      victim = "198.51.100.7"
      5.times { client_ip(headers: { "HTTP_X_FORWARDED_FOR" => victim }) }
      expect(Tina4.trusted_proxy?(victim)).to be(false),
        "the victim address must not be trusted for this test to mean anything"
      # The attacker's forged traffic lands in the PEER's bucket, never the
      # victim's, because the header is not consulted at all.
      expect(client_ip(headers: { "HTTP_X_FORWARDED_FOR" => victim })).to eq(TEST_PEER)
    end
  end

  describe "trusted proxy matching" do
    it "trusted proxy matches an exact address" do
      ENV["TINA4_TRUSTED_PROXIES"] = "192.168.1.5"
      expect(Tina4.trusted_proxy?("192.168.1.5")).to be(true)
      expect(Tina4.trusted_proxy?("192.168.1.6")).to be(false)
    end

    it "trusted proxy matches a cidr range" do
      ENV["TINA4_TRUSTED_PROXIES"] = "10.0.0.0/8"
      expect(Tina4.trusted_proxy?("10.4.5.6")).to be(true)
      expect(Tina4.trusted_proxy?("11.4.5.6")).to be(false)
    end

    it "trusted proxy matches an ipv6 address and range" do
      ENV["TINA4_TRUSTED_PROXIES"] = "::1, fd00::/8"
      expect(Tina4.trusted_proxy?("::1")).to be(true)
      expect(Tina4.trusted_proxy?("fd12:3456::9")).to be(true)
      expect(Tina4.trusted_proxy?("2001:db8::1")).to be(false)
    end

    it "trusted proxy matches an ipv4 mapped ipv6 peer" do
      # Dual-stack listeners hand out ::ffff:10.0.0.1 routinely. If that did
      # not match 10.0.0.0/8 the operator's allow-list would silently miss.
      ENV["TINA4_TRUSTED_PROXIES"] = "10.0.0.0/8"
      expect(Tina4.trusted_proxy?("::ffff:10.0.0.1")).to be(true)
    end

    it "trusted proxy is empty by default" do
      expect(Tina4.trusted_proxy_networks).to eq([])
      expect(Tina4.trusted_proxy?("10.0.0.1")).to be(false)
    end

    it "trusted proxy ignores a malformed entry" do
      # A typo must not take the whole allow-list down with it.
      ENV["TINA4_TRUSTED_PROXIES"] = "10.0.0.0/8, not-an-ip, ::1"
      expect(Tina4.trusted_proxy?("10.1.2.3")).to be(true)
      expect(Tina4.trusted_proxy?("::1")).to be(true)
      expect(Tina4.trusted_proxy?("192.168.0.1")).to be(false)
    end
  end

  describe "forwarded for chain" do
    it "client ip takes the rightmost untrusted hop" do
      # A client can PREPEND to X-Forwarded-For; the proxy appends. So the
      # leftmost entry is attacker-controlled even behind a real proxy.
      ENV["TINA4_TRUSTED_PROXIES"] = TEST_PEER
      expect(client_ip(headers: { "HTTP_X_FORWARDED_FOR" => "1.2.3.4, 5.6.7.8" }))
        .to eq("5.6.7.8")
    end

    it "client ip skips hops that are themselves trusted proxies" do
      ENV["TINA4_TRUSTED_PROXIES"] = "#{TEST_PEER}, 5.6.7.8"
      expect(client_ip(headers: { "HTTP_X_FORWARDED_FOR" => "1.2.3.4, 5.6.7.8" }))
        .to eq("1.2.3.4")
    end

    it "client ip is the peer when the peer is not trusted" do
      expect(client_ip(peer: "198.51.100.1",
                       headers: { "HTTP_X_FORWARDED_FOR" => "1.2.3.4" }))
        .to eq("198.51.100.1")
    end

    it "client ip falls back to x real ip behind a trusted proxy" do
      ENV["TINA4_TRUSTED_PROXIES"] = TEST_PEER
      expect(client_ip(headers: { "HTTP_X_REAL_IP" => "9.9.9.9" })).to eq("9.9.9.9")
    end

    it "client ip ignores x real ip from an untrusted peer" do
      expect(client_ip(peer: "198.51.100.1",
                       headers: { "HTTP_X_REAL_IP" => "9.9.9.9" }))
        .to eq("198.51.100.1")
    end
  end
end
