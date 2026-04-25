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
      def stop_all(timeout: 2.0)
        snapshot = mutex.synchronize { tasks.dup }
        snapshot.each { |task| stop_task(task, timeout: timeout) }
        mutex.synchronize { tasks.clear }
      end

      # Stop a single task. Used by tests that register, fire, then stop.
      def stop_task(task, timeout: 2.0)
        task[:running] = false
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
