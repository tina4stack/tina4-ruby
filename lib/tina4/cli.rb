# frozen_string_literal: true

require "optparse"
require "fileutils"

module Tina4
  class CLI
    COMMANDS = %w[init start migrate migrate:status migrate:rollback seed seed:create test version routes console generate ai help].freeze

    # ── Field type mapping ──────────────────────────────────────────────
    FIELD_TYPE_MAP = {
      "string"   => { orm: "string_field",  sql: "VARCHAR(255)", default: "''" },
      "str"      => { orm: "string_field",  sql: "VARCHAR(255)", default: "''" },
      "int"      => { orm: "integer_field", sql: "INTEGER",      default: "0" },
      "integer"  => { orm: "integer_field", sql: "INTEGER",      default: "0" },
      "float"    => { orm: "float_field",   sql: "REAL",         default: "0" },
      "numeric"  => { orm: "float_field",   sql: "REAL",         default: "0" },
      "decimal"  => { orm: "float_field",   sql: "REAL",         default: "0" },
      "bool"     => { orm: "boolean_field", sql: "INTEGER",      default: "0" },
      "boolean"  => { orm: "boolean_field", sql: "INTEGER",      default: "0" },
      "text"     => { orm: "string_field",  sql: "TEXT",         default: "''" },
      "datetime" => { orm: "string_field",  sql: "TEXT",         default: "NULL" },
      "blob"     => { orm: "string_field",  sql: "BLOB",         default: "NULL" },
    }.freeze

    def self.start(argv)
      new.run(argv)
    end

    def run(argv)
      command = argv.shift || "help"
      case command
      when "init"       then cmd_init(argv)
      when "start", "serve" then cmd_start(argv)
      when "migrate"    then cmd_migrate(argv)
      when "migrate:status" then cmd_migrate_status(argv)
      when "migrate:rollback" then cmd_migrate_rollback(argv)
      when "seed"       then cmd_seed(argv)
      when "seed:create" then cmd_seed_create(argv)
      when "test"       then cmd_test(argv)
      when "version"    then cmd_version
      when "routes"     then cmd_routes
      when "console"    then cmd_console
      when "generate"   then cmd_generate(argv)
      when "ai"         then cmd_ai(argv)
      when "help", "-h", "--help" then cmd_help
      else
        puts "Unknown command: #{command}"
        cmd_help
        exit 1
      end
    end

    private

    # ── Helpers ──────────────────────────────────────────────────────────

    # CamelCase -> snake_case: ProductCategory -> product_category
    def to_snake_case(name)
      name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
          .downcase
    end

    # Class name -> singular table name: Product -> product
    def to_table_name(name)
      to_snake_case(name)
    end

    # Parse "name:string,price:float" -> [["name","string"], ["price","float"]]
    def parse_fields(fields_str)
      return [] if fields_str.nil? || fields_str.strip.empty?

      fields_str.split(",").map do |part|
        part = part.strip
        if part.include?(":")
          name, type = part.split(":", 2)
          [name.strip, type.strip.downcase]
        elsif !part.empty?
          [part.strip, "string"]
        end
      end.compact
    end

    # Parse --key value and --flag from args. Returns [flags_hash, positional_array]
    def parse_flags(args)
      flags = {}
      positional = []
      i = 0
      while i < args.length
        if args[i].start_with?("--")
          key = args[i][2..]
          if i + 1 < args.length && !args[i + 1].start_with?("--")
            flags[key] = args[i + 1]
            i += 2
          else
            flags[key] = true
            i += 1
          end
        else
          positional << args[i]
          i += 1
        end
      end
      [flags, positional]
    end

    # Kill any process listening on the given port. Returns true if killed.
    def kill_process_on_port(port)
      result = `lsof -ti :#{port} 2>/dev/null`.strip
      return false if result.empty?

      pids = result.split("\n")
      pids.each do |pid|
        Process.kill("TERM", pid.to_i)
      rescue Errno::ESRCH, Errno::EPERM
        # Process already gone or no permission
      end
      sleep 0.5
      puts "  Killed existing process on port #{port} (PID: #{pids.join(', ')})"
      true
    rescue Errno::ENOENT
      false
    end

    # ── init ──────────────────────────────────────────────────────────────

    def cmd_init(argv)
      options = { template: "default" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby init [PATH] [options]"
        opts.on("--template TEMPLATE", "Project template (default: default)") { |v| options[:template] = v }
      end
      parser.parse!(argv)

      name = argv.shift || "."
      dir = File.expand_path(name)
      FileUtils.mkdir_p(dir)

      project_name = File.basename(dir)
      create_project_structure(dir)
      create_sample_files(dir, project_name)

      puts "\nProject scaffolded at #{dir}"
      if name == "."
        puts "  bundle install"
        puts "  ruby app.rb"
      else
        puts "  cd #{dir}"
        puts "  bundle install"
        puts "  ruby app.rb"
      end
    end

    # ── start ─────────────────────────────────────────────────────────────

    def cmd_start(argv)
      options = { port: nil, host: nil, dev: false, no_browser: false, no_reload: false, production: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby start [options]"
        opts.on("-p", "--port PORT", Integer, "Port (default: 7147)") { |v| options[:port] = v }
        opts.on("-h", "--host HOST", "Host (default: 0.0.0.0)") { |v| options[:host] = v }
        opts.on("-d", "--dev", "Enable dev mode with auto-reload") { options[:dev] = true }
        opts.on("--production", "Use production server (Puma)") { options[:production] = true }
        opts.on("--no-browser", "Do not open browser on start") { options[:no_browser] = true }
        opts.on("--no-reload", "Disable file watcher / live-reload") { options[:no_reload] = true }
      end
      parser.parse!(argv)

      # --no-browser from env (TINA4_NO_BROWSER=true)
      no_browser_env = ENV.fetch("TINA4_NO_BROWSER", "").downcase
      if no_browser_env.match?(/\A(true|1|yes)\z/)
        options[:no_browser] = true
      end

      # --no-reload flag sets TINA4_NO_RELOAD so the existing env check picks it up
      if options[:no_reload]
        ENV["TINA4_NO_RELOAD"] = "true"
      end

      # Priority: CLI flag > ENV var > default
      options[:port] = resolve_config(:port, options[:port])
      options[:host] = resolve_config(:host, options[:host])

      # Kill existing process on port
      kill_process_on_port(options[:port])

      require_relative "../tina4"

      root_dir = Dir.pwd
      Tina4.initialize!(root_dir)

      # Register health check endpoint
      Tina4::Health.register!

      # Load route files
      load_routes(root_dir)

      # File watching is handled by the Rust CLI (tina4 serve). The framework
      # only needs POST /__dev/api/reload to update the mtime counter for browser polling.
      # No internal file watcher.

      app = Tina4::RackApp.new(root_dir: root_dir)

      is_debug = Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])

      # Use Puma only when explicitly requested via --production flag
      # WEBrick is used for development (supports dev toolbar/reload)
      if options[:production]
        begin
          require "puma"
          require "puma/configuration"
          require "puma/launcher"

          puma_host = options[:host]
          puma_port = options[:port]

          config = Puma::Configuration.new do |user_config|
            user_config.bind "tcp://#{puma_host}:#{puma_port}"
            user_config.app app
            user_config.threads 0, 16
            user_config.workers 0
            user_config.environment "production"
            user_config.log_requests false
            user_config.quiet
          end

          Tina4::Log.info("Production server: puma")

          # Setup graceful shutdown (Puma manages its own signals, but we handle DB cleanup)
          Tina4::Shutdown.setup

          launcher = Puma::Launcher.new(config)
          launcher.run
          return
        rescue LoadError
          # Puma not installed, fall through to WEBrick
        end
      end

      Tina4::Log.info("Development server: WEBrick")
      server = Tina4::WebServer.new(app, host: options[:host], port: options[:port])
      server.start
    end

    # ── migrate ───────────────────────────────────────────────────────────

    def cmd_migrate(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby migrate [options]"
        opts.on("--create NAME", "Create a new migration") { |v| options[:create] = v }
        opts.on("--rollback N", Integer, "Rollback N migrations") { |v| options[:rollback] = v }
      end
      parser.parse!(argv)

      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)

      db = Tina4.database
      unless db
        puts "No database configured. Set DATABASE_URL in your .env file."
        return
      end

      migration = Tina4::Migration.new(db)

      if options[:create]
        path = migration.create(options[:create])
        puts "Created migration: #{path}"
      elsif options[:rollback]
        migration.rollback(options[:rollback])
        puts "Rolled back #{options[:rollback]} migration(s)"
      else
        results = migration.run
        if results.empty?
          puts "No pending migrations"
        else
          results.each do |r|
            status_icon = r[:status] == "success" ? "OK" : "FAIL"
            puts "  [#{status_icon}] #{r[:name]}"
          end
        end
      end
    end

    # ── migrate:status ─────────────────────────────────────────────────────

    def cmd_migrate_status(_argv)
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)

      db = Tina4.database
      unless db
        puts "No database configured. Set DATABASE_URL in your .env file."
        return
      end

      migration = Tina4::Migration.new(db)
      info = migration.status

      puts "\nMigration Status"
      puts "-" * 60

      if info[:completed].any?
        puts "\nCompleted:"
        info[:completed].each { |name| puts "  [OK] #{name}" }
      end

      if info[:pending].any?
        puts "\nPending:"
        info[:pending].each { |name| puts "  [  ] #{name}" }
      end

      if info[:completed].empty? && info[:pending].empty?
        puts "  No migrations found."
      end

      puts "-" * 60
      puts "  Completed: #{info[:completed].length}  Pending: #{info[:pending].length}\n"
    end

    # ── migrate:rollback ───────────────────────────────────────────────────

    def cmd_migrate_rollback(argv)
      options = { steps: 1 }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby migrate:rollback [options]"
        opts.on("-n", "--steps N", Integer, "Number of batches to rollback (default: 1)") { |v| options[:steps] = v }
      end
      parser.parse!(argv)

      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)

      db = Tina4.database
      unless db
        puts "No database configured. Set DATABASE_URL in your .env file."
        return
      end

      migration = Tina4::Migration.new(db)
      results = migration.rollback(options[:steps])

      if results.empty?
        puts "Nothing to rollback."
      else
        results.each do |r|
          status_icon = r[:status] == "rolled_back" ? "OK" : "FAIL"
          puts "  [#{status_icon}] #{r[:name]}"
        end
        puts "Rolled back #{results.length} migration(s)."
      end
    end

    # ── seed ──────────────────────────────────────────────────────────────

    def cmd_seed(argv)
      options = { clear: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby seed [options]"
        opts.on("--clear", "Clear tables before seeding") { options[:clear] = true }
      end
      parser.parse!(argv)

      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)
      load_routes(Dir.pwd)
      Tina4.seed_dir(seed_folder: "seeds", clear: options[:clear])
    end

    # ── seed:create ───────────────────────────────────────────────────────

    def cmd_seed_create(argv)
      name = argv.shift
      unless name
        puts "Usage: tina4ruby seed:create NAME"
        exit 1
      end

      dir = File.join(Dir.pwd, "seeds")
      FileUtils.mkdir_p(dir)

      existing = Dir.glob(File.join(dir, "*.rb")).select { |f| File.basename(f)[0] =~ /\d/ }.sort
      numbers = existing.map { |f| File.basename(f).match(/^(\d+)/)[1].to_i }
      next_num = numbers.empty? ? 1 : numbers.max + 1

      clean_name = name.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
      filename = format("%03d_%s.rb", next_num, clean_name)
      filepath = File.join(dir, filename)

      File.write(filepath, <<~RUBY)
        # Seed: #{name.strip}
        #
        # This file is executed by `tina4ruby seed`.
        # Use Tina4.seed_orm or Tina4.seed_table to populate data.
        #
        # Examples:
        #   Tina4.seed_orm(User, count: 50)
        #   Tina4.seed_table("audit_log", { action: :string, created_at: :datetime }, count: 100)
      RUBY

      puts "Created seed file: #{filepath}"
    end

    # ── test ──────────────────────────────────────────────────────────────

    def cmd_test(argv)
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)

      # Load test files
      test_dirs = %w[tests test spec src/tests]
      test_dirs.each do |dir|
        test_dir = File.join(Dir.pwd, dir)
        next unless Dir.exist?(test_dir)
        Dir.glob(File.join(test_dir, "**/*_test.rb")).sort.each { |f| load f }
        Dir.glob(File.join(test_dir, "**/test_*.rb")).sort.each { |f| load f }
      end

      # Also load inline tests from routes
      load_routes(Dir.pwd)

      results = Tina4::Testing.run_all
      exit(1) if results[:failed] > 0 || results[:errors] > 0
    end

    # ── version ───────────────────────────────────────────────────────────

    def cmd_version
      require_relative "version"
      puts "Tina4 Ruby v#{Tina4::VERSION}"
    end

    # ── routes ────────────────────────────────────────────────────────────

    def cmd_routes
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)
      load_routes(Dir.pwd)

      puts "\nRegistered Routes:"
      puts "-" * 60
      Tina4::Router.routes.each do |route|
        auth = route.auth_handler ? " [AUTH]" : ""
        puts "  #{route.method.ljust(8)} #{route.path}#{auth}"
      end
      puts "-" * 60
      puts "Total: #{Tina4::Router.routes.length} routes\n"
    end

    # ── console ───────────────────────────────────────────────────────────

    def cmd_console
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)
      load_routes(Dir.pwd)

      require "irb"
      IRB.start
    end

    # ── ai ────────────────────────────────────────────────────────────────

    def cmd_ai(argv)
      options = { all: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby ai [options]"
        opts.on("--all", "Install context for ALL AI tools (non-interactive)") { options[:all] = true }
      end
      parser.parse!(argv)

      require_relative "ai"

      root_dir = Dir.pwd

      if options[:all]
        Tina4::AI.install_all(root_dir)
      else
        selection = Tina4::AI.show_menu(root_dir)
        Tina4::AI.install_selected(root_dir, selection) unless selection.empty?
      end
    end

    # ── generate ────────────────────────────────────────────────────────

    def cmd_generate(argv)
      what = argv.shift

      unless what
        puts "Usage: tina4ruby generate <what> <name> [options]"
        puts "  Generators: model, route, crud, migration, middleware, test, form, view, auth"
        puts '  Options:    --fields "name:string,price:float"  --model ModelName'
        exit 1
      end

      # Auth doesn't require a name argument
      no_name_generators = %w[auth]
      unless no_name_generators.include?(what)
        if argv.empty? || argv.first.start_with?("--")
          puts "Usage: tina4ruby generate #{what} <name> [options]"
          exit 1
        end
      end

      name = no_name_generators.include?(what) ? "" : argv.shift
      flags, _positional = parse_flags(argv)

      case what
      when "model"      then generate_model(name, flags)
      when "route"      then generate_route(name, flags)
      when "crud"       then generate_crud(name, flags)
      when "migration"  then generate_migration(name, flags)
      when "middleware"  then generate_middleware(name, flags)
      when "test"       then generate_test(name, flags)
      when "form"       then generate_form(name, flags)
      when "view"       then generate_view(name, flags)
      when "auth"       then generate_auth(name, flags)
      else
        puts "Unknown generator: #{what}"
        puts "  Available: model, route, crud, migration, middleware, test, form, view, auth"
        exit 1
      end
    end

    # ── Generator: model ─────────────────────────────────────────────────

    def generate_model(name, flags)
      fields = parse_fields(flags["fields"])
      table = to_table_name(name)
      snake = to_snake_case(name)

      # Build field lines
      field_lines = ["  integer_field :id, primary_key: true, auto_increment: true"]
      if fields.any?
        fields.each do |fname, ftype|
          info = FIELD_TYPE_MAP[ftype] || FIELD_TYPE_MAP["string"]
          field_lines << "  #{info[:orm]} :#{fname}"
        end
      else
        field_lines << "  string_field :name"
      end
      field_lines << "  string_field :created_at"

      # Write model file
      dir = "src/orm"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{snake}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      content = <<~RUBY
        class #{name} < Tina4::ORM
          table_name "#{table}"

        #{field_lines.join("\n")}
        end
      RUBY

      File.write(path, content)
      puts "  Created #{path}"

      # Generate matching migration (unless --no-migration)
      unless flags["no-migration"]
        generate_migration("create_#{table}", flags, fields_override: fields, table_override: table)
      end
    end

    # ── Generator: route ─────────────────────────────────────────────────

    def generate_route(name, flags)
      route_path = name.sub(%r{^/}, "")
      singular = route_path.end_with?("s") ? route_path[0..-2] : route_path
      model = flags["model"]

      dir = "src/routes"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{route_path}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      if model
        model_snake = to_snake_case(model)
        content = <<~RUBY
          require_relative "../orm/#{model_snake}"

          Tina4.get "/api/#{route_path}" do |request, response|
            # List all #{route_path} with pagination
            page = (request.params["page"] || 1).to_i
            per_page = (request.params["per_page"] || 20).to_i
            offset = (page - 1) * per_page
            results = #{model}.all(limit: per_page, offset: offset)
            response.json({ data: results.map(&:to_h), page: page, per_page: per_page })
          end

          Tina4.get "/api/#{route_path}/{id:int}" do |request, response|
            # Get a single #{singular} by ID
            item = #{model}.find(request.params["id"])
            if item.nil?
              response.json({ error: "Not found" }, 404)
            else
              response.json(item.to_h)
            end
          end

          Tina4.post "/api/#{route_path}" do |request, response|
            # Create a new #{singular}
            item = #{model}.create(request.body)
            response.json(item.to_h, 201)
          end

          Tina4.put "/api/#{route_path}/{id:int}" do |request, response|
            # Update a #{singular} by ID
            item = #{model}.find(request.params["id"])
            if item.nil?
              response.json({ error: "Not found" }, 404)
            else
              request.body.each do |key, value|
                next if key.to_s == "id"
                setter = "#{'#'}{key}="
                item.send(setter, value) if item.respond_to?(setter)
              end
              item.save
              response.json(item.to_h)
            end
          end

          Tina4.delete "/api/#{route_path}/{id:int}" do |request, response|
            # Delete a #{singular} by ID
            item = #{model}.find(request.params["id"])
            if item.nil?
              response.json({ error: "Not found" }, 404)
            else
              item.delete
              response.json(nil, 204)
            end
          end
        RUBY
      else
        content = <<~RUBY
          Tina4.get "/api/#{route_path}" do |request, response|
            # List all #{route_path}
            response.json({ data: [] })
          end

          Tina4.get "/api/#{route_path}/{id:int}" do |request, response|
            # Get a single #{singular}
            response.json({ data: {} })
          end

          Tina4.post "/api/#{route_path}" do |request, response|
            # Create a new #{singular}
            response.json({ data: request.body }, 201)
          end

          Tina4.put "/api/#{route_path}/{id:int}" do |request, response|
            # Update a #{singular}
            response.json({ data: request.body })
          end

          Tina4.delete "/api/#{route_path}/{id:int}" do |request, response|
            # Delete a #{singular}
            response.json(nil, 204)
          end
        RUBY
      end

      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: crud ──────────────────────────────────────────────────

    def generate_crud(name, flags)
      table = to_table_name(name)
      route_name = "#{table}s"

      puts "\n  Generating CRUD for #{name}...\n"

      # 1. Model + migration
      generate_model(name, flags)

      # 2. Routes with model
      generate_route(route_name, { "model" => name })

      # 3. Form
      generate_form(name, flags)

      # 4. View (list + detail)
      generate_view(name, flags)

      # 5. Test
      generate_test(route_name, { "model" => name })

      puts "\n  CRUD generation complete for #{name}."
      puts "  Run: tina4ruby migrate"
      puts "  Visit: /swagger to see the API docs"
    end

    # ── Generator: migration ─────────────────────────────────────────────

    def generate_migration(name, flags = {}, fields_override: nil, table_override: nil)
      now = Time.now
      timestamp = now.strftime("%Y%m%d%H%M%S")
      dir = "migrations"
      FileUtils.mkdir_p(dir)

      # Determine table name
      if table_override
        table = table_override
      else
        table = name.sub(/^create_/, "").sub(/^add_/, "").sub(/^drop_/, "")
        table = to_snake_case(table)
      end

      # Build SQL columns from fields
      fields = fields_override || parse_fields(flags["fields"])
      is_create = name.start_with?("create_") || !fields_override.nil?

      filename = "#{timestamp}_#{name}.sql"
      path = File.join(dir, filename)

      if is_create
        col_lines = ["    id INTEGER PRIMARY KEY AUTOINCREMENT"]
        fields.each do |fname, ftype|
          info = FIELD_TYPE_MAP[ftype] || FIELD_TYPE_MAP["string"]
          default = info[:default] != "NULL" ? " DEFAULT #{info[:default]}" : ""
          col_lines << "    #{fname} #{info[:sql]}#{default}"
        end
        col_lines << "    created_at TEXT DEFAULT CURRENT_TIMESTAMP"

        up_sql = "CREATE TABLE IF NOT EXISTS #{table} (\n#{col_lines.join(",\n")}\n);"
        down_sql = "DROP TABLE IF EXISTS #{table};"
      else
        up_sql = "-- Write your UP migration SQL here\n-- Example: ALTER TABLE #{table} ADD COLUMN new_col TEXT DEFAULT '';"
        down_sql = "-- Write your DOWN rollback SQL here\n-- Example: ALTER TABLE #{table} DROP COLUMN new_col;"
      end

      content = <<~SQL
        -- Migration: #{name}
        -- Created: #{now.strftime("%Y-%m-%d %H:%M:%S")}

        -- UP
        #{up_sql}

        -- DOWN
        #{down_sql}
      SQL

      File.write(path, content)
      puts "  Created #{path}"

      # Also create .down.sql for the migration runner
      down_path = File.join(dir, "#{timestamp}_#{name}.down.sql")
      down_content = <<~SQL
        -- Rollback: #{name}
        -- Created: #{now.strftime("%Y-%m-%d %H:%M:%S")}

        #{down_sql}
      SQL

      File.write(down_path, down_content)
      puts "  Created #{down_path}"
    end

    # ── Generator: middleware ────────────────────────────────────────────

    def generate_middleware(name, flags = {})
      snake = to_snake_case(name)
      dir = "src/middleware"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{snake}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      content = <<~RUBY
        # #{name} middleware
        #
        # Usage in routes:
        #   require_relative "../middleware/#{snake}"
        #   Tina4.get "/api/protected", middleware: [#{name}] do |request, response|
        #     response.json({ data: "protected" })
        #   end

        class #{name}
          def self.before_#{snake}(request, response)
            # Runs before the route handler.
            # Return [request, response] to continue, or
            # return [request, response.json({ error: "Unauthorized" }, 401)] to block.
            Tina4::Log.info("#{name}: \#{request.request_method} \#{request.path}")
            [request, response]
          end

          def self.after_#{snake}(request, response)
            # Runs after the route handler.
            [request, response]
          end
        end
      RUBY

      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: test ──────────────────────────────────────────────────

    def generate_test(name, flags = {})
      model = flags["model"]
      snake = to_snake_case(name)
      singular = snake.end_with?("s") ? snake[0..-2] : snake

      dir = "spec"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{snake}_spec.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      if model
        content = <<~RUBY
          # Tests for #{name} CRUD operations
          RSpec.describe "#{model}" do
            before(:each) do
              # Set up test fixtures
            end

            after(:each) do
              # Clean up after tests
            end

            it "lists #{snake}" do
              # TODO: implement
              expect(true).to be true
            end

            it "gets a single #{singular}" do
              # TODO: implement
              expect(true).to be true
            end

            it "creates a #{singular}" do
              # TODO: implement
              expect(true).to be true
            end

            it "updates a #{singular}" do
              # TODO: implement
              expect(true).to be true
            end

            it "deletes a #{singular}" do
              # TODO: implement
              expect(true).to be true
            end
          end
        RUBY
      else
        class_name = name.split("_").map(&:capitalize).join
        content = <<~RUBY
          # Tests for #{name}
          RSpec.describe "#{class_name}" do
            before(:each) do
              # Set up test fixtures
            end

            after(:each) do
              # Clean up after tests
            end

            it "works as expected" do
              # TODO: replace with real tests
              expect(true).to be true
            end
          end
        RUBY
      end

      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: form ──────────────────────────────────────────────────

    def generate_form(name, flags = {})
      fields = parse_fields(flags["fields"])
      table = to_table_name(name)
      route_name = "#{table}s"

      # Input type mapping
      input_types = {
        "string" => "text", "str" => "text", "text" => "textarea",
        "int" => "number", "integer" => "number",
        "float" => "number", "numeric" => "number", "decimal" => "number",
        "bool" => "checkbox", "boolean" => "checkbox",
        "datetime" => "datetime-local", "blob" => "file",
      }

      dir = "src/templates/forms"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{table}.twig")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      # Build form fields
      field_html = ""
      form_fields = fields.any? ? fields : [["name", "string"]]
      form_fields.each do |fname, ftype|
        itype = input_types[ftype] || "text"
        label = fname.tr("_", " ").split.map(&:capitalize).join(" ")
        step = %w[float numeric decimal].include?(ftype) ? ' step="0.01"' : ""

        if itype == "textarea"
          field_html += <<~HTML
                <div class="form-group mb-3">
                    <label for="#{fname}">#{label}</label>
                    <textarea id="#{fname}" name="#{fname}" class="form-control" rows="4" placeholder="#{label}">{{ item.#{fname} }}</textarea>
                </div>
          HTML
        elsif itype == "checkbox"
          field_html += <<~HTML
                <div class="form-group mb-3">
                    <label>
                        <input type="checkbox" id="#{fname}" name="#{fname}" value="1" {% if item.#{fname} %}checked{% endif %}>
                        #{label}
                    </label>
                </div>
          HTML
        else
          field_html += <<~HTML
                <div class="form-group mb-3">
                    <label for="#{fname}">#{label}</label>
                    <input type="#{itype}" id="#{fname}" name="#{fname}" class="form-control"#{step} value="{{ item.#{fname} }}" placeholder="#{label}">
                </div>
          HTML
        end
      end

      content = <<~HTML
        {% extends "base.twig" %}
        {% block title %}#{name} {% if item.id %}Edit{% else %}Create{% endif %}{% endblock %}
        {% block content %}
        <div class="container mt-4">
            <h1>{% if item.id %}Edit #{name}{% else %}Create #{name}{% endif %}</h1>
            <form method="post" action="/api/#{route_name}{% if item.id %}/{{ item.id }}{% endif %}">
                {{ form_token() }}
        #{field_html}        <button type="submit" class="btn btn-primary">
                    {% if item.id %}Update{% else %}Create{% endif %}
                </button>
                <a href="/api/#{route_name}" class="btn btn-secondary">Cancel</a>
            </form>
        </div>
        {% endblock %}
      HTML

      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: view ──────────────────────────────────────────────────

    def generate_view(name, flags = {})
      fields = parse_fields(flags["fields"])
      table = to_table_name(name)
      route_name = "#{table}s"

      cols = fields.any? ? fields.map { |f, _| f } : ["name"]

      dir = "src/templates/pages"
      FileUtils.mkdir_p(dir)

      # List view
      list_path = File.join(dir, "#{route_name}.twig")
      unless File.exist?(list_path)
        th = cols.map { |c| "<th>#{c.tr('_', ' ').split.map(&:capitalize).join(' ')}</th>" }.join("\n                ")
        td = cols.map { |c| "<td>{{ item.#{c} }}</td>" }.join("\n                ")

        list_content = <<~HTML
          {% extends "base.twig" %}
          {% block title %}#{name}s{% endblock %}
          {% block content %}
          <div class="container mt-4">
              <div class="d-flex justify-content-between align-items-center mb-3">
                  <h1>#{name}s</h1>
                  <a href="/#{route_name}/create" class="btn btn-primary">Add #{name}</a>
              </div>
              <table class="table">
                  <thead>
                      <tr>
                          <th>ID</th>
                          #{th}
                          <th>Actions</th>
                      </tr>
                  </thead>
                  <tbody>
                  {% for item in items %}
                      <tr>
                          <td>{{ item.id }}</td>
                          #{td}
                          <td>
                              <a href="/#{route_name}/{{ item.id }}" class="btn btn-sm btn-primary">View</a>
                              <a href="/#{route_name}/{{ item.id }}/edit" class="btn btn-sm btn-secondary">Edit</a>
                          </td>
                      </tr>
                  {% endfor %}
                  </tbody>
              </table>
          </div>
          {% endblock %}
        HTML

        File.write(list_path, list_content)
        puts "  Created #{list_path}"
      end

      # Detail view
      detail_path = File.join(dir, "#{table}.twig")
      unless File.exist?(detail_path)
        detail_fields = cols.map do |c|
          "    <div class=\"mb-3\"><strong>#{c.tr('_', ' ').split.map(&:capitalize).join(' ')}:</strong> {{ item.#{c} }}</div>"
        end.join("\n")

        detail_content = <<~HTML
          {% extends "base.twig" %}
          {% block title %}#{name} Detail{% endblock %}
          {% block content %}
          <div class="container mt-4">
              <div class="d-flex justify-content-between align-items-center mb-3">
                  <h1>#{name} \#{{ item.id }}</h1>
                  <div>
                      <a href="/#{route_name}/{{ item.id }}/edit" class="btn btn-secondary">Edit</a>
                      <a href="/#{route_name}" class="btn btn-outline-secondary">Back</a>
                  </div>
              </div>
          #{detail_fields}
          </div>
          {% endblock %}
        HTML

        File.write(detail_path, detail_content)
        puts "  Created #{detail_path}"
      end
    end

    # ── Generator: auth ──────────────────────────────────────────────────

    def generate_auth(_name = nil, flags = {})
      puts "\n  Generating authentication scaffolding...\n"

      # 1. User model + migration
      generate_model("User", { "fields" => "email:string,password:string,role:string" })

      # 2. Auth routes
      dir = "src/routes"
      FileUtils.mkdir_p(dir)
      auth_path = File.join(dir, "auth.rb")
      unless File.exist?(auth_path)
        content = <<~'RUBY'
          require_relative "../orm/user"

          Tina4.post "/api/auth/register" do |request, response|
            # Register a new user
            email = request.body["email"].to_s
            password = request.body["password"].to_s

            if email.empty? || password.empty?
              next response.json({ error: "Email and password required" }, 400)
            end

            # Check if user exists
            existing = User.where("email = ?", [email])
            unless existing.empty?
              next response.json({ error: "Email already registered" }, 409)
            end

            # Create user with hashed password
            user = User.create({
              email: email,
              password: Tina4::Auth.hash_password(password),
              role: "user",
            })
            response.json({ message: "Registered", id: user.id }, 201)
          end

          Tina4.post "/api/auth/login" do |request, response|
            # Login with email and password
            email = request.body["email"].to_s
            password = request.body["password"].to_s

            users = User.where("email = ?", [email])
            if users.empty?
              next response.json({ error: "Invalid credentials" }, 401)
            end
            user = users.first

            unless Tina4::Auth.check_password(password, user.password)
              next response.json({ error: "Invalid credentials" }, 401)
            end

            token = Tina4::Auth.get_token({ user_id: user.id, email: user.email, role: user.role })
            response.json({ token: token })
          end

          Tina4.get "/api/auth/me" do |request, response|
            # Get current authenticated user
            payload = Tina4::Auth.authenticate_request(request.headers)
            if payload.nil?
              next response.json({ error: "Unauthorized" }, 401)
            end

            user = User.find(payload["user_id"])
            if user.nil?
              next response.json({ error: "User not found" }, 404)
            end

            response.json({ id: user.id, email: user.email, role: user.role })
          end
        RUBY

        File.write(auth_path, content)
        puts "  Created #{auth_path}"
      end

      # 3. Login template
      forms_dir = "src/templates/forms"
      FileUtils.mkdir_p(forms_dir)
      login_path = File.join(forms_dir, "login.twig")
      unless File.exist?(login_path)
        File.write(login_path, <<~HTML)
          {% extends "base.twig" %}
          {% block title %}Login{% endblock %}
          {% block content %}
          <div class="container mt-4" style="max-width:400px">
              <h1>Login</h1>
              <form method="post" action="/api/auth/login">
                  {{ form_token() }}
                  <div class="form-group mb-3">
                      <label for="email">Email</label>
                      <input type="email" id="email" name="email" class="form-control" placeholder="Email" required>
                  </div>
                  <div class="form-group mb-3">
                      <label for="password">Password</label>
                      <input type="password" id="password" name="password" class="form-control" placeholder="Password" required>
                  </div>
                  <button type="submit" class="btn btn-primary w-100">Login</button>
                  <p class="mt-3 text-center"><a href="/register">Create an account</a></p>
              </form>
          </div>
          {% endblock %}
        HTML
        puts "  Created #{login_path}"
      end

      # 4. Register template
      register_path = File.join(forms_dir, "register.twig")
      unless File.exist?(register_path)
        File.write(register_path, <<~HTML)
          {% extends "base.twig" %}
          {% block title %}Register{% endblock %}
          {% block content %}
          <div class="container mt-4" style="max-width:400px">
              <h1>Register</h1>
              <form method="post" action="/api/auth/register">
                  {{ form_token() }}
                  <div class="form-group mb-3">
                      <label for="email">Email</label>
                      <input type="email" id="email" name="email" class="form-control" placeholder="Email" required>
                  </div>
                  <div class="form-group mb-3">
                      <label for="password">Password</label>
                      <input type="password" id="password" name="password" class="form-control" placeholder="Password" minlength="8" required>
                  </div>
                  <button type="submit" class="btn btn-primary w-100">Register</button>
                  <p class="mt-3 text-center"><a href="/login">Already have an account?</a></p>
              </form>
          </div>
          {% endblock %}
        HTML
        puts "  Created #{register_path}"
      end

      # 5. Auth test
      generate_test("auth", { "model" => "User" })

      puts "\n  Authentication scaffolding complete."
      puts "  Run: tina4ruby migrate"
      puts "  POST /api/auth/register  - create account"
      puts "  POST /api/auth/login     - get JWT token"
      puts "  GET  /api/auth/me        - get profile (requires token)"
    end

    # ── help ──────────────────────────────────────────────────────────────

    def cmd_help
      puts <<~HELP
        Tina4 Ruby CLI

        Usage: tina4ruby COMMAND [options]

        Commands:
          init [NAME]        Initialize a new Tina4 project
          start              Start the Tina4 web server
          serve              Alias for start
          migrate            Run database migrations
          migrate:status     Show migration status (completed and pending)
          migrate:rollback   Rollback the last batch of migrations
          seed               Run all seed files in seeds/
          seed:create NAME   Create a new seed file
          test               Run inline tests
          version            Show Tina4 version
          routes             List all registered routes
          console            Start an interactive console
          ai                 Detect AI tools and install context files
          help               Show this help message

        Generators:
          generate model <Name> [--fields "name:string,price:float"]
          generate route <name> [--model Name]
          generate crud <Name> [--fields "..."]   Model + migration + routes + form + view + test
          generate migration <description>
          generate middleware <Name>
          generate test <name>
          generate form <Name> [--fields "..."]   Form template with inputs matching model fields
          generate view <Name> [--fields "..."]   List + detail templates for viewing records
          generate auth                           Login/register/logout routes + User model + templates

        Field types: string, int, float, bool, text, datetime, blob
        Table names: singular by default (Product -> product)

        https://tina4.com

        Run 'tina4ruby COMMAND --help' for more information on a command.
      HELP
    end

    # ── config resolution ──────────────────────────────────────────────────

    DEFAULT_PORT = 7147
    DEFAULT_HOST = "0.0.0.0"

    # Priority: CLI flag > ENV var > default
    def resolve_config(key, cli_value)
      case key
      when :port
        return cli_value if cli_value
        return ENV["PORT"].to_i if ENV["PORT"] && !ENV["PORT"].empty?
        DEFAULT_PORT
      when :host
        return cli_value if cli_value
        return ENV["HOST"] if ENV["HOST"] && !ENV["HOST"].empty?
        DEFAULT_HOST
      end
    end

    # ── shared helpers ────────────────────────────────────────────────────

    def load_routes(root_dir)
      route_dirs = %w[src/routes routes src/api api src/orm orm]
      route_dirs.each do |dir|
        route_dir = File.join(root_dir, dir)
        next unless Dir.exist?(route_dir)
        Dir.glob(File.join(route_dir, "**/*.rb")).sort.each { |f| load f }
      end

      # Also load app.rb if it exists
      app_file = File.join(root_dir, "app.rb")
      load app_file if File.exist?(app_file)

      index_file = File.join(root_dir, "index.rb")
      load index_file if File.exist?(index_file)
    end

    def create_project_structure(dir)
      %w[
        src/routes src/orm src/middleware src/templates src/templates/errors
        src/templates/forms src/templates/pages
        src/public src/public/css src/public/js src/public/images
        migrations logs spec seeds
      ].each do |subdir|
        FileUtils.mkdir_p(File.join(dir, subdir))
      end

      # Copy framework public assets into the project so they're visible
      framework_public = File.join(File.dirname(__FILE__), "public")
      project_public = File.join(dir, "src", "public")
      assets_to_copy = %w[
        css/tina4.css
        css/tina4.min.css
        js/tina4.min.js
        js/frond.min.js
        images/tina4-logo-icon.webp
      ]
      assets_to_copy.each do |asset|
        src = File.join(framework_public, asset)
        dst = File.join(project_public, asset)
        FileUtils.mkdir_p(File.dirname(dst))
        if File.exist?(src) && !File.exist?(dst)
          FileUtils.cp(src, dst)
          puts "  Copied #{asset}"
        end
      end
    end

    def create_sample_files(dir, project_name)
      # app.rb
      unless File.exist?(File.join(dir, "app.rb"))
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          require "tina4"
          Tina4.initialize!(__dir__)
          app = Tina4::RackApp.new
          Tina4::WebServer.new(app, port: 7147).start
        RUBY
      end

      # Gemfile
      unless File.exist?(File.join(dir, "Gemfile"))
        File.write(File.join(dir, "Gemfile"), <<~RUBY)
          source "https://rubygems.org"
          gem "tina4-ruby", "~> 3.0"
        RUBY
      end

      # .env
      unless File.exist?(File.join(dir, ".env"))
        File.write(File.join(dir, ".env"), <<~TEXT)
          TINA4_DEBUG=true
          TINA4_LOG_LEVEL=ALL
        TEXT
      end

      # .gitignore
      unless File.exist?(File.join(dir, ".gitignore"))
        File.write(File.join(dir, ".gitignore"), <<~TEXT)
          .env
          .keys/
          logs/
          sessions/
          .queue/
          *.db
          vendor/
        TEXT
      end

      # Dockerfile
      unless File.exist?(File.join(dir, "Dockerfile"))
        File.write(File.join(dir, "Dockerfile"), <<~DOCKERFILE)
          # === Build Stage ===
          FROM ruby:3.3-alpine AS builder

          # Install build dependencies
          RUN apk add --no-cache \\
              build-base \\
              libffi-dev \\
              gcompat

          WORKDIR /app

          # Copy dependency definition first (layer caching)
          COPY Gemfile Gemfile.lock* ./

          # Install gems
          RUN bundle config set --local without 'development test' && \\
              bundle install --jobs 4 --retry 3

          # Copy application code
          COPY . .

          # === Runtime Stage ===
          FROM ruby:3.3-alpine

          # Runtime packages only
          RUN apk add --no-cache libffi gcompat

          WORKDIR /app

          # Copy installed gems
          COPY --from=builder /usr/local/bundle /usr/local/bundle

          # Copy application code
          COPY --from=builder /app /app

          EXPOSE 7147

          # Swagger defaults (override with env vars in docker-compose/k8s if needed)
          ENV SWAGGER_TITLE="Tina4 API"
          ENV SWAGGER_VERSION="0.1.0"
          ENV SWAGGER_DESCRIPTION="Auto-generated API documentation"

          # Start the server on all interfaces
          CMD ["bundle", "exec", "tina4ruby", "start", "-p", "7147", "-h", "0.0.0.0"]
        DOCKERFILE
      end

      # .dockerignore
      unless File.exist?(File.join(dir, ".dockerignore"))
        File.write(File.join(dir, ".dockerignore"), <<~TEXT)
          .git
          .env
          .keys/
          logs/
          sessions/
          .queue/
          *.db
          *.gem
          tmp/
          spec/
          vendor/bundle
        TEXT
      end

      # Base template
      templates_dir = File.join(dir, "src", "templates")
      unless File.exist?(File.join(templates_dir, "base.twig"))
        File.write(File.join(templates_dir, "base.twig"), <<~HTML)
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>{% block title %}#{project_name}{% endblock %}</title>
            <link rel="stylesheet" href="/css/tina4.min.css">
            {% block head %}{% endblock %}
          </head>
          <body>
            {% block content %}{% endblock %}
            <script src="/js/tina4.min.js"></script>
            <script src="/js/frond.min.js"></script>
            {% block scripts %}{% endblock %}
          </body>
          </html>
        HTML
      end
    end
  end
end
