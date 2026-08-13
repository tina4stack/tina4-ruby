# frozen_string_literal: true

module Tina4
  # Graceful shutdown on SIGTERM / SIGINT.
  #
  # The order is the contract, identical in all four Tina4 frameworks:
  #
  #   1. Stop accepting FIRST. The listening socket closes before anything is
  #      drained, so a connection arriving after the signal gets a clean
  #      CONNECTION REFUSED - not a 503, not a TCP reset.
  #   2. Tell live WebSocket peers we are going away (RFC 6455 close code 1001).
  #   3. Drain in-flight requests, bounded by TINA4_SHUTDOWN_TIMEOUT.
  #   4. Stop background tasks, close database connections, exit 0.
  #
  # SIGHUP is deliberately NOT trapped: the Rust CLI owns file watching and
  # production logs go to stdout, so neither Puma's log-reopen nor gunicorn's
  # config-reload use for SIGHUP is a Tina4 need.
  module Shutdown
    # Matches Kubernetes' default terminationGracePeriodSeconds and Gunicorn's
    # graceful_timeout, and is the same default in Python, PHP and Node.
    DEFAULT_TIMEOUT = 30 # seconds

    class << self
      attr_reader :in_flight_count

      # The resolved TINA4_SHUTDOWN_TIMEOUT. Public because the production path
      # does not drain in Ruby at all - it maps this onto Puma's own
      # force_shutdown_after so the documented env var means the same thing
      # whichever server owns the socket.
      attr_reader :timeout

      # trap_signals: false when another server owns INT/TERM (Puma does). A
      # Tina4 trap on that path would be installed but never usefully serviced:
      # there is no listener to close and nothing calls track_request, so if the
      # other server's own trap install ever failed, ours would swallow the
      # default terminate and do nothing - the process would survive the signal.
      def setup(server: nil, timeout: nil, trap_signals: true)
        @server = server
        @timeout = resolve_timeout(timeout)
        @shutting_down = false
        @shutdown_complete = false
        @mutex = Mutex.new
        @in_flight_count = 0
        @in_flight_cv = ConditionVariable.new

        install_signal_handlers if trap_signals
      end

      def shutting_down?
        @shutting_down
      end

      def track_request
        @mutex.synchronize { @in_flight_count += 1 }
        begin
          yield
        ensure
          @mutex.synchronize do
            @in_flight_count -= 1
            @in_flight_cv.broadcast if @in_flight_count <= 0
          end
        end
      end

      def initiate_shutdown
        return if @shutting_down

        @shutting_down = true
        Tina4::Log.info("Shutdown signal received, stopping gracefully...")

        stop_accepting
        drained = wait_for_in_flight
        release_resources

        Tina4::Log.info("Shutdown complete")
        # Graceful shutdown owns the final call to reset() (Decision 24 /
        # LOG-I02): flush+close owned sinks AFTER the shutdown record above,
        # exactly once.
        Tina4::Log.reset
        @shutdown_complete = true
        return if drained

        # The deadline expired with requests still in flight. WEBrick's accept
        # loop joins its worker threads with NO timeout of its own, so simply
        # returning here would hang the process for as long as the slowest
        # handler runs - exactly what TINA4_SHUTDOWN_TIMEOUT exists to prevent.
        # Flush first: exit! runs no at_exit handlers and does not flush stdio,
        # which would swallow the warning that explains the forced exit.
        $stdout.flush
        $stderr.flush
        exit!(0)
      end

      # The teardown NO web server can do for us, because no web server knows
      # these things exist: live WebSocket peers owed an RFC 6455 close frame,
      # Tina4 background threads, and ORM-bound database connections.
      #
      # Public so the production path can run exactly the same teardown from an
      # ensure around Puma's launcher: Puma owns the socket, the drain and the
      # signals there, but a database connection it has never heard of would
      # otherwise leak on every single shutdown.
      def release_resources
        close_websockets
        stop_background_tasks
        close_database
      end

      # Block until initiate_shutdown has finished every teardown step.
      #
      # stop_accepting unblocks WEBrick's accept loop immediately, so its #start
      # returns as soon as the in-flight workers are joined - which can be while
      # the signal handler's thread is still stopping background tasks and
      # closing database connections. The server's main thread calls this so the
      # process does not exit out from under that teardown.
      def wait_for_completion(timeout = nil)
        return unless @shutting_down

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   (timeout || @timeout.to_f + 5)
        until @shutdown_complete || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.02
        end
      end

      private

      # TINA4_SHUTDOWN_TIMEOUT in seconds (same name and default in all four
      # frameworks). An unparseable or negative value warns and falls back to the
      # default: `"abc".to_i` is 0, and a silent 0-second drain would force-close
      # every in-flight request on the first signal. An explicit 0 is honoured -
      # that is a deliberate choice, not a silent one.
      def resolve_timeout(explicit)
        raw = explicit || ENV["TINA4_SHUTDOWN_TIMEOUT"]
        return DEFAULT_TIMEOUT if raw.nil? || raw.to_s.strip.empty?

        seconds = Float(raw)
        raise ArgumentError, "must not be negative" if seconds.negative?

        seconds
      rescue ArgumentError, TypeError
        Tina4::Log.warning(
          "TINA4_SHUTDOWN_TIMEOUT=#{raw.inspect} is not a non-negative number, using #{DEFAULT_TIMEOUT}s"
        )
        DEFAULT_TIMEOUT
      end

      # Close the listening socket BEFORE draining. WEBrick's #shutdown wakes its
      # accept loop and closes the listeners; it does not touch the worker
      # threads already running, which the loop's own ensure joins - so new
      # connections are refused while in-flight requests still run to completion
      # and write their full response. Measured on webrick 1.9.2 / Ruby 4.0.2:
      # #shutdown returns in ~0.1ms, a connection attempted 0.3s later is
      # ECONNREFUSED, and the 2s handler mid-flight still returns a full 200.
      def stop_accepting
        return unless @server.respond_to?(:shutdown)

        @server.shutdown
        Tina4::Log.info("Stopped accepting new connections")
      rescue StandardError => e
        Tina4::Log.error("Error closing the listening socket: #{e.message}")
      end

      # RFC 6455 close code 1001 "going away" is what a server sends when it is
      # shutting down, so clients reconnect elsewhere instead of treating the
      # drop as an error. Both live managers are covered: the process-wide route
      # engine (Tina4::WebSocket.current, published by RackApp) and the
      # dev-reload channel's own manager - the same pair DevAdmin#ws_managers
      # enumerates.
      def close_websockets
        closed = 0
        live_websocket_managers.each do |manager|
          manager.connections.values.each do |connection|
            connection.close(code: 1001, reason: "going away")
            closed += 1
          rescue StandardError => e
            Tina4::Log.warning("Error closing WebSocket #{connection.id}: #{e.message}")
          end
        end
        Tina4::Log.info("Closed #{closed} WebSocket connection(s) with 1001 going away") if closed.positive?
      rescue StandardError => e
        Tina4::Log.error("Error closing WebSocket connections: #{e.message}")
      end

      def live_websocket_managers
        managers = []
        return managers unless defined?(Tina4::WebSocket)

        managers << Tina4::WebSocket.current if Tina4::WebSocket.current
        managers << Tina4::DevReload.manager if defined?(Tina4::DevReload)
        managers
      end

      # true when everything drained, false when the deadline expired.
      def wait_for_in_flight
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        @mutex.synchronize do
          while @in_flight_count > 0
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              Tina4::Log.warning(
                "TINA4_SHUTDOWN_TIMEOUT=#{@timeout}s reached with #{@in_flight_count} " \
                "request(s) still in flight, forcing close"
              )
              return false
            end
            @in_flight_cv.wait(@mutex, remaining)
          end
        end
        true
      end

      def stop_background_tasks
        return unless defined?(Tina4::Background)

        Tina4::Background.stop_all
        Tina4::Log.info("Background tasks stopped")
      rescue StandardError => e
        Tina4::Log.error("Error stopping background tasks: #{e.message}")
      end

      # Close the DEFAULT connection and every NAMED one. Only closing
      # Tina4.database leaked every connection registered with
      # bind_database(db, name:) - a model pointed at a secondary database held
      # its connection open through shutdown.
      def close_database
        connections = [Tina4.database, *Tina4.databases.values].compact.uniq(&:object_id)
        return if connections.empty?

        connections.each do |connection|
          connection.close
        rescue StandardError => e
          Tina4::Log.error("Error closing database: #{e.message}")
        end
        Tina4::Log.info("Database connections closed (#{connections.size})")
      end

      def install_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            # A trap context must stay async-signal-safe (no mutexes, no IO), so
            # the real work happens on a thread.
            Thread.new { initiate_shutdown }
          end
        end
      end
    end
  end
end
