# frozen_string_literal: true

# `tina4ruby serve` decides debug from the operator, never from a default
# (ADR-0079 s3). Debug decides whether /__dev is mounted, so each case boots the
# real CLI server in a child process on its own port and asks it for /__dev:
# 404 means debug is off.
#
#   - --production turns debug off (the explicit flag beats .env, ADR-0041); it
#     used to only choose Puma and leave TINA4_DEBUG=true from .env on.
#   - a missing .env no longer writes TINA4_DEBUG="true" (and an API key) as a
#     side effect of booting.
#
# Case names match the auth_token_contract.json "debug-is-explicit" invariant.
# No mocks: a real process, a real socket, real .env files.
require "spec_helper"
require "net/http"
require "socket"
require "rbconfig"
require "timeout"

RSpec.describe "tina4ruby serve debug is explicit (ADR-0079)" do
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def dev_status(env_file, *flags)
    dir = Dir.mktmpdir("tina4_serve")
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, ".env"), env_file) if env_file
    port = free_port
    exe = File.expand_path("../exe/tina4ruby", __dir__)
    lib = File.expand_path("../lib", __dir__)
    env = ENV.to_h.reject { |k, _| k.start_with?("TINA4_") }.merge(
      "TINA4_NO_BROWSER" => "true", "TINA4_SECRET" => "cli-serve-debug-secret-0123456789abcdef",
      "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true", "TINA4_DEFAULT_WEBSERVER" => "true"
    )
    log = File.join(dir, "serve.log")
    pid = Process.spawn(env, RbConfig.ruby, "-I", lib, exe, "serve", "-p", port.to_s, "-h", "127.0.0.1",
                        "--no-browser", *flags, chdir: dir, out: log, err: log, pgroup: true)
    begin
      deadline = Time.now + 30
      while Time.now < deadline
        raise "serve exited early: #{File.read(log)}" if Process.waitpid(pid, Process::WNOHANG)

        begin
          return Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/__dev")).code.to_i
        rescue SystemCallError, IOError, Net::ReadTimeout
          sleep 0.2
        end
      end
      raise "serve never answered: #{File.read(log)}"
    ensure
      begin
        Process.kill("TERM", -pid)
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      rescue Timeout::Error
        Process.kill("KILL", -pid)
        Process.wait(pid)
      end
      FileUtils.rm_rf(dir)
    end
  end

  it "serve honours debug false from env file" do
    expect(dev_status("TINA4_DEBUG=false\n")).to eq(404)
  end

  it "serve honours debug true from env file" do
    # Control: proves the /__dev probe can tell debug-on from debug-off.
    expect(dev_status("TINA4_DEBUG=true\n")).not_to eq(404)
  end

  it "production flag turns debug off" do
    expect(dev_status("TINA4_DEBUG=true\n", "--production")).to eq(404)
  end

  it "a missing env file does not enable debug" do
    expect(dev_status(nil)).to eq(404)
  end
end
