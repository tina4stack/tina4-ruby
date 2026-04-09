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

    # Start or resume a session. If session_id is given, load that session;
    # otherwise generate a new ID. Returns the session ID string.
    def start(session_id = nil)
      if session_id
        @id = session_id
        @data = load_session
      else
        @id = SecureRandom.hex(32)
        @data = {}
      end
      @modified = false
      @id
    end

    # Returns the current session ID string.
    def get_session_id
      @id
    end

    # Reads raw session data for a given session ID from backend storage.
    # Returns the data hash or nil.
    def read(session_id)
      @handler.read(session_id)
    end

    # Writes raw session data for a given session ID to backend storage.
    def write(session_id, data, ttl = nil)
      if ttl
        @handler.write(session_id, data, ttl)
      else
        @handler.write(session_id, data)
      end
    end

    # Garbage collection: remove expired sessions from the handler
    def gc(max_lifetime = nil)
      max_lifetime ||= @options[:max_age]
      @handler.gc(max_lifetime) if @handler.respond_to?(:gc)
    end

    def cookie_header(cookie_name = nil)
      name = cookie_name || @options[:cookie_name]
      samesite = ENV["TINA4_SESSION_SAMESITE"] || "Lax"
      "#{name}=#{@id}; Path=/; HttpOnly; SameSite=#{samesite}; Max-Age=#{@options[:max_age]}"
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

    def gc(max_lifetime = nil)
      ensure_loaded
      @session.gc(max_lifetime)
    end

    def start(session_id = nil)
      ensure_loaded
      @session.start(session_id)
    end

    def get_session_id
      ensure_loaded
      @session.get_session_id
    end

    def read(session_id)
      ensure_loaded
      @session.read(session_id)
    end

    def write(session_id, data, ttl = nil)
      ensure_loaded
      @session.write(session_id, data, ttl)
    end

    def cookie_header(cookie_name = nil)
      ensure_loaded
      @session.cookie_header(cookie_name)
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
