# frozen_string_literal: true

require "socket"
require "tina4"

# Memcached session backend - against a REAL memcached server.
#
# Memcached was one of the seven CACHE backends in all four frameworks but was
# not a session backend in any of them, even though it is the classic PHP
# session store. This is the parity feature that closes that gap.
#
# NO MOCKS. Every assertion drives a live memcached over TCP. If the server is
# not reachable the group skips, unless TINA4_REQUIRE_SERVICES is set - then a
# missing service is a FAILURE, because a suite that silently skips its only
# real verification is not verification.
RSpec.describe Tina4::SessionHandlers::MemcachedHandler do
  # Locals, not constants: a constant here leaks into every other spec file.
  host = ENV["TINA4_TEST_MEMCACHED_HOST"] || "127.0.0.1"
  port = (ENV["TINA4_TEST_MEMCACHED_PORT"] || 11_211).to_i

  reachable = begin
    Socket.tcp(host, port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end

  if !reachable && ENV["TINA4_REQUIRE_SERVICES"]
    raise "TINA4_REQUIRE_SERVICES is set but memcached is not reachable at #{host}:#{port}"
  end

  before do
    skip("memcached not reachable at #{host}:#{port}") unless reachable
  end

  let(:session) do
    { "_created" => 1, "_accessed" => 2, "user_id" => 7,
      "nested" => { "a" => [1, 2, 3], "flag" => true } }
  end

  let(:handler) do
    described_class.new(host: host, port: port, prefix: "tina4:test:session:")
  end

  it "returns the same session it wrote" do
    handler.write("sid-basic", session, 60)
    expect(handler.read("sid-basic")).to eq(session)
    handler.destroy("sid-basic")
  end

  it "returns an empty hash for a miss rather than an error" do
    # A miss and a failure must be different outcomes. Collapsing them is how a
    # dead cache silently logs every user out instead of surfacing an outage.
    expect(handler.read("sid-definitely-not-present")).to eq({})
  end

  it "removes the session on destroy" do
    handler.write("sid-destroy", session, 60)
    expect(handler.read("sid-destroy")).not_to eq({})
    handler.destroy("sid-destroy")
    expect(handler.read("sid-destroy")).to eq({})
  end

  it "treats destroying an absent session as a no-op" do
    # Idempotent destroy - logging out twice must not raise.
    expect { handler.destroy("sid-never-existed") }.not_to raise_error
  end

  it "overwrites a previous value on write" do
    handler.write("sid-over", { "v" => 1 }, 60)
    handler.write("sid-over", { "v" => 2 }, 60)
    expect(handler.read("sid-over")).to eq({ "v" => 2 })
    handler.destroy("sid-over")
  end

  it "lets the TTL actually expire the session" do
    # Expiry is memcached's own, which is why cleanup is a no-op here.
    handler.write("sid-ttl", session, 1)
    expect(handler.read("sid-ttl")).not_to eq({})
    sleep 3
    expect(handler.read("sid-ttl")).to eq({})
  end

  it "hashes an over-long session id rather than truncating it" do
    # Memcached rejects keys over 250 bytes. Truncating would let two different
    # sessions collide on one key - one user reading another's session.
    a = "x" * 400
    b = ("x" * 399) + "y"
    handler.write(a, { "who" => "a" }, 60)
    handler.write(b, { "who" => "b" }, 60)
    expect(handler.read(a)).to eq({ "who" => "a" })
    expect(handler.read(b)).to eq({ "who" => "b" })
    handler.destroy(a)
    handler.destroy(b)
  end

  it "handles a session id containing a space" do
    # A space is illegal in a memcached key and would be a protocol error.
    sid = "has a space"
    handler.write(sid, { "ok" => true }, 60)
    expect(handler.read(sid)).to eq({ "ok" => true })
    handler.destroy(sid)
  end

  it "raises rather than reading empty when the server is unreachable" do
    # The whole point of the miss/failure split: an unreachable backend must
    # RAISE so the Session layer logs loud and degrades. Returning {} would be
    # indistinguishable from "no session yet", silently logging every user out
    # during an outage.
    dead = described_class.new(host: "127.0.0.1", port: 59_999, timeout: 1)
    expect { dead.read("sid-any") }.to raise_error(/Memcached session backend/)
    expect { dead.write("sid-any", { "a" => 1 }, 60) }.to raise_error(/Memcached session backend/)
  end

  it "treats cleanup as a no-op because memcached expires its own keys" do
    expect { handler.cleanup }.not_to raise_error
  end

  it "is selectable as a session backend by name" do
    # A handler nothing can select is not a backend.
    %w[memcached memcache].each do |spelling|
      s = Tina4::Session.new({}, handler: spelling,
                                 handler_options: { host: host, port: port })
      expect(s.send(:create_handler)).to be_a(described_class)
    end
  end
end
