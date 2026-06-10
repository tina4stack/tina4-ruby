# frozen_string_literal: true

require "fileutils"

module Tina4
  # Tina4 AI -- Install AI coding assistant context files.
  #
  # Simple menu-driven installer for AI tool context files.
  # The user picks which tools they use, we install the appropriate files.
  #
  #   selection = Tina4::AI.show_menu(".")
  #   Tina4::AI.install_selected(".", selection)
  #
  module AI
    # Ordered list of supported AI tools
    AI_TOOLS = [
      { name: "claude-code", description: "Claude Code", context_file: "CLAUDE.md", config_dir: ".claude" },
      { name: "cursor", description: "Cursor", context_file: ".cursorules", config_dir: ".cursor" },
      { name: "copilot", description: "GitHub Copilot", context_file: ".github/copilot-instructions.md", config_dir: ".github" },
      { name: "windsurf", description: "Windsurf", context_file: ".windsurfrules", config_dir: nil },
      { name: "aider", description: "Aider", context_file: "CONVENTIONS.md", config_dir: nil },
      { name: "cline", description: "Cline", context_file: ".clinerules", config_dir: nil },
      { name: "codex", description: "OpenAI Codex", context_file: "AGENTS.md", config_dir: nil }
    ].freeze

    class << self
      # Check if a tool's context file already exists.
      #
      # @param root [String] project root directory
      # @param tool [Hash] tool entry from AI_TOOLS
      # @return [Boolean]
      def is_installed(root, tool)
        File.exist?(File.join(File.expand_path(root), tool[:context_file]))
      end

      # Print the numbered menu and return user input.
      #
      # @param root [String] project root directory (default: ".")
      # @return [String] user input (comma-separated numbers or "all")
      def show_menu(root = ".")
        root = File.expand_path(root)
        green = "\e[32m"
        reset = "\e[0m"

        puts "\n  Tina4 AI Context Installer\n"
        AI_TOOLS.each_with_index do |tool, i|
          marker = is_installed(root, tool) ? "  #{green}[installed]#{reset}" : ""
          puts format("  %d. %-20s %s%s", i + 1, tool[:description], tool[:context_file], marker)
        end

        # tina4-ai tools option
        tina4_ai_installed = system("which mdview > /dev/null 2>&1")
        marker = tina4_ai_installed ? "  #{green}[installed]#{reset}" : ""
        puts "  8. Install tina4-ai tools  (requires Python)#{marker}"
        puts

        print "  Select (comma-separated, or 'all'): "
        $stdin.gets&.strip || ""
      end

      # Install context files for the selected tools.
      #
      # @param root [String] project root directory
      # @param selection [String] comma-separated numbers like "1,2,3" or "all"
      # @return [Array<String>] list of created/updated file paths
      def install_selected(root, selection)
        root_path = File.expand_path(root)
        created = []

        if selection.downcase == "all"
          indices = (0...AI_TOOLS.length).to_a
          do_tina4_ai = true
        else
          parts = selection.split(",").map(&:strip).reject(&:empty?)
          indices = []
          do_tina4_ai = false
          parts.each do |p|
            n = Integer(p) rescue next
            if n == 8
              do_tina4_ai = true
            elsif n >= 1 && n <= AI_TOOLS.length
              indices << (n - 1)
            end
          end
        end

        indices.each do |idx|
          tool = AI_TOOLS[idx]
          context = generate_context(tool[:name])
          files = install_for_tool(root_path, tool, context)
          created.concat(files)
        end

        install_tina4_ai if do_tina4_ai

        created
      end

      # Install context for all AI tools (non-interactive).
      #
      # @param root [String] project root directory
      # @return [Array<String>] list of created/updated file paths
      def install_all(root = ".")
        install_selected(root, "all")
      end

      # Generate per-tool Tina4 Ruby context document.
      #
      # @param tool_name [String] AI tool name (default: "claude-code")
      # @return [String]
      def generate_context(tool_name = "claude-code")
        case tool_name
        when "claude-code"
          generate_claude_code_context
        when "cursor"
          generate_cursor_context
        when "copilot"
          generate_copilot_context
        when "windsurf"
          generate_windsurf_context
        when "aider"
          generate_aider_context
        when "cline"
          generate_cline_context
        when "codex"
          generate_codex_context
        else
          generate_claude_code_context
        end
      end

      # Install context file for a single tool.
      #
      # @param root [String] absolute project root path
      # @param tool [Hash] tool entry from AI_TOOLS
      # @param context [String] generated context content
      # @return [Array<String>] list of created/updated relative file paths
      # ── v3.13.9: non-destructive context-file writer ─────────────────
      #
      # Pre-v3.13.9 the installer wrote a full developer guide to
      # CLAUDE.md (and the other context files) on every run, clobbering
      # whatever the user had put there. Now it writes only a marker-
      # bracketed Tina4 skill block -- pointing the assistant at
      # .claude/skills/tina4-*/SKILL.md -- and leaves the rest alone.

      # Return [start, end] markers for the given context file.
      def markers_for(context_file)
        if context_file.downcase.end_with?(".md")
          ["<!-- tina4-skills:start -->", "<!-- tina4-skills:end -->"]
        else
          ["# tina4-skills:start", "# tina4-skills:end"]
        end
      end

      # Return the marker-bracketed Tina4 skill registration block.
      def skill_block(context_file)
        start, finish = markers_for(context_file)
        body = if context_file.downcase.end_with?(".md")
          "## Tina4 Skills\n\n" \
          "When working on this Tina4 project, these skills give the assistant project-aware behaviour:\n\n" \
          "- **tina4-developer** -- Read `.claude/skills/tina4-developer/SKILL.md` before building features.\n" \
          "- **tina4-js** -- Read `.claude/skills/tina4-js/SKILL.md` for frontend work.\n" \
          "- **tina4-maintainer** -- Read `.claude/skills/tina4-maintainer/SKILL.md` for framework-level changes.\n\n" \
          "See https://tina4.com for full docs."
        else
          "Tina4 Skills -- read these files before working on this project:\n" \
          "  .claude/skills/tina4-developer/SKILL.md   (feature development)\n" \
          "  .claude/skills/tina4-js/SKILL.md          (frontend / tina4-js)\n" \
          "  .claude/skills/tina4-maintainer/SKILL.md  (framework-level changes)\n" \
          "Docs: https://tina4.com"
        end
        "#{start}\n#{body}\n#{finish}"
      end

      # True iff both start and end markers appear in order.
      def has_markers?(existing, start, finish)
        s_idx = existing.index(start)
        return false unless s_idx
        !existing.index(finish, s_idx + start.length).nil?
      end

      # Replace the bracketed block in `existing` with `block`.
      def replace_marker_block(existing, block, start, finish)
        s_idx = existing.index(start)
        return existing.rstrip + "\n\n" + block + "\n" unless s_idx
        e_idx = existing.index(finish, s_idx + start.length)
        return existing.rstrip + "\n\n" + block + "\n" unless e_idx
        before = existing[0...s_idx].rstrip
        after = existing[(e_idx + finish.length)..].sub(/\A\n+/, "")
        glue_before = before.empty? ? "" : "\n\n"
        glue_after = after.empty? ? "\n" : "\n" + after
        "#{before}#{glue_before}#{block}#{glue_after}"
      end

      # Headers the pre-v3.13.9 installer wrote at the top of CLAUDE.md.
      OLD_FRAMEWORK_HEADERS = [
        "# Tina4 Python",
        "# Tina4 PHP",
        "# Tina4 Ruby",
        "# CLAUDE.md -- AI Developer Guide for tina4-nodejs",
        "# CLAUDE.md — AI Developer Guide for tina4-nodejs",
      ].freeze

      def looks_like_old_framework_install?(existing)
        head = existing.lstrip[0, 400] || ""
        OLD_FRAMEWORK_HEADERS.any? { |h| head.start_with?(h) }
      end

      # Write the context file non-destructively. Returns a human-readable
      # action verb for the caller's log line.
      #
      # Four branches:
      #   1. Doesn't exist  -> write framework guide + skill block
      #   2. Has markers    -> refresh just the skill block (idempotent)
      #   3. Old header     -> migrate: replace old dump with new guide + block
      #   4. User content   -> append the skill block, preserve everything else
      def write_or_merge(context_path, context_file, framework_guide)
        # Force UTF-8 — CLAUDE.md and the framework guide both contain
        # non-ASCII (em-dashes, ✓, etc.). Without this, File.read may
        # return ASCII-8BIT and string concat raises CompatibilityError.
        block = skill_block(context_file).dup.force_encoding("UTF-8")
        guide = framework_guide.dup.force_encoding("UTF-8")
        start, finish = markers_for(context_file)

        unless File.exist?(context_path)
          File.write(context_path, guide.rstrip + "\n\n" + block + "\n", encoding: "UTF-8")
          return "Installed"
        end

        existing = File.read(context_path, encoding: "UTF-8")

        if has_markers?(existing, start, finish)
          File.write(context_path, replace_marker_block(existing, block, start, finish), encoding: "UTF-8")
          return "Refreshed skill block in"
        end

        if looks_like_old_framework_install?(existing)
          head = existing.lstrip
          preamble = existing[0, existing.length - head.length] || ""
          new_content = (preamble.strip.empty? ? "" : preamble.rstrip + "\n\n") +
                        guide.rstrip + "\n\n" + block + "\n"
          File.write(context_path, new_content, encoding: "UTF-8")
          return "Migrated (replaced old framework dump in)"
        end

        File.write(context_path, existing.rstrip + "\n\n" + block + "\n", encoding: "UTF-8")
        "Appended skill block to"
      end

      def install_for_tool(root, tool, context)
        created = []
        context_path = File.join(root, tool[:context_file])

        # Create directories
        if tool[:config_dir]
          FileUtils.mkdir_p(File.join(root, tool[:config_dir]))
        end
        FileUtils.mkdir_p(File.dirname(context_path))

        # v3.13.9: non-destructive write -- see write_or_merge below.
        action = write_or_merge(context_path, tool[:context_file], context)
        rel = context_path.sub("#{root}/", "")
        created << rel
        puts "  \e[32m✓\e[0m #{action} #{rel}"

        # Claude-specific extras
        if tool[:name] == "claude-code"
          skills = install_claude_skills(root)
          created.concat(skills)
        end

        created
      end

      # Copy Claude Code skill files from the framework's templates.
      #
      # @param root [String] absolute project root path
      # @return [Array<String>] list of created/updated relative file paths
      def install_claude_skills(root)
        created = []

        # Determine the framework root (where lib/tina4/ lives)
        framework_root = File.expand_path("../../..", __FILE__)

        # Copy skill directories from .claude/skills/ in the framework to the project
        framework_skills_dir = File.join(framework_root, ".claude", "skills")
        if Dir.exist?(framework_skills_dir)
          target_skills_dir = File.join(root, ".claude", "skills")
          FileUtils.mkdir_p(target_skills_dir)
          Dir.children(framework_skills_dir).each do |entry|
            skill_dir = File.join(framework_skills_dir, entry)
            next unless File.directory?(skill_dir)

            target_dir = File.join(target_skills_dir, entry)
            FileUtils.rm_rf(target_dir) if Dir.exist?(target_dir)
            FileUtils.cp_r(skill_dir, target_dir)
            rel = target_dir.sub("#{root}/", "")
            created << rel
            puts "  \e[32m✓\e[0m Updated #{rel}"
          end
        end

        # Copy claude-commands if they exist
        commands_source = File.join(framework_root, "templates", "ai", "claude-commands")
        if Dir.exist?(commands_source)
          commands_dir = File.join(root, ".claude", "commands")
          FileUtils.mkdir_p(commands_dir)
          Dir.glob(File.join(commands_source, "*.md")).each do |skill_file|
            target = File.join(commands_dir, File.basename(skill_file))
            FileUtils.cp(skill_file, target)
            rel = target.sub("#{root}/", "")
            created << rel
          end
        end

        created
      end

      # Install tina4-ai package (provides mdview for markdown viewing).
      def install_tina4_ai
        puts "  Installing tina4-ai tools..."
        %w[pip3 pip].each do |cmd|
          next unless system("which #{cmd} > /dev/null 2>&1")

          result = `#{cmd} install --upgrade tina4-ai 2>&1`
          # Subprocess output is ASCII-8BIT — force UTF-8 with byte replacement
          # so non-ASCII content (often emitted by pip on locale mismatch)
          # doesn't crash String#strip with Encoding::CompatibilityError.
          safe_result = result.dup.force_encoding("UTF-8")
          unless safe_result.valid_encoding?
            safe_result = safe_result.encode("UTF-8", "UTF-8", invalid: :replace, undef: :replace, replace: "?")
          end
          if $?.success?
            puts "  \e[32m✓\e[0m Installed tina4-ai (mdview)"
            return
          else
            puts "  \e[33m!\e[0m #{cmd} failed: #{safe_result.strip[0..100]}"
          end
        end
        puts "  \e[33m!\e[0m Python/pip not available -- skip tina4-ai"
      end

      private

      # Read existing CLAUDE.md from the framework root.
      #
      # @return [String]
      def generate_claude_code_context
        framework_root = File.expand_path("../../..", __FILE__)
        claude_md = File.join(framework_root, "CLAUDE.md")
        if File.exist?(claude_md)
          File.read(claude_md)
        else
          "# Tina4 Ruby #{Tina4::VERSION}\n\nSee https://tina4.com for documentation.\n"
        end
      end

      # Cursor context (~45 lines).
      #
      # @return [String]
      def generate_cursor_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Cursor Rules

          You are working in a **Tina4 Ruby** project — a zero-dependency, batteries-included web framework.
          Documentation: https://tina4.com

          ## Project Structure

          ```
          src/routes/    — Route handlers (auto-discovered)
          src/orm/       — ORM models
          src/templates/ — Twig templates
          src/app/       — Service classes
          src/scss/      — SCSS (auto-compiled)
          src/public/    — Static assets
          src/seeds/     — Database seeders
          migrations/    — SQL migration files
          spec/          — RSpec tests
          ```

          ## Route Pattern

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end
          ```

          ## ORM Pattern

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end
          ```

          ## Conventions

          1. Routes return `response.call(data, status)` — never `puts` or `render`
          2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
          3. Every template extends `base.twig`
          4. All schema changes via migrations — never create tables in route code
          5. Use built-in features — never install gems for things Tina4 already provides
          6. Service pattern — complex logic in `src/app/`, routes stay thin
          7. Use `snake_case` for methods and variables

          ## Built-in Features (No Gems Needed)

          Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions (File/Redis/Valkey/MongoDB/DB), GraphQL + GraphiQL, WebSocket + Redis backplane, WSDL/SOAP, Queue (File/RabbitMQ/Kafka/MongoDB), HTTP client, Messenger (SMTP/IMAP), FakeData/Seeder, Migrations, SCSS compiler, Swagger/OpenAPI, i18n, Events, Container/DI, HtmlElement, Inline testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server
        CONTEXT
      end

      # GitHub Copilot context (~30 lines).
      #
      # @return [String]
      def generate_copilot_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Copilot Instructions

          This is a **Tina4 Ruby** project. Tina4 is a zero-dependency web framework. Docs: https://tina4.com

          ## Structure

          Routes in `src/routes/`, ORM models in `src/orm/`, templates in `src/templates/`, services in `src/app/`, tests in `spec/`.

          ## Route Example

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end
          ```

          ## ORM Example

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end
          ```

          ## Rules

          - Always return `response.call(data, status)` from routes
          - GET is public; POST/PUT/PATCH/DELETE require auth by default
          - Templates extend `base.twig`; schema changes via migrations only
          - Use `snake_case`; never install gems for built-in features
          - Built-in: Router, ORM, Database, JWT auth, Sessions, GraphQL, WebSocket, Queue, Messenger, Migrations, SCSS, Swagger, i18n, Events, DI, Testing
        CONTEXT
      end

      # Windsurf context (~60 lines).
      #
      # @return [String]
      def generate_windsurf_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Windsurf Rules

          You are working in a **Tina4 Ruby** project — a zero-dependency, batteries-included web framework.
          Documentation: https://tina4.com

          ## Project Structure

          ```
          src/routes/    — Route handlers (auto-discovered)
          src/orm/       — ORM models
          src/templates/ — Twig templates
          src/app/       — Service classes
          src/scss/      — SCSS (auto-compiled)
          src/public/    — Static assets
          src/seeds/     — Database seeders
          migrations/    — SQL migration files
          spec/          — RSpec tests
          ```

          ## CLI Commands

          ```bash
          tina4ruby init .          # Scaffold project
          tina4ruby serve           # Start dev server on port 7147
          tina4ruby migrate         # Run database migrations
          tina4ruby test            # Run test suite
          tina4ruby routes          # List all registered routes
          ```

          ## Route Pattern

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end
          ```

          ## ORM Pattern

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end
          ```

          ## Template Pattern

          ```twig
          {% extends "base.twig" %}
          {% block content %}
          <div class="container">
            <h1>{{ title }}</h1>
            {% for item in items %}
              <p>{{ item.name }}</p>
            {% endfor %}
          </div>
          {% endblock %}
          ```

          ## Conventions

          1. Routes return `response.call(data, status)` — never `puts` or `render`
          2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
          3. Every template extends `base.twig`
          4. All schema changes via migrations — never create tables in route code
          5. Use built-in features — never install gems for things Tina4 already provides
          6. Service pattern — complex logic in `src/app/`, routes stay thin
          7. Use `snake_case` for methods and variables

          ## Built-in Features (No Gems Needed)

          Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions (File/Redis/Valkey/MongoDB/DB), GraphQL + GraphiQL, WebSocket + Redis backplane, WSDL/SOAP, Queue (File/RabbitMQ/Kafka/MongoDB), HTTP client, Messenger (SMTP/IMAP), FakeData/Seeder, Migrations, SCSS compiler, Swagger/OpenAPI, i18n, Events, Container/DI, HtmlElement, Inline testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server

          ## Database Drivers

          SQLite, PostgreSQL, MySQL, MSSQL, Firebird. Connection string format: `driver://host:port/database`.

          ## Auth

          JWT auth built-in via `Tina4::Auth`. `secure_get` / `secure_post` for protected routes. Password hashing via `Tina4::Auth.hash_password` / `check_password`.
        CONTEXT
      end

      # Aider context (~58 lines).
      #
      # @return [String]
      def generate_aider_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Conventions

          ## Framework

          Tina4 Ruby is a zero-dependency, batteries-included web framework. Docs: https://tina4.com

          ## Project Structure

          ```
          src/routes/    — Route handlers (auto-discovered)
          src/orm/       — ORM models
          src/templates/ — Twig templates
          src/app/       — Service classes
          src/scss/      — SCSS (auto-compiled)
          src/public/    — Static assets
          src/seeds/     — Database seeders
          migrations/    — SQL migration files
          spec/          — RSpec tests
          ```

          ## CLI

          ```bash
          tina4ruby init .          # Scaffold project
          tina4ruby serve           # Start dev server on port 7147
          tina4ruby migrate         # Run database migrations
          tina4ruby test            # Run test suite
          tina4ruby routes          # List all registered routes
          ```

          ## Route Pattern

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end
          ```

          ## ORM Pattern

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end
          ```

          ## Conventions

          1. Routes return `response.call(data, status)` — never `puts` or `render`
          2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
          3. Every template extends `base.twig`
          4. All schema changes via migrations — never create tables in route code
          5. Use built-in features — never install gems for things Tina4 already provides
          6. Service pattern — complex logic in `src/app/`, routes stay thin
          7. Use `snake_case` for methods and variables
          8. Wrap route logic in `begin/rescue`, log with `Tina4::Log.error()`

          ## Built-in Features

          Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions (File/Redis/Valkey/MongoDB/DB), GraphQL + GraphiQL, WebSocket + Redis backplane, WSDL/SOAP, Queue (File/RabbitMQ/Kafka/MongoDB), HTTP client, Messenger (SMTP/IMAP), FakeData/Seeder, Migrations, SCSS compiler, Swagger/OpenAPI, i18n, Events, Container/DI, HtmlElement, Inline testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server

          ## Testing

          Run: `bundle exec rspec` or `tina4ruby test`. Tests in `spec/`.
        CONTEXT
      end

      # Cline context (~42 lines).
      #
      # @return [String]
      def generate_cline_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Cline Rules

          Tina4 Ruby is a zero-dependency web framework. Docs: https://tina4.com

          ## Structure

          ```
          src/routes/    — Route handlers (auto-discovered)
          src/orm/       — ORM models
          src/templates/ — Twig templates
          src/app/       — Service classes
          src/scss/      — SCSS (auto-compiled)
          src/public/    — Static assets
          src/seeds/     — Database seeders
          migrations/    — SQL migration files
          spec/          — RSpec tests
          ```

          ## Route Pattern

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end
          ```

          ## ORM Pattern

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end
          ```

          ## Conventions

          1. Routes return `response.call(data, status)` — never `puts` or `render`
          2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
          3. Every template extends `base.twig`
          4. All schema changes via migrations — never create tables in route code
          5. Use built-in features — never install gems for things Tina4 already provides
          6. Service pattern — complex logic in `src/app/`, routes stay thin
          7. Use `snake_case` for methods and variables

          ## Built-in Features

          Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions, GraphQL, WebSocket, Queue, Messenger, Migrations, SCSS, Swagger, i18n, Events, Container/DI, Testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server
        CONTEXT
      end

      # OpenAI Codex context (~70 lines).
      #
      # @return [String]
      def generate_codex_context
        <<~CONTEXT
          # Tina4 Ruby #{Tina4::VERSION} — Codex Agent Instructions

          You are working in a **Tina4 Ruby** project — a zero-dependency, batteries-included web framework.
          Documentation: https://tina4.com

          ## Project Structure

          ```
          src/routes/    — Route handlers (auto-discovered)
          src/orm/       — ORM models
          src/templates/ — Twig templates
          src/app/       — Service classes
          src/scss/      — SCSS (auto-compiled)
          src/public/    — Static assets
          src/seeds/     — Database seeders
          migrations/    — SQL migration files
          spec/          — RSpec tests
          ```

          ## CLI Commands

          ```bash
          tina4ruby init .          # Scaffold project
          tina4ruby serve           # Start dev server on port 7147
          tina4ruby serve --dev     # Dev mode with auto-reload
          tina4ruby migrate         # Run database migrations
          tina4ruby test            # Run test suite
          tina4ruby routes          # List all registered routes
          tina4ruby seed            # Run database seeders
          ```

          ## Route Pattern

          ```ruby
          Tina4.get "/api/users" do |request, response|
            response.call({ users: [] }, Tina4::HTTP_OK)
          end

          Tina4.post "/api/users" do |request, response|
            response.call({ created: request.body["name"] }, 201)
          end

          # Protected GET route
          Tina4.secure_get "/api/admin/users" do |request, response|
            response.call({ users: User.all }, Tina4::HTTP_OK)
          end

          # Route with template rendering
          Tina4::Router.get "/dashboard", template: "dashboard.twig" do |request, response|
            response.call({ title: "Dashboard" }, Tina4::HTTP_OK)
          end
          ```

          ## ORM Pattern

          ```ruby
          class User < Tina4::ORM
            table_name "users"
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name, required: true
            string_field :email
          end

          # Usage
          user = User.create(name: "Alice", email: "alice@example.com")
          users = User.where("name LIKE ?", ["%ali%"])
          user = User.find(1)
          ```

          ## Template Pattern

          ```twig
          {% extends "base.twig" %}
          {% block content %}
          <div class="container">
            <h1>{{ title }}</h1>
            {% for item in items %}
              <p>{{ item.name }}</p>
            {% endfor %}
          </div>
          {% endblock %}
          ```

          ## Conventions

          1. Routes return `response.call(data, status)` — never `puts` or `render`
          2. GET routes are public; POST/PUT/PATCH/DELETE require auth by default
          3. Every template extends `base.twig`
          4. All schema changes via migrations — never create tables in route code
          5. Use built-in features — never install gems for things Tina4 already provides
          6. Service pattern — complex logic in `src/app/`, routes stay thin
          7. Use `snake_case` for methods and variables
          8. Wrap route logic in `begin/rescue`, log with `Tina4::Log.error()`
          9. Database drivers: SQLite, PostgreSQL, MySQL, MSSQL, Firebird

          ## Built-in Features (No Gems Needed)

          Router, ORM, Database (SQLite/PostgreSQL/MySQL/MSSQL/Firebird), Frond templates (Twig-compatible), JWT auth, Sessions (File/Redis/Valkey/MongoDB/DB), GraphQL + GraphiQL, WebSocket + Redis backplane, WSDL/SOAP, Queue (File/RabbitMQ/Kafka/MongoDB), HTTP client, Messenger (SMTP/IMAP), FakeData/Seeder, Migrations, SCSS compiler, Swagger/OpenAPI, i18n, Events, Container/DI, HtmlElement, Inline testing, Error overlay, Dev dashboard, Rate limiter, Response cache, Logging, MCP server

          ## Testing

          Run: `bundle exec rspec` or `tina4ruby test`. Tests live in `spec/`. Use `Tina4::Testing` for inline tests.
        CONTEXT
      end
    end
  end
end
