# frozen_string_literal: true

# Shared harness for the graceful-shutdown specs (feature 9).
#
# Both the development path (spec/graceful_shutdown_spec.rb, WEBrick) and the
# production path (spec/puma_shutdown_spec.rb, Puma) need the same thing: a REAL
# server in its own process group, a REAL signal, and the REAL exit status -
# with the child's stdout/stderr on a FILE, because an inherited fd wedges a
# piped rspec run forever, and with the whole process GROUP killed afterwards.

require "socket"
require "net/http"
require "timeout"
require "tmpdir"
require "fileutils"

module ShutdownProbe
  module_function

  def worktree_lib
    File.expand_path("../../lib", __dir__)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Base child environment. The throwaway project has no Gemfile, so a child
  # still honouring the parent's Bundler env fails to boot; nil deletes a key.
  def base_env(overrides = {})
    {
      "TINA4_DEBUG" => "false",
      "TINA4_NO_AI_PORT" => "true",
      "TINA4_LOG_LEVEL" => "[TINA4_LOG_INFO]",
      "TINA4_DEBUG_LEVEL" => nil,
      "TINA4_NO_BROWSER" => "true",
      "TINA4_SHUTDOWN_TIMEOUT" => nil,
      "TINA4_DEFAULT_WEBSERVER" => nil,
      "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil,
      "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8"
    }.merge(overrides)
  end

  # Ruby that fails LOUD if the child resolved an INSTALLED tina4ruby gem
  # instead of this working tree. Several stale versions are on the box, they
  # boot and serve happily, and a path slip therefore turns a whole spec into a
  # green test of RELEASED code - which has already happened here once.
  def load_guard(lib = worktree_lib)
    <<~RUBY
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"
      loaded_from = $LOADED_FEATURES.find { |feature| feature.end_with?("/tina4.rb") }
      unless loaded_from.to_s.start_with?(#{lib.inspect})
        abort("loaded the WRONG tina4: \#{loaded_from} (expected #{lib})")
      end
    RUBY
  end

  # A real spawned server. Owns its process group and its temp project.
  class Server
    attr_reader :pid, :port, :dir, :log_path

    def initialize(pid, port, dir, log_path)
      @pid = pid
      @port = port
      @dir = dir
      @log_path = log_path
      @status = nil
    end

    # Read as binary and force UTF-8: the child's log lands with the default
    # external encoding (US-ASCII once the Bundler env is stripped), and
    # interpolating that into a UTF-8 failure message raises
    # Encoding::CompatibilityError instead of showing the diagnostic.
    def log
      return "(no log)" unless File.exist?(@log_path)

      File.read(@log_path, mode: "rb").force_encoding(Encoding::UTF_8).scrub
    end

    def signal(name)
      Process.kill(name, @pid)
    end

    # Non-blocking exit check. Reaps and caches the Process::Status so the exit
    # code is still readable after the child is gone.
    def exited?
      return true unless @status.nil?

      _pid, status = Process.waitpid2(@pid, Process::WNOHANG)
      @status = status
      !@status.nil?
    rescue Errno::ECHILD
      true
    end

    def wait_for_exit(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until exited? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.02
      end
      @status
    end

    def wait_until_serving!(path = "/ping", timeout: 40)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return self if get(path)&.first == 200
        raise "server exited during boot\n--- server log ---\n#{log}" if exited?

        sleep 0.1
      end
      raise "server never served #{path} on port #{@port}\n--- server log ---\n#{log}"
    end

    def wait_for_file!(name, timeout: 15)
      path = File.join(@dir, name)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.02
      end
      return if File.exist?(path)

      raise "#{name} never appeared\n--- server log ---\n#{log}"
    end

    # Block until the slow handler has actually ENTERED its wall-clock loop.
    # Removes the sleep-and-hope timing that makes signal tests flaky.
    def wait_until_handling!(timeout: 15)
      wait_for_file!("slow_started", timeout: timeout)
    end

    def read_file(name)
      path = File.join(@dir, name)
      File.exist?(path) ? File.read(path) : nil
    end

    def get(path, timeout: 5)
      Net::HTTP.start("127.0.0.1", @port, open_timeout: timeout, read_timeout: timeout) do |http|
        response = http.get(path)
        [response.code.to_i, response.body]
      end
    rescue StandardError
      nil
    end

    # Issue a request on its own thread; the thread's value is the outcome.
    def start_request(path, read_timeout: 30)
      Thread.new do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: read_timeout) do |http|
            response = http.get(path)
            { status: response.code.to_i, body: response.body.to_s,
              seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
          end
        rescue StandardError => e
          { status: nil, error: "#{e.class}: #{e.message}",
            seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
        end
      end
    end

    # Attempt a brand new TCP connection and classify what the OS/server did.
    # :refused is the contract - the listening socket is closed, so connect()
    # fails outright rather than the request being accepted and answered.
    def probe_connection(timeout: 3)
      socket = Socket.tcp("127.0.0.1", @port, connect_timeout: timeout)
      socket.write("GET /ping HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nConnection: close\r\n\r\n")
      raw = +""
      begin
        Timeout.timeout(timeout) { loop { raw << socket.readpartial(4096) } }
      rescue EOFError, Timeout::Error, Errno::ECONNRESET, Errno::EPIPE, IOError
        # whatever we got is the answer
      end
      socket.close
      raw.empty? ? { outcome: :accepted_no_response, raw: "" } : { outcome: :accepted, raw: raw }
    rescue Errno::ECONNREFUSED
      { outcome: :refused, raw: "" }
    rescue StandardError => e
      { outcome: :error, raw: "#{e.class}: #{e.message}" }
    end

    def port_free?
      server = TCPServer.new("127.0.0.1", @port)
      server.close
      true
    rescue Errno::EADDRINUSE
      false
    end

    # Kill the whole process GROUP, reap, and remove the temp project.
    # Unconditional: never gated on the handle looking alive, so a child that
    # spawned its own children cannot outlive the example.
    def destroy!
      Process.kill("KILL", -@pid)
    rescue Errno::ESRCH, Errno::EPERM
      # already gone
    ensure
      wait_for_exit(5)
      begin
        Process.waitpid(@pid)
      rescue Errno::ECHILD, Errno::ESRCH
        # already reaped
      end
      FileUtils.remove_entry(@dir, true)
    end
  end
end
