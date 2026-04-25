# frozen_string_literal: true

module Tina4
  module Shutdown
    DEFAULT_TIMEOUT = 30 # seconds

    class << self
      attr_reader :in_flight_count

      def setup(server: nil, timeout: nil)
        @server = server
        @timeout = (timeout || ENV["TINA4_SHUTDOWN_TIMEOUT"] || DEFAULT_TIMEOUT).to_i
        @shutting_down = false
        @mutex = Mutex.new
        @in_flight_count = 0
        @in_flight_cv = ConditionVariable.new

        install_signal_handlers
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

        # Wait for in-flight requests with timeout
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        @mutex.synchronize do
          while @in_flight_count > 0
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              Tina4::Log.warning("Shutdown timeout reached with #{@in_flight_count} requests still in flight")
              break
            end
            @in_flight_cv.wait(@mutex, remaining)
          end
        end

        # Stop background tasks
        if defined?(Tina4::Background)
          begin
            Tina4::Background.stop_all
            Tina4::Log.info("Background tasks stopped")
          rescue => e
            Tina4::Log.error("Error stopping background tasks: #{e.message}")
          end
        end

        # Close database connections
        if Tina4.database
          begin
            Tina4.database.close
            Tina4::Log.info("Database connections closed")
          rescue => e
            Tina4::Log.error("Error closing database: #{e.message}")
          end
        end

        Tina4::Log.info("Shutdown complete")

        # Stop the server
        @server&.shutdown if @server.respond_to?(:shutdown)
      end

      private

      def install_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            # Signal handlers must be async-signal-safe; use Thread to do real work
            Thread.new { initiate_shutdown }
          end
        end
      end
    end
  end
end
