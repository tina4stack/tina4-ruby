# frozen_string_literal: true

# ── Core (always loaded) ──────────────────────────────────────────────
require_relative "tina4/version"
require_relative "tina4/constants"
require_relative "tina4/log"
require_relative "tina4/debug"  # backward compat alias
require_relative "tina4/env"
require_relative "tina4/router"
require_relative "tina4/request"
require_relative "tina4/response"
require_relative "tina4/rack_app"
require_relative "tina4/database"
require_relative "tina4/database_result"
require_relative "tina4/field_types"
require_relative "tina4/orm"
require_relative "tina4/query_builder"
require_relative "tina4/migration"
require_relative "tina4/auto_crud"
require_relative "tina4/database/sqlite3_adapter"
require_relative "tina4/template"
require_relative "tina4/frond"
require_relative "tina4/auth"
require_relative "tina4/session"
require_relative "tina4/middleware"
require_relative "tina4/cors"
require_relative "tina4/rate_limiter"
require_relative "tina4/health"
require_relative "tina4/shutdown"
require_relative "tina4/background"
require_relative "tina4/localization"
require_relative "tina4/container"
require_relative "tina4/service"
require_relative "tina4/service_runner"
require_relative "tina4/events"
require_relative "tina4/plan"
require_relative "tina4/project_index"
require_relative "tina4/dev_admin"
require_relative "tina4/feedback"
require_relative "tina4/dev_mailbox"
require_relative "tina4/ai"
require_relative "tina4/cache"
require_relative "tina4/sql_translator"
require_relative "tina4/cache_backends"
require_relative "tina4/response_cache"
require_relative "tina4/html_element"
require_relative "tina4/error_overlay"
require_relative "tina4/test_client"
require_relative "tina4/test"
require_relative "tina4/docs"
require_relative "tina4/context"
require_relative "tina4/mcp"
require_relative "tina4/realtime"

