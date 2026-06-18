# frozen_string_literal: true

# Tina4 Events — Simple observer pattern for decoupled communication.
#
# Zero-dependency event system. Fire events, register listeners.
#
#   Tina4::Events.on("user.created") { |user| puts "Welcome #{user[:name]}!" }
#   Tina4::Events.on("user.created") { |user| puts "New signup: #{user[:email]}" }
#   Tina4::Events.emit("user.created", { name: "Alice", email: "alice@example.com" })
#
# One-time listeners:
#
#   Tina4::Events.once("app.ready") { puts "App started!" }
#
module Tina4
  class Events
    @listeners = Hash.new { |h, k| h[k] = [] }

    class << self
      # Register a listener for an event.
      #
      #   Tina4::Events.on("user.created") { |user| ... }
      #   Tina4::Events.on("user.created", priority: 10) { |user| ... }
      #
      # Higher priority runs first.
      def on(event, priority: 0, &block)
        raise ArgumentError, "block required" unless block_given?

        @listeners[event] << { priority: priority, callback: block, once: false }
        @listeners[event].sort_by! { |entry| -entry[:priority] }
        block
      end

      # Register a listener that fires only once then auto-removes.
      #
      #   Tina4::Events.once("app.ready") { puts "App started!" }
      #
      def once(event, priority: 0, &block)
        raise ArgumentError, "block required" unless block_given?

        @listeners[event] << { priority: priority, callback: block, once: true }
        @listeners[event].sort_by! { |entry| -entry[:priority] }
        block
      end

      # Remove a specific listener, or all listeners for an event.
      #
      #   Tina4::Events.off("user.created", handler)  # remove specific
      #   Tina4::Events.off("user.created")            # remove all for event
      #
      def off(event, callback = nil)
        if callback.nil?
          @listeners.delete(event)
        else
          @listeners[event].reject! { |entry| entry[:callback] == callback }
        end
      end

      # Fire an event synchronously. Returns array of listener results.
      #
      #   results = Tina4::Events.emit("user.created", user_data)
      #
      # Listener isolation (visible-but-resilient): each listener is called
      # inside a rescue so ONE throwing listener never aborts the rest of the
      # emit. A failed listener is LOGGED (never silent) and contributes a nil
      # slot, so N listeners always yield N results in priority order. Pass
      # strict: true to RE-RAISE on the first listener error instead of
      # isolating (later listeners then do NOT run).
      def emit(event, *args, strict: false)
        entries = @listeners[event].dup
        results = []
        entries.each do |entry|
          # Remove one-time listeners before calling so re-entrant emits are
          # safe AND so the one-shot is gone before any throw — cleanup stays
          # correct under isolation.
          @listeners[event].delete(entry) if entry[:once]
          begin
            results << entry[:callback].call(*args)
          rescue StandardError, ScriptError => error
            raise if strict

            log_listener_error(event, error)
            results << nil
          end
        end
        results
      end

      # Get all listener callbacks for an event (in priority order).
      def listeners(event)
        @listeners[event].map { |entry| entry[:callback] }
      end

      # List all registered event names.
      def events
        @listeners.keys
      end

      # Fire an event asynchronously. Each listener runs in its own thread.
      #
      #   Tina4::Events.emit_async("user.created", user_data)
      #
      # Listener isolation: each threaded listener is wrapped so one rejection
      # never aborts the others. A failed listener is LOGGED (never silent).
      # Pass strict: true to RE-RAISE the first listener error on the main
      # thread (the thread that raised aborts on join) instead of isolating.
      def emit_async(event, *args, strict: false)
        return unless @listeners&.key?(event)

        @listeners[event].sort_by { |l| -(l[:priority] || 0) }.map do |listener|
          Thread.new do
            # In strict mode the error is re-raised to surface on #join; mute
            # the per-thread auto-report so the deliberate raise doesn't spam
            # stderr (the caller still sees it via join).
            Thread.current.report_on_exception = false if strict
            begin
              listener[:callback].call(*args)
            rescue StandardError, ScriptError => error
              raise if strict

              log_listener_error(event, error)
              nil
            end
          end
        end
      end

      # Remove all listeners for all events.
      def clear
        @listeners.clear
      end

      private

      # NEVER silently swallow a listener error — always surface it. Logs via
      # Tina4::Log.warning with BOTH the event name and the error class+message.
      # Wrapped so a broken logger can't break the bus: on any logger failure it
      # falls back to $stderr so the error is still seen.
      def log_listener_error(event, error)
        Tina4::Log.warning(
          "Event listener for '#{event}' raised #{error.class.name}: #{error.message}"
        )
      rescue StandardError
        begin
          $stderr.puts(
            "Event listener for '#{event}' raised #{error.class.name}: #{error.message}"
          )
          $stderr.flush
        rescue StandardError
          # Last-resort: never let logging break the event bus.
        end
      end
    end
  end
end
