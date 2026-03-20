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
      def emit(event, *args)
        entries = @listeners[event].dup
        results = []
        entries.each do |entry|
          # Remove one-time listeners before calling so re-entrant emits are safe
          @listeners[event].delete(entry) if entry[:once]
          results << entry[:callback].call(*args)
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

      # Remove all listeners for all events.
      def clear
        @listeners.clear
      end
    end
  end
end
