# frozen_string_literal: true
require "securerandom"
require "json"

module Tina4
  class Session
    DEFAULT_OPTIONS = {
      secret: nil,
      max_age: 3600,
      handler: :file,
      handler_options: {}
    }.freeze

    attr_reader :id, :data

    # The session cookie name — the SINGLE source of truth shared by the WRITE
    # side (#cookie_header) and the READ side (#extract_session_id AND RackApp's
    # incoming-cookie parse), so a cookie written under a renamed name is read
    # back on the next request. Keeping the default literal in ONE place means it
    # can never drift between the emit and parse paths. Parity with Python's
    # module-level session_cookie_name() (tina4_python/session/__init__.py).
    #
    #   TINA4_SESSION_NAME   Cookie name (default: tina4_session)
    def self.cookie_name
      name = ENV["TINA4_SESSION_NAME"]
      name.nil? || name.empty? ? "tina4_session" : name
    end

    def initialize(env, options = {})
      @options = DEFAULT_OPTIONS.merge(options)
      # TINA4_SESSION_NAME — resolved by the ONE shared resolver (Session.cookie_name)
      # that BOTH the write path (#cookie_header) and the read paths
      # (#extract_session_id + RackApp incoming-cookie parse) go through, so a
      # renamed cookie is emitted and read back under the same name. An explicit
      # :cookie_name option still wins (same precedence as :handler below).
      @options[:cookie_name] = self.class.cookie_name unless options.key?(:cookie_name)
      # No guessable built-in secret. The session never signs with this value
      # (IDs are SecureRandom.hex(32)), so we resolve it from TINA4_SECRET only
      # — nil when unset. This honours the framework's blank-secret discipline
      # (Auth.ensure_dev_secret never uses a guessable default); Python/Node
      # sessions carry no secret field at all.
      @options[:secret] ||= ENV["TINA4_SECRET"]
      # TINA4_SESSION_TTL — cookie Max-Age (parity with Python's Session._ttl,
      # which reads the same var). Only consulted when the caller did NOT pass
      # an explicit :max_age (an explicit option always wins). Keeps the cookie
      # honouring TINA4_SESSION_TTL now that rack_app routes the Set-Cookie
      # through #cookie_header instead of hand-writing it (issue #31).
      unless options.key?(:max_age)
        ttl_env = ENV["TINA4_SESSION_TTL"]
        @options[:max_age] = Integer(ttl_env) if ttl_env && !ttl_env.strip.empty?
      end
      # TINA4_SESSION_BACKEND — selects the storage handler unless the caller
      # explicitly passed :handler (same precedence as :cookie_name above; an
      # explicit option always wins over the environment). Without this the
      # shipped redis/valkey/mongo/database handlers are unreachable by config.
      # Parity with Python's Session._resolve_handler.
      @options[:handler] = env_session_backend || @options[:handler] unless options.key?(:handler)
      # Backend-failure policy strict flag (parity with Python's
      # TINA4_SESSION_STRICT). When truthy, read/write/destroy/gc failures
      # RE-RAISE instead of logging + degrading.
      @strict = Tina4::Env.is_truthy(ENV["TINA4_SESSION_STRICT"])
      # Whether THIS request reached us over https, decided PROXY-AWARE from the
      # Rack env at construction (x-forwarded-proto first hop, else rack scheme /
      # HTTPS). #cookie_header ORs this into the Secure flag so a cookie set on an
      # https request is Secure even when TINA4_SESSION_SECURE is unset — a
      # session cookie for an encrypted request must never be sent in the clear.
      # Uses the SAME detector as Request#url so the two never disagree (issue #31).
      @request_secure = Tina4::Request.secure_scheme?(env || {})
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

    # Get a session value with optional default.
    #
    # The default is returned for an ABSENT key, never for a stored FALSE. This
    # was `@data[key.to_s] || default`, which handed back the caller's default
    # for any falsy stored value — so a feature flag stored as false read back
    # as the caller's `true` default. Python (`dict.get`), PHP (`??`) and Node
    # (`??`) all return the stored false, so Ruby was the 1-of-4 outlier.
    #
    # Deliberately the `nil?` form and NOT `@data.key?(k) ? @data[k] : default`:
    # both fix the false case, but the key? form would ALSO flip a stored nil
    # from the default to nil. Ruby currently agrees with PHP and Node there
    # (stored nil -> default) and only Python disagrees (stored None -> None),
    # so changing it is a cross-framework decision, not a side effect of this
    # fix. This form is exactly PHP's `??` and Node's `??`. Same idiom as
    # #get_flash below.
    def get(key, default = nil)
      value = @data[key.to_s]
      value.nil? ? default : value
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
      # Secure is set when ANY of the unified-contract conditions hold (parity
      # with tina4-php#175/#179): TINA4_SESSION_SECURE is truthy, OR SameSite is
      # None (browsers reject a None cookie without Secure per RFC 6265bis), OR
      # the request itself is https (proxy-aware, from @request_secure). A plain
      # HTTP request with the flag unset and SameSite != None stays non-Secure.
      secure = %w[true 1 yes on].include?((ENV["TINA4_SESSION_SECURE"] || "false").to_s.strip.downcase) ||
               samesite.to_s.strip.casecmp("none").zero? ||
               @request_secure == true

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

    # Every accepted backend name, aliases included. Byte-identical membership in
    # all four frameworks. Written once here so the case below and the error
    # message can never disagree.
    VALID_BACKENDS = %w[
      file filesystem
      redis
      valkey
      mongodb mongo
      memcached memcache
      database db
    ].freeze

    # Canonical name of each backend, for the error message. Listing every alias
    # would make it longer without making it clearer.
    CANONICAL_BACKENDS = %w[file redis valkey mongodb memcached database].freeze

    # Reject a backend name that is not a known backend.
    #
    # Never sees a blank name: create_handler normalises blank to "file" first,
    # in one place. Blank must NOT be an error - an env var set to "" is a SET
    # variable, so rejecting it would break every deployment that clears the var
    # to fall back to the default.
    def validate_backend!(name)
      return if VALID_BACKENDS.include?(name)

      raise ArgumentError,
            "Unknown session backend \"#{name}\". " \
            "Valid backends: #{CANONICAL_BACKENDS.join(', ')}. " \
            "Leave TINA4_SESSION_BACKEND unset for the file default."
    end

    # The configured TINA4_SESSION_BACKEND name, or nil when unset/blank (so the
    # caller keeps the DEFAULT_OPTIONS handler). The value is normalised at
    # dispatch in #create_handler, not here.
    def env_session_backend
      value = ENV["TINA4_SESSION_BACKEND"]
      value && !value.strip.empty? ? value : nil
    end

    # Build the storage handler for the resolved backend name.
    #
    # The accepted names - and the aliases - mirror Python's
    # Session._resolve_handler exactly: file|filesystem, redis, valkey,
    # mongodb|mongo, memcached|memcache, database|db. The name is normalised
    # (downcase + strip) so "Redis" / " mongodb " from a .env line resolve.
    #
    # An UNKNOWN value RAISES. It used to fall back to the file handler
    # silently, and the comment here described that as correct parity with
    # Python - it was, and both were wrong. A typo in TINA4_SESSION_BACKEND
    # ("redsi") produced a running app writing sessions to local disk while the
    # operator believed they were in Redis: nothing logged, nothing failed, and
    # the symptom surfaced later as users being logged out whenever a request
    # landed on another instance.
    def create_handler
      name = @options[:handler].to_s.downcase.strip
      name = "file" if name.empty?
      validate_backend!(name)
      case name.to_sym
      when :file, :filesystem
        Tina4::SessionHandlers::FileHandler.new(@options[:handler_options])
      when :redis
        Tina4::SessionHandlers::RedisHandler.new(@options[:handler_options])
      when :mongo, :mongodb
        Tina4::SessionHandlers::MongoHandler.new(@options[:handler_options])
      when :valkey
        Tina4::SessionHandlers::ValkeyHandler.new(@options[:handler_options])
      when :memcached, :memcache
        Tina4::SessionHandlers::MemcachedHandler.new(@options[:handler_options])
      when :database, :db
        # Parity with Python: the database backend "uses whatever DB is
        # connected", so reuse the single ORM resolver (named binding → global
        # Tina4.bind_database → TINA4_DATABASE_URL auto-discovery) rather than
        # opening a second, divergent connection. An explicit
        # handler_options[:db] still wins; a nil here leaves the handler's own
        # env-derived default untouched.
        Tina4::SessionHandlers::DatabaseHandler.new(
          { db: Tina4::ORM.db }.merge(@options[:handler_options] || {})
        )
      else
        # Unreachable for a user's typo - validate_backend! already rejected it.
        # Only a name that IS in VALID_BACKENDS but has no branch above can land
        # here, which is a bug in this method rather than a configuration error,
        # so it must not be swallowed into a file handler either.
        raise ArgumentError,
              "Session backend #{name.inspect} is listed in VALID_BACKENDS but " \
              "has no handler branch. This is a framework bug, not a " \
              "configuration error."
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
