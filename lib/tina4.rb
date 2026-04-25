# frozen_string_literal: true

# ── Fast JSON: use oj if available, fall back to stdlib json ──────────
begin
  require "oj"
  Oj.default_options = { mode: :compat, symbol_keys: false }
rescue LoadError
  # oj not installed — stdlib json is fine
end

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
require_relative "tina4/queue"
require_relative "tina4/service_runner"
require_relative "tina4/events"
require_relative "tina4/plan"
require_relative "tina4/project_index"
require_relative "tina4/dev_admin"
require_relative "tina4/messenger"
require_relative "tina4/dev_mailbox"
require_relative "tina4/ai"
require_relative "tina4/cache"
require_relative "tina4/sql_translation"
require_relative "tina4/response_cache"
require_relative "tina4/html_element"
require_relative "tina4/error_overlay"
require_relative "tina4/test_client"
require_relative "tina4/docs"
require_relative "tina4/mcp"

module Tina4
  # ── Lazy-loaded: database drivers ─────────────────────────────────────
  module Drivers
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
  autoload :Testing,             File.expand_path("tina4/testing", __dir__)
  autoload :ScssCompiler,        File.expand_path("tina4/scss_compiler", __dir__)
  autoload :FakeData,            File.expand_path("tina4/seeder", __dir__)
  autoload :WSDL,                File.expand_path("tina4/wsdl", __dir__)
  BANNER = <<~'BANNER'

  ______ _             __ __
 /_  __/(_)___  ____ _/ // /
  / /  / / __ \/ __ `/ // /_
 / /  / / / / / /_/ /__  __/
/_/  /_/_/ /_/\__,_/  /_/
  BANNER

  class << self
    attr_accessor :root_dir, :database

    def print_banner(host: "0.0.0.0", port: 7147, server_name: nil)
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
      puts "  Swagger:   http://localhost:#{port}/swagger"
      puts "  Dashboard: http://localhost:#{port}/__dev"
      puts "  Debug:     #{is_debug ? 'ON' : 'OFF'} (Log level: #{log_level})"
      puts ""
    rescue
      puts "#{color}TINA4 Ruby v#{VERSION}#{reset}"
    end

    def initialize!(root_dir = Dir.pwd)
      @root_dir = root_dir

      # Print banner
      print_banner

      # Load environment
      Tina4::Env.load_env(root_dir)

      # Setup debug logging
      Tina4::Log.configure(root_dir)
      Tina4::Log.info("Tina4 Ruby v#{VERSION} initializing...")

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

    # WebSocket route registration
    def websocket(path, &block)
      Tina4::Router.websocket(path, &block)
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

    private

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
      db_url = ENV["DATABASE_URL"] || ENV["DB_URL"]
      if db_url && !db_url.empty?
        begin
          @database = Tina4::Database.new(db_url)
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
