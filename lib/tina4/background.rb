# frozen_string_literal: true

module Tina4
  # Periodic background task registry.
  #
  # Matches Python's `tina4_python.core.server.background(fn, interval)` and
  # PHP's `$app->background($callback, $interval)` — a callback that runs
  # periodically alongside the server lifecycle.
  #
  # Ruby has no asyncio event loop, so each task runs in its own thread.
  # The GIL keeps it cooperative-enough for the periodic work this is meant
  # for (queue draining, health checks, simulators). Errors in the callback
  # are caught and logged so they don't kill the thread.
  module Background
    class << self
      # Register a periodic callback.
      #
      # @param callback [#call, nil] Object responding to `call` with no args.
      # @param interval [Float] Seconds between invocations (default 1.0).
      # @param block    [Proc]   Optional block (used if callback is nil).
      # @return [Hash] The registered task descriptor.
      def register(callback = nil, interval: 1.0, &block)
        cb = callback || block
        raise ArgumentError, "background requires a callback or block" if cb.nil?
        raise ArgumentError, "callback must respond to :call" unless cb.respond_to?(:call)

        task = { callback: cb, interval: interval.to_f, thread: nil, running: false }
        mutex.synchronize { tasks << task }
        start_task(task)
        task
      end

      # All registered task descriptors. Tests use this for introspection.
      def tasks
        @tasks ||= []
      end

      # Stop and join every running task. Called on graceful shutdown.
      #
      # Each stop_task deregisters its own descriptor, so there is no blanket
      # `tasks.clear` here: clearing would ALSO drop a task registered while
      # this loop was running — leaving its thread alive but invisible in the
      # registry, which is the worse of the two failure modes.
      def stop_all(timeout: 2.0)
        snapshot = mutex.synchronize { tasks.dup }
        snapshot.each { |task| stop_task(task, timeout: timeout) }
      end

      # Stop a single task and DEREGISTER it. Used by tests that register, fire,
      # then stop, and by any subsystem that owns a task for part of its life
      # (e.g. Mqtt::Client#stop_keepalive).
      #
      # The descriptor is removed from `tasks` so the registry never reports a
      # stopped task as registered — leaving it in place made `tasks` grow for
      # the life of the process on every start/stop cycle and made introspection
      # lie about what is actually running.
      #
      # Idempotent: a second call on the same descriptor removes nothing, finds
      # no thread and returns safely.
      def stop_task(task, timeout: 2.0)
        task[:running] = false
        # Identity, not equality: `tasks.delete(task)` uses `==`, which would
        # take out any OTHER descriptor that happens to hold an equal Hash
        # (same callback, same interval). Only this exact descriptor goes.
        mutex.synchronize { tasks.delete_if { |registered| registered.equal?(task) } }

        thread = task[:thread]
        return unless thread

        thread.join(timeout) || thread.kill
        task[:thread] = nil
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end

      def start_task(task)
        task[:running] = true
        task[:thread] = Thread.new do
          while task[:running]
            sleep task[:interval]
            break unless task[:running]

            begin
              task[:callback].call
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
