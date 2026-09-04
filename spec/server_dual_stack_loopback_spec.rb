# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"

# The dev server must be reachable on BOTH loopback families.
#
# Windows resolves `localhost` to ::1 (IPv6) first, so a server bound only to
# 127.0.0.1 -- or to 0.0.0.0, the IPv4 wildcard, which does NOT cover IPv6 --
# refused the browser with ERR_CONNECTION_REFUSED even though it was serving.
# Binding both loopback families closes that gap. Mirrors the tina4-php
# ServerDualStackLoopbackTest.
#
# These are real sockets: the server binds through its own start() and a real
# TCP client connects on each family. No subprocess is spawned, so it runs on
# Windows too (where the bug lives) as well as on Linux CI.
RSpec.describe "Tina4::WebServer dual-stack loopback" do
  let(:app) { Tina4::RackApp.new }

  # ---- helpers -------------------------------------------------------------

  # Grab an OS-assigned ephemeral port, then release it so the server under
  # test can bind it. Same helper shape as server_parity_spec.rb.
  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  # Boot the real WebServer bound to 127.0.0.1 in a background thread, blocking
  # until the primary listener actually accepts a TCP connection. start()
  # refuses to boot unless the CLI runs it or TINA4_OVERRIDE_CLIENT=true, and we
  # leave the AI port off. Returns the [server, thread] pair.
  def boot_server(port)
    srv = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)
    prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
    prev_no_ai = ENV["TINA4_NO_AI_PORT"]
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"
    thread = Thread.new { srv.start }
    thread.abort_on_exception = false

    deadline = Time.now + 10
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        break
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "server never came up on port #{port}" if Time.now > deadline

        sleep 0.05
      end
    end

    [srv, thread]
  ensure
    if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
    if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
  end

  # True when a real TCP client can connect to host:port.
  def accepts?(host, port)
    Timeout.timeout(5) do
      TCPSocket.new(host, port).close
      true
    end
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT, SocketError, Timeout::Error
    false
  end

  # True when this host can bind IPv6 loopback at all.
  def ipv6_loopback_available?
    server = TCPServer.new("::1", 0)
    server.close
    true
  rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT, SocketError
    false
  end

  # ---- the mapping (pure function, no dependency) --------------------------

  describe ".loopback_bind_hosts" do
    it "names the IPv6 sibling for an IPv4-loopback host" do
      expect(Tina4::WebServer.loopback_bind_hosts("127.0.0.1")).to eq(["::1"])
    end

    it "names the IPv6 sibling for the IPv4 wildcard (0.0.0.0 misses ::1)" do
      expect(Tina4::WebServer.loopback_bind_hosts("0.0.0.0")).to eq(["::1"])
    end

    it "names the IPv4 sibling for an IPv6-loopback host" do
      expect(Tina4::WebServer.loopback_bind_hosts("::1")).to eq(["127.0.0.1"])
    end

    it "names the IPv4 sibling for the IPv6 wildcard (::)" do
      expect(Tina4::WebServer.loopback_bind_hosts("::")).to eq(["127.0.0.1"])
    end

    it "binds both families explicitly for localhost (resolves per-OS)" do
      expect(Tina4::WebServer.loopback_bind_hosts("localhost")).to eq(["127.0.0.1", "::1"])
    end

    it "adds no sibling for an explicit LAN address" do
      expect(Tina4::WebServer.loopback_bind_hosts("192.168.1.10")).to eq([])
    end

    it "normalises case, surrounding whitespace and IPv6 brackets" do
      expect(Tina4::WebServer.loopback_bind_hosts("  LOCALHOST ")).to eq(["127.0.0.1", "::1"])
      expect(Tina4::WebServer.loopback_bind_hosts("[::1]")).to eq(["127.0.0.1"])
    end
  end

  # ---- the real dual-stack behaviour (real sockets) ------------------------

  describe "a server bound to 127.0.0.1" do
    it "ALSO answers on ::1 -- the Windows `localhost` browser depends on it" do
      skip "IPv6 loopback (::1) is unavailable here" unless ipv6_loopback_available?

      port = free_port
      srv, thread = boot_server(port)

      begin
        expect(accepts?("127.0.0.1", port)).to be(true), "the primary IPv4 loopback listener must accept"
        expect(accepts?("::1", port)).to be(true), "IPv6 loopback must ALSO accept after the dual-stack fix"
      ensure
        srv.stop
        thread.join(5)
      end
    end
  end
end
