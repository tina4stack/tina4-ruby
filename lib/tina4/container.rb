# frozen_string_literal: true

module Tina4
  # Lightweight dependency injection container.
  #
  #   Tina4.register(:mailer, MailService.new)          # concrete instance
  #   Tina4.register(:db) { Database.new(ENV["DB_URL"]) } # lazy factory
  #   Tina4.resolve(:mailer)                            # => MailService instance
  #
  module Container
    class << self
      def registry
        @registry ||= {}
      end

      # Register a service by name.
      # Pass an instance directly, or a block for lazy instantiation.
      def register(name, instance = nil, &factory)
        raise ArgumentError, "provide an instance or a block, not both" if instance && factory
        raise ArgumentError, "provide an instance or a block" unless instance || factory

        registry[name.to_sym] = if factory
          { factory: factory, instance: nil }
        else
          { factory: nil, instance: instance }
        end
      end

      # Resolve a service by name.
      # Lazy factories are called once and memoized.
      def resolve(name)
        entry = registry[name.to_sym]
        raise KeyError, "service not registered: #{name}" unless entry

        if entry[:instance]
          entry[:instance]
        elsif entry[:factory]
          entry[:instance] = entry[:factory].call
          entry[:instance]
        end
      end

      # Check if a service is registered.
      def registered?(name)
        registry.key?(name.to_sym)
      end

      # Remove all registrations (useful in tests).
      def clear!
        @registry = {}
      end
    end
  end
end
