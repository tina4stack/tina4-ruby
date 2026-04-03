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

    # Get a session value with optional default
    def get(key, default = nil)
      @data[key.to_s] || default
    end

    # Set a session value
    def set(key, value)
      @data[key.to_s] = value
      @modified = true
    end

    # Check if a key exists in the session
    def has?(key)
      @data.key?(key.to_s)
    end

    # Return all session data
    def all
      @data.dup
    end

    # Flash data: set a value that is removed after next read.
    # Call with value to set, call without value to get (and remove).
    def flash(key, value = nil)
      flash_key = "_flash_#{key}"
      if value.nil?
        val = @data.delete(flash_key.to_s)
        @modified = true if val
        val
      else
        @data[flash_key.to_s] = value
        @modified = true
        value
      end
    end

    # Get flash data by key (alias for flash(key) without value)
    def get_flash(key, default = nil)
      result = flash(key)
      result.nil? ? default : result
    end

    # Regenerate the session ID while preserving data — returns new ID
    def regenerate
      old_id = @id
      @id = SecureRandom.hex(32)
      @handler.destroy(old_id)
      @modified = true
      @id
    end

    # Garbage collection: remove expired sessions from the handler
    def gc(max_age = nil)
      max_age ||= @options[:max_age]
      @handler.gc(max_age) if @handler.respond_to?(:gc)
    end

    def cookie_header
      samesite = ENV["TINA4_SESSION_SAMESITE"] || "Lax"
      "#{@options[:cookie_name]}=#{@id}; Path=/; HttpOnly; SameSite=#{samesite}; Max-Age=#{@options[:max_age]}"
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
      when :valkey
        Tina4::SessionHandlers::ValkeyHandler.new(@options[:handler_options])
      when :database, :db
        Tina4::SessionHandlers::DatabaseHandler.new(@options[:handler_options])
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

    def get(key, default = nil)
      ensure_loaded
      @session.get(key, default)
    end

    def set(key, value)
      ensure_loaded
      @session.set(key, value)
    end

    def has?(key)
      ensure_loaded
      @session.has?(key)
    end

    def all
      ensure_loaded
      @session.all
    end

    def flash(key, value = nil)
      ensure_loaded
      @session.flash(key, value)
    end

    def regenerate
      ensure_loaded
      @session.regenerate
    end

    def gc(max_age = nil)
      ensure_loaded
      @session.gc(max_age)
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
