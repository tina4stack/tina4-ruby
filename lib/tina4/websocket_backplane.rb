# frozen_string_literal: true

# WebSocket Backplane Abstraction for Tina4 Ruby.
#
# Enables broadcasting WebSocket messages across multiple server instances
# using a shared pub/sub channel (e.g. Redis). Without a backplane configured,
# broadcast() only reaches connections on the local process.
#
# Configuration via environment variables:
#   TINA4_WS_BACKPLANE     — Backend type: "redis", "nats", or "" (default: none)
#   TINA4_WS_BACKPLANE_URL — Connection string (default: redis://localhost:6379)
#
# Usage:
#   backplane = Tina4::WebSocketBackplane.create
#   if backplane
#     backplane.subscribe("chat") { |msg| relay_to_local(msg) }
#     backplane.publish("chat", '{"user":"A","text":"hello"}')
#   end

module Tina4
  # Base backplane interface for scaling WebSocket broadcast across instances.
  #
  # Subclasses implement publish/subscribe over a shared message bus so that
  # every server instance receives every broadcast, not just the originator.
  class WebSocketBackplane
    # Publish a message to all instances listening on +channel+.
    def publish(channel, message)
      raise NotImplementedError, "#{self.class}#publish not implemented"
    end

    # Subscribe to +channel+. The block is called with each incoming message.
    # Runs in a background thread.
    def subscribe(channel, &block)
      raise NotImplementedError, "#{self.class}#subscribe not implemented"
    end

    # Stop listening on +channel+.
    def unsubscribe(channel)
      raise NotImplementedError, "#{self.class}#unsubscribe not implemented"
    end

    # Tear down connections and background threads.
    def close
      raise NotImplementedError, "#{self.class}#close not implemented"
    end

    # Factory that reads TINA4_WS_BACKPLANE and returns the appropriate
    # backplane instance, or +nil+ if no backplane is configured.
    #
    # This keeps backplane usage entirely optional — callers simply check
    # +if backplane+ before publishing.
    def self.create(url: nil)
      backend = ENV.fetch("TINA4_WS_BACKPLANE", "").strip.downcase

      case backend
      when "redis"
        RedisBackplane.new(url: url)
      when "nats"
        NATSBackplane.new(url: url)
      when ""
        nil
      else
        raise ArgumentError, "Unknown TINA4_WS_BACKPLANE value: '#{backend}'"
      end
    end
  end

  # Redis pub/sub backplane.
  #
  # Requires the +redis+ gem (+gem install redis+). The require is deferred
  # so the rest of Tina4 works fine without it installed — an error is raised
  # only when this class is actually instantiated.
  class RedisBackplane < WebSocketBackplane
    def initialize(url: nil)
      begin
        require "redis"
      rescue LoadError
        raise LoadError,
          "The 'redis' gem is required for RedisBackplane. " \
          "Install it with: gem install redis"
      end

      @url = url || ENV.fetch("TINA4_WS_BACKPLANE_URL", "redis://localhost:6379")
      @redis = Redis.new(url: @url)
      @subscriber = Redis.new(url: @url)
      @threads = {}
      @running = true
    end

    def publish(channel, message)
      @redis.publish(channel, message)
    end

    def subscribe(channel, &block)
      @threads[channel] = Thread.new do
        @subscriber.subscribe(channel) do |on|
          on.message do |_chan, msg|
            block.call(msg) if @running
          end
        end
      end
    end

    def unsubscribe(channel)
      @subscriber.unsubscribe(channel)
      thread = @threads.delete(channel)
      thread&.join(1)
    end

    def close
      @running = false
      @threads.each_value { |t| t.kill }
      @threads.clear
      @subscriber.close
      @redis.close
    end
  end

  # NATS pub/sub backplane.
  #
  # Requires the +nats-pure+ gem (+gem install nats-pure+). The require is
  # deferred so the rest of Tina4 works fine without it installed — an error
  # is raised only when this class is actually instantiated.
  #
  # NATS is async-native, so we run a background thread with an event
  # machine for the subscription listener.
  class NATSBackplane < WebSocketBackplane
    def initialize(url: nil)
      begin
        require "nats/client"
      rescue LoadError
        raise LoadError,
          "The 'nats-pure' gem is required for NATSBackplane. " \
          "Install it with: gem install nats-pure"
      end

      @url = url || ENV.fetch("TINA4_WS_BACKPLANE_URL", "nats://localhost:4222")
      @subs = {}
      @threads = {}
      @running = true
      @mutex = Mutex.new

      # Connect to NATS in a background thread with its own event loop
      @nats = NATS::IO::Client.new
      @nats.connect(@url)
    end

    def publish(channel, message)
      @nats.publish(channel, message)
      @nats.flush
    end

    def subscribe(channel, &block)
      @mutex.synchronize do
        sid = @nats.subscribe(channel) do |msg|
          block.call(msg.data) if @running
        end
        @subs[channel] = sid

        # Run NATS event processing in a background thread
        @threads[channel] ||= Thread.new do
          loop do
            break unless @running
            sleep 0.01
          end
        end
      end
    end

    def unsubscribe(channel)
      @mutex.synchronize do
        sid = @subs.delete(channel)
        @nats.unsubscribe(sid) if sid
        thread = @threads.delete(channel)
        thread&.kill
      end
    end

    def close
      @running = false
      @mutex.synchronize do
        @subs.each_value { |sid| @nats.unsubscribe(sid) rescue nil }
        @subs.clear
        @threads.each_value { |t| t.kill }
        @threads.clear
      end
      @nats.close
    end
  end
end
