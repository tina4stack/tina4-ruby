# frozen_string_literal: true

require "optparse"
require "fileutils"

module Tina4
  class CLI
    COMMANDS = %w[init start migrate migrate:status migrate:rollback seed seed:create test version routes console generate ai metrics help].freeze

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
      when "metrics"    then cmd_metrics(argv)
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

    # Canonical AI-FILL placeholder block for a LOGIC-shaped stub.
    #
    # A tight, grounded *fill-spec* — not a vague ``# TODO`` — so a coding agent
    # (or dev) completes it correctly and idiomatically. `raise
    # NotImplementedError` makes an unfilled scaffold fail LOUD, and the
    # greppable AI-FILL banner lets a human/agent jump to every gap in a file.
    # <= 6 comment lines; `Use:` names only REAL tina4-ruby symbols (verified in
    # the framework source, file:line).
    #
    #   <indent># ─── AI-FILL: <fn> ───────────────────────────
    #   <indent># Intent:  <what this must do>
    #   <indent># Given:   <inputs + shape>
    #   <indent># Use:     <named REAL Tina4 API — the idiomatic path>
    #   <indent># Return:  <exact return value + status>
    #   <indent># Ground:  tina4_context("<intent>", "ruby") · skill tina4-developer-ruby
    #   <indent>raise NotImplementedError, "<feature>: <what>"   # remove when done
    #   <indent># ─────────────────────────────────────────────
    def ai_fill(fn, intent, use, raise_msg, given: nil, ret: nil, ground: nil, indent: "  ")
      bar = "─" * 60
      head = "#{indent}# ─── AI-FILL: #{fn} "
      head += "─" * [4, 66 - head.length].max
      lines = [head, "#{indent}# Intent:  #{intent}"]
      lines << "#{indent}# Given:   #{given}" if given
      lines << "#{indent}# Use:     #{use}"
      lines << "#{indent}# Return:  #{ret}" if ret
      lines << "#{indent}# Ground:  #{ground}" if ground
      lines << "#{indent}raise NotImplementedError, #{raise_msg.inspect}   # remove when done"
      lines << "#{indent}# #{bar}"
      lines.join("\n") + "\n"
    end

    # Lighter EXTEND marker for CRUD-shaped WORKING code. Marks the natural
    # extension point in generated code that already runs — NO
    # NotImplementedError (the boilerplate IS the feature); just a greppable hint
    # at where custom validation / business rules go.
    def extend_marker(note, hint = "", indent: "  ")
      head = "#{indent}# ─── EXTEND: #{note} "
      head += "─" * [4, 66 - head.length].max
      out = head + "\n"
      out += "#{indent}# #{hint}\n" unless hint.to_s.empty?
      out
    end

    # Parse a --every duration ('5m', '30s', '2h', '1d', or bare seconds) ->
    # seconds. Falls back to 60s on an empty/unparseable value so a scaffold
    # always has a valid interval for Tina4.service(interval: ...).
    def parse_every(every)
      return 60 if every.nil? || every == true
      every = every.to_s.strip.downcase
      return 60 if every.empty?
      units = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86400 }
      unit = every[-1]
      if units.key?(unit)
        [1, (every[0..-2].to_f * units[unit]).to_i].max
      else
        n = every.to_f
        n.positive? ? [1, n.to_i].max : 60
      end
    rescue StandardError
      60
    end

    # Parse --key value and --flag from args. Returns [flags_hash, positional_array]
    def parse_flags(args)
      # Boolean-only flags that never take a value argument
      boolean_flags = %w[no-browser no-reload production managed all clear dev json public no-migration]

      flags = {}
      positional = []
      i = 0
      while i < args.length
        if args[i].start_with?("--")
          key = args[i][2..]
          if boolean_flags.include?(key)
            flags[key] = true
            i += 1
          elsif i + 1 < args.length && !args[i + 1].start_with?("--")
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

      # Register the always-on Frond {% live %} refresh endpoint
      # (GET /__frond/live/{name}) so server-rendered live blocks can poll/SSE.
      Tina4::Frond.register_live_endpoint!

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
        puts "No database configured. Set TINA4_DATABASE_URL in your .env file."
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
          # FAIL-FAST: a failed migration must give CI a non-zero exit (parity
          # with the Python master). Only the startup auto-migration hook
          # swallows failures; the explicit CLI does not.
          exit 1 if results.any? { |r| r[:status] == "failed" }
        end
      end
    end

    # ── migrate:status ─────────────────────────────────────────────────────

    def cmd_migrate_status(_argv)
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)

      db = Tina4.database
      unless db
        puts "No database configured. Set TINA4_DATABASE_URL in your .env file."
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
        puts "No database configured. Set TINA4_DATABASE_URL in your .env file."
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

    # ── metrics ───────────────────────────────────────────────────────────

    # Report top code-quality offenders (complexity, size, maintainability,
    # tests). Mirrors the Python-master `tina4python metrics` command.
    #
    #   tina4ruby metrics                       # human report, scans src/ (or framework)
    #   tina4ruby metrics --top 10              # only the worst 10
    #   tina4ruby metrics --path lib            # scan a specific directory
    #   tina4ruby metrics --json                # machine-readable for CI
    #   tina4ruby metrics --fail-on warn        # exit 1 if any warn/error offender
    #   tina4ruby metrics --fail-on error       # exit 1 only on error-severity
    def cmd_metrics(argv)
      require "json"
      require "set"
      require_relative "metrics"

      flags, _positional = parse_flags(argv)

      top = (flags["top"].to_s =~ /\A\d+\z/) ? flags["top"].to_i : 20
      as_json = flags.key?("json")
      path = flags["path"].is_a?(String) ? flags["path"] : "src"
      fail_on = flags["fail-on"].is_a?(String) ? flags["fail-on"] : nil

      unless [nil, "warn", "error"].include?(fail_on)
        puts "  invalid --fail-on '#{fail_on}' (use warn or error)"
        exit 2
      end

      result = Tina4::Metrics.offenders(path, top)
      summary = result["summary"]
      found = result["offenders"]

      if summary.key?("error")
        puts "  metrics error: #{summary['error']}"
        exit 2
      end

      # Decide exit code from the FULL offender set, not just the printed top-N.
      # full_analysis is cached, so this reuses the same analysis.
      all_offenders = Tina4::Metrics.offenders(path, [summary["total_offenders"], 1].max)["offenders"]
      severities = all_offenders.map { |o| o["severity"] }.to_set
      exit_code = 0
      if fail_on == "warn" && !(severities & %w[warn error]).empty?
        exit_code = 1
      elsif fail_on == "error" && severities.include?("error")
        exit_code = 1
      end

      if as_json
        puts JSON.pretty_generate({ "summary" => summary, "offenders" => found })
        exit exit_code
      end

      # ── Human report ──────────────────────────────────────────────────
      use_color = $stdout.tty?
      colorize = lambda do |text, code|
        use_color ? "\e[#{code}m#{text}\e[0m" : text
      end
      sev_color = { "error" => "31", "warn" => "33", "info" => "2" } # red / yellow / dim

      puts
      puts "  Tina4 Metrics — #{summary['scan_mode']} scan (#{summary['scan_root']})"
      puts "  files: #{summary['files_analyzed']}   " \
           "functions: #{summary['total_functions']}   " \
           "avg complexity: #{summary['avg_complexity']}   " \
           "avg maintainability: #{summary['avg_maintainability']}"
      showing = found.empty? ? "" : " (showing top #{found.length})"
      puts "  offenders: #{summary['total_offenders']} total#{showing}"
      puts

      if found.empty?
        puts "  " + colorize.call("✓ no offenders — clean", "32")
        puts
        exit exit_code
      end

      # Compute column widths so the table lines up.
      locs = found.map { |o| "#{o['file']}:#{o['line']}" }
      loc_w = [("FILE:LINE".length)].concat(locs.map(&:length)).max
      kind_w = [("KIND".length)].concat(found.map { |o| o["kind"].length }).max

      header = format("  %3s  %-8s  %-#{kind_w}s  %-#{loc_w}s  DETAIL", "#", "SEVERITY", "KIND", "FILE:LINE")
      puts colorize.call(header, "1")
      puts "  " + ("-" * (header.length - 2))
      found.each_with_index do |o, i|
        sev = o["severity"]
        sev_cell = colorize.call(format("%-8s", sev), sev_color[sev])
        puts format("  %3d  %s  %-#{kind_w}s  %-#{loc_w}s  %s",
                    i + 1, sev_cell, o["kind"], locs[i], o["detail"])
      end
      puts
      exit exit_code
    end

    # ── generate ────────────────────────────────────────────────────────

    ALL_GENERATORS = "model, route, crud, migration, middleware, test, form, view, auth, " \
                     "service, queue, validator, seeder, websocket, listener"

    def cmd_generate(argv)
      what = argv.shift

      unless what
        puts "Usage: tina4ruby generate <what> <name> [options]"
        puts "  Generators: #{ALL_GENERATORS}"
        puts '  Options:    --fields "name:string,price:float"  --model ModelName'
        puts '              --public                  open a route'"'"'s writes (default: secure)'
        puts '              --every 5m | --cron "..."  service schedule'
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
      when "service"    then generate_service(name, flags)
      when "queue"      then generate_queue(name, flags)
      when "validator"  then generate_validator(name, flags)
      when "seeder"     then generate_seeder(name, flags)
      when "websocket"  then generate_websocket(name, flags)
      when "listener"   then generate_listener(name, flags)
      else
        puts "Unknown generator: #{what}"
        puts "  Available: #{ALL_GENERATORS}"
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

    # Generate a CRUD route file — SECURE BY DEFAULT.
    #
    #   tina4ruby generate route products
    #   tina4ruby generate route products --model Product
    #   tina4ruby generate route products --model Product --public   # open writes
    #
    # Writes (POST/PUT/DELETE) are Bearer-token-gated by default: the router sets
    # auth_required on POST/PUT/PATCH/DELETE (lib/tina4/router.rb:24) and
    # enforce_route_auth 401s a tokenless write (lib/tina4/rack_app.rb:1129).
    # Reads (GET) are public by default, so no opt-out is emitted for them.
    # `--public` chains `.no_auth` on the write handlers as the explicit opt-out
    # — mirroring AutoCrud's `post_route.no_auth if is_public`
    # (lib/tina4/auto_crud.rb:169). The generated routes register through
    # `Tina4::Router.get/post/...` (no bearer auth_handler attached), so `.no_auth`
    # genuinely opens the write on BOTH the live server and the TestClient — the
    # same registration path AutoCrud uses.
    def generate_route(name, flags)
      route_path = name.sub(%r{^/}, "")
      singular = route_path.end_with?("s") ? route_path[0..-2] : route_path
      model = flags["model"]
      public_writes = flags["public"] ? true : false

      dir = "src/routes"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{route_path}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      # `.no_auth` is chained on the WRITE handlers only when writes go public.
      no_auth = public_writes ? ".no_auth" : ""
      write_doc =
        if public_writes
          "Public (--public): no token required."
        else
          "Secure by default: requires a Bearer token (use --public to open)."
        end

      if model
        model_snake = to_snake_case(model)
        # WORKING code (the boilerplate IS the feature) + EXTEND markers at the
        # natural extension points (no NotImplementedError).
        ext_create = extend_marker(
          "validate / business rules before persist",
          'e.g. reject invalid input; ground: tina4_context("validate before create", "ruby")'
        )
        ext_update = extend_marker(
          "guard which fields / who may update",
          'e.g. enforce ownership; ground: tina4_context("authorize update", "ruby")'
        )
        content = <<~RUBY
          require_relative "../orm/#{model_snake}"

          # List all #{route_path} with pagination — public read (GET is ungated).
          Tina4::Router.get "/api/#{route_path}" do |request, response|
            page = (request.params["page"] || 1).to_i
            per_page = (request.params["per_page"] || 20).to_i
            offset = (page - 1) * per_page
            records = #{model}.all(limit: per_page, offset: offset)
            response.json({ data: records.map(&:to_h), count: #{model}.count, page: page, per_page: per_page })
          end

          # Get a single #{singular} by ID — public read.
          Tina4::Router.get "/api/#{route_path}/{id:int}" do |request, response|
            item = #{model}.find(request.params["id"])
            next response.json({ error: "Not found" }, 404) if item.nil?
            response.json(item.to_h)
          end

          # Create a new #{singular}. #{write_doc}
          Tina4::Router.post "/api/#{route_path}" do |request, response|
          #{ext_create.chomp}
            item = #{model}.create(request.body)
            response.json(item.to_h, 201)
          end#{no_auth}

          # Update a #{singular} by ID. #{write_doc}
          Tina4::Router.put "/api/#{route_path}/{id:int}" do |request, response|
            item = #{model}.find(request.params["id"])
            next response.json({ error: "Not found" }, 404) if item.nil?
          #{ext_update.chomp}
            request.body.each do |key, value|
              next if key.to_s == "id"
              setter = "#{'#'}{key}="
              item.send(setter, value) if item.respond_to?(setter)
            end
            item.save
            response.json(item.to_h)
          end#{no_auth}

          # Delete a #{singular} by ID. #{write_doc}
          Tina4::Router.delete "/api/#{route_path}/{id:int}" do |request, response|
            item = #{model}.find(request.params["id"])
            next response.json({ error: "Not found" }, 404) if item.nil?
            item.delete
            response.json(nil, 204)
          end#{no_auth}
        RUBY
      else
        # CUSTOM route — no model. Every handler body is a LOGIC-shaped stub:
        # AI-FILL fill-spec + raise NotImplementedError (fails loud until filled).
        m = singular.split("_").map(&:capitalize).join  # PascalCase hint
        b_list = ai_fill(
          "list_#{route_path}",
          "return the #{route_path} collection (add pagination if it grows)",
          "#{m}.all(limit:, offset:)  or  #{m}.where(sql, params)  (require_relative \"../orm/#{to_snake_case(m)}\")",
          "list_#{route_path}: query and return the records",
          ret: 'response.json({ data: rows.map(&:to_h) })',
          ground: 'tina4_context("list ORM records with pagination", "ruby")'
        )
        b_get = ai_fill(
          "get_#{singular}",
          "fetch one #{singular} by id",
          "#{m}.find(request.params[\"id\"])  (require_relative \"../orm/#{to_snake_case(m)}\")",
          "get_#{singular}: fetch by id or 404",
          given: 'request.params["id"] -> Integer',
          ret: 'response.json(item.to_h)  or  response.json({ error: "Not found" }, 404)',
          ground: 'tina4_context("find ORM record by id", "ruby")'
        )
        b_create = ai_fill(
          "create_#{singular}",
          "validate the body and persist a new #{singular}",
          "#{m}.create(request.body)  (require_relative \"../orm/#{to_snake_case(m)}\")",
          "create_#{singular}: persist and return the new record",
          given: "request.body -> Hash of fields",
          ret: "response.json(item.to_h, 201)",
          ground: 'tina4_context("create ORM record and return 201", "ruby")'
        )
        b_update = ai_fill(
          "update_#{singular}",
          "load, mutate and save an existing #{singular}",
          "#{m}.find(request.params[\"id\"])  then set fields and item.save",
          "update_#{singular}: apply changes and return the record",
          given: 'request.params["id"] -> Integer; request.body -> changed fields',
          ret: "response.json(item.to_h)  or  404",
          ground: 'tina4_context("update ORM record", "ruby")'
        )
        b_delete = ai_fill(
          "delete_#{singular}",
          "delete a #{singular} by id",
          "#{m}.find(request.params[\"id\"])  then item.delete",
          "delete_#{singular}: delete and return 204",
          given: 'request.params["id"] -> Integer',
          ret: "response.json(nil, 204)  or  404",
          ground: 'tina4_context("delete ORM record", "ruby")'
        )
        content = <<~RUBY
          # List all #{route_path} — public read (GET is ungated).
          Tina4::Router.get "/api/#{route_path}" do |request, response|
          #{b_list.chomp}
          end

          # Get a single #{singular} — public read.
          Tina4::Router.get "/api/#{route_path}/{id:int}" do |request, response|
          #{b_get.chomp}
          end

          # Create a new #{singular}. #{write_doc}
          Tina4::Router.post "/api/#{route_path}" do |request, response|
          #{b_create.chomp}
          end#{no_auth}

          # Update a #{singular}. #{write_doc}
          Tina4::Router.put "/api/#{route_path}/{id:int}" do |request, response|
          #{b_update.chomp}
          end#{no_auth}

          # Delete a #{singular}. #{write_doc}
          Tina4::Router.delete "/api/#{route_path}/{id:int}" do |request, response|
          #{b_delete.chomp}
          end#{no_auth}
        RUBY
      end

      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: crud ──────────────────────────────────────────────────

    def generate_crud(name, flags)
      table = to_table_name(name)
      route_name = "#{table}s"
      is_public = flags["public"] ? true : false

      puts "\n  Generating CRUD for #{name}...\n"

      # 1. Model + migration
      generate_model(name, flags)

      # 2. Routes with model — secure-by-default; thread --public through so
      #    `generate crud X --public` opens the writes (mirrors AutoCrud public:).
      generate_route(route_name, { "model" => name, "public" => is_public })

      # 3. Form
      generate_form(name, flags)

      # 4. View (list + detail)
      generate_view(name, flags)

      # 5. Test — secure-by-default gate test (behavioural, real TestClient).
      generate_test(route_name, { "model" => name, "secure_writes" => true, "public" => is_public })

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

      # Secure-by-default CRUD spec (emitted by `generate crud`): proves the gate
      # by BEHAVIOR through the real Tina4::TestClient — reads public, writes
      # gated — instead of assuming an anonymous create returns 201. Grounded on
      # spec/test_client_auth_spec.rb (real Router, real enforce_route_auth, real
      # JWT via Tina4::Auth.get_token / valid_token signed with real RSA keys).
      if model && flags["secure_writes"]
        model_snake = to_snake_case(model)
        posture = flags["public"] ? "open (--public)" : "gated"
        write_examples =
          if flags["public"]
            <<~RUBY.chomp
              it "allows an anonymous POST (201) — --public opened the write" do
                  res = client.post("/api/#{snake}", json: { name: "test" })
                  expect(res.status).to eq(201)
                end
            RUBY
          else
            <<~RUBY.chomp
              it "rejects a tokenless POST with 401 (secure by default)" do
                  expect(client.post("/api/#{snake}", json: { name: "test" }).status).to eq(401)
                end

                it "creates with a valid Bearer token (201)" do
                  token = Tina4::Auth.get_token({ "user_id" => 1 })
                  res = client.post("/api/#{snake}", json: { name: "test" },
                                    headers: { "Authorization" => "Bearer #{'#'}{token}" })
                  expect(res.status).to eq(201)
                end
            RUBY
          end

        content = <<~RUBY
          # frozen_string_literal: true
          #
          # #{model} CRUD gate — reads public, writes #{posture} (secure by default).
          #
          # Real end-to-end via Tina4::TestClient: NO mocks — real Router, real auth
          # gate (Tina4::RackApp.enforce_route_auth), real JWT. A real SQLite DB +
          # table is bound in before(:each), so the create path is exercised for real.
          require "spec_helper"
          require "tmpdir"
          require_relative "../src/orm/#{model_snake}"

          RSpec.describe "#{model} CRUD (reads public, writes #{posture})" do
            let(:client) { Tina4::TestClient.new }

            before(:each) do
              @dir = Dir.mktmpdir("#{snake}_crud")
              # Fresh RSA key material so get_token / valid_token agree.
              Tina4::Auth.instance_variable_set(:@private_key, nil)
              Tina4::Auth.instance_variable_set(:@public_key, nil)
              Tina4::Auth.instance_variable_set(:@keys_dir, nil)
              Tina4::Auth.setup(@dir)
              # A stray API key would authorise every write regardless of the JWT.
              @prior_api_key = ENV.delete("TINA4_API_KEY")
              Tina4.bind_database(Tina4::Database.new("sqlite:///" + File.join(@dir, "test.db")))
              #{model}.create_table
              # `load` (not require) re-registers the routes after spec_helper's
              # after(:each) Router.clear! wipes them between examples.
              load File.expand_path("../src/routes/#{snake}.rb", __dir__)
            end

            after(:each) do
              ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
              FileUtils.rm_rf(@dir)
            end

            it "serves GET (read) publicly" do
              expect(client.get("/api/#{snake}").status).to eq(200)
            end

            #{write_examples}
          end
        RUBY
        File.write(path, content)
        puts "  Created #{path}"
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

          # PUBLIC: register mints accounts before any token exists — clear BOTH
          # write gates (auth: false drops the bearer auth_handler; .no_auth
          # clears the router's auth_required).
          Tina4.post "/api/auth/register", auth: false do |request, response|
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
          end.no_auth

          # PUBLIC: login mints the token — clear BOTH write gates (see register).
          Tina4.post "/api/auth/login", auth: false do |request, response|
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
          end.no_auth

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

    # ── Scaffolding-first logic generators (wiring + AI-FILL placeholder) ─────
    #
    # Each grounds on the REAL current tina4-ruby API (verified against the
    # source, file:line) and drops the ai_fill() AI-FILL placeholder (raise
    # NotImplementedError) where the custom logic goes:
    #   service   -> lib/tina4/service_runner.rb  Tina4::ServiceRunner.register/.discover/.list
    #                (via the Tina4.service DSL, lib/tina4.rb:431)
    #   queue     -> lib/tina4/queue.rb           Tina4::Queue#push / #consume
    #                lib/tina4/job.rb              Job#payload / #complete / #fail
    #   validator -> lib/tina4/validator.rb        Tina4::Validator (#required/#email/#is_valid?)
    #   seeder    -> lib/tina4/seeder.rb           Tina4::FakeData / Tina4.seed_orm
    #   websocket -> lib/tina4/router.rb           Tina4.websocket (connection, event, data)
    #   listener  -> lib/tina4/events.rb           Tina4::Events.on / .emit

    # ── Generator: service ────────────────────────────────────────────────
    #
    #   tina4ruby generate service Cleanup --every 5m
    #   tina4ruby generate service Report --cron "0 3 * * *"
    def generate_service(name, flags = {})
      snake = to_snake_case(name)
      cron = flags["cron"]
      if cron && cron != true
        options_kw = "timing: #{cron.inspect}"   # ServiceRunner cron key is :timing
        note = "cron '#{cron}'"
      else
        seconds = parse_every(flags["every"])
        options_kw = "interval: #{seconds}"
        note = "every #{seconds}s"
      end

      dir = "src/services"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{snake}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        "#{snake}_task",
        "do the scheduled work for this service",
        "context.name / context.running (Tina4::ServiceContext); call your ORM / app code",
        "service:#{snake}: implement the scheduled task",
        given: "context -> Tina4::ServiceContext (.name, .running, .last_run, .error_count)",
        ground: 'tina4_context("background service scheduled task", "ruby")'
      )
      content = <<~RUBY
        # #{name} background service — runs #{note} via Tina4::ServiceRunner.
        #
        # Registered on load by Tina4.service(...). `tina4ruby start` does NOT
        # auto-start services (src/services is not on the boot auto-discover path,
        # lib/tina4.rb:566). Wire a runner explicitly to run it:
        #
        #     Tina4::ServiceRunner.discover("src/services")  # loads this file
        #     Tina4::ServiceRunner.start
        #
        # The block receives a Tina4::ServiceContext; a daemon-style task would
        # loop while context.running.

        def #{snake}_task(context)
        #{body.chomp}
        end

        # Wiring: registers "#{snake}" on the class-level ServiceRunner registry;
        # appears in Tina4::ServiceRunner.list.
        Tina4.service("#{snake}", #{options_kw}) { |context| #{snake}_task(context) }
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: queue ──────────────────────────────────────────────────
    #
    #   tina4ruby generate queue order-emails
    def generate_queue(name, flags = {})
      topic = name.sub(%r{^/}, "")
      slug = to_snake_case(topic.gsub(/[^0-9a-zA-Z]+/, "_")).gsub(/\A_+|_+\z/, "")
      slug = "topic" if slug.empty?

      dir = "src/services"  # consumer runs as a daemon service (see below)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{slug}_consumer.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        "handle_#{slug}",
        "process ONE #{topic} job payload",
        "your ORM / Tina4::Messenger code; return to ack (job.complete), raise to nack (job.fail)",
        "queue:#{topic}: process the job payload",
        given: "payload -> the pushed Hash (job.payload)",
        ground: 'tina4_context("process a queue job", "ruby")'
      )
      content = <<~RUBY
        # #{topic} queue — producer + consumer worker.
        #
        # Produce from anywhere:   publish_#{slug}({ ... })
        # The consumer is a long-running worker wired as a daemon service so
        #     Tina4::ServiceRunner.discover("src/services"); Tina4::ServiceRunner.start
        # runs it without blocking boot (consume polls forever).

        # Enqueue a #{topic} job for the worker below to process. Returns the Tina4::Job.
        def publish_#{slug}(payload)
          Tina4::Queue.new(topic: "#{topic}").push(payload)
        end

        # Process ONE #{topic} job payload (`payload` is job.payload — the pushed data).
        def handle_#{slug}(payload)
        #{body.chomp}
        end

        # Long-running #{topic} worker. consume yields Jobs; ack with job.complete,
        # nack with job.fail. `context` is the Tina4::ServiceContext under ServiceRunner.
        def consume_#{slug}(context = nil)
          Tina4::Queue.new(topic: "#{topic}").consume do |job|
            handle_#{slug}(job.payload)
            job.complete             # ack — job done, removed from the queue
          rescue StandardError => e
            job.fail(e.message)      # nack — retry / dead-letter
          end
        end

        # Wiring: consumer runs as a daemon service (manages its own poll loop).
        # Discovered by Tina4::ServiceRunner.discover("src/services").
        Tina4.service("#{topic}-consumer", daemon: true) { |context| consume_#{slug}(context) }
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: validator ──────────────────────────────────────────────
    #
    #   tina4ruby generate validator CreateUser
    def generate_validator(name, flags = {})
      snake = to_snake_case(name)
      dir = "src/validators"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{snake}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        "validate_#{snake}",
        "declare the validation rules for a #{name} payload",
        'validator.required("name").email("email").min_length("name", 2).integer("age")',
        "validator:#{snake}: add the rule set",
        given: "validator -> Tina4::Validator.new(data) (chainable)",
        ret: "the same validator (caller checks .is_valid? / .errors)",
        ground: 'tina4_context("validate request body with Validator", "ruby")'
      )
      content = <<~RUBY
        # #{name} request validator.
        #
        # Tina4::Validator is NOT part of the default `require "tina4"` surface
        # (unlike Queue / Events / ServiceRunner), so require it explicitly here.
        # NOT auto-loaded — require this file from the route that validates:
        #     require_relative "../validators/#{snake}"
        #     v = validate_#{snake}(request.body)
        #     next response.json({ error: v.errors.first[:message] }, 400) unless v.is_valid?
        require "tina4/validator"

        def validate_#{snake}(data)
          validator = Tina4::Validator.new(data)
        #{body.chomp}
          validator
        end
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: seeder ─────────────────────────────────────────────────
    #
    #   tina4ruby generate seeder Product
    def generate_seeder(name, flags = {})
      table = to_table_name(name)
      model_snake = to_snake_case(name)
      dir = "seeds"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{table}_seeder.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        "#{table}_field_overrides",
        "map #{name} fields to fake-data generators (only those needing a specific shape)",
        "fake.name / fake.email / fake.integer(min: 1, max: 99) / fake.company  (Tina4::FakeData)",
        "seeder:#{name}: return the field->value overrides Hash",
        given: "fake -> Tina4::FakeData instance",
        ret: '{ "email" => ->(f) { f.email }, "status" => "active" }  (Hash)',
        ground: 'tina4_context("seed ORM model with FakeData", "ruby")'
      )
      content = <<~RUBY
        # Seeder for #{name} — run with: tina4ruby seed
        #
        # Executed top-to-bottom by `tina4ruby seed` (Tina4.seed_dir loads each
        # file in seeds/, lib/tina4/seeder.rb:890). Tina4.seed_orm auto-fills every
        # field by type/name; override the ones that need a specific shape via
        # #{table}_field_overrides.
        require_relative "../src/orm/#{model_snake}"

        # Map #{name} fields -> Tina4::FakeData generators (or static values).
        # Each callable receives a FakeData instance:
        #     { "email" => ->(fake) { fake.email }, "status" => "active" }
        def #{table}_field_overrides(fake)
        #{body.chomp}
        end

        # Wiring: seed rows via Tina4.seed_orm. Guarded on a bound database so
        # merely LOADING this file (e.g. in a spec) does not run the unfilled
        # placeholder — `tina4ruby seed` binds the DB first, at which point the
        # override raises LOUD until filled.
        if Tina4.database
          fake = Tina4::FakeData.new
          summary = Tina4.seed_orm(#{name}, count: 20, overrides: #{table}_field_overrides(fake))
          puts "Seeded #{'#'}{summary.seeded} #{name} row(s), #{'#'}{summary.failed} failed"
        end
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: websocket ──────────────────────────────────────────────
    #
    #   tina4ruby generate websocket chat
    #   tina4ruby generate websocket /ws/rooms/{id}
    def generate_websocket(name, flags = {})
      raw = name.strip
      ws_path = raw.start_with?("/") ? raw : "/ws/#{raw.sub(%r{^/}, '')}"
      slug = to_snake_case(raw.gsub(%r{\A/+|/+\z}, "").gsub(/[^0-9a-zA-Z]+/, "_")).gsub(/\A_+|_+\z/, "")
      slug = "ws" if slug.empty?
      base = slug.start_with?("ws_") ? slug[3..] : slug
      base = "ws" if base.nil? || base.empty?
      handler = "#{base}_ws"

      dir = "src/routes"  # Tina4.websocket auto-registers on load (src/routes is discovered)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "ws_#{base}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        handler,
        %(handle an inbound "message" frame on #{ws_path}),
        "connection.broadcast(data)  or  connection.send(payload)  (Tina4 WebSocketConnection)",
        "websocket:#{ws_path}: handle the inbound message",
        given: "connection -> WebSocketConnection; event -> :open/:message/:close; data -> String on :message",
        ground: 'tina4_context("websocket broadcast message", "ruby")',
        indent: "    "
      )
      content = <<~RUBY
        # #{ws_path} WebSocket route.
        #
        # Registered on load by Tina4.websocket (src/routes is auto-discovered at
        # boot, lib/tina4.rb:566). The server invokes the block as
        # (connection, event, data) for each event: :open (connect), :message
        # (inbound frame), :close (disconnect). Use Tina4.secure_websocket instead
        # to require a JWT on the upgrade; connection.broadcast / connection.send
        # reach the other clients.
        Tina4.websocket "#{ws_path}" do |connection, event, data|
          case event
          when :open
            connection.send('{"type":"welcome"}')
          when :close
            # client disconnected — nothing to clean up yet
          else # :message
        #{body.chomp}
          end
        end
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
    end

    # ── Generator: listener ───────────────────────────────────────────────
    #
    #   tina4ruby generate listener user.created
    def generate_listener(name, flags = {})
      event = name.strip
      slug = to_snake_case(event.gsub(/[^0-9a-zA-Z]+/, "_")).gsub(/\A_+|_+\z/, "")
      slug = "event" if slug.empty?

      dir = "src/listeners"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{slug}.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end

      body = ai_fill(
        "on_#{slug}",
        "react to the '#{event}' event",
        "your app code — Tina4::Messenger, an ORM write, or Tina4::Events.emit(...) a follow-up",
        "listener:#{event}: react to the event payload",
        given: %(data -> whatever Tina4::Events.emit("#{event}", data) passed),
        ground: 'tina4_context("event listener reaction", "ruby")'
      )
      content = <<~RUBY
        # Listener for the '#{event}' event.
        #
        # NOT auto-loaded at boot — src/listeners is not on the auto-discover path
        # (lib/tina4.rb:566 scans routes/api/orm only). Require this file from
        # app.rb (or an initializer) so Tina4::Events.on binds it:
        #     require_relative "src/listeners/#{slug}"
        # Fires when something calls Tina4::Events.emit("#{event}", data). Listeners
        # are isolated — a raise is logged and the other listeners still run (pass
        # strict: true to emit to re-raise instead).
        def on_#{slug}(data = nil)
        #{body.chomp}
        end

        # Wiring: bind the reaction on the real event bus.
        Tina4::Events.on("#{event}") { |data| on_#{slug}(data) }
      RUBY
      File.write(path, content)
      puts "  Created #{path}"
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
          metrics            Rank top code-quality offenders
          help               Show this help message

        Generators:
          generate model <Name> [--fields "name:string,price:float"]
          generate route <name> [--model Name] [--public]   Writes secure by default; --public opens them
          generate crud <Name> [--fields "..."] [--public]  Model + migration + routes + form + view + test
          generate migration <description>
          generate middleware <Name>
          generate test <name>
          generate form <Name> [--fields "..."]   Form template with inputs matching model fields
          generate view <Name> [--fields "..."]   List + detail templates for viewing records
          generate auth                           Login/register/logout routes + User model + templates
          generate service <Name> [--every 5m | --cron "..."]   Scheduled ServiceRunner task (src/services/)
          generate queue <topic>                  Producer + consumer worker (src/services/)
          generate validator <Name>               Request-body Validator (src/validators/)
          generate seeder <Model>                 FakeData + seed_orm seeder (seeds/)
          generate websocket <path>               Tina4.websocket handler (src/routes/)
          generate listener <event>               Tina4::Events.on listener (src/listeners/)

        Scaffolding-first: logic-shaped generators (route without --model, service,
        queue, validator, seeder, websocket, listener) emit wiring + an AI-FILL
        placeholder (raise NotImplementedError) where the custom logic goes; CRUD-
        shaped ones emit working code. Writes are secure by default — use --public
        to open them.

        Metrics:
          metrics [--top N] [--json] [--fail-on warn|error] [--path DIR]
            --top N        Show only the worst N offenders (default: 20)
            --json         Print machine-readable JSON ({summary, offenders}) for CI
            --fail-on      Exit 1 if any offender at/above this severity (warn|error)
            --path DIR     Scan DIR (default: src/, auto-resolves to the framework)

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
          .env.local
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
