# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


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
#   backplane = Tina4::WebSocketBackplane.create_backplane
#   if backplane
#     backplane.subscribe("chat") { |msg| relay_to_local(msg) }
#     backplane.publish("chat", '{"user":"A","text":"hello"}')
#   end

require_relative "database_url"

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
    def self.create_backplane(url: nil)
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
      # GHSA-h2mr-m3v3-cq8c: the redis gem re-parses the URL with URI.parse,
      # which reads `redis://u:12?q@h` as host "u", port 12 and then quotes that
      # host in its connection errors. Refuse (generically) any URL whose
      # userinfo URI.parse would not take the way the shared redaction does.
      Tina4::DatabaseUrl.assert_client_url!(@url, "Invalid TINA4_WS_BACKPLANE_URL for the Redis backplane")
      @redis, @subscriber = open_clients
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
      rescue StandardError => e
        # A refused login or a dropped connection ends this listener for good.
        # Say so in the framework log: before, the thread died with only a raw
        # stack trace on stderr while "backplane active" stood as the last word.
        # The redis client's messages carry the URL without its userinfo.
        Tina4::Log.error("WebSocket backplane subscriber stopped on '#{channel}': #{e.message}") if @running && defined?(Tina4::Log)
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

    private

    # The publisher and subscriber clients. A URL the client cannot parse
    # raises URI::InvalidURIError quoting the WHOLE raw URL, password included,
    # and WebSocket#ensure_backplane logs e.message. Re-raised naming only the
    # redacted form - outside the rescue and with cause: nil, because a chained
    # cause carries that raw message into every crash report and full_message.
    def open_clients
      clients = new_clients
      return clients if clients.is_a?(Array)

      raise ArgumentError.new("Invalid TINA4_WS_BACKPLANE_URL for the Redis backplane: " \
                              "#{Tina4::DatabaseUrl.redact(@url)} (#{clients.class})"), cause: nil
    end

    # Both clients, or the error building them raised (returned, not raised).
    def new_clients
      [Redis.new(url: @url), Redis.new(url: @url)]
    rescue StandardError => e
      e
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

      # Same rule as RedisBackplane (GHSA-h2mr-m3v3-cq8c): refuse a URL whose
      # userinfo the client would read differently from the shared redaction.
      # nats-pure takes a comma-separated server list, so each is checked.
      @url.to_s.split(",").each do |server|
        Tina4::DatabaseUrl.assert_client_url!(server.strip, "Invalid TINA4_WS_BACKPLANE_URL for the NATS backplane")
      end

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
        # NATS::Client#subscribe returns a NATS::Subscription. The client's own
        # #unsubscribe is private in nats-pure 2.x, so we tear a subscription
        # down through the subscription object, not the client (see #unsubscribe).
        subscription = @nats.subscribe(channel) do |msg|
          block.call(msg.data) if @running
        end
        @subs[channel] = subscription

        # The NATS client dispatches subscription callbacks on its own reader
        # thread, so this keeper thread only has to stay alive until unsubscribe
        # or close kills it. It blocks on an empty queue - nothing is ever
        # pushed - so it waits at zero CPU. Before, it woke a hundred times a
        # second on `sleep 0.01` just to re-check @running, burning energy to do
        # nothing (Carbonah E004).
        @threads[channel] ||= Thread.new { Thread::Queue.new.pop }
      end
    end

    def unsubscribe(channel)
      @mutex.synchronize do
        subscription = @subs.delete(channel)
        subscription&.unsubscribe
        thread = @threads.delete(channel)
        thread&.kill
      end
    end

    def close
      @running = false
      @mutex.synchronize do
        @subs.each_value { |subscription| subscription.unsubscribe rescue nil }
        @subs.clear
        @threads.each_value { |t| t.kill }
        @threads.clear
      end
      @nats.close
    end
  end
end
