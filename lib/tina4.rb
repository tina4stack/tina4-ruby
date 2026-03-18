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
require_relative "tina4/debug"
require_relative "tina4/env"
require_relative "tina4/router"
require_relative "tina4/request"
require_relative "tina4/response"
require_relative "tina4/rack_app"
require_relative "tina4/database"
require_relative "tina4/database_result"
require_relative "tina4/field_types"
require_relative "tina4/orm"
require_relative "tina4/migration"
require_relative "tina4/template"
require_relative "tina4/auth"
require_relative "tina4/session"
require_relative "tina4/middleware"
require_relative "tina4/localization"
require_relative "tina4/queue"

module Tina4
  # ── Lazy-loaded: database drivers ─────────────────────────────────────
  module Drivers
    autoload :SqliteDriver,   File.expand_path("tina4/drivers/sqlite_driver", __dir__)
    autoload :PostgresDriver, File.expand_path("tina4/drivers/postgres_driver", __dir__)
    autoload :MysqlDriver,    File.expand_path("tina4/drivers/mysql_driver", __dir__)
    autoload :MssqlDriver,    File.expand_path("tina4/drivers/mssql_driver", __dir__)
    autoload :FirebirdDriver, File.expand_path("tina4/drivers/firebird_driver", __dir__)
  end

  # ── Lazy-loaded: session handlers ─────────────────────────────────────
  module SessionHandlers
    autoload :FileHandler,  File.expand_path("tina4/session_handlers/file_handler", __dir__)
    autoload :RedisHandler, File.expand_path("tina4/session_handlers/redis_handler", __dir__)
    autoload :MongoHandler, File.expand_path("tina4/session_handlers/mongo_handler", __dir__)
  end

  # ── Lazy-loaded: queue backends ───────────────────────────────────────
  module QueueBackends
    autoload :LiteBackend,     File.expand_path("tina4/queue_backends/lite_backend", __dir__)
    autoload :RabbitmqBackend, File.expand_path("tina4/queue_backends/rabbitmq_backend", __dir__)
    autoload :KafkaBackend,    File.expand_path("tina4/queue_backends/kafka_backend", __dir__)
  end

  # ── Lazy-loaded: web server ───────────────────────────────────────────
  autoload :WebServer, File.expand_path("tina4/webserver", __dir__)

  # ── Lazy-loaded: optional modules ─────────────────────────────────────
  autoload :Swagger,             File.expand_path("tina4/swagger", __dir__)
  autoload :Crud,                File.expand_path("tina4/crud", __dir__)
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
  autoload :DevReload,           File.expand_path("tina4/dev_reload", __dir__)
  autoload :FakeData,            File.expand_path("tina4/seeder", __dir__)
  autoload :Seeder,              File.expand_path("tina4/seeder", __dir__)
  autoload :WSDL,                File.expand_path("tina4/wsdl", __dir__)
  BANNER = <<~'BANNER'

    ████████╗██╗███╗   ██╗ █████╗ ██╗  ██╗
    ╚══██╔══╝██║████╗  ██║██╔══██╗██║  ██║
       ██║   ██║██╔██╗ ██║███████║███████║
       ██║   ██║██║╚██╗██║██╔══██║╚════██║
       ██║   ██║██║ ╚████║██║  ██║     ██║
       ╚═╝   ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝     ╚═╝
  BANNER

  class << self
    attr_accessor :root_dir, :database

    def print_banner
      puts "\e[35m#{BANNER}\e[0m"
      puts "    \e[35mTina4 Ruby v#{VERSION} - This is not a framework\e[0m"
      puts ""
    rescue
      puts "\e[35mTINA4 Ruby v#{VERSION}\e[0m"
    end

    def initialize!(root_dir = Dir.pwd)
      @root_dir = root_dir

      # Print banner
      print_banner

      # Load environment
      Tina4::Env.load(root_dir)

      # Setup debug logging
      Tina4::Debug.setup(root_dir)
      Tina4::Debug.info("Tina4 Ruby v#{VERSION} initializing...")

      # Setup auth keys
      Tina4::Auth.setup(root_dir)

      # Load translations
      Tina4::Localization.load(root_dir)

      # Connect database if configured
      setup_database

      # Auto-discover routes
      auto_discover(root_dir)

      Tina4::Debug.info("Tina4 initialized successfully")
    end

    # DSL methods for route registration
    # GET is public by default (matching tina4_python behavior)
    # POST/PUT/PATCH/DELETE are secured by default — use auth: false to make public
    def get(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth == false ? nil : auth
      Tina4::Router.add_route("GET", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def post(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add_route("POST", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def put(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add_route("PUT", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def patch(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add_route("PATCH", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def delete(path, auth: :default, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      Tina4::Router.add_route("DELETE", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def any(path, auth: false, swagger_meta: {}, &block)
      auth_handler = resolve_auth(auth)
      %w[GET POST PUT PATCH DELETE].each do |method|
        Tina4::Router.add_route(method, path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
      end
    end

    def options(path, &block)
      Tina4::Router.add_route("OPTIONS", path, block)
    end

    # Explicit secure variants (always secured, regardless of HTTP method)
    def secure_get(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add_route("GET", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_post(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add_route("POST", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_put(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add_route("PUT", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_patch(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add_route("PATCH", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    def secure_delete(path, auth: nil, swagger_meta: {}, &block)
      auth_handler = auth || Tina4::Auth.default_secure_auth
      Tina4::Router.add_route("DELETE", path, block, auth_handler: auth_handler, swagger_meta: swagger_meta)
    end

    # Route groups
    def group(prefix, auth: nil, &block)
      Tina4::Router.group(prefix, auth_handler: auth, &block)
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

    def setup_database
      db_url = ENV["DATABASE_URL"] || ENV["DB_URL"]
      if db_url && !db_url.empty?
        begin
          @database = Tina4::Database.new(db_url)
          Tina4::Debug.info("Database connected: #{db_url.sub(/:[^:@]+@/, ':***@')}")
        rescue => e
          Tina4::Debug.error("Database connection failed: #{e.message}")
        end
      end
    end

    def auto_discover(root_dir)
      route_dirs = %w[routes src/routes src/api api]
      route_dirs.each do |dir|
        full_dir = File.join(root_dir, dir)
        next unless Dir.exist?(full_dir)

        Dir.glob(File.join(full_dir, "**/*.rb")).sort.each do |file|
          begin
            load file
            Tina4::Debug.debug("Auto-loaded: #{file}")
          rescue => e
            Tina4::Debug.error("Failed to load #{file}: #{e.message}")
          end
        end
      end
    end
  end
end
