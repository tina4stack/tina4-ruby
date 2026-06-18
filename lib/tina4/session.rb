# frozen_string_literal: true
require "securerandom"
require "json"

module Tina4
  class Session
    DEFAULT_OPTIONS = {
      cookie_name: "tina4_session",
      secret: nil,
      max_age: 3600,
      handler: :file,
      handler_options: {}
    }.freeze

    attr_reader :id, :data

    def initialize(env, options = {})
      @options = DEFAULT_OPTIONS.merge(options)
      # TINA4_SESSION_NAME — overrides cookie_name unless caller explicitly passed one.
      env_name = ENV["TINA4_SESSION_NAME"]
      if !options.key?(:cookie_name) && env_name && !env_name.empty?
        @options[:cookie_name] = env_name
      end
      # No guessable built-in secret. The session never signs with this value
      # (IDs are SecureRandom.hex(32)), so we resolve it from TINA4_SECRET only
      # — nil when unset. This honours the framework's blank-secret discipline
      # (Auth.ensure_dev_secret never uses a guessable default); Python/Node
      # sessions carry no secret field at all.
      @options[:secret] ||= ENV["TINA4_SECRET"]
      # Backend-failure policy strict flag (parity with Python's
      # TINA4_SESSION_STRICT). When truthy, read/write/destroy/gc failures
      # RE-RAISE instead of logging + degrading.
      @strict = Tina4::Env.is_truthy(ENV["TINA4_SESSION_STRICT"])
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

    # Persist the session if dirty. On a backend write failure the error is
    # logged and false is returned — the @modified (dirty) flag is RETAINED so
    # a later save can retry. Returns true on a successful (or no-op) write.
    def save
      return true unless @modified
      if safe_write(@id, @data)
        @modified = false
        true
      else
        false # dirty flag retained for retry
      end
    end

    # Destroy the current session. Should be called right after login or any
    # privilege change to defend against session fixation (see #regenerate).
    def destroy
      safe_destroy(@id)
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

    # Regenerate the session ID while preserving data — returns the new ID.
    # Call this right after login or any privilege change to defend against
    # session fixation (a pre-auth session ID must not survive into the
    # authenticated session). Destroys the old backend record (best-effort)
    # and persists under the new ID.
    def regenerate
      old_id = @id
      @id = SecureRandom.hex(32)
      safe_destroy(old_id)
      @modified = true
      save
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
    # Returns the data hash, or {} on a backend failure (logged + degraded).
    def read(session_id)
      safe_read(session_id)
    end

    # Writes raw session data for a given session ID to backend storage.
    # Returns true on success, false on a backend failure (logged + degraded).
    def write(session_id, data, ttl = nil)
      safe_write(session_id, data, ttl)
    end

    # Garbage collection: remove expired sessions from the handler.
    # A backend failure is logged and swallowed (never crashes the request).
    def gc(max_lifetime = nil)
      return unless @handler.respond_to?(:gc)
      max_lifetime ||= @options[:max_age]
      @handler.gc(max_lifetime)
    rescue StandardError => e
      log_backend_error("gc", e)
      raise if @strict
      nil
    end

    def cookie_header(cookie_name = nil)
      name = cookie_name || @options[:cookie_name]
      samesite = ENV["TINA4_SESSION_SAMESITE"] || "Lax"
      # HttpOnly defaults to true (existing behaviour); flip off only when explicitly false.
      httponly = !%w[false 0 no off].include?((ENV["TINA4_SESSION_HTTPONLY"] || "true").to_s.strip.downcase)
      # Secure defaults to false; flip on with truthy env var.
      secure = %w[true 1 yes on].include?((ENV["TINA4_SESSION_SECURE"] || "false").to_s.strip.downcase)

      parts = ["#{name}=#{@id}", "Path=/"]
      parts << "HttpOnly" if httponly
      parts << "Secure" if secure
      parts << "SameSite=#{samesite}"
      parts << "Max-Age=#{@options[:max_age]}"
      parts.join("; ")
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
      safe_read(@id)
    end

    # ── Backend-failure policy (parity with Python's Session boundary) ──
    #
    # Centralised here, NOT in each handler, so every backend (file, redis,
    # valkey, mongo, database) shares one policy. The rule:
    #   read   failure → log + return {} (empty session, never a 500)
    #   write  failure → log + return false (caller retains dirty for retry)
    #   destroy failure → log + swallow (return false)
    #   gc     failure → log + swallow (see #gc)
    # A genuinely-empty but HEALTHY backend (handler returns nil/{} WITHOUT
    # raising) is NOT a failure and logs nothing. TINA4_SESSION_STRICT=true
    # re-raises instead of degrading.

    def safe_read(session_id)
      existing = @handler.read(session_id)
      existing || {}
    rescue StandardError => e
      log_backend_error("read", e)
      raise if @strict
      {}
    end

    def safe_write(session_id, data, ttl = nil)
      if ttl
        @handler.write(session_id, data, ttl)
      else
        @handler.write(session_id, data)
      end
      true
    rescue StandardError => e
      log_backend_error("write", e)
      raise if @strict
      false
    end

    def safe_destroy(session_id)
      @handler.destroy(session_id)
      true
    rescue StandardError => e
      log_backend_error("destroy", e)
      raise if @strict
      false
    end

    # Single source of the backend-failure log line. Names the operation and
    # the concrete handler class so ops can see WHICH backend failed.
    def log_backend_error(operation, error)
      handler_class = @handler.class.name
      Tina4::Log.error("Session #{operation} failed (#{handler_class}): #{error.message}")
    rescue StandardError
      warn("Session #{operation} failed: #{error.message}")
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
