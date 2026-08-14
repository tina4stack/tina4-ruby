# frozen_string_literal: true

require "optparse"
require "fileutils"
require_relative "port_takeover"

module Tina4
  class CLI
    # ── Command registries — the single source of truth ─────────────────
    #
    # ONE entry per command/generator drives dispatch (#run / #cmd_generate),
    # the human help (#cmd_help), AND the machine-readable manifest
    # (`commands --json`). Add a command in ONE place and it appears in
    # dispatch, help, and discovery — there is no second list to sync. Ruby
    # mirror of the Python master's COMMANDS / GENERATORS registries
    # (tina4_python/cli/__init__.py).
    #
    #   GENERATORS[name] = { handler: :method_symbol, usage: str, summary: str }
    #   COMMANDS[name]   = { handler: :method_symbol, summary: str,
    #                        usage?: str,          # arg/flag hint for #cmd_help (human only)
    #                        args?: [str],         # positional args for the manifest ("x?" = optional)
    #                        subcommands?: [str] } # sub-names for the manifest (generate)
    #
    # Handlers are instance-method symbols dispatched via #send: GENERATORS
    # handlers take (name, flags); COMMANDS handlers take (argv).

    GENERATORS = {
      "model"      => { handler: :generate_model,      usage: '<Name> [--fields "name:string,price:float"]', summary: "ORM model + matching migration" },
      "route"      => { handler: :generate_route,      usage: "<name> [--model Name] [--public]",             summary: "CRUD route file, secure by default (--public opens writes)" },
      "crud"       => { handler: :generate_crud,       usage: '<Name> [--fields "..."] [--public]',           summary: "Model + migration + routes + form + view + test" },
      "migration"  => { handler: :generate_migration,  usage: "<description>",                                 summary: "Timestamped migration file (UP/DOWN)" },
      "middleware" => { handler: :generate_middleware, usage: "<Name>",                                        summary: "Middleware with before/after hooks" },
      "test"       => { handler: :generate_test,       usage: "<name> [--model Name]",                         summary: "RSpec test file" },
      "form"       => { handler: :generate_form,       usage: '<Name> [--fields "..."]',                       summary: "Form template with inputs matching model fields" },
      "view"       => { handler: :generate_view,       usage: '<Name> [--fields "..."]',                       summary: "List + detail view templates" },
      "auth"       => { handler: :generate_auth,       usage: "",                                              summary: "Login/register routes + User model + templates" },
      "service"    => { handler: :generate_service,    usage: '<Name> [--every 5m | --cron "..."]',            summary: "Scheduled ServiceRunner task (src/services/)" },
      "queue"      => { handler: :generate_queue,      usage: "<topic>",                                       summary: "Producer + consumer worker (src/services/)" },
      "validator"  => { handler: :generate_validator,  usage: "<Name>",                                        summary: "Request-body Validator (src/validators/)" },
      "seeder"     => { handler: :generate_seeder,     usage: "<Model>",                                       summary: "FakeData + seed_orm seeder (seeds/)" },
      "websocket"  => { handler: :generate_websocket,  usage: "<path>",                                        summary: "Tina4.websocket handler (src/routes/)" },
      "listener"   => { handler: :generate_listener,   usage: "<event>",                                       summary: "Tina4::Events.on listener (src/listeners/)" },
    }.freeze

    # Sub-dispatch table for the top-level `queue` command — the SINGLE source
    # for its subcommands (drives #cmd_queue dispatch AND the manifest's
    # queue.subcommands). Ruby mirror of the Python master's _QUEUE_SUBCOMMANDS.
    # Distinct from the `queue` GENERATOR, which SCAFFOLDS a consumer file.
    QUEUE_SUBCOMMANDS = {
      "work"  => :queue_work,
      "stats" => :queue_stats,
      "retry" => :queue_retry,
      "clear" => :queue_clear,
    }.freeze

    COMMANDS = {
      "init"             => { handler: :cmd_init,             usage: "[NAME]", args: ["name?"],           summary: "Initialize a new Tina4 project" },
      "start"            => { handler: :cmd_start,            usage: "[options]",                          summary: "Start the Tina4 web server" },
      "serve"            => { handler: :cmd_start,                                                         summary: "Alias for start" },
      "migrate"          => { handler: :cmd_migrate,          usage: "[--create NAME] [--rollback N]",     summary: "Run database migrations" },
      "migrate:create"   => { handler: :cmd_migrate_create,   usage: "<desc>", args: ["description"],      summary: "Create a new migration file" },
      "migrate:status"   => { handler: :cmd_migrate_status,                                                summary: "Show migration status (completed and pending)" },
      "migrate:rollback" => { handler: :cmd_migrate_rollback, usage: "[-n N]",                             summary: "Rollback the last batch of migrations" },
      "seed"             => { handler: :cmd_seed,             usage: "[--clear]",                          summary: "Run all seed files in seeds/" },
      "seed:create"      => { handler: :cmd_seed_create,      usage: "NAME", args: ["name"],               summary: "Create a new seed file" },
      "test"             => { handler: :cmd_test,                                                          summary: "Run inline tests" },
      "queue"            => { handler: :cmd_queue,            usage: "<work|stats|retry|clear> [topic]", subcommands: QUEUE_SUBCOMMANDS.keys, summary: "Run queue workers and manage jobs" },
      "build"            => { handler: :cmd_build,            usage: "[--tag NAME] [--file PATH]",         summary: "Build the deployable Docker image" },
      "version"          => { handler: :cmd_version,                                                       summary: "Show Tina4 version" },
      "routes"           => { handler: :cmd_routes,                                                        summary: "List all registered routes" },
      "console"          => { handler: :cmd_console,                                                       summary: "Start an interactive console" },
      "generate"         => { handler: :cmd_generate,         usage: "<what> <name> [options]", subcommands: GENERATORS.keys, summary: "Generate scaffolding (see Generators below)" },
      "ai"               => { handler: :cmd_ai,               usage: "[--all]",                            summary: "Detect AI tools and install context files" },
      "commands"         => { handler: :cmd_commands,         usage: "[--json]",                           summary: "List available commands (add --json for machine form)" },
      "help"             => { handler: :cmd_help,                                                          summary: "Show this help message" },
    }.freeze

    # ── Delegation to the `tina4` client ────────────────────────────────
    #
    # `doctor`, `setup` and `deploy` are owned by the Rust `tina4` client, not by
    # any framework. `doctor` probes ALL FOUR runtimes plus package managers,
    # ports and global AI-skills currency; `setup` installs language runtimes
    # (Homebrew / Chocolatey, with UAC elevation on Windows) and scaffolds a
    # project from nothing; `deploy` writes deployment boilerplate baked into the
    # client binary. Cloning any of them into four languages would duplicate
    # hundreds of lines per language for zero new capability — and four copies
    # would immediately drift.
    #
    # So the framework CLI DELEGATES: it resolves `tina4` on PATH, runs it with
    # the same argv, and exits with the client's exit code. All four frameworks
    # reach the SAME implementation, which is a stronger parity guarantee than
    # four ports.
    #
    # Delegation is ALLOW-LISTED, never blind. The client forwards ITS unknown
    # commands to the framework CLI, so a framework that forwarded its unknowns
    # back would ping-pong an unknown command between two processes forever. This
    # closed set contains only commands the client dispatches natively, so no loop
    # is possible by construction, and a real typo still gets "Unknown command".
    #
    # There are no handlers here: #run runs `tina4 <name> <args...>` and exits
    # with its code. Keep this set closed and identical in all four frameworks.
    # Summaries are the client's own wording, verbatim. Ruby mirror of the Python
    # master's DELEGATED / _delegate_to_client.

    DELEGATED = {
      "doctor" => { summary: "Check installed languages and tools" },
      "setup"  => { summary: "Guided, menu-driven setup: install everything + scaffold a ready-to-run project" },
      "deploy" => { usage: "<docker|systemd|nginx|cpanel> [--force]", args: ["target"],
                    summary: "Generate deployment scaffolding (Dockerfile, systemd unit, nginx block, cPanel)" },
    }.freeze

    CLIENT_BINARY = "tina4"

    # Internal process marker (same class as the client's own
    # TINA4_SETUP_ELEVATED): set on the child so a client that resolves back to a
    # framework CLI is caught instead of spawning forever. NOT user configuration
    # — deliberately absent from the CLI's known_vars().
    DELEGATION_GUARD_ENV = "TINA4_CLI_DELEGATED"

    # 127 is the conventional "command not found" and covers both ways the client
    # can be unreachable (absent from PATH, or the loop guard tripping).
    EXIT_CLIENT_UNAVAILABLE = 127
    EXIT_UNKNOWN_COMMAND = 1

    CLIENT_INSTALL_HINT = <<~HINT.freeze
      Install it:  curl -fsSL https://tina4.com/install.sh | sh
      Windows:     irm https://tina4.com/install.ps1 | iex
    HINT

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
      command = "help" if %w[-h --help].include?(command)

      # Dispatch from the single-source-of-truth COMMANDS registry. The same
      # registry drives #cmd_help and the `commands --json` manifest, so
      # dispatch, help, and discovery never drift.
      spec = COMMANDS[command]
      if spec
        send(spec[:handler], argv)
      elsif DELEGATED.key?(command)
        exit delegate_to_client(command, argv)
      else
        # A genuinely unknown command is an ERROR: exit non-zero so a typo in a
        # script or CI step fails loudly instead of reporting success.
        puts "Unknown command: #{command}"
        cmd_help
        exit EXIT_UNKNOWN_COMMAND
      end
    end

    private

    # Absolute path of the `tina4` client on PATH, or nil if it isn't there.
    #
    # Scans PATH directly rather than shelling out to which/where — one less
    # process and it behaves the same on every platform.
    def find_client
      windows = RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      names = windows ? %W[#{CLIENT_BINARY}.exe #{CLIENT_BINARY}.cmd #{CLIENT_BINARY}.bat] : [CLIENT_BINARY]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        names.each do |name|
          candidate = File.join(dir, name)
          return candidate if File.file?(candidate) && (windows || File.executable?(candidate))
        end
      end
      nil
    end

    # Run `tina4 <command> <args...>`, returning the client's exit code.
    #
    # Returns EXIT_CLIENT_UNAVAILABLE (127) with an actionable message when the
    # client is not on PATH, or when the re-entry guard shows the resolved `tina4`
    # came back to a framework CLI (a delegation loop).
    def delegate_to_client(command, args)
      if ENV[DELEGATION_GUARD_ENV] == command
        warn "  Refusing to delegate '#{command}' again — the 'tina4' on your PATH"
        warn "  resolved back to a framework CLI instead of the tina4 client."
        warn ""
        warn "  Check which 'tina4' comes first on your PATH and put the client first."
        return EXIT_CLIENT_UNAVAILABLE
      end

      client = find_client
      if client.nil?
        warn "  '#{command}' is provided by the tina4 client, which is not on your PATH."
        warn ""
        CLIENT_INSTALL_HINT.each_line { |line| warn "  #{line.chomp}" }
        warn ""
        warn "  Then run:    #{CLIENT_BINARY} #{command}"
        return EXIT_CLIENT_UNAVAILABLE
      end

      # Array form => no shell, so no quoting/injection surface. stdio is
      # inherited, so the client's interactive prompts (setup) and colour output
      # work exactly as if it had been invoked directly.
      system({ DELEGATION_GUARD_ENV => command }, client, command, *args)
      $?&.exitstatus || EXIT_CLIENT_UNAVAILABLE
    end

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

    # Called without --fields, the generators fall back to a single `name`
    # string column. That default MUST be materialised here, in one place, and
    # then flow into the model, the migration, the form, the view and the spec
    # alike. It used to live only inside the model template, so `generate model
    # X` / `generate crud X` wrote a model declaring `name` while the migration
    # - built from the parsed field list, which was empty - created only id +
    # created_at. The first write then failed with "no such column: name".
    DEFAULT_FIELDS = [["name", "string"]].freeze

    # Parsed --fields, or the default single `name` column when none given.
    def fields_or_default(fields_str)
      parsed = parse_fields(fields_str)
      parsed.any? ? parsed : DEFAULT_FIELDS.map(&:dup)
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
      boolean_flags = %w[no-browser no-reload production managed all clear dev json public no-migration once]

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
    # True when this process is running inside a container.
    #
    # Reclaiming a port makes sense on a dev machine, where a previous
    # `tina4 serve` may still hold it. Inside a container the server IS the
    # container, so there is no stale sibling to reclaim from -- and trying is
    # actively dangerous (see #kill_process_on_port).
    # Container detection lives in the shared takeover module now; kept as an
    # instance method so existing callers/specs resolve it on the CLI.
    def in_container?
      Tina4::PortTakeover.in_container?
    end

    # Thin wrapper over the shared Tina4::PortTakeover.selectable_pids so the CLI
    # and the runtime bind-failure path share ONE implementation.
    def selectable_pids(lsof_output, me, my_group = nil)
      Tina4::PortTakeover.selectable_pids(lsof_output, me, my_group)
    end

    # Reclaim `port` from a stale Tina4 dev server, only when it is safe.
    #
    # Routes through the shared identity-checked takeover (TAKEOVER-DEC-01/02): a
    # holder is signalled ONLY when a Tina4 dev server recorded its PID in the
    # per-port PID file. A foreign holder is left running and a clear message is
    # printed; takeover is also skipped in a container, outside dev mode, and when
    # opted out (TINA4_NO_TAKEOVER / --no-kill). Returns true only when a Tina4
    # holder was actually signalled.
    def kill_process_on_port(port)
      result = Tina4::PortTakeover.take_over_port(
        port, dev: Tina4::PortTakeover.dev?, no_takeover: Tina4::PortTakeover.no_takeover_opted_out?
      )
      if result.reclaimed?
        puts "  #{result.message}"
        return true
      end
      puts "  #{result.message}" if result.refused? && !result.message.empty?
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
      options = { port: nil, host: nil, dev: false, no_browser: false, no_reload: false, production: false,
                  managed: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tina4ruby start [options]"
        opts.on("-p", "--port PORT", Integer, "Port (default: 7147)") { |v| options[:port] = v }
        opts.on("-h", "--host HOST", "Host (default: 0.0.0.0)") { |v| options[:host] = v }
        opts.on("-d", "--dev", "Enable dev mode with auto-reload") { options[:dev] = true }
        # --managed says the Rust CLI owns this process (it supervises, watches
        # files, and compiles SCSS, so the framework must not duplicate any of
        # it). "managed" was already declared in boolean_flags above, but this
        # parser never accepted it, so `tina4ruby serve --managed` died with
        # OptionParser::InvalidOption -- which is precisely how the Rust CLI
        # invokes PHP. That mismatch is why Ruby could not be launched through
        # the shared launcher the other frameworks use.
        opts.on("--managed", "Running under the tina4 CLI supervisor") { options[:managed] = true }
        opts.on("--production", "Use production server (Puma)") { options[:production] = true }
        opts.on("--no-browser", "Do not open browser on start") { options[:no_browser] = true }
        opts.on("--no-reload", "Disable file watcher / live-reload") { options[:no_reload] = true }
        opts.on("--no-kill", "Never take over the port from a stale dev server") { options[:no_kill] = true }
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

      # --no-kill opts out of port takeover for the whole process, so the CLI
      # path here AND the runtime bind-failure fallback both honour it
      # (TAKEOVER-DEC-03).
      ENV["TINA4_NO_TAKEOVER"] = "true" if options[:no_kill]

      # Priority: CLI flag > ENV var > default
      options[:port] = resolve_config(:port, options[:port])
      options[:host] = resolve_config(:host, options[:host])

      # Kill existing process on port
      kill_process_on_port(options[:port])

      require_relative "../tina4"

      root_dir = Dir.pwd
      Tina4.initialize!(root_dir)

      # Built-in routes (health, Frond live). Shared with Tina4.run! so the two
      # entry points cannot drift again -- they did, and app.rb served 404 on
      # /health for it. register! is idempotent, so calling it here is safe.
      Tina4.register_builtin_routes!

      # Load route files
      load_routes(root_dir)

      # File watching is handled by the Rust CLI (tina4 serve). The framework
      # only needs POST /__dev/api/reload to update the mtime counter for browser polling.
      # No internal file watcher.

      app = Tina4::RackApp.new(root_dir: root_dir)

      is_debug = Tina4::Env.is_truthy(ENV["TINA4_DEBUG"])

      # Use Puma only when explicitly requested via --production flag
      # WEBrick is used for development (supports dev toolbar/reload)
      # Same production server, same shutdown contract as Tina4.run! - one
      # implementation, so the two entry points cannot drift again (the old
      # copy here claimed "we handle DB cleanup" and did no cleanup at all).
      # TINA4_DEFAULT_WEBSERVER=TRUE pins the built-in server even with
      # --production.
      if options[:production] && !Tina4.builtin_webserver_pinned? && Tina4.puma_available?
        Tina4.start_puma_server(app, host: options[:host], port: options[:port])
        return
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

    # ── migrate:create ───────────────────────────────────────────────────

    # Create a new timestamped migration file (UP .sql + .down.sql), matching
    # the Python master `migrate:create`. CHEAP + database-free: it only writes
    # files via the static Tina4::Migration.create_migration helper — no app
    # boot, no DB connection, no tracking table. `description` is every arg
    # joined with a space (parity with Python's `" ".join(args)`).
    def cmd_migrate_create(argv)
      description = (argv || []).join(" ").strip
      if description.empty?
        puts "Usage: tina4ruby migrate:create <description>"
        exit 1
      end

      require_relative "log"
      require_relative "migration"
      path = Tina4::Migration.create_migration(description, migrations_dir: "migrations")
      puts "Created: #{path}"
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

    # ── queue ─────────────────────────────────────────────────────────────
    #
    # Top-level `queue` command — wires straight to the real Tina4::Queue (lite
    # /file backend by default; RabbitMQ/Kafka/MongoDB via TINA4_QUEUE_BACKEND).
    # `stats`, `retry` and `clear` operate on the queue without starting a
    # server; `work` runs the app's consumer for a topic. Distinct from
    # `generate queue`, which SCAFFOLDS a consumer file. Mirrors the Python
    # master's `queue` command.
    #
    #   tina4ruby queue work  [topic] [--once] [--poll N] [--services DIR]
    #   tina4ruby queue stats [topic] [--json]
    #   tina4ruby queue retry [topic]
    #   tina4ruby queue clear [status] [topic]
    def cmd_queue(argv)
      argv ||= []
      if argv.empty?
        puts "Usage: tina4ruby queue <work|stats|retry|clear> [options]"
        puts "  Subcommands: #{QUEUE_SUBCOMMANDS.keys.join(', ')}"
        exit 1
      end

      sub = argv[0].downcase
      handler = QUEUE_SUBCOMMANDS[sub]
      if handler.nil?
        puts "Unknown queue subcommand: #{sub}"
        puts "  Available: #{QUEUE_SUBCOMMANDS.keys.join(', ')}"
        exit 1
      end
      send(handler, argv[1..])
    end

    # Load the framework classes (Queue, backends, ServiceRunner) WITHOUT
    # booting the app (no route discovery, no server, no auto-migrate), then
    # load .env — mirrors the Python master's _load_env() before queue ops.
    def load_queue_runtime
      require_relative "../tina4"
      Tina4::Env.load_env(Dir.pwd)
    end

    # Resolve the per-job handler a consumer declares for `topic`.
    #
    # A consumer scaffolded by `generate queue <topic>` registers a daemon
    # service via Tina4.service(..., topic:, handle:). When its `topic` matches,
    # `queue work` drives that per-job `handle` callable so THIS command owns the
    # poll loop (honouring --poll / the bounded --once drain) instead of the
    # consumer's own endless loop. Returns the callable, or nil when no consumer
    # in `services_dir` targets this topic. Ruby parity for the Python master's
    # _resolve_queue_handler (which reads a module-level `service` dict).
    def resolve_queue_handler(services_dir, topic)
      dir = File.expand_path(services_dir, Dir.pwd)
      return nil unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.rb")).sort.each do |file|
        next if File.basename(file).start_with?("_")
        begin
          load file
        rescue StandardError, ScriptError
          next # a broken sibling must not sink the worker
        end
      end

      Tina4::ServiceRunner.list.each do |svc|
        options = svc[:options] || {}
        handle = options[:handle]
        return handle if options[:topic].to_s == topic.to_s && handle.respond_to?(:call)
      end
      nil
    end

    # Run a consumer loop that pops and processes jobs on a topic.
    #
    #   tina4ruby queue work [topic] [--once] [--poll N] [--services DIR]
    #
    # Long-running by default (polls every --poll seconds, 1.0 default; Ctrl-C to
    # stop). --once does a single-pass drain — it processes every currently
    # available job then exits (poll interval 0). The per-job handler is resolved
    # from the app's consumer for this topic (see #resolve_queue_handler); with no
    # handler it drains and acks with a warning rather than inventing behaviour.
    def queue_work(argv)
      load_queue_runtime
      flags, positional = parse_flags(argv)
      topic = positional[0] || "default"
      once = flags["once"] ? true : false

      poll =
        if once
          0.0 # single-pass: consume() returns as soon as the topic is empty
        else
          poll_raw = flags["poll"].to_s.strip
          if poll_raw.empty? || poll_raw == "true"
            1.0
          else
            begin
              Float(poll_raw)
            rescue ArgumentError
              1.0
            end
          end
        end

      services_dir = flags["services"]
      services_dir = ENV["TINA4_SERVICE_DIR"] || "src/services" unless services_dir.is_a?(String)

      handler = resolve_queue_handler(services_dir, topic)
      queue = Tina4::Queue.new(topic: topic)

      if handler.nil?
        puts "  ⚠ No consumer handler found for topic '#{topic}' in #{services_dir}."
        puts "    Scaffold one with: tina4ruby generate queue #{topic}"
        puts "    Draining (consume + ack) without processing."
      end

      mode = once ? "single-pass drain" : format("polling every %gs (Ctrl-C to stop)", poll)
      puts "  Queue worker on '#{topic}' — #{mode}..."

      processed = 0
      failed = 0
      begin
        queue.consume(topic, poll_interval: poll) do |job|
          begin
            handler.call(job.payload) unless handler.nil?
            job.complete
            processed += 1
          rescue StandardError, NotImplementedError => e
            # A bad job nacks (retry / dead-letter), the worker lives on —
            # parity with the Python master's `except Exception`. NotImplemented-
            # Error is a ScriptError (not a StandardError) in Ruby, so name it
            # explicitly: an UNFILLED `generate queue` scaffold stub raises it and
            # must nack the job, not crash the worker. Interrupt (Ctrl-C) is
            # neither, so it still propagates to the outer stop handler.
            job.fail(e.message)
            failed += 1
          end
        end
      rescue Interrupt
        puts "\n  Interrupted — stopping worker."
      end

      puts "  Processed #{processed} job(s), #{failed} failed on '#{topic}'."
    end

    # Print pending / in-flight / failed / dead-letter / completed counts.
    #
    #   tina4ruby queue stats [topic] [--json]
    def queue_stats(argv)
      require "json"
      load_queue_runtime
      flags, positional = parse_flags(argv)
      topic = positional[0] || "default"

      queue = Tina4::Queue.new(topic: topic)
      stats = {
        "topic"     => topic,
        "pending"   => queue.size(status: "pending"),      # waiting to run
        "reserved"  => queue.size(status: "reserved"),     # popped, not yet acked
        "failed"    => queue.failed.length,                # failed once, still retrying
        "dead"      => queue.size(status: "dead"),         # exhausted retries (dead-letter)
        "completed" => queue.size(status: "completed"),    # terminal-completed (0 on file backend)
      }

      if flags.key?("json")
        puts JSON.pretty_generate(stats)
        return
      end

      puts
      puts "  Queue '#{topic}'"
      puts "    pending    #{stats['pending']}"
      puts "    reserved   #{stats['reserved']}    (in-flight)"
      puts "    failed     #{stats['failed']}    (retrying)"
      puts "    dead       #{stats['dead']}    (dead-letter)"
      puts "    completed  #{stats['completed']}"
      puts
    end

    # Re-queue failed and dead-letter jobs so they run again.
    #
    #   tina4ruby queue retry [topic]
    #
    # Revives every dead-letter job (manual override, regardless of attempt
    # count) and re-queues any failed-but-still-eligible jobs.
    def queue_retry(argv)
      load_queue_runtime
      _flags, positional = parse_flags(argv)
      topic = positional[0] || "default"

      queue = Tina4::Queue.new(topic: topic)

      # max_retries: 0 => every job in the dead-letter store, whatever its
      # attempt count (matches what stats/size("dead") reports).
      dead = queue.dead_letters(max_retries: 0)
      revived = dead.count { |job| queue.retry(queue_job_id(job)) }
      # Any failed-but-retryable jobs still under the limit.
      requeued = queue.retry_failed

      total = revived + requeued
      puts "  Re-queued #{total} job(s) on '#{topic}' (#{revived} dead-letter, #{requeued} failed)."
    end

    # Purge jobs of a given status (default: completed).
    #
    #   tina4ruby queue clear [status] [topic]
    #
    # status is one of pending / reserved / completed / failed / dead. The
    # default 'completed' clears finished jobs; pass e.g. `queue clear pending`
    # or `queue clear dead orders` to purge another status / topic.
    def queue_clear(argv)
      load_queue_runtime
      _flags, positional = parse_flags(argv)
      status = positional[0] || "completed"
      topic = positional[1] || "default"

      queue = Tina4::Queue.new(topic: topic)
      removed = queue.purge(status)
      puts "  Cleared #{removed} '#{status}' job(s) from '#{topic}'."
    end

    # Extract a job id from either a raw backend Hash or a Job object, so
    # `queue retry` works regardless of what a backend's dead_letters returns.
    def queue_job_id(job)
      return job.id if job.respond_to?(:id)
      job["id"] || job[:id]
    end

    # ── build ─────────────────────────────────────────────────────────────
    #
    # Build the deployable Docker image for this Tina4 app. A Tina4 app deploys
    # as a container (`tina4ruby init` scaffolds a Dockerfile), so `build`
    # produces THAT artifact — it shells out to the `docker` CLI (no new gem)
    # and fails loud with guidance when there is no Dockerfile or docker is not
    # on PATH. Mirrors the Python master's `build`.
    #
    #   tina4ruby build                    # docker build -t <dir>:latest .
    #   tina4ruby build --tag myapp:1.2     # explicit image tag
    #   tina4ruby build --file docker/Dockerfile
    def cmd_build(argv)
      flags, _positional = parse_flags(argv)

      tag = flags["tag"]
      unless tag.is_a?(String) && !tag.empty?
        # Default tag: <project-folder>:latest, lower-cased (docker repo names
        # must be lowercase). Fall back to a sane name for an unnamed cwd.
        base = File.basename(Dir.pwd).downcase
        base = "tina4app" if base.empty?
        tag = "#{base}:latest"
      end

      dockerfile = flags["file"].is_a?(String) ? flags["file"] : "Dockerfile"
      unless File.file?(dockerfile)
        puts "  ✗ No #{dockerfile} found."
        puts "  A Tina4 app deploys as a container. Scaffold a Dockerfile first:"
        puts "      tina4 deploy docker        (or: tina4ruby init)"
        exit 1
      end

      docker = which_executable("docker")
      if docker.nil?
        puts "  ✗ docker was not found on PATH."
        puts "  Install Docker to build the deployable image, or build manually:"
        puts "      docker build -t #{tag} -f #{dockerfile} ."
        exit 1
      end

      puts "  Building image #{tag} from #{dockerfile} ..."
      ok = system(docker, "build", "-t", tag, "-f", dockerfile, ".")
      unless ok
        code = ($?&.exitstatus) || 1
        puts "  ✗ docker build failed (exit #{code})"
        exit code
      end
      puts "  ✓ Built image #{tag}"
      puts "  Run: docker run -p 7147:7147 #{tag}"
    end

    # Locate an executable on PATH — the stdlib-only equivalent of Python's
    # shutil.which (no new gem). Honours PATHEXT on Windows.
    def which_executable(cmd)
      exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(File::PATH_SEPARATOR) : [""]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?
        exts.each do |ext|
          candidate = File.join(dir, "#{cmd}#{ext}")
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
      end
      nil
    end

    # ── version ───────────────────────────────────────────────────────────

    def cmd_version(_argv = nil)
      require_relative "version"
      puts "Tina4 Ruby v#{Tina4::VERSION}"
    end

    # ── routes ────────────────────────────────────────────────────────────

    def cmd_routes(_argv = nil)
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

    def cmd_console(_argv = nil)
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
      all = GENERATORS.keys.join(", ")  # single source: the GENERATORS registry

      unless what
        puts "Usage: tina4ruby generate <what> <name> [options]"
        puts "  Generators: #{all}"
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

      # Dispatch from the GENERATORS registry (single source of truth for the
      # generate subcommands; also feeds #cmd_help and the manifest).
      gen_spec = GENERATORS[what]
      if gen_spec
        send(gen_spec[:handler], name, flags)
      else
        puts "Unknown generator: #{what}"
        puts "  Available: #{all}"
        exit 1
      end
    end

    # ── Generator: model ─────────────────────────────────────────────────

    def generate_model(name, flags, emit_test: true)
      fields = fields_or_default(flags["fields"])
      table = to_table_name(name)
      snake = to_snake_case(name)

      # Build field lines
      field_lines = ["  integer_field :id, primary_key: true, auto_increment: true"]
      fields.each do |fname, ftype|
        info = FIELD_TYPE_MAP[ftype] || FIELD_TYPE_MAP["string"]
        field_lines << "  #{info[:orm]} :#{fname}"
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

      # Generate matching migration (unless --no-migration). The model's own
      # co-emitted spec proves the schema through the real ORM, so the migration
      # sub-call does NOT also co-emit a migration spec (emit_test: false).
      unless flags["no-migration"]
        generate_migration("create_#{table}", flags, fields_override: fields,
                                                      table_override: table, emit_test: false)
      end

      # Co-emit a real SQLite roundtrip spec next to the model.
      emit_model_test(name, table, fields) if emit_test
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
    def generate_route(name, flags, emit_test: true)
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
            page = (request.query["page"] || 1).to_i
            per_page = (request.query["per_page"] || 20).to_i
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
            # create/save signal failure by RETURN VALUE, they do not raise -
            # unchecked, a failed write surfaces as an unrelated NoMethodError
            # on false and hides the real cause.
            next response.json({ error: "Could not create #{singular}" }, 400) if item == false

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
            next response.json({ error: "Could not update #{singular}" }, 400) if item.save == false

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

      # Co-emit a real spec. A --model route is working code → reuse the
      # secure-gate behavioural spec (reads public, writes gated) via
      # generate_test; a no-model route's handlers are loud stubs → the
      # Router-registration + live-stub spec.
      if emit_test
        if model
          generate_test(route_path, { "model" => model, "secure_writes" => true, "public" => public_writes })
        else
          emit_route_stub_test(route_path)
        end
      end
    end

    # ── Generator: crud ──────────────────────────────────────────────────

    def generate_crud(name, flags)
      table = to_table_name(name)
      route_name = "#{table}s"
      is_public = flags["public"] ? true : false

      puts "\n  Generating CRUD for #{name}...\n"

      # 1. Model + migration (emit_test: false — crud emits its own broader gate
      #    spec at step 5, so the sub-generators stay quiet to avoid double-emit).
      generate_model(name, flags, emit_test: false)

      # 2. Routes with model — secure-by-default; thread --public through so
      #    `generate crud X --public` opens the writes (mirrors AutoCrud public:).
      #    emit_test: false — the crud gate spec at step 5 targets the same file.
      generate_route(route_name, { "model" => name, "public" => is_public }, emit_test: false)

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

    def generate_migration(name, flags = {}, fields_override: nil, table_override: nil, emit_test: true)
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
      # An EMPTY array is truthy in Ruby, so a plain `fields_override || parse`
      # short-circuits to [] and the fallback never fires - that is exactly how
      # a model declaring `name` ended up with a column-less migration. Test for
      # content, not truthiness, so the semantics match Python/Node.
      fields = fields_override&.any? ? fields_override : parse_fields(flags["fields"])
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

      # The main .sql holds ONLY the UP migration. The runner executes the WHOLE
      # file (comments stripped), so embedding the DOWN here would CREATE then
      # immediately DROP the table — the migration would silently no-op. The
      # rollback SQL lives solely in the sibling .down.sql. Matches the Python
      # master (tina4_python/cli/__init__.py).
      content = <<~SQL
        -- Migration: #{name}
        -- Created: #{now.strftime("%Y-%m-%d %H:%M:%S")}

        #{up_sql}
      SQL

      File.write(path, content)
      puts "  Created #{path}"

      # Also create .down.sql for the migration runner
      down_filename = "#{timestamp}_#{name}.down.sql"
      down_path = File.join(dir, down_filename)
      down_content = <<~SQL
        -- Rollback: #{name}
        -- Created: #{now.strftime("%Y-%m-%d %H:%M:%S")}

        #{down_sql}
      SQL

      File.write(down_path, down_content)
      puts "  Created #{down_path}"

      # Co-emit a real apply-UP/DOWN spec — only for CREATE migrations, whose UP
      # SQL is real DDL to assert against (a placeholder ALTER has nothing yet).
      emit_migration_test(name, table, filename, down_filename) if emit_test && is_create
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
            Tina4::Log.info("#{name}: \#{request.method} \#{request.path}")
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

      # Co-emit a real dispatch spec (drives the scaffold through the real
      # server middleware dispatch — Tina4::Middleware.run_before/run_after).
      emit_middleware_test(name, snake)
    end

    # ── Generator: test ──────────────────────────────────────────────────

    def generate_test(name, flags = {})
      model = flags["model"]
      snake = to_snake_case(name)
      singular = snake.end_with?("s") ? snake[0..-2] : snake

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
        write_test(snake, content)
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

      write_test(snake, content)
    end

    # ── Generator: form ──────────────────────────────────────────────────

    def generate_form(name, flags = {})
      fields = fields_or_default(flags["fields"])
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
      fields.each do |fname, ftype|
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
      fields = fields_or_default(flags["fields"])
      table = to_table_name(name)
      route_name = "#{table}s"

      cols = fields.map { |f, _| f }

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

      # 1. User model + migration (emit_test: false — auth emits its own broader
      #    register/login/me spec at step 5).
      generate_model("User", { "fields" => "email:string,password:string,role:string" }, emit_test: false)

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

      # 5. Auth test — real register/login/me end-to-end (real Router, real Auth
      #    JWT + PBKDF2, real SQLite). Replaces the old placeholder stub spec.
      emit_auth_test

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

      # Co-emit a real ServiceRunner registration/discovery spec.
      emit_service_test(name, snake)
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
        # Discovered by Tina4::ServiceRunner.discover("src/services"). The `topic`
        # + per-job `handle` options let `tina4ruby queue work #{topic}` drive this
        # consumer directly (own the poll loop / bounded --once drain) without
        # wiring a ServiceRunner.
        Tina4.service("#{topic}-consumer", daemon: true, topic: "#{topic}", handle: method(:handle_#{slug})) { |context| consume_#{slug}(context) }
      RUBY
      File.write(path, content)
      puts "  Created #{path}"

      # Co-emit a real file-backed Queue spec (push a real job + daemon wiring).
      emit_queue_test(topic, slug)
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

      # Ships a working starter rule (not a loud stub): a rules-less validator
      # validates nothing, so there would be no negative case for the co-emitted
      # valid/invalid spec to assert against. `required("name")` mirrors the model
      # generator's default `name` field — edit it for your real payload.
      body = extend_marker(
        "add / adjust the rules for your #{name} payload",
        'e.g. validator.email("email").min_length("name", 2).integer("age") · ' \
        'ground: tina4_context("validate request body with Validator", "ruby")'
      ) + %(  validator.required("name")\n)
      content = <<~RUBY
        # #{name} request validator.
        #
        # Tina4::Validator comes with `require "tina4"` — no extra require needed.
        # This FILE is not auto-discovered though (only src/routes/ and src/orm/
        # are), so require it from the route that validates:
        #     require_relative "../validators/#{snake}"
        #     v = validate_#{snake}(request.body)
        #     next response.json({ error: v.errors.first[:message] }, 400) unless v.is_valid?

        def validate_#{snake}(data)
          validator = Tina4::Validator.new(data)
        #{body.chomp}
          validator
        end
      RUBY
      File.write(path, content)
      puts "  Created #{path}"

      # Co-emit a real valid + invalid spec against the starter rule.
      emit_validator_test(name, snake)
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

      # Ships working out of the box (not a loud stub): seed_orm auto-fills every
      # field by type/name, so a zero-override seeder already seeds real rows.
      # Return overrides only for fields that need a specific shape.
      body = extend_marker(
        "override #{name} fields that need a specific shape (optional)",
        'e.g. { "email" => ->(fake) { fake.email }, "status" => "active" } · ' \
        'ground: tina4_context("seed ORM model with FakeData", "ruby")'
      ) + %(  {}\n)
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
        # merely LOADING this file (e.g. from another script) is a no-op — only
        # `tina4ruby seed` (which binds the DB first) actually seeds. seed_orm
        # auto-fills every field, so this works out of the box.
        if Tina4.database
          fake = Tina4::FakeData.new
          summary = Tina4.seed_orm(#{name}, count: 20, overrides: #{table}_field_overrides(fake))
          puts "Seeded #{'#'}{summary.seeded} #{name} row(s), #{'#'}{summary.failed} failed"
        end
      RUBY
      File.write(path, content)
      puts "  Created #{path}"

      # Co-emit a real seeding spec (runs the seeder against real SQLite).
      emit_seeder_test(name, table)
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

      # Co-emit a real handler spec (Router registration + drives the handler).
      emit_websocket_test(ws_path, base, handler)
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

      # Co-emit a real event-bus spec (emit the real event, assert it ran).
      emit_listener_test(event, slug)
    end

    # ── co-emitted tests: every code-producing generator ships a real spec ──
    #
    # One shared writer (#write_test) + one focused builder per generator. The
    # builders are NOT copy-paste boilerplate — each drives a different real
    # subsystem (real SQLite / TestClient / Router / ServiceRunner / Queue /
    # event bus), grounded on the same real-collaborator patterns the
    # scaffolding-first acceptance matrix already proves. CRUD-shaped scaffolds
    # (working code) get behavioural specs; logic-shaped scaffolds (loud
    # NotImplementedError stubs) get wiring specs + a lock-in that the
    # placeholder fails loud. `test` itself (it IS the test generator) and
    # form/view (template-only, no Ruby logic to run) are the only exemptions.
    # Ruby mirror of the Python master's _write_test + _emit_* builders
    # (tina4_python/cli/__init__.py, owner req 2026-07-10, Phase 4).

    # Write a co-emitted spec to spec/<name>_spec.rb — the SINGLE place a
    # generated spec is written (path + overwrite refusal + the "Created" line
    # every generator prints). Generalized from #generate_test so the generators
    # share one rule instead of a dozen copy-pasted write blocks.
    def write_test(test_name, content)
      dir = "spec"
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{test_name}_spec.rb")
      if File.exist?(path)
        puts "  File already exists: #{path}"
        return
      end
      File.write(path, content)
      puts "  Created #{path}"
    end

    # snake/kebab/dotted -> PascalCase: user_created -> UserCreated.
    def pascalize(name)
      name.to_s.split(/[^0-9a-zA-Z]+/).reject(&:empty?).map { |part| part[0].upcase + part[1..].to_s }.join
    end

    # A source-text Ruby literal that is a valid value for a scaffolded field
    # type (used to build a real create() payload in the model spec).
    def sample_literal(field_type)
      {
        "int" => "1", "integer" => "1",
        "float" => "1.5", "numeric" => "1.5", "decimal" => "1.5",
        "bool" => "true", "boolean" => "true",
        "datetime" => '"2020-01-01 00:00:00"',
        "blob" => '"x"',
      }.fetch((field_type || "string").to_s.downcase, '"sample"')
    end

    # model -> real SQLite roundtrip (create / read back / missing -> nil).
    def emit_model_test(model, table, fields)
      # Reuse the single DEFAULT_FIELDS constant rather than re-stating the
      # literal, so the co-emitted spec can never describe a shape the model
      # does not actually have.
      fields = fields.empty? ? DEFAULT_FIELDS.map(&:dup) : fields
      payload = fields.map { |fname, ftype| %("#{fname}" => #{sample_literal(ftype)}) }.join(", ")
      # Assert a STRING field round-trips (type-safe); else just the id round-trips
      # (avoids datetime/bool/float equality pitfalls on the read-back).
      string_field = fields.find { |_f, t| %w[string str text].include?((t || "string").to_s.downcase) }
      value_assert = string_field ? %(\n      expect(fetched.#{string_field[0]}).to eq("sample")) : ""
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real ORM roundtrip spec for #{model} — no mocks, real SQLite.
        #
        # Generated with src/orm/#{table}.rb by `tina4ruby generate model #{model}`.
        # The model scaffold is working code, so this passes on generation: it
        # binds a real on-disk SQLite database, creates the table, saves a row and
        # reads it back.
        require "spec_helper"
        require "tmpdir"
        require_relative "../src/orm/#{table}"

        RSpec.describe "#{model} model (real SQLite)" do
          before(:each) do
            @dir = Dir.mktmpdir("#{table}_model")
            Tina4.bind_database(Tina4::Database.new("sqlite:///" + File.join(@dir, "test.db")))
            #{model}.create_table
          end

          after(:each) { FileUtils.rm_rf(@dir) }

          it "creates a row and reads it back" do
            row = #{model}.create({ #{payload} })
            expect(row).not_to be_nil
            expect(row.id).not_to be_nil
            fetched = #{model}.find(row.id)
            expect(fetched).not_to be_nil
            expect(fetched.id).to eq(row.id)#{value_assert}
          end

          it "returns nil for a missing id" do
            expect(#{model}.find(999999)).to be_nil
          end
        end
      RUBY
      write_test("#{table}_model", content)
    end

    # route (no --model) -> real Router registration + the handler is a live loud
    # stub. (route --model reuses the secure-gate #generate_test spec instead.)
    def emit_route_stub_test(route)
      klass = pascalize(route)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Routing spec for #{route} — no mocks, real Router.
        #
        # Generated with src/routes/#{route}.rb by `tina4ruby generate route
        # #{route}` (no --model). The handlers are AI-FILL stubs that raise until
        # you implement them, so this tests what IS live on generation: all five
        # routes register on the REAL Router, and the list handler fails loud until
        # filled. Fill a handler, then assert its real response here.
        require "spec_helper"

        RSpec.describe "#{klass} routing (real Router)" do
          before(:each) { load File.expand_path("../src/routes/#{route}.rb", __dir__) }

          it "registers all five CRUD routes" do
            paths = Tina4::Router.routes.map { |r| [r.method, r.path] }
            expect(paths).to include(["GET", "/api/#{route}"])
            expect(paths).to include(["GET", "/api/#{route}/{id:int}"])
            expect(paths).to include(["POST", "/api/#{route}"])
            expect(paths).to include(["PUT", "/api/#{route}/{id:int}"])
            expect(paths).to include(["DELETE", "/api/#{route}/{id:int}"])
          end

          it "the list handler is a live stub (raises until filled)" do
            route, = Tina4::Router.match("GET", "/api/#{route}")
            expect { route.handler.call(nil, nil) }.to raise_error(NotImplementedError)
          end
        end
      RUBY
      write_test(route, content)
    end

    # middleware -> a request routed THROUGH the real server dispatch.
    def emit_middleware_test(name, snake)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real dispatch spec for the #{name} middleware — no mocks.
        #
        # Generated with src/middleware/#{snake}.rb by `tina4ruby generate
        # middleware #{name}`. Drives the middleware through the REAL server
        # dispatch (Tina4::Middleware.run_before / run_after) with a real Request +
        # Response — the same code path the live server runs.
        require "spec_helper"
        require "stringio"
        require_relative "../src/middleware/#{snake}"

        RSpec.describe "#{name} middleware (real dispatch)" do
          before(:each) { Tina4::Middleware.clear! if Tina4::Middleware.respond_to?(:clear!) }

          def build_request
            env = {
              "REQUEST_METHOD" => "GET", "PATH_INFO" => "/", "QUERY_STRING" => "",
              "HTTP_HOST" => "localhost", "rack.input" => StringIO.new("")
            }
            Tina4::Request.new(env)
          end

          it "before_* passes the request through (does not block the handler)" do
            response = Tina4::Response.new
            ok = Tina4::Middleware.run_before([#{name}], build_request, response)
            expect(ok).to be true                 # the scaffold does not halt the chain
            expect(response.status_code).to be < 400
          end

          it "after_* runs and leaves the response intact" do
            response = Tina4::Response.new
            Tina4::Middleware.run_after([#{name}], build_request, response)
            expect(response.status_code).to be < 400
          end
        end
      RUBY
      write_test(snake, content)
    end

    # service -> registrable / discoverable on the REAL ServiceRunner + loud stub.
    def emit_service_test(name, snake)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real ServiceRunner spec for the #{name} service — no mocks.
        #
        # Generated with src/services/#{snake}.rb by `tina4ruby generate service
        # #{name}`. Loading the file registers the scaffold on the REAL
        # class-level ServiceRunner registry; the task body is an AI-FILL stub that
        # raises until filled.
        require "spec_helper"
        require_relative "../src/services/#{snake}"

        RSpec.describe "#{pascalize(snake)} service (real ServiceRunner)" do
          it "registers on the ServiceRunner registry" do
            expect(Tina4::ServiceRunner.list.any? { |s| s[:name] == "#{snake}" }).to be true
          end

          it "the task is a live stub (raises until filled)" do
            expect { #{snake}_task(nil) }.to raise_error(NotImplementedError)
          end
        end
      RUBY
      write_test(snake, content)
    end

    # queue -> push a REAL job onto the real file-backed Queue + daemon wiring.
    def emit_queue_test(topic, slug)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real file-backed Queue spec for the #{topic} worker — no mocks.
        #
        # Generated with src/services/#{slug}_consumer.rb by `tina4ruby generate
        # queue #{topic}`. Pushes a REAL job onto the real file-backed Queue and
        # asserts it is enqueued, and that the consumer is wired as a daemon
        # service. handle_#{slug} is an AI-FILL stub that raises until you fill it
        # — then assert the processed side effect here.
        require "spec_helper"
        require_relative "../src/services/#{slug}_consumer"

        RSpec.describe "#{pascalize(slug)} queue (real file-backed Queue)" do
          it "publish enqueues a real job" do
            before_size = Tina4::Queue.new(topic: "#{topic}").size
            job = publish_#{slug}({ "hello" => "world" })
            expect(job).not_to be_nil
            expect(job.id).not_to be_nil
            expect(Tina4::Queue.new(topic: "#{topic}").size).to be >= before_size + 1
          end

          it "the consumer is wired as a daemon service" do
            svc = Tina4::ServiceRunner.list.find { |s| s[:name] == "#{topic}-consumer" }
            expect(svc).not_to be_nil
            expect(svc[:options][:daemon]).to be true
          end

          it "handle_#{slug} is a live stub (raises until filled)" do
            expect { handle_#{slug}({}) }.to raise_error(NotImplementedError)
          end
        end
      RUBY
      write_test(slug, content)
    end

    # validator -> run the scaffold against valid + invalid real input.
    def emit_validator_test(name, snake)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real validation spec for validate_#{snake} — no mocks.
        #
        # Generated with src/validators/#{snake}.rb by `tina4ruby generate
        # validator #{name}`. The scaffold ships a starter rule (required "name"),
        # so this passes on generation — adjust the rules for your payload and
        # update these cases with them.
        require "spec_helper"
        require_relative "../src/validators/#{snake}"

        RSpec.describe "#{pascalize(snake)} validator" do
          it "valid input passes" do
            expect(validate_#{snake}({ "name" => "Ada" }).is_valid?).to be true
          end

          it "invalid input fails with errors" do
            result = validate_#{snake}({})
            expect(result.is_valid?).to be false
            expect(result.errors).not_to be_empty
          end
        end
      RUBY
      write_test(snake, content)
    end

    # seeder -> run the scaffold against real SQLite, assert rows created.
    def emit_seeder_test(model, table)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real seeding spec for the #{model} seeder — no mocks, real SQLite.
        #
        # Generated with seeds/#{table}_seeder.rb by `tina4ruby generate seeder
        # #{model}`. Binds a real SQLite DB, creates the table, then loads the
        # scaffolded seeder (its guarded block auto-fills every field via FakeData
        # and seeds rows) and asserts rows were created.
        require "spec_helper"
        require "tmpdir"
        require_relative "../src/orm/#{table}"

        RSpec.describe "#{model} seeder (real SQLite)" do
          before(:each) do
            @dir = Dir.mktmpdir("#{table}_seeder")
            Tina4.bind_database(Tina4::Database.new("sqlite:///" + File.join(@dir, "seed.db")))
            #{model}.create_table
          end

          after(:each) { FileUtils.rm_rf(@dir) }

          it "field_overrides returns a Hash" do
            load File.expand_path("../seeds/#{table}_seeder.rb", __dir__)
            expect(#{table}_field_overrides(Tina4::FakeData.new)).to be_a(Hash)
          end

          it "running the seeder creates rows" do
            load File.expand_path("../seeds/#{table}_seeder.rb", __dir__)
            expect(#{model}.count).to be >= 1
          end
        end
      RUBY
      write_test("#{table}_seeder", content)
    end

    # websocket -> real Router registration + drive the real handler (the
    # socket-free "close" event) directly (no mock socket).
    def emit_websocket_test(ws_path, base, _handler)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real handler spec for the #{ws_path} WebSocket route — no mocks.
        #
        # Generated with src/routes/ws_#{base}.rb by `tina4ruby generate websocket
        # ...`. Confirms the handler registers on the REAL Router and drives the
        # real handler for the :close event (no socket needed). The :message branch
        # is an AI-FILL stub that raises until you fill it; a full RFC6455 loopback
        # is out of scope for a unit spec, so assert its broadcast/response against
        # a live server once implemented.
        require "spec_helper"

        RSpec.describe "#{pascalize(base)} WebSocket (real Router)" do
          # `load` (not require) re-registers the handler after spec_helper's
          # after(:each) Router.clear! wipes the ws routes between examples.
          before(:each) { load File.expand_path("../src/routes/ws_#{base}.rb", __dir__) }

          def ws_route
            Tina4::Router.get_web_socket_routes.find { |r| r.path == "#{ws_path}" }
          end

          it "registers the handler on the Router ws routes" do
            expect(ws_route).not_to be_nil
          end

          it "handles the :close event cleanly (no connection needed)" do
            expect(ws_route.handler.call(nil, :close, nil)).to be_nil
          end

          it "the :message branch is a live stub (raises until filled)" do
            expect { ws_route.handler.call(nil, :message, "hi") }.to raise_error(NotImplementedError)
          end
        end
      RUBY
      write_test("ws_#{base}", content)
    end

    # listener -> emit the REAL event on the real bus, assert the listener ran.
    def emit_listener_test(event, slug)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real event-bus spec for the '#{event}' listener — no mocks.
        #
        # Generated with src/listeners/#{slug}.rb by `tina4ruby generate listener
        # #{event}`. Confirms the listener binds on the REAL event bus and that
        # emitting the event reaches it. The reaction body is an AI-FILL stub that
        # raises until filled, so a strict emit re-raises here (proving it ran).
        require "spec_helper"

        RSpec.describe "#{pascalize(slug)} listener (real event bus)" do
          before(:each) do
            Tina4::Events.clear
            load File.expand_path("../src/listeners/#{slug}.rb", __dir__)
          end

          it "binds on the event bus" do
            expect(Tina4::Events.events).to include("#{event}")
            expect(Tina4::Events.listeners("#{event}").length).to be >= 1
          end

          it "emitting reaches the listener (strict re-raises the stub)" do
            expect { Tina4::Events.emit("#{event}", { "id" => 1 }, strict: true) }.to raise_error(NotImplementedError)
          end
        end
      RUBY
      write_test(slug, content)
    end

    # auth -> real register / login / me end-to-end via the real TestClient.
    # No dynamic names (always User + /api/auth/*), so a fully-literal
    # single-quoted heredoc keeps the emitted `#{token}` interpolation intact.
    def emit_auth_test
      content = <<~'RUBY'
        # frozen_string_literal: true
        #
        # Real auth spec — register / login / me via the real TestClient.
        #
        # Generated with the auth scaffold by `tina4ruby generate auth`. No mocks:
        # real Router, real Auth (PBKDF2 + JWT), real SQLite. register + login are
        # public (.no_auth); the token from login authenticates /api/auth/me.
        require "spec_helper"
        require "tmpdir"
        require_relative "../src/orm/user"

        RSpec.describe "Auth (register / login / me via real TestClient)" do
          let(:client) { Tina4::TestClient.new }

          before(:each) do
            @dir = Dir.mktmpdir("auth_spec")
            # Fresh RSA key material so get_token / valid_token agree.
            Tina4::Auth.instance_variable_set(:@private_key, nil)
            Tina4::Auth.instance_variable_set(:@public_key, nil)
            Tina4::Auth.instance_variable_set(:@keys_dir, nil)
            Tina4::Auth.setup(@dir)
            # A stray API key would authorise every request regardless of the JWT.
            @prior_api_key = ENV.delete("TINA4_API_KEY")
            Tina4.bind_database(Tina4::Database.new("sqlite:///" + File.join(@dir, "auth.db")))
            User.create_table
            # `load` (not require) re-registers the routes after spec_helper's
            # after(:each) Router.clear! wipes them between examples.
            load File.expand_path("../src/routes/auth.rb", __dir__)
          end

          after(:each) do
            ENV["TINA4_API_KEY"] = @prior_api_key if @prior_api_key
            FileUtils.rm_rf(@dir)
          end

          it "register, then duplicate 409, then login, then me with the token" do
            reg = client.post("/api/auth/register", json: { email: "a@b.c", password: "secret12" })
            expect(reg.status).to eq(201)

            dup = client.post("/api/auth/register", json: { email: "a@b.c", password: "secret12" })
            expect(dup.status).to eq(409)

            login = client.post("/api/auth/login", json: { email: "a@b.c", password: "secret12" })
            expect(login.status).to eq(200)
            token = login.json["token"]
            expect(token).not_to be_nil

            me = client.get("/api/auth/me", headers: { "Authorization" => "Bearer #{token}" })
            expect(me.status).to eq(200)
            expect(me.json["email"]).to eq("a@b.c")
          end

          it "login with the wrong password is 401" do
            client.post("/api/auth/register", json: { email: "x@y.z", password: "secret12" })
            bad = client.post("/api/auth/login", json: { email: "x@y.z", password: "WRONG" })
            expect(bad.status).to eq(401)
          end

          it "me without a token is 401" do
            expect(client.get("/api/auth/me").status).to eq(401)
          end
        end
      RUBY
      write_test("auth", content)
    end

    # migration (create_*) -> apply UP then DOWN against real SQLite via the real
    # Migration runner, asserting the table appears then disappears. Only for
    # CREATE migrations — a placeholder ALTER migration has no real SQL yet.
    def emit_migration_test(migration_name, table, _up_file, _down_file)
      content = <<~RUBY
        # frozen_string_literal: true
        #
        # Real migration spec for #{migration_name} — no mocks, real SQLite.
        #
        # Generated with the migration by `tina4ruby generate migration
        # #{migration_name}`. Runs the migration through the REAL Tina4::Migration
        # runner against a fresh real SQLite database, asserts the table exists,
        # then rolls back and asserts it is gone — the raw UP/DOWN SQL the runner
        # executes.
        require "spec_helper"
        require "tmpdir"

        RSpec.describe "#{pascalize(table)} migration (real SQLite up/down)" do
          it "UP creates the table and DOWN drops it" do
            dir = Dir.mktmpdir("#{table}_migration")
            db = Tina4::Database.new("sqlite:///" + File.join(dir, "mig.db"))
            migrations_dir = File.expand_path("../migrations", __dir__)
            migration = Tina4::Migration.new(db, migrations_dir: migrations_dir)

            migration.run
            expect(db.table_exists?("#{table}")).to be true

            migration.rollback(1)
            expect(db.table_exists?("#{table}")).to be false

            db.close
            FileUtils.rm_rf(dir)
          end
        end
      RUBY
      write_test("#{table}_migration", content)
    end

    # ── help ──────────────────────────────────────────────────────────────

    # Print the human-readable command reference.
    #
    # Generated from the COMMANDS, DELEGATED and GENERATORS registries — the SAME
    # single source of truth that drives dispatch (#run / #cmd_generate) and the
    # `commands --json` manifest — so the help text can never drift from what
    # the CLI actually does.
    def cmd_help(_argv = nil)
      command_rows = COMMANDS.map do |name, spec|
        ["#{name} #{spec[:usage]}".rstrip, spec[:summary]]
      end
      delegated_rows = DELEGATED.map do |name, spec|
        ["#{name} #{spec[:usage]}".rstrip, spec[:summary]]
      end
      generator_rows = GENERATORS.map do |name, spec|
        ["generate #{name} #{spec[:usage]}".rstrip, spec[:summary]]
      end
      # Align summaries in a column; a left cell longer than the cap overflows
      # cleanly (2-space gap) rather than pushing every other summary out.
      pad = [46, (command_rows + delegated_rows + generator_rows).map { |left, _| left.length }.max].min

      row = lambda do |left, summary|
        gap = left.length <= pad ? pad : left.length
        "  #{left.ljust(gap)}  #{summary}"
      end

      lines = ["Tina4 Ruby CLI", "", "Usage: tina4ruby COMMAND [options]", "", "Commands:"]
      lines += command_rows.map { |left, summary| row.call(left, summary) }
      lines += ["", "Delegated to the #{CLIENT_BINARY} client (same behaviour in every framework):"]
      lines += delegated_rows.map { |left, summary| row.call(left, summary) }
      lines += ["  (these run the #{CLIENT_BINARY} client — install: " \
                "curl -fsSL https://tina4.com/install.sh | sh)"]
      lines += ["", "Generators:"]
      lines += generator_rows.map { |left, summary| row.call(left, summary) }
      lines += [
        "",
        "Scaffolding-first: logic-shaped generators (route without --model, service,",
        "queue, validator, seeder, websocket, listener) emit wiring + an AI-FILL",
        "placeholder (raise NotImplementedError) where the custom logic goes; CRUD-",
        "shaped ones emit working code. Writes are secure by default; use --public",
        "to open them.",
        "",
        "Field types: string, int, float, bool, text, datetime, blob",
        "Table names: singular by default (Product -> product)",
        "",
        "https://tina4.com",
        "",
        "Run 'tina4ruby COMMAND --help' for more information on a command.",
      ]
      puts lines.join("\n")
    end

    # ── commands (self-describing manifest) ─────────────────────────────────

    # Build the machine-readable manifest of the CLI's command surface.
    #
    # Pure data: reads the COMMANDS and DELEGATED registries and the framework
    # version — no bootstrap, no database, no migrations, no app imports. This is
    # exactly what `commands --json` serializes and what the tina4 client consumes
    # to discover which commands this framework supports.
    #
    # Commands handed to the `tina4` client carry "delegated" => true, so the
    # manifest describes the WHOLE surface the CLI accepts while still saying who
    # implements each one. The client needs no change: its help renderer already
    # drops manifest names that clash with its own natives.
    #
    # Shape:
    #   { "framework" => "ruby", "version" => "<x.y.z>",
    #     "commands" => [ { "name", "summary", "args"?, "subcommands"?, "delegated"? }, ... ] }
    def commands_manifest
      require_relative "version"
      commands = COMMANDS.map do |name, spec|
        entry = { "name" => name, "summary" => spec[:summary] }
        entry["args"] = spec[:args].dup if spec[:args]
        entry["subcommands"] = spec[:subcommands].dup if spec[:subcommands]
        entry
      end
      commands += DELEGATED.map do |name, spec|
        entry = { "name" => name, "summary" => spec[:summary], "delegated" => true }
        entry["args"] = spec[:args].dup if spec[:args]
        entry
      end
      { "framework" => "ruby", "version" => Tina4::VERSION, "commands" => commands }
    end

    # Emit the CLI's own command surface — the self-describing manifest.
    #
    #   tina4ruby commands           human-readable list
    #   tina4ruby commands --json    machine-readable manifest (for the tina4 client)
    #
    # CHEAP + side-effect-free by contract: it only prints the static COMMANDS
    # registry plus the framework version. It MUST NOT bootstrap the framework,
    # open a database, run migrations, or load app modules — the tina4 client
    # calls this on `tina4 --help`, in any directory, so it must be instant and
    # safe to run anywhere.
    def cmd_commands(argv = nil)
      require "json"
      argv = argv || []
      manifest = commands_manifest

      if argv.include?("--json")
        puts JSON.pretty_generate(manifest)
        return
      end

      puts "\nTina4 #{manifest['framework']} - #{manifest['version']}\n\n"
      width = manifest["commands"].map { |command| command["name"].length }.max
      manifest["commands"].each do |command|
        marker = command["delegated"] ? " (#{CLIENT_BINARY} client)" : ""
        puts "  #{command['name'].ljust(width)}  #{command['summary']}#{marker}"
        if command["subcommands"]
          puts "  #{''.ljust(width)}    #{command['subcommands'].join(', ')}"
        end
      end
      puts
    end

    # ── config resolution ──────────────────────────────────────────────────

    DEFAULT_PORT = 7147
    DEFAULT_HOST = "0.0.0.0"

    # Priority: CLI flag > TINA4_PORT > PORT (deprecated) > default.
    #
    # This used to read bare PORT only, ignoring TINA4_PORT entirely, while
    # Tina4.resolve_bind_port (which WebServer/Tina4.run! use) and
    # Tina4.mcp_port (the +2000 supervisor port) both already read
    # TINA4_PORT first. So under `tina4ruby serve` with only TINA4_PORT set,
    # this method alone fell through to bare PORT/DEFAULT_PORT while the
    # AI port (base+1000, derived from THIS resolved base) and the supervisor
    # port derived from a DIFFERENT base -- three ports, two answers for the
    # same knob (DUALPORT-DEC-02, DUALPORT-BASE-PRECEDENCE). Not delegated to
    # Tina4.resolve_bind_port itself: this runs before `require_relative
    # "../tina4"` below, so the Tina4 module is not loaded yet at this point.
    def resolve_config(key, cli_value)
      case key
      when :port
        return cli_value if cli_value
        tina4_port = ENV["TINA4_PORT"]
        return tina4_port.to_i if tina4_port && tina4_port.match?(/\A\d+\z/)
        return ENV["PORT"].to_i if ENV["PORT"] && !ENV["PORT"].empty?
        DEFAULT_PORT
      when :host
        return cli_value if cli_value
        # Host: CLI flag > TINA4_HOST > HOST > default. TINA4_HOST wins over the
        # legacy plain HOST so a stray OS-level HOST (shared CI runners) can't
        # silently override the framework's bind. Parity with Python's
        # resolve_config.
        return ENV["TINA4_HOST"] if ENV["TINA4_HOST"] && !ENV["TINA4_HOST"].empty?
        return ENV["HOST"] if ENV["HOST"] && !ENV["HOST"].empty?
        # DEVADMIN-DEC-02 (feature 127): in dev/serve mode the dashboard exposes
        # an unauthenticated file/SQL/RCE surface, so the DEFAULT bind is
        # loopback, not 0.0.0.0. Only the DEFAULT changes: production
        # (TINA4_DEBUG off) keeps 0.0.0.0, and a developer who WANTS network
        # exposure sets TINA4_HOST=0.0.0.0 to override deliberately.
        Tina4.truthy?(ENV["TINA4_DEBUG"]) ? "127.0.0.1" : DEFAULT_HOST
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
          data/queue/
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

          # Swagger defaults (override with env vars in docker-compose/k8s if needed).
          # The TINA4_ prefix is REQUIRED: the un-prefixed names are the legacy
          # v2/v3.11 forms, and check_legacy_env_vars! refuses to boot when it
          # finds one, so a generated image would exit 2 during startup.
          ENV TINA4_SWAGGER_TITLE="Tina4 API"
          ENV TINA4_SWAGGER_VERSION="0.1.0"
          ENV TINA4_SWAGGER_DESCRIPTION="Auto-generated API documentation"

          # Required: WebServer#start exits 1 unless the tina4 CLI launched it
          # (--managed) or this is set. A container has no CLI supervising it.
          ENV TINA4_OVERRIDE_CLIENT=true
          ENV TINA4_DEBUG=false

          # Start the server on all interfaces
          CMD ["bundle", "exec", "tina4ruby", "start", "-p", "7147", "-h", "0.0.0.0", "--production"]
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
          data/queue/
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
            <!-- tina4-js reactive frontend (signals, components, router).
                 Served from the framework's bundled public dir, same as
                 tina4-python/example/src/templates/base.twig:47-48 and
                 tina4-php/example/src/templates/base.twig:47-48. -->
            <script src="/js/tina4js.min.js"></script>
            {% block scripts %}{% endblock %}
          </body>
          </html>
        HTML
      end
    end
  end
end
