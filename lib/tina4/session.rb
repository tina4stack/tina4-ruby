# frozen_string_literal: true
require "securerandom"
require "json"

module Tina4
  class Session
    DEFAULT_OPTIONS = {
      cookie_name: "tina4_session",
      secret: nil,
      max_age: 86400,
      handler: :file,
      handler_options: {}
    }.freeze

    attr_reader :id, :data

    def initialize(env, options = {})
      @options = DEFAULT_OPTIONS.merge(options)
      @options[:secret] ||= ENV["SECRET"] || "tina4-default-secret"
      @handler = create_handler
      @id = extract_session_id(env) || SecureRandom.hex(32)
      @data = load_session
      @modified = false
    end

    def [](key)
      @data[key.to_s]
    end

    def []=(key, value)
      @data[key.to_s] = value
      @modified = true
    end

    def delete(key)
      @data.delete(key.to_s)
      @modified = true
    end

    def clear
      @data = {}
      @modified = true
    end

    def to_hash
      @data.dup
    end

    def save
      return unless @modified
      @handler.write(@id, @data)
      @modified = false
    end

    def destroy
      @handler.destroy(@id)
      @data = {}
    end

    def cookie_header
      "#{@options[:cookie_name]}=#{@id}; Path=/; HttpOnly; SameSite=Lax; Max-Age=#{@options[:max_age]}"
    end

    private

    def extract_session_id(env)
      cookie_str = env["HTTP_COOKIE"] || ""
      cookie_str.split(";").each do |pair|
        key, value = pair.strip.split("=", 2)
        return value if key == @options[:cookie_name]
      end
      nil
    end

    def load_session
      existing = @handler.read(@id)
      existing || {}
    end

    def create_handler
      case @options[:handler].to_sym
      when :file
        Tina4::SessionHandlers::FileHandler.new(@options[:handler_options])
      when :redis
        Tina4::SessionHandlers::RedisHandler.new(@options[:handler_options])
      when :mongo, :mongodb
        Tina4::SessionHandlers::MongoHandler.new(@options[:handler_options])
      else
        Tina4::SessionHandlers::FileHandler.new(@options[:handler_options])
      end
    end
  end

  class LazySession
    def initialize(env, options = {})
      @env = env
      @options = options
      @session = nil
    end

    def [](key)
      ensure_loaded
      @session[key]
    end

    def []=(key, value)
      ensure_loaded
      @session[key] = value
    end

    def delete(key)
      ensure_loaded
      @session.delete(key)
    end

    def clear
      ensure_loaded
      @session.clear
    end

    def save
      @session&.save
    end

    def destroy
      @session&.destroy
    end

    def cookie_header
      ensure_loaded
      @session.cookie_header
    end

    def to_hash
      ensure_loaded
      @session.to_hash
    end

    private

    def ensure_loaded
      @session ||= Session.new(@env, @options)
    end
  end
end
