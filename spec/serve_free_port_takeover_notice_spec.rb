# frozen_string_literal: true

# `tina4ruby serve` must only say a port is in use when something holds it.
#
# PortTakeover.take_over_port refused outside dev mode, and when takeover was
# opted out, before it looked for a holder. So with debug off (or --no-kill)
# every start printed "Port N is in use ..." on a port nothing held, and a
# production operator was told a free port was taken. Parity with tina4-php#362.
#
# No mocks: real sockets, and the real CLI in a child process on its own port.
# The held-port cases are the controls: the notice must still appear when the
# port really is taken.
require "spec_helper"
require "tina4/port_takeover"
require "socket"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "tina4ruby serve says nothing about a free port" do
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # A live listener without SO_REUSEADDR, so a later bind fails on every OS.
  def hold_port
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    socket.bind(Addrinfo.tcp("127.0.0.1", 0))
    socket.listen(5)
    [socket, socket.local_address.ip_port]
  end

  def windows?
    RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)
  end

  def spawn_serve(port, overrides, *flags)
    dir = Dir.mktmpdir("tina4_serve_free_port")
    @dirs << dir
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    log = File.join(dir, "serve.log")
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_", "BUNDLE", "RUBYOPT") }.merge(
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_BROWSER" => "true",
      "TINA4_SECRET" => "serve-free-port-secret-0123456789abcdef",
      "TINA4_DEFAULT_WEBSERVER" => "true", "TINA4_NO_AI_PORT" => "true"
    ).merge(overrides)
    exe = File.expand_path("../exe/tina4ruby", __dir__)
    lib = File.expand_path("../lib", __dir__)
    options = { chdir: dir, out: log, err: [:child, :out], unsetenv_others: true }
    options[:pgroup] = true unless windows?
    pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", *flags, "-p", port.to_s,
                        "-h", "127.0.0.1", "--no-browser", "--no-reload", **options)
    @pids << pid
    [pid, log]
  end

  def read(log)
    File.exist?(log) ? File.read(log, mode: "rb").force_encoding(Encoding::UTF_8).scrub : ""
  end

  def exited?(pid)
    !Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    true
  end

  def wait_for(pid, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if yield
      return false if exited?(pid)

      sleep 0.1
    end
    false
  end

  # Boot serve on a free port, wait for its own Server banner, return its output.
  def output_once_serving(overrides, *flags)
    port = free_port
    pid, log = spawn_serve(port, overrides, *flags)
    own_server = %r{Server:\s+http://\S*:#{port}\b}
    up = wait_for(pid) { read(log).match?(own_server) }
    raise "serve never came up on free port #{port}:\n#{read(log)}" unless up

    read(log)
  end

  before do
    @pids = []
    @dirs = []
    @held = []
  end

  after do
    @pids.each do |pid|
      if windows?
        system("taskkill", "/T", "/F", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
      else
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          # already gone
        end
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        # already reaped
      end
    end
    @held.each(&:close)
    @dirs.each { |dir| FileUtils.remove_entry(dir, true) }
  end

  describe "the shared helper" do
    it "does not refuse a free port outside dev mode" do
      result = Tina4::PortTakeover.take_over_port(free_port, dev: false, no_takeover: false, host: "127.0.0.1")
      expect(result.status).to eq(Tina4::PortTakeover::NOTHING)
      expect(result.message).to eq("")
    end

    it "does not refuse a free port when opted out" do
      result = Tina4::PortTakeover.take_over_port(free_port, dev: true, no_takeover: true, host: "127.0.0.1")
      expect(result.status).to eq(Tina4::PortTakeover::NOTHING)
      expect(result.message).to eq("")
    end

    it "still refuses a held port outside dev mode" do
      socket, port = hold_port
      @held << socket
      result = Tina4::PortTakeover.take_over_port(port, dev: false, no_takeover: false, host: "127.0.0.1")
      expect(result.status).to eq(Tina4::PortTakeover::REFUSED_PROD)
      expect(result.message).to include("Port #{port} is in use")
    end
  end

  describe "the real CLI" do
    it "says nothing about a free port with debug off" do
      expect(output_once_serving({ "TINA4_DEBUG" => "false" })).not_to include("is in use")
    end

    it "says nothing about a free port with --no-kill" do
      expect(output_once_serving({ "TINA4_DEBUG" => "true" }, "--no-kill")).not_to include("is in use")
    end

    it "still refuses a held port with debug off" do
      socket, port = hold_port
      @held << socket
      pid, log = spawn_serve(port, { "TINA4_DEBUG" => "false" })
      notice = "Port #{port} is in use; takeover is disabled outside dev mode"
      wait_for(pid) { read(log).include?(notice) }
      expect(read(log)).to include(notice)
    end
  end
end
