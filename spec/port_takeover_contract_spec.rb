# frozen_string_literal: true

# Real-process conformance for identity-checked port takeover (feature 129).
#
# `tina4 serve` reclaims a busy port so a restart does not fail with "address
# already in use". Before TAKEOVER-DEC-01/02/03 both takeover paths SIGTERM'd
# WHATEVER held the port -- a foreign dev server, a database, a stray listener --
# with no check that the victim was a Tina4 dev server. This suite pins the fix.
#
# NO MOCKS. Every case starts a REAL child Ruby process that binds a REAL port and
# asserts the outcome BY PID: a foreign holder must still be running afterwards; a
# Tina4 holder must be gone. The Tina4 holder records its identity through the REAL
# framework Tina4::PortTakeover.write_pidfile (the same call the dev server makes).
#
# Mutation proof: in Tina4::PortTakeover.take_over_port replace the identity
# filter with `tina4_holders = holders`, and the two foreign-spare examples go RED
# (the foreign child is SIGTERM'd). Restore it and they pass.
#
# Parity: Python tests/test_port_takeover_contract.py, PHP
# tests/PortTakeoverContractTest.php, Node test/portTakeoverContract.test.ts.

require "spec_helper"
require "tina4/port_takeover"
require "tina4/webserver"
require "socket"
require "tmpdir"
require "fileutils"

RSpec.describe "identity-checked port takeover" do
  let(:lib_dir) { File.expand_path("../lib", __dir__) }

  before(:each) do
    # POSIX lsof/SIGTERM takeover; the lab + dev are POSIX. A per-example skip
    # (never hit there) counts rather than DROPS the examples on Windows.
    skip "POSIX-only takeover mechanism" if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
    @base_dir = Dir.mktmpdir("tina4-takeover")
    @spawned = []
  end

  after(:each) do
    # Reap EVERYTHING this suite spawned -- leave nothing on the lab.
    @spawned.each do |pid|
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EPERM
        # already gone
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        # already reaped
      end
    end
    FileUtils.remove_entry(@base_dir) if @base_dir && Dir.exist?(@base_dir)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Start a real child that binds *port*; a Tina4 child also writes its PID file.
  def spawn_holder(port, tina4:)
    script = File.join(@base_dir, "child-#{port}.rb")
    write_line = tina4 ? "Tina4::PortTakeover.write_pidfile(port, base)" : ""
    File.write(script, <<~RUBY)
      require "socket"
      require "tina4/port_takeover"
      port = ARGV[0].to_i
      base = ARGV[1]
      server = TCPServer.new("127.0.0.1", port)
      #{write_line}
      $stdout.puts("READY"); $stdout.flush
      sleep 60
    RUBY

    pid = spawn(RbConfig.ruby, "-I", lib_dir, script, port.to_s, @base_dir,
                out: File::NULL, err: File::NULL)
    @spawned << pid

    pidfile = Tina4::PortTakeover.pidfile_path(port, @base_dir)
    deadline = Time.now + 10.0
    while Time.now < deadline
      raise "child exited early" unless child_alive?(pid)
      return pid if listening?(port) && (!tina4 || File.exist?(pidfile))

      sleep 0.05
    end
    raise "child never bound port #{port}"
  end

  # poll() semantics: waitpid reaps a SIGTERM'd child so it is not mistaken for
  # alive (Process.kill(0, pid) would report a zombie as alive).
  def child_alive?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    false
  end

  def wait_exit(pid, timeout: 3.0)
    deadline = Time.now + timeout
    sleep 0.05 while child_alive?(pid) && Time.now < deadline
    !child_alive?(pid)
  end

  def listening?(port)
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue StandardError
    false
  end

  # ── the four conformance cases (all real processes, asserted by PID) ────────

  it "a foreign holder is not killed and takeover refuses" do
    port = free_port
    pid = spawn_holder(port, tina4: false)

    result = Tina4::PortTakeover.take_over_port(port, dev: true, no_takeover: false, base_dir: @base_dir)

    expect(result.status).to eq(Tina4::PortTakeover::REFUSED_FOREIGN)
    expect(result.message).to include("non-Tina4")
    expect(result.killed).to eq([])
    # The foreign process must STILL be running -- proven by PID, not a mock.
    expect(child_alive?(pid)).to be(true), "takeover killed a foreign (non-Tina4) process"
    expect(listening?(port)).to be(true)
  end

  it "a tina4 dev server holder is reclaimed" do
    port = free_port
    pid = spawn_holder(port, tina4: true)

    result = Tina4::PortTakeover.take_over_port(port, dev: true, no_takeover: false, base_dir: @base_dir)

    expect(result.status).to eq(Tina4::PortTakeover::KILLED)
    expect(result.killed).to eq([pid])
    expect(wait_exit(pid)).to be(true), "the Tina4 dev server was not reclaimed"
  end

  it "opt out refuses to kill the holder" do
    port = free_port
    pid = spawn_holder(port, tina4: true)

    result = Tina4::PortTakeover.take_over_port(port, dev: true, no_takeover: true, base_dir: @base_dir)

    expect(result.status).to eq(Tina4::PortTakeover::REFUSED_OPTOUT)
    expect(result.killed).to eq([])
    expect(child_alive?(pid)).to be(true), "opt-out still killed the holder"
  end

  it "production mode refuses to kill the holder" do
    port = free_port
    pid = spawn_holder(port, tina4: true)

    result = Tina4::PortTakeover.take_over_port(port, dev: false, no_takeover: false, base_dir: @base_dir)

    expect(result.status).to eq(Tina4::PortTakeover::REFUSED_PROD)
    expect(result.killed).to eq([])
    expect(child_alive?(pid)).to be(true), "production bind killed a port holder"
  end

  it "the runtime path also spares a foreign holder" do
    # The runtime bind-failure fallback (WebServer#free_port) runs the SAME
    # identity gate (DEC-02): a foreign holder makes it raise and stay alive.
    port = free_port
    pid = spawn_holder(port, tina4: false)

    old_debug = ENV["TINA4_DEBUG"]
    old_opt = ENV["TINA4_NO_TAKEOVER"]
    ENV["TINA4_DEBUG"] = "true"
    ENV.delete("TINA4_NO_TAKEOVER")
    begin
      server = Tina4::WebServer.new(nil, host: "127.0.0.1", port: port)
      expect { server.free_port(port) }.to raise_error(/non-Tina4/)
      expect(child_alive?(pid)).to be(true), "the runtime path killed a foreign process"
    ensure
      old_debug.nil? ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = old_debug
      old_opt.nil? ? ENV.delete("TINA4_NO_TAKEOVER") : ENV["TINA4_NO_TAKEOVER"] = old_opt
    end
  end
end
