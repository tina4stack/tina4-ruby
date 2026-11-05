# frozen_string_literal: true

# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Raw TCP service contract — feature 142, ADR-0102 (Ruby port of the Python
# reference tests). Every case runs a REAL client socket against a REAL
# in-process listener — no mocks, no doubles. The pure cases drive the service's
# own acceptor + reader threads (Ruby's thread-per-connection model IS the D1
# in-process mechanism); two cases spawn a REAL framework child server so the
# listener folds into the genuine boot and shutdown path.
#
# Each example names, in a comment, the mutation that must turn it red.

require "spec_helper"
require "socket"
require_relative "support/shutdown_probe"

RSpec.describe "Raw TCP service contract (feature 142)" do
  let(:services) { [] }

  after do
    services.each { |svc| svc.stop(timeout: 2.0) rescue nil }
    Tina4::Tcp.clear_registry
    @child&.destroy! rescue nil
  end

  # ── Real-socket helpers (no doubles) ───────────────────────────────────────

  def start_service(**opts, &block)
    svc = Tina4::TcpService.new(0, **opts, &block)
    svc.start("127.0.0.1")
    services << svc
    svc
  end

  def connect(port)
    TCPSocket.new("127.0.0.1", port)
  end

  def wait_until(timeout: 2.0)
    deadline = now + timeout
    sleep(0.01) until yield || now >= deadline
    yield
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Read exactly n bytes from a client socket, or "" on timeout.
  def read_exactly(sock, n, timeout: 2.0)
    buf = +"".b
    deadline = now + timeout
    while buf.bytesize < n && now < deadline
      ready = IO.select([sock], nil, nil, 0.05)
      next if ready.nil?

      chunk = sock.read_nonblock(n - buf.bytesize, exception: false)
      break if chunk.nil? # EOF
      next if chunk == :wait_readable

      buf << chunk
    end
    buf
  end

  # True when the client socket has hit EOF (peer closed).
  def client_eof?(sock, timeout: 2.0)
    deadline = now + timeout
    while now < deadline
      ready = IO.select([sock], nil, nil, 0.05)
      next if ready.nil?

      chunk = sock.read_nonblock(1, exception: false)
      return true if chunk.nil?
      next if chunk == :wait_readable
    end
    false
  end

  # A service whose on_data identifies by a 'LOGIN:<id>' frame.
  def login_service
    start_service(on_data: lambda do |conn, data|
      conn.identify(data[6..]) if data.start_with?("LOGIN:")
    end)
  end

  # ── tcp-callbacks-raw-and-line ─────────────────────────────────────────────

  it "on_data delivers raw bytes, not newline-split" do
    # Mutation: split on_data on newlines and the joined bytes differ.
    received = []
    lock = Mutex.new
    svc = start_service(on_data: ->(_c, d) { lock.synchronize { received << d } })
    sock = connect(svc.bound_port)
    sock.write("a\nb\nc")
    wait_until { lock.synchronize { received.join } == "a\nb\nc" }
    joined = lock.synchronize { received.join }
    expect(joined).to eq("a\nb\nc")
    expect(joined).to include("\n")
    sock.close
  end

  it "on_line splits a newline-delimited stream, terminator stripped, tail buffered" do
    # Mutation: stop chomping \r, or deliver the tail early.
    lines = []
    lock = Mutex.new
    svc = start_service(on_line: ->(_c, l) { lock.synchronize { lines << l } })
    sock = connect(svc.bound_port)
    sock.write("a\r\nb\nc")
    wait_until { lock.synchronize { lines.dup } == %w[a b] }
    expect(lock.synchronize { lines.dup }).to eq(%w[a b])
    sock.write("\n")
    wait_until { lock.synchronize { lines.dup } == %w[a b c] }
    expect(lock.synchronize { lines.dup }).to eq(%w[a b c])
    sock.close
  end

  it "on_close fires exactly once when the peer closes" do
    # Mutation: fire on_close twice, or never, or skip removal.
    closes = []
    lock = Mutex.new
    svc = start_service(on_close: ->(_c) { lock.synchronize { closes << 1 } })
    sock = connect(svc.bound_port)
    wait_until { svc.count == 1 }
    expect(svc.count).to eq(1)
    sock.close
    wait_until { lock.synchronize { closes.size } == 1 && svc.count.zero? }
    expect(lock.synchronize { closes.size }).to eq(1)
    expect(svc.count).to eq(0)
  end

  # ── tcp-binary-roundtrip-ack ───────────────────────────────────────────────

  it "a binary frame round-trips and is ACKed on the same socket" do
    # Mutation: have send mangle/reorder bytes and the read fails.
    ack = "\x78\x78\x05\x01".b
    svc = start_service(on_data: ->(c, _d) { c.send(ack) })
    sock = connect(svc.bound_port)
    sock.write("\x78\x78\x11\x0A\xFF\x00".b)
    expect(read_exactly(sock, ack.bytesize)).to eq(ack)
    sock.close
  end

  # ── tcp-identify-registry-push ─────────────────────────────────────────────

  it "identify registers and send_to reaches that socket" do
    # Mutation: make register_id a no-op and send_to never arrives.
    svc = login_service
    sock = connect(svc.bound_port)
    sock.write("LOGIN:imeiA")
    expect(wait_until { !svc.connection("imeiA").nil? }).to be_truthy
    expect(svc.send_to("imeiA", "CMD1")).to be(true)
    expect(read_exactly(sock, 4)).to eq("CMD1")
    sock.close
  end

  it "send_to is isolated to the addressed device" do
    # Mutation: broadcast instead of addressing one, and B wrongly receives.
    svc = login_service
    a = connect(svc.bound_port)
    b = connect(svc.bound_port)
    a.write("LOGIN:imeiA")
    b.write("LOGIN:imeiB")
    wait_until { svc.connection("imeiA") && svc.connection("imeiB") }
    svc.send_to("imeiA", "ONLYA")
    expect(read_exactly(a, 5)).to eq("ONLYA")
    expect(read_exactly(b, 1, timeout: 0.4)).to eq("")
    a.close
    b.close
  end

  it "send_to to an unknown id is a no-op, not a raise" do
    # Mutation: raise on a missing id and this errors instead of passing.
    svc = login_service
    expect(svc.send_to("ghost", "CMD")).to be(false)
  end

  it "broadcast reaches every live connection" do
    # Mutation: iterate a subset and a client misses the message.
    svc = login_service
    socks = %w[imei1 imei2 imei3].map do |id|
      s = connect(svc.bound_port)
      s.write("LOGIN:#{id}")
      s
    end
    wait_until { svc.count == 3 }
    expect(svc.broadcast("PING!")).to eq(3)
    socks.each { |s| expect(read_exactly(s, 5)).to eq("PING!"); s.close }
  end

  it "re-identify with the same id supersedes the first" do
    # Mutation: keep the first registered and send_to reaches the stale socket.
    svc = login_service
    s1 = connect(svc.bound_port)
    s1.write("LOGIN:imeiA")
    wait_until { !svc.connection("imeiA").nil? }
    first = svc.connection("imeiA")
    s2 = connect(svc.bound_port)
    s2.write("LOGIN:imeiA")
    wait_until { !svc.connection("imeiA").equal?(first) }
    svc.send_to("imeiA", "TO2!!")
    expect(read_exactly(s2, 5)).to eq("TO2!!")
    expect(read_exactly(s1, 1, timeout: 0.4)).to eq("")
    s1.close
    s2.close
  end

  # ── tcp-connection-object ──────────────────────────────────────────────────

  it "remote_addr is the raw socket peer, never a forwarded header" do
    # Mutation: return a header value and the loopback assert fails.
    seen = []
    lock = Mutex.new
    svc = start_service(on_connect: ->(c) { lock.synchronize { seen << c.remote_addr } })
    sock = connect(svc.bound_port)
    wait_until { lock.synchronize { !seen.empty? } }
    expect(lock.synchronize { seen.first }).to include("127.0.0.1")
    sock.close
  end

  it "context persists across on_data calls for one connection" do
    # Mutation: rebuild context per call and the accumulated buffer is lost.
    svc = start_service(on_data: ->(c, d) { c.context[:buf] = (c.context[:buf] || +"") + d })
    s1 = connect(svc.bound_port)
    s1.write("AA")
    sleep(0.05)
    s1.write("BB")
    expect(wait_until { any_ctx_buf?(svc, "AABB") }).to be_truthy
    s2 = connect(svc.bound_port)
    s2.write("ZZ")
    wait_until { any_ctx_buf?(svc, "ZZ") }
    expect(any_ctx_buf?(svc, "AABB")).to be(true)
    expect(any_ctx_buf?(svc, "ZZ")).to be(true)
    s1.close
    s2.close
  end

  it "close ends the connection, fires on_close, removes the registry entry" do
    # Mutation: skip removal in close and count stays 1.
    closed = []
    lock = Mutex.new
    svc = login_service
    svc.on_close { |c| lock.synchronize { closed << c.id } }
    sock = connect(svc.bound_port)
    sock.write("LOGIN:imeiZ")
    wait_until { !svc.connection("imeiZ").nil? }
    conn = svc.connection("imeiZ")
    conn.close
    expect(client_eof?(sock)).to be(true)
    wait_until { lock.synchronize { closed.dup } == ["imeiZ"] && svc.count.zero? }
    expect(lock.synchronize { closed.dup }).to eq(["imeiZ"])
    expect(svc.connection("imeiZ")).to be_nil
    sock.close rescue nil
  end

  # ── tcp-max-connections-refusal ────────────────────────────────────────────

  it "the (N+1)th connection is refused with max_connections=2" do
    # Mutation: drop the limit check and count hits 3.
    svc = start_service(max_connections: 2)
    a = connect(svc.bound_port)
    b = connect(svc.bound_port)
    wait_until { svc.count == 2 }
    c = connect(svc.bound_port)
    expect(client_eof?(c)).to be(true)
    sleep(0.1)
    expect(svc.count).to eq(2)
    [a, b, c].each { |s| s.close rescue nil }
  end

  # ── tcp-idle-reaper-default-off ────────────────────────────────────────────

  it "idle_timeout=0 keeps a silent connection open" do
    # Mutation: reap when timeout==0 and the silent connection is closed.
    svc = start_service(idle_timeout: 0)
    sock = connect(svc.bound_port)
    wait_until { svc.count == 1 }
    sleep(0.6)
    expect(svc.count).to eq(1)
    sock.close
  end

  it "idle_timeout>0 reaps only the silent connection" do
    # Mutation: reap on activity too and the active one dies.
    closes = []
    lock = Mutex.new
    svc = start_service(idle_timeout: 0.3, on_close: ->(_c) { lock.synchronize { closes << 1 } })
    silent = connect(svc.bound_port)
    active = connect(svc.bound_port)
    wait_until { svc.count == 2 }
    deadline = now + 0.8
    while now < deadline
      active.write("x")
      sleep(0.08)
    end
    expect(wait_until(timeout: 1.5) { lock.synchronize { closes.size } == 1 }).to be_truthy
    expect(svc.count).to eq(1)
    silent.close rescue nil
    active.close
  end

  # ── tcp-backpressure ───────────────────────────────────────────────────────

  it "a stalled reader is bounded and dropped, others keep serving" do
    # Mutation: remove the backlog check in send and the loop never returns false.
    conns = Queue.new
    svc = start_service(
      max_backlog: 65_536,
      on_connect: ->(c) { conns << c },
      on_data: ->(c, d) { c.send(d) }
    )
    stalled = connect(svc.bound_port) # connects and NEVER reads
    server_conn = conns.pop
    dropped = false
    400.times do
      unless server_conn.send("x" * 16_384)
        dropped = true
        break
      end
    end
    expect(dropped).to be(true)
    expect(server_conn.closed?).to be(true)

    ok = connect(svc.bound_port)
    ok.write("ping")
    expect(read_exactly(ok, 4)).to eq("ping")
    stalled.close rescue nil
    ok.close
  end

  # ── tcp-single-owner-bind ──────────────────────────────────────────────────

  it "only one owner binds the TCP port" do
    # Mutation: let the second bind succeed / raise and this fails.
    port = ShutdownProbe.free_port
    owner = Tina4::TcpService.new(port, name: "owner")
    second = Tina4::TcpService.new(port, name: "owner")
    services << owner << second
    expect(owner.start("127.0.0.1")).to be(true)
    expect(owner.owner?).to be(true)
    expect(second.start("127.0.0.1")).to be(false)
    expect(second.owner?).to be(false)
    sock = connect(port)
    expect(wait_until { owner.count == 1 }).to be_truthy
    sock.close
  end

  # ── the public Tcp facade + registry accessor ──────────────────────────────

  it "Tcp.service registers a named service reachable via Tcp.get; unknown raises" do
    svc = Tina4::Tcp.service(0, name: "trackers")
    services << svc
    expect(Tina4::Tcp.get("trackers")).to equal(svc)
    expect { Tina4::Tcp.get("nope") }.to raise_error(KeyError)
  end

  it "stop drains live connections (client sees EOF) and fires on_close" do
    # Mutation: make drain skip closing connections and the client never sees EOF.
    closes = []
    lock = Mutex.new
    svc = start_service(on_close: ->(_c) { lock.synchronize { closes << 1 } })
    sock = connect(svc.bound_port)
    wait_until { svc.count == 1 }
    svc.stop(timeout: 3.0)
    expect(client_eof?(sock)).to be(true)
    expect(lock.synchronize { closes.size }).to eq(1)
    sock.close rescue nil
  end

  # ── child-server cases (REAL spawned framework server) ──────────────────────

  def boot_child(extra_env = {})
    dir = SpecTmpdir.create("tina4-tcp")
    http_port = ShutdownProbe.free_port
    tcp_port = http_port + 1
    lib = ShutdownProbe.worktree_lib
    app_path = File.join(dir, "app.rb")
    File.write(app_path, <<~RUBY)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"
      Tina4.initialize!(#{dir.inspect})
      Tina4.get "/ping" do |request, response|
        response.json({ ok: true })
      end
      Tina4::Tcp.service(#{tcp_port}, name: "trackers",
        on_connect: ->(c) { c.send("HELLO\\n") },
        on_data: ->(c, d) { c.send("ECHO:" + d) })
      app = Tina4::RackApp.new(root_dir: #{dir.inspect})
      Tina4::WebServer.new(app, host: "127.0.0.1", port: #{http_port}).start
    RUBY
    env = ShutdownProbe.base_env(
      "TINA4_OVERRIDE_CLIENT" => "true",
      "PROBE_PORT" => http_port.to_s, "TINA4_NO_AI_PORT" => "true"
    ).merge(extra_env)
    log_path = File.join(dir, "server.log")
    pid = spawn(env, RbConfig.ruby, app_path, chdir: dir, out: log_path, err: log_path, pgroup: true)
    server = ShutdownProbe::Server.new(pid, http_port, dir, log_path)
    server.wait_until_serving!("/ping", timeout: 40)
    @child = server
    [server, http_port, tcp_port]
  end

  it "listens and accepts in-process while HTTP still serves" do
    # Mutation: don't start TCP services in WebServer#start and the greeting never arrives.
    server, http_port, tcp_port = boot_child

    # Wait for the TCP port to open too.
    expect(wait_until(timeout: 10) do
      TCPSocket.new("127.0.0.1", tcp_port).close
      true
    rescue Errno::ECONNREFUSED
      false
    end).to be_truthy

    tcp = connect(tcp_port)
    expect(read_exactly(tcp, 6, timeout: 5)).to eq("HELLO\n") # on_connect fired in-process

    code, = server.get("/ping") # HTTP still serves concurrently
    expect(code).to eq(200)
    tcp.close
  end

  it "SIGTERM drains the live TCP connection and exits 0" do
    skip "[needs:runtime=posix-signals] SIGTERM unavailable" unless Signal.list.key?("TERM")
    server, _http_port, tcp_port = boot_child("TINA4_SHUTDOWN_TIMEOUT" => "10")

    expect(wait_until(timeout: 10) do
      TCPSocket.new("127.0.0.1", tcp_port).close
      true
    rescue Errno::ECONNREFUSED
      false
    end).to be_truthy

    tcp = connect(tcp_port)
    expect(read_exactly(tcp, 6, timeout: 5)).to eq("HELLO\n")

    server.signal("TERM")
    # The live TCP connection is closed cleanly (EOF) within the drain.
    expect(client_eof?(tcp, timeout: 12)).to be(true)
    tcp.close rescue nil
    status = server.wait_for_exit(12) # graceful shutdown exits 0
    expect(status&.exitstatus).to eq(0)
  end

  # ── helper ──────────────────────────────────────────────────────────────────

  def any_ctx_buf?(svc, want)
    conns = svc.instance_variable_get(:@connections)
    mutex = svc.instance_variable_get(:@mutex)
    mutex.synchronize { conns.values.any? { |c| c.context[:buf] == want } }
  end
end
