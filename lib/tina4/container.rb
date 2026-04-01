# frozen_string_literal: true

module Tina4
  # Lightweight dependency injection container.
  #
  #   Tina4::Container.register(:mailer) { MailService.new } # transient — new instance each resolve
  #   Tina4::Container.singleton(:db) { Database.new(ENV["DB_URL"]) } # singleton — memoised
  #   Tina4::Container.register(:cache, RedisCacheInstance)  # concrete instance (always same)
  #   Tina4::Container.resolve(:db)                          # => Database instance
  #
  module Container
    class << self
      def registry
        @registry ||= {}
      end

      # Register a service by name.
      # Pass a concrete instance directly, or a block for transient instantiation.
      # Blocks are called on every resolve() — use singleton() for memoised factories.
      def register(name, instance = nil, &factory)
        raise ArgumentError, "provide an instance or a block, not both" if instance && factory
        raise ArgumentError, "provide an instance or a block" unless instance || factory

        registry[name.to_sym] = if factory
          { factory: factory, singleton: false, instance: nil }
        else
          { factory: nil, singleton: false, instance: instance }
        end
      end

      # Register a singleton factory by name.
      # The block is called once on first resolve() and the result is memoised.
      def singleton(name, &factory)
        raise ArgumentError, "singleton requires a block" unless factory

        registry[name.to_sym] = { factory: factory, singleton: true, instance: nil }
      end

      # Resolve a service by name.
      # Singletons and concrete instances return the same object each time.
      # Transient factories (register with block) return a new object each time.
      def resolve(name)
        entry = registry[name.to_sym]
        raise KeyError, "service not registered: #{name}" unless entry

        # Concrete instance (register with value)
        return entry[:instance] if entry[:instance] && entry[:factory].nil?

        if entry[:factory]
          if entry[:singleton]
            # Singleton — call once, memoize
            entry[:instance] ||= entry[:factory].call
            entry[:instance]
          else
            # Transient — call every time
            entry[:factory].call
          end
        else
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
