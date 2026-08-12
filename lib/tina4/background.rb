# frozen_string_literal: true

module Tina4
  # Periodic background task registry.
  #
  # Matches Python's `tina4_python.core.server.background(fn, interval)` and
  # PHP's `$app->background($callback, $interval)` — a callback that runs
  # periodically alongside the server lifecycle.
  #
  # Ruby has no asyncio event loop, so each task runs in its own dedicated OS
  # thread, started at registration time. Because the thread runs regardless of
  # which web server (Puma/WEBrick) is in front, a Ruby background task is never
  # a silent no-op under production — the thread IS the runtime (contrast the
  # Python ASGI / PHP-FPM silent-no-op the other frameworks had to fix). The GIL
  # keeps it cooperative-enough for the periodic work this is meant for (queue
  # draining, health checks, simulators). Errors in the callback are caught and
  # logged so they don't kill the thread.
  module Background
    # Handle for one registered background task — the ONE background surface,
    # identical across the four frameworks: a handle with a boolean `stop` plus a
    # count. Mirrors Python's `BackgroundTask` (`handle.stop()`), PHP's
    # `Tina4\BackgroundTask` (`$handle->stop()`) and Node's `background()` handle
    # (`handle.stop()`).
    #
    # It also answers `[:callback]`/`[:interval]`/`[:thread]`/`[:running]` (read
    # AND write) so a descriptor and a handle are the same object — code that
    # introspected the old Hash descriptor keeps working unchanged.
    class Task
      attr_accessor :callback, :interval, :thread, :running

      def initialize(callback, interval)
        @callback = callback
        @interval = interval
        @thread = nil
        @running = false
      end

      # Stop this task and DEREGISTER it. Idempotent — a second call is a safe
      # no-op that returns false.
      #
      # @param timeout [Float] Seconds to wait for an in-flight run before killing.
      # @return [Boolean] true if this call removed the task, false if already gone.
      def stop(timeout: 2.0)
        Background.stop_task(self, timeout: timeout)
      end

      # @return [Boolean] true once stop has run (the task is no longer running).
      def stopped?
        !@running
      end

      # @return [Boolean] true while the task is registered and ticking.
      def running?
        @running
      end

      # Hash-style read, so `task[:thread]` / `task[:running]` still work.
      def [](key)
        case key
        when :callback then @callback
        when :interval then @interval
        when :thread then @thread
        when :running then @running
        end
      end

      # Hash-style write, so the scheduler's `task[:thread] = ...` still works.
      def []=(key, value)
        case key
        when :callback then @callback = value
        when :interval then @interval = value
        when :thread then @thread = value
        when :running then @running = value
        end
      end
    end

    class << self
      # Register a periodic callback.
      #
      # @param callback [#call, nil] Object responding to `call` with no args.
      # @param interval [Float] Seconds between invocations (default 1.0).
      # @param block    [Proc]   Optional block (used if callback is nil).
      # @return [Task] The registered task handle — call `.stop` to end it.
      def register(callback = nil, interval: 1.0, &block)
        cb = callback || block
        raise ArgumentError, "background requires a callback or block" if cb.nil?
        raise ArgumentError, "callback must respond to :call" unless cb.respond_to?(:call)

        task = Task.new(cb, interval.to_f)
        mutex.synchronize { tasks << task }
        start_task(task)
        task
      end

      # All registered task handles. Tests use this for introspection.
      def tasks
        @tasks ||= []
      end

      # Number of REGISTERED background tasks (stopped ones are already gone).
      # The count half of the ONE shared surface, matching Python's
      # `background_task_count()`, PHP's `backgroundTaskCount()` and Node's
      # `backgroundTaskCount()`.
      #
      # @return [Integer]
      def count
        mutex.synchronize { tasks.length }
      end

      # Stop and join every running task. Called on graceful shutdown.
      #
      # Each stop_task deregisters its own handle, so there is no blanket
      # `tasks.clear` here: clearing would ALSO drop a task registered while
      # this loop was running — leaving its thread alive but invisible in the
      # registry, which is the worse of the two failure modes.
      def stop_all(timeout: 2.0)
        snapshot = mutex.synchronize { tasks.dup }
        snapshot.each { |task| stop_task(task, timeout: timeout) }
      end

      # Stop a single task and DEREGISTER it. Used by `Task#stop`, by graceful
      # shutdown, and by any subsystem that owns a task for part of its life
      # (e.g. Mqtt::Client#stop_keepalive).
      #
      # The handle is removed from `tasks` so the registry never reports a stopped
      # task as registered — leaving it in place made `tasks` grow for the life of
      # the process on every start/stop cycle and made introspection lie about
      # what is actually running.
      #
      # Idempotent: a second call on the same handle removes nothing, finds no
      # thread and returns false.
      #
      # @return [Boolean] true if this call removed a registered task, else false.
      def stop_task(task, timeout: 2.0)
        task.running = false
        # Identity, not equality: `tasks.delete(task)` uses `==`, which would take
        # out any OTHER handle that happens to compare equal. Only this exact one
        # goes, and we record whether it WAS registered so stop() is a truthful bool.
        was_registered = mutex.synchronize do
          present = tasks.any? { |registered| registered.equal?(task) }
          tasks.delete_if { |registered| registered.equal?(task) }
          present
        end

        thread = task.thread
        if thread
          thread.join(timeout) || thread.kill
          task.thread = nil
        end

        was_registered
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end

      def start_task(task)
        task.running = true
        task.thread = Thread.new do
          while task.running
            sleep task.interval
            break unless task.running

            begin
              task.callback.call
            rescue => e
              # Never let a callback error kill the thread — next interval still fires.
              if defined?(Tina4::Log) && Tina4::Log.respond_to?(:error)
                Tina4::Log.error("background task error: #{e.class}: #{e.message}")
              end
            end
          end
        end
      end
    end
  end
end