module Tina4
  # ── Lazy-loaded: database drivers ─────────────────────────────────────
  module Drivers
    autoload :SchemaSplit,    File.expand_path("tina4/drivers/schema_split", __dir__)
    autoload :SqliteDriver,   File.expand_path("tina4/drivers/sqlite_driver", __dir__)
    autoload :PostgresDriver, File.expand_path("tina4/drivers/postgres_driver", __dir__)
    autoload :MysqlDriver,    File.expand_path("tina4/drivers/mysql_driver", __dir__)
    autoload :MssqlDriver,    File.expand_path("tina4/drivers/mssql_driver", __dir__)
    autoload :FirebirdDriver, File.expand_path("tina4/drivers/firebird_driver", __dir__)
    autoload :MongodbDriver,  File.expand_path("tina4/drivers/mongodb_driver", __dir__)
    autoload :OdbcDriver,     File.expand_path("tina4/drivers/odbc_driver", __dir__)
  end

  # ── Lazy-loaded: session handlers ─────────────────────────────────────
  module SessionHandlers
    autoload :FileHandler,  File.expand_path("tina4/session_handlers/file_handler", __dir__)
    autoload :RedisHandler, File.expand_path("tina4/session_handlers/redis_handler", __dir__)
    autoload :MongoHandler,  File.expand_path("tina4/session_handlers/mongo_handler", __dir__)
    autoload :ValkeyHandler,   File.expand_path("tina4/session_handlers/valkey_handler", __dir__)
    autoload :DatabaseHandler, File.expand_path("tina4/session_handlers/database_handler", __dir__)
  end

  # ── Lazy-loaded: queue backends ───────────────────────────────────────
  module QueueBackends
    autoload :LiteBackend,     File.expand_path("tina4/queue_backends/lite_backend", __dir__)
    autoload :RabbitmqBackend, File.expand_path("tina4/queue_backends/rabbitmq_backend", __dir__)
    autoload :KafkaBackend,    File.expand_path("tina4/queue_backends/kafka_backend", __dir__)
    autoload :MongoBackend,    File.expand_path("tina4/queue_backends/mongo_backend", __dir__)
  end

  # ── Lazy-loaded: web server ───────────────────────────────────────────
  autoload :WebServer, File.expand_path("tina4/webserver", __dir__)

  # ── Lazy-loaded: optional modules ─────────────────────────────────────
  autoload :Swagger,             File.expand_path("tina4/swagger", __dir__)
  autoload :Crud,                File.expand_path("tina4/crud", __dir__)
  autoload :CRUD,                File.expand_path("tina4/crud", __dir__)
  autoload :API,                 File.expand_path("tina4/api", __dir__)
  autoload :APIResponse,         File.expand_path("tina4/api", __dir__)
  autoload :GraphQLType,         File.expand_path("tina4/graphql", __dir__)
  autoload :GraphQLSchema,       File.expand_path("tina4/graphql", __dir__)
  autoload :GraphQLParser,       File.expand_path("tina4/graphql", __dir__)
  autoload :GraphQLExecutor,     File.expand_path("tina4/graphql", __dir__)
  autoload :GraphQLError,        File.expand_path("tina4/graphql", __dir__)
  autoload :GraphQL,             File.expand_path("tina4/graphql", __dir__)
  autoload :WebSocket,           File.expand_path("tina4/websocket", __dir__)
  autoload :WebSocketConnection, File.expand_path("tina4/websocket", __dir__)
  autoload :DevReload,           File.expand_path("tina4/websocket", __dir__)
  autoload :WebSocketBackplane,  File.expand_path("tina4/websocket_backplane", __dir__)
  autoload :RedisBackplane,      File.expand_path("tina4/websocket_backplane", __dir__)
  autoload :NATSBackplane,       File.expand_path("tina4/websocket_backplane", __dir__)
  # MQTT 3.1.1 — zero-dependency IoT client (socket + pack/unpack only).
  # Autoloaded, not required: an app that never talks to a broker pays nothing.
  autoload :Mqtt,                File.expand_path("tina4/mqtt", __dir__)
  autoload :MqttError,           File.expand_path("tina4/mqtt", __dir__)
  autoload :MqttTimeoutError,    File.expand_path("tina4/mqtt", __dir__)
  autoload :MqttMessage,         File.expand_path("tina4/mqtt_message", __dir__)
  autoload :Testing,             File.expand_path("tina4/testing", __dir__)
  # Queue / Messenger / DocStore were the last three optional subsystems still
  # loaded eagerly, so every `require "tina4"` paid for a queue backend, an
  # SMTP/IMAP client and a JSON1 document store even in an app that talks to
  # none of them. Every reference to them across the framework is inside a
  # method body (CLI commands, dev-admin handlers, MCP tools), so autoload
  # resolves them on first real use. `defined?(Tina4::Queue)` still answers
  # "constant" against an autoload entry WITHOUT triggering the load, so the
  # `if defined?(Tina4::Queue)` guards in dev_admin keep working and stay lazy.
  # queue.rb defines Job as well as Queue -- BOTH need an entry. An autoload
  # table is explicit where a `require` was implicit, so every constant a
  # newly-lazy file defines has to be listed or it becomes a NameError. Missing
  # Job here took the whole spec suite down to 0 examples.
  autoload :Queue,               File.expand_path("tina4/queue", __dir__)
  autoload :Job,                 File.expand_path("tina4/queue", __dir__)
  autoload :Messenger,           File.expand_path("tina4/messenger", __dir__)
  autoload :MessengerError,      File.expand_path("tina4/messenger", __dir__)
  autoload :MessengerConnectionError, File.expand_path("tina4/messenger", __dir__)

  # Factory for a Messenger configured from the environment.
  #
  # Defined HERE, eagerly, and not in messenger.rb: `autoload` only fires on a
  # CONSTANT reference, and a module function is not a constant. A cold
  # `require "tina4"; Tina4.create_messenger` therefore raised NoMethodError until
  # something else happened to touch Tina4::Messenger first -- the documented entry
  # point was unreachable on a fresh process. Naming the constant below is what
  # triggers the autoload.
  def self.create_messenger(**options)
    Tina4::Messenger.create_messenger(**options)
  end
  autoload :IMAP_CONNECTION_ERRORS, File.expand_path("tina4/messenger", __dir__)
  autoload :DocStore,            File.expand_path("tina4/docstore", __dir__)
  autoload :ScssCompiler,        File.expand_path("tina4/scss_compiler", __dir__)
  autoload :FakeData,            File.expand_path("tina4/seeder", __dir__)
  autoload :WSDL,                File.expand_path("tina4/wsdl", __dir__)
  # Validator is a counted framework feature and belongs on the main
  # `require "tina4"` surface like every other subsystem — PHP reaches
  # Tina4\Validator through composer's autoloader, Node exports Validator from
  # packages/core/src/index.ts, and Python resolves tina4_python.validator as a
  # submodule with no extra wiring. Ruby was the odd one out: validator.rb was
  # neither required nor autoloaded, so Tina4::Validator raised NameError after a
  # clean boot. Autoloaded (not eagerly required) so it still costs nothing until
  # a route actually validates. (feature-recount D5)
  autoload :Validator,           File.expand_path("tina4/validator", __dir__)
  BANNER = <<~'BANNER'

  ______ _             __ __
 /_  __/(_)___  ____ _/ // /
  / /  / / __ \/ __ `/ // /_
 / /  / / / / / /_/ /__  __/
/_/  /_/_/ /_/\__,_/  /_/
  BANNER

  class << self
    attr_accessor :root_dir
    attr_reader :database

    # Bind a database connection.
    #   bind_database(db)                  → sets the global default (Tina4.database)
    #   bind_database(db, name: :analytics) → registers a named connection
    # A model with `self.db = :analytics` resolves from this named registry;
    # otherwise models fall back to the global default / TINA4_DATABASE_URL.
    def bind_database(db, name: nil)
      if name.nil?
        @database = db
      else
        (@databases ||= {})[name.to_sym] = db
      end
      db
    end

    # Named connection registry. bind_database(db, name:) populates it;
    # models with a Symbol/String `self.db` resolve against it.
    def databases = (@databases ||= {})

    # Build the startup banner's optional surface lines (issue #99).
    #
    # Only advertise a surface that is actually REACHABLE. In production, or with
    # TINA4_DEBUG off, /swagger and /__dev return 404 -- printing them anyway
    # both misleads an operator into believing a dev surface is exposed and sends
    # a developer to a dead link.
    #
    # Kept as a pure function of (port, two booleans) so the contract is unit
    # testable without booting a server and grepping stdout. Parity: Python
    # banner_surface_lines, PHP App::bannerSurfaceLines, Node bannerSurfaceLines.
    #
    # @return [Array<String>] zero, one or two ready-to-puts banner rows.
    def banner_surface_lines(port, swagger_enabled:, dev_admin_enabled:)
      lines = []
      lines << "  Swagger:   http://localhost:#{port}/swagger" if swagger_enabled
      lines << "  Dashboard: http://localhost:#{port}/__dev" if dev_admin_enabled
      lines
    end

    def print_banner(host: "0.0.0.0", port: 7147, server_name: nil)
      # TINA4_SUPPRESS — short-circuit ALL banner output for headless / CI runs.
      return if Tina4::Env.is_truthy(ENV["TINA4_SUPPRESS"])

      is_tty = $stdout.respond_to?(:isatty) && $stdout.isatty
      color = is_tty ? "\e[31m" : ""
      reset = is_tty ? "\e[0m" : ""

      is_debug = Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])
      log_level = (ENV["TINA4_LOG_LEVEL"] || "[TINA4_LOG_ALL]").upcase
      display = (host == "0.0.0.0" || host == "::") ? "localhost" : host

      # Auto-detect server name if not provided
      if server_name.nil?
        if is_debug
          server_name = "WEBrick"
        else
          begin
            require "puma"
            server_name = "puma"
          rescue LoadError
            server_name = "WEBrick"
          end
        end
      end

      puts "#{color}#{BANNER}#{reset}"
      puts "  TINA4 — The Intelligent Native Application 4ramework"
      puts "  Simple. Fast. Human. | Built for AI. Built for you."
      puts ""
      puts "  Server:    http://#{display}:#{port} (#{server_name})"
      # Only advertise a surface that is actually reachable (issue #99).
      banner_surface_lines(
        port,
        swagger_enabled: Tina4::Swagger.enabled?,
        dev_admin_enabled: is_debug
      ).each { |line| puts line }
      puts "  Debug:     #{is_debug ? 'ON' : 'OFF'} (Log level: #{log_level})"
      puts ""
    rescue
      puts "#{color}TINA4 Ruby v#{VERSION}#{reset}"
    end

    def initialize!(root_dir = Dir.pwd)
      @root_dir = root_dir

      # Print banner
      print_banner

      # Load environment. Precedence: real-env > .env.local > .env
      # (.env.local loads first, both first-wins, so a real env var always wins).
      Tina4::Env.load_env(root_dir)

      # Setup debug logging
      Tina4::Log.configure(root_dir)
      Tina4::Log.info("Tina4 Ruby v#{VERSION} initializing...")

      # Fail-safe dev secret: in dev (and NOT CI/prod) mint a per-machine
      # random TINA4_SECRET into gitignored .env.local if it is blank; in
      # CI/prod with a blank secret, emit the actionable warning. Runs once at
      # boot after env load, before any auth use. Never crashes boot.
      Tina4::Auth.ensure_dev_secret(root_dir)

      # Setup auth keys
      Tina4::Auth.setup(root_dir)

      # Load translations
      Tina4::Localization.load(root_dir)

      # Auto-wire t() into template globals if locales were loaded
      autowire_i18n_template_global

      # Connect database if configured
      setup_database

      # Auto-discover routes
      auto_discover(root_dir)

      # Apply pending DB migrations on startup (non-breaking — see method doc).
      # Runs AFTER route discovery / DB bind, BEFORE serving.
      auto_migrate_on_startup!(root_dir)

      Tina4::Log.info("Tina4 initialized successfully")
    end

    # Initialize and start the web server.
    # This is the primary entry point for app.rb files:
    #   Tina4.initialize!(__dir__)
    #   Tina4.run!
    # Or combined: Tina4.run!(__dir__)
    def find_available_port(start, max_tries = 10)
      require "socket"
      max_tries.times do |offset|
        port = start + offset
        begin
          server = TCPServer.new("127.0.0.1", port)
          server.close
          return port
        rescue Errno::EADDRINUSE, Errno::EACCES
          next
        end
      end
      start
    end

    def open_browser(url)
      require "rbconfig"
      Thread.new do
        sleep 2
        case RbConfig::CONFIG["host_os"]
        when /darwin/i then system("open", url)
        when /mswin|mingw/i then system("start", url)
        else system("xdg-open", url)
        end
      end
    end

    # The framework's own routes, in ONE place. Both entry points call this:
    # Tina4.run! (app.rb) and the CLI's cmd_start. Anything added here is
    # available however the app was launched -- which is the whole point.
    def register_builtin_routes!
      Tina4::Health.register!
      Tina4::Frond.register_live_endpoint!
    end

    def run!(root_dir = nil, port: nil, host: nil, debug: nil)
      # Handle legacy call: run!(port: 7147) where root_dir receives the hash
      if root_dir.is_a?(Hash)
        port ||= root_dir[:port]
        host ||= root_dir[:host]
        debug = root_dir[:debug] if debug.nil? && root_dir.key?(:debug)
        root_dir = nil
      end
      root_dir ||= Dir.pwd

      ENV["PORT"] = port.to_s if port
      ENV["HOST"] = host.to_s if host
      ENV["TINA4_DEBUG"] = debug.to_s unless debug.nil?

      initialize!(root_dir) unless @root_dir

      # Built-in routes. These used to be registered ONLY by the CLI's
      # cmd_start, so an app booted the documented way -- `Tina4.run!` from
      # app.rb, which is exactly what `tina4 init ruby` scaffolds -- served 404
      # on /health while the identical code under `tina4ruby serve` served 200.
      # A container health check pointed at /health therefore failed against a
      # perfectly healthy app.
      register_builtin_routes!

      host = ENV.fetch("HOST", ENV.fetch("TINA4_HOST", "0.0.0.0"))
      port = ENV.fetch("PORT", ENV.fetch("TINA4_PORT", "7147")).to_i

      actual_port = find_available_port(port)
      if actual_port != port
        Tina4::Log.info("Port #{port} in use, using #{actual_port}")
        port = actual_port
      end

      display_host = (host == "0.0.0.0" || host == "::") ? "localhost" : host
      url = "http://#{display_host}:#{port}"

      app = Tina4::RackApp.new(root_dir: root_dir)
      is_debug = Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])

      # Try Puma first (production-grade), fall back to WEBrick
      if !is_debug
        begin
          require "puma"
          require "puma/configuration"
          require "puma/launcher"

          config = Puma::Configuration.new do |user_config|
            user_config.bind "tcp://#{host}:#{port}"
            user_config.app app
            user_config.threads 0, 16
            user_config.workers 0
            user_config.environment "production"
            user_config.log_requests false
            user_config.quiet
          end

          Tina4::Log.info("Production server: puma")
          Tina4::Shutdown.setup

          open_browser(url)
          launcher = Puma::Launcher.new(config)
          launcher.run
          return
        rescue LoadError
          # Puma not installed, fall through to WEBrick
        end
      end

      Tina4::Log.info("Development server: WEBrick")
      open_browser(url)
      server = Tina4::WebServer.new(app, host: host, port: port)
      server.start
    end

    # DSL methods for route registration
    # GET is public by default (matching tina4_python behavior)
    # POST/PUT/PATCH/DELETE are secured by default — use auth: false to make public
    def get(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth == false ? nil : auth
      Tina4::Router.add("GET", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def post(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add("POST", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def put(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add("PUT", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def patch(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add("PATCH", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def delete(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add("DELETE", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def any(path, auth: false, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      %w[GET POST PUT PATCH DELETE].each do |method|
        Tina4::Router.add(method, path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
      end
    end

    def options(path, &block)
      Tina4::Router.add("OPTIONS", path, block)
    end

    # Explicit secure variants (always secured, regardless of HTTP method)
    def secure_get(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add("GET", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_post(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add("POST", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_put(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add("PUT", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_patch(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add("PATCH", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_delete(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add("DELETE", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    # Route groups
    def group(prefix, auth: nil, &block)
      Tina4::Router.group(prefix, auth_handler: auth, &block)
    end

    # WebSocket route registration. PUBLIC by default (mirrors GET). Pass
    # secure: true OR chain .secure on the returned route to require a valid JWT
    # on the upgrade.
    def websocket(path, secure: false, &block)
      Tina4::Router.websocket(path, secure: secure, &block)
    end

    # Register a SECURED WebSocket route — declarative sibling of
    # Tina4.websocket(...).secure, mirroring secure_get/secure_post.
    def secure_websocket(path, &block)
      Tina4::Router.secure_websocket(path, &block)
    end

    # Middleware hooks
    def before(pattern = nil, &block)
      Tina4::Middleware.before(pattern, &block)
    end

    def after(pattern = nil, &block)
      Tina4::Middleware.after(pattern, &block)
    end

    # Template globals
    def template_global(key, value)
      Tina4::Template.add_global(key, value)
    end

    # Inline test DSL
    def describe(name, &block)
      Tina4::Testing.describe(name, &block)
    end

    # Translation shortcut
    def t(key, **options)
      Tina4::Localization.t(key, **options)
    end

    # Service runner DSL
    def service(name, options = {}, &block)
      Tina4::ServiceRunner.register(name, nil, options, &block)
    end

    # Register a periodic background task.
    # Mirrors Python's tina4_python.core.server.background(fn, interval) and
    # PHP's $app->background($callback, $interval).
    #
    #   Tina4.background(interval: 5.0) { drain_queue }
    #   Tina4.background(method(:health_check), interval: 30.0)
    def background(callback = nil, interval: 1.0, &block)
      Tina4::Background.register(callback, interval: interval, &block)
    end

    # DI container shortcuts
    def register(name, instance = nil, &block)
      Tina4::Container.register(name, instance, &block)
    end

    def singleton(name, &block)
      Tina4::Container.singleton(name, &block)
    end

    def resolve(name)
      Tina4::Container.get(name)
    end

    # Apply pending DB migrations on startup — NON-BREAKING. Public so it can be
    # called explicitly (and unit-tested) as `Tina4.auto_migrate_on_startup!`.
    #
    # When a migrations/ folder exists (with at least one .sql file) and
    # TINA4_AUTO_MIGRATE is not disabled, pending migrations are applied during
    # boot so the schema is current with no manual `tina4ruby migrate` step. A
    # failure here is logged LOUD and the service STILL starts — a bad migration
    # must never take the backend down. (The explicit `tina4ruby migrate` CLI
    # stays fail-fast so CI still gets a non-zero exit.)
    #
    # Disable with TINA4_AUTO_MIGRATE=false (also 0/no/off) — e.g. multi-instance
    # production that migrates as a separate deploy step (concurrent first-apply
    # can race).
    def auto_migrate_on_startup!(root_dir = Dir.pwd)
      # Gate 1: a migrations folder with at least one .sql file must exist.
      migrations_dir = resolve_startup_migrations_dir(root_dir)
      return unless migrations_dir

      # Gate 2: TINA4_AUTO_MIGRATE not disabled (default "true"; false/0/no/off off).
      unless Tina4::Env.is_truthy(ENV.fetch("TINA4_AUTO_MIGRATE", "true"))
        Tina4::Log.debug("TINA4_AUTO_MIGRATE is off — skipping startup migrations")
        return
      end

      # Gate 3: a database must be resolvable.
      db = Tina4.database
      unless db
        Tina4::Log.debug("Startup migrations skipped (no database configured)")
        return
      end

      begin
        migration = Tina4::Migration.new(db, migrations_dir: migrations_dir)
        results = migration.run
        applied = Array(results).count { |r| r[:status] == "success" }
        Tina4::Log.info("Applied #{applied} pending migration(s) on startup") if applied.positive?
        # A migration that records as "failed" surfaces in `run`'s results but
        # does NOT raise from the runner; treat a recorded failure as loud-log too.
        if Array(results).any? { |r| r[:status] == "failed" }
          Tina4::Log.error(
            "Startup auto-migration failed — the service is starting anyway. " \
            "Run `tina4ruby migrate` to retry."
          )
        end
      rescue => e
        # NON-BREAKING: never re-raise out of the startup hook.
        Tina4::Log.error(
          "Startup auto-migration failed: #{e.message} — the service is starting " \
          "anyway. Run `tina4ruby migrate` to retry."
        )
      end
    end

    private

    # Resolve the migrations directory for startup auto-migration, returning it
    # only when it exists AND contains at least one .sql file. Prefers
    # src/migrations, falls back to migrations/ (mirrors Migration#resolve_migrations_dir).
    def resolve_startup_migrations_dir(root_dir)
      %w[src/migrations migrations].each do |rel|
        dir = File.join(root_dir, rel)
        next unless Dir.exist?(dir)
        return dir unless Dir.glob(File.join(dir, "*.sql")).empty?
      end
      nil
    end

    # Resolve auth option for route registration
    # :default => use bearer auth (default for POST/PUT/PATCH/DELETE)
    # false    => no auth (public route)
    # nil      => no auth
    # Proc/Lambda => custom auth handler
    def resolve_auth(auth)
      case auth
      when :default
        Tina4::Auth.default_secure_auth
      when false, nil
        nil
      else
        auth  # Custom auth handler (proc/lambda)
      end
    end

    def autowire_i18n_template_global
      # Only register if translations were actually loaded
      return if Tina4::Localization.translations.empty?

      # Don't overwrite a user-registered t() global
      return if Tina4::Template.globals.key?("t")

      Tina4::Template.add_global("t", ->(key, **opts) { Tina4::Localization.t(key, **opts) })
      Tina4::Log.debug("Auto-wired i18n t() as template global")
    end

    def setup_database
      db_url = ENV["TINA4_DATABASE_URL"]
      if db_url && !db_url.empty?
        begin
          bind_database(Tina4::Database.new(db_url))
          Tina4::Log.info("Database connected: #{db_url.sub(/:[^:@]+@/, ':***@')}")
        rescue => e
          Tina4::Log.error("Database connection failed: #{e.message}")
        end
      end
    end

    def auto_discover(root_dir)
      # src/ prefixed directories take priority over root-level ones
      discover_dirs = %w[src/routes routes src/api api src/orm orm]
      discover_dirs.each do |dir|
        full_dir = File.join(root_dir, dir)
        next unless Dir.exist?(full_dir)

        Dir.glob(File.join(full_dir, "**/*.rb")).sort.each do |file|
          begin
            load file
            Tina4::Log.debug("Auto-loaded: #{file}")
          rescue => e
            Tina4::Log.error("Failed to load #{file}: #{e.message}")
          end
        end
      end
    end
  end
end
