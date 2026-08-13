# frozen_string_literal: true

module Tina4
  # Identity-checked port takeover, shared by the CLI and the runtime paths.
  #
  # `tina4 serve` reclaims a busy port so the edit-restart loop does not fail
  # with "address already in use". The convenience has a sharp edge: "whatever is
  # listening" is not always the old Tina4 server, and before this module BOTH
  # takeover paths (the CLI #kill_process_on_port and the runtime bind-failure
  # WebServer#free_port) SIGTERM'd whatever held the port, with NO check that the
  # victim was a Tina4 dev server -- a foreign holder (another dev server, a
  # database, a stray listener) was killed.
  #
  # This is the ONE takeover implementation both paths call (TAKEOVER-DEC-02), so
  # the runtime path can never again be a weaker twin of the CLI path. It adds:
  #
  #  - Identity (TAKEOVER-DEC-01): a Tina4 dev server writes a per-port PID file
  #    (`data/.tina4-serve-<port>.pid`) when it binds and removes it on clean
  #    exit. Takeover only signals a holder whose PID matches that file; a holder
  #    with no matching Tina4 PID file is REFUSED, never killed.
  #  - Dev gate + opt-out (TAKEOVER-DEC-03): takeover runs only in dev
  #    (`TINA4_DEBUG` truthy) and only when not opted out (`TINA4_NO_TAKEOVER` /
  #    `tina4 serve --no-kill`). A production bind never kills a port holder.
  #  - The existing PID safety filter and container guard, unchanged, on top.
  #
  # Refusing is always safe (the developer frees the port by hand); over-killing
  # was the bug this fixes.
  module PortTakeover
    NOTHING = "nothing"
    KILLED = "killed"
    REFUSED_FOREIGN = "refused_foreign"
    REFUSED_OPTOUT = "refused_optout"
    REFUSED_PROD = "refused_prod"
    SKIPPED_CONTAINER = "skipped_container"
    REFUSALS = [REFUSED_FOREIGN, REFUSED_OPTOUT, REFUSED_PROD].freeze

    # What a takeover attempt did, so each caller can react in its own idiom.
    Result = Struct.new(:status, :port, :killed, :message) do
      def reclaimed?
        status == KILLED
      end

      def refused?
        REFUSALS.include?(status)
      end
    end

    module_function

    def truthy?(value)
      %w[true 1 yes on].include?(value.to_s.strip.downcase)
    end

    # Dev mode = TINA4_DEBUG truthy. Takeover runs only in dev.
    def dev?
      truthy?(ENV["TINA4_DEBUG"])
    end

    # True when takeover is disabled via TINA4_NO_TAKEOVER.
    def no_takeover_opted_out?
      truthy?(ENV["TINA4_NO_TAKEOVER"])
    end

    # True when this process is running inside a container. Reclaiming a port
    # makes sense on a dev machine; inside a container the server IS the
    # container, so there is no stale sibling to reclaim from.
    def in_container?
      return true if File.exist?("/.dockerenv") || File.exist?("/run/.containerenv")

      blob = File.read("/proc/1/cgroup")
      blob.include?("docker") || blob.include?("containerd") || blob.include?("kubepods")
    rescue SystemCallError
      false
    end

    # The PIDs from `lsof -ti` output that are safe to signal.
    #
    # Pure so the safety rule can be tested directly. A non-numeric field becomes
    # 0 under `to_i`, and signalling PID 0 hits EVERY process in the caller's own
    # process group -- the server kills itself. Accept only all-digit tokens;
    # never PID 0 (our group), PID 1 (init), ourselves, or our own process group.
    # This is the PID-SAFETY gate only; whether a survivor is a Tina4 server is
    # the SEPARATE identity check in #take_over_port.
    def selectable_pids(lsof_output, me, my_group = nil)
      pids = []
      lsof_output.split(/\s+/).each do |token|
        next unless token.match?(/\A\d+\z/) # never coerce junk into a PID

        pid = token.to_i
        next if pid <= 1 || pid == me # 0 = our group, 1 = init, me = suicide
        next if !my_group.nil? && pid == my_group

        pids << pid unless pids.include?(pid)
      end
      pids
    end

    def runtime_dir(base_dir = nil)
      base_dir || File.join(Dir.pwd, "data")
    end

    def pidfile_path(port, base_dir = nil)
      File.join(runtime_dir(base_dir), ".tina4-serve-#{port}.pid")
    end

    # Record THIS process as the Tina4 dev server on *port* (best-effort).
    def write_pidfile(port, base_dir = nil, pid = nil)
      dir = runtime_dir(base_dir)
      require "fileutils"
      FileUtils.mkdir_p(dir)
      File.write(pidfile_path(port, base_dir), (pid || Process.pid).to_s)
    rescue SystemCallError
      nil # identity is a convenience; never let it break the server
    end

    # The PID a Tina4 dev server recorded for *port*, or nil if none/garbage.
    def read_pidfile(port, base_dir = nil)
      token = File.read(pidfile_path(port, base_dir)).strip
      token.match?(/\A\d+\z/) ? token.to_i : nil
    rescue SystemCallError
      nil
    end

    # Drop the PID file for *port* (clean shutdown, or after reclaiming it).
    def remove_pidfile(port, base_dir = nil)
      File.delete(pidfile_path(port, base_dir))
    rescue SystemCallError
      nil
    end

    # Raw lsof/netstat PID tokens for whatever holds *port*.
    def port_holders(port)
      if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        tokens = []
        `netstat -ano 2>&1`.each_line do |line|
          next unless line.include?(":#{port}") &&
                      (line.include?("LISTENING") || line.include?("ESTABLISHED"))

          candidate = line.strip.split(/\s+/).last
          tokens << candidate if candidate&.match?(/\A\d+\z/)
        end
        tokens
      else
        `lsof -ti :#{port} 2>/dev/null`.split
      end
    rescue StandardError
      []
    end

    # Reclaim *port* ONLY from an identity-confirmed Tina4 dev server. The single
    # guarded path for both the CLI (`tina4 serve`) and the runtime bind-failure
    # fallback. `dev`/`no_takeover` are passed in so this stays pure and directly
    # testable; callers resolve them from #dev? / #no_takeover_opted_out?.
    def take_over_port(port, dev:, no_takeover:, base_dir: nil, grace: 0.5)
      if no_takeover
        return Result.new(REFUSED_OPTOUT, port, [],
                          "Port #{port} is in use and takeover is disabled " \
                          "(TINA4_NO_TAKEOVER/--no-kill) -- free it or choose another port.")
      end
      unless dev
        return Result.new(REFUSED_PROD, port, [],
                          "Port #{port} is in use; takeover is disabled outside dev mode " \
                          "-- free it or choose another port.")
      end
      return Result.new(SKIPPED_CONTAINER, port, [], "") if in_container?

      tokens = port_holders(port)
      return Result.new(NOTHING, port, [], "") if tokens.empty?

      me = Process.pid
      my_group = begin
        Process.getpgrp
      rescue StandardError
        nil
      end
      holders = selectable_pids(tokens.join(" "), me, my_group)
      return Result.new(NOTHING, port, [], "") if holders.empty?

      recorded = read_pidfile(port, base_dir)
      tina4_holders = recorded.nil? ? [] : holders.select { |pid| pid == recorded }
      if tina4_holders.empty?
        return Result.new(REFUSED_FOREIGN, port, [],
                          "Port #{port} is held by a non-Tina4 process " \
                          "-- free it or choose another port.")
      end

      killed = []
      tina4_holders.each do |pid|
        Process.kill("TERM", pid)
        killed << pid
      rescue Errno::ESRCH, Errno::EPERM
        # already gone or no permission
      end
      return Result.new(NOTHING, port, [], "") if killed.empty?

      remove_pidfile(port, base_dir)
      sleep(grace) if grace.positive?
      Result.new(KILLED, port, killed,
                 "Reclaimed port #{port} from Tina4 dev server (PID: #{killed.join(', ')}).")
    end
  end
end
