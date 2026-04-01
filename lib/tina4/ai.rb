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
      def installed?(root, tool)
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
          marker = installed?(root, tool) ? "  #{green}[installed]#{reset}" : ""
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

        context = generate_context

        indices.each do |idx|
          tool = AI_TOOLS[idx]
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

      # Generate the universal Tina4 Ruby context document for any AI assistant.
      #
      # @return [String]
      def generate_context
        <<~CONTEXT
          # Tina4 Ruby -- AI Context

          This project uses **Tina4 Ruby**, a lightweight, batteries-included web framework
          with zero third-party dependencies for core features.

          **Documentation:** https://tina4.com

          ## Quick Start

          ```bash
          tina4ruby init .          # Scaffold project
          tina4ruby serve           # Start dev server on port 7147
          tina4ruby migrate         # Run database migrations
          tina4ruby test            # Run test suite
          tina4ruby routes          # List all registered routes
          ```

          ## Project Structure

          ```
          lib/tina4/        -- Core framework modules
          src/routes/       -- Route handlers (auto-discovered, one per resource)
          src/orm/          -- ORM models (one per file, filename = class name)
          src/templates/    -- Twig/ERB templates (extends base template)
          src/app/          -- Shared helpers and service classes
          src/scss/         -- SCSS files (auto-compiled to public/css/)
          src/public/       -- Static assets served at /
          src/locales/      -- Translation JSON files
          src/seeds/        -- Database seeder scripts
          migrations/       -- SQL migration files (sequential numbered)
          spec/             -- RSpec test files
          ```

          ## Built-in Features (No External Gems Needed for Core)

          | Feature | Module | Require |
          |---------|--------|---------|
          | Routing | Tina4::Router | `require "tina4/router"` |
          | ORM | Tina4::ORM | `require "tina4/orm"` |
          | Database | Tina4::Database | `require "tina4/database"` |
          | Templates | Tina4::Template | `require "tina4/template"` |
          | JWT Auth | Tina4::Auth | `require "tina4/auth"` |
          | REST API Client | Tina4::API | `require "tina4/api"` |
          | GraphQL | Tina4::GraphQL | `require "tina4/graphql"` |
          | WebSocket | Tina4::WebSocket | `require "tina4/websocket"` |
          | SOAP/WSDL | Tina4::WSDL | `require "tina4/wsdl"` |
          | Email (SMTP+IMAP) | Tina4::Messenger | `require "tina4/messenger"` |
          | Background Queue | Tina4::Queue | `require "tina4/queue"` |
          | SCSS Compilation | Tina4::ScssCompiler | `require "tina4/scss_compiler"` |
          | Migrations | Tina4::Migration | `require "tina4/migration"` |
          | Seeder | Tina4::FakeData | `require "tina4/seeder"` |
          | i18n | Tina4::Localization | `require "tina4/localization"` |
          | Swagger/OpenAPI | Tina4::Swagger | `require "tina4/swagger"` |
          | Sessions | Tina4::Session | `require "tina4/session"` |
          | Middleware | Tina4::Middleware | `require "tina4/middleware"` |
          | HTML Builder | Tina4::HtmlElement | `require "tina4/html_element"` |
          | Form Tokens | Tina4::Template | `{{ form_token() }}` in Twig |

          ## Key Conventions

          1. **Routes use block handlers** with `|request, response|` params
          2. **GET routes are public**, POST/PUT/PATCH/DELETE require auth by default
          3. **Use `auth: false`** to make write routes public, `secure_get` to protect GET routes
          4. **Every template extends a base template** -- no standalone HTML pages
          5. **No inline styles** -- use SCSS with CSS variables
          6. **All schema changes via migrations** -- never create tables in route code
          7. **Service pattern** -- complex logic goes in service classes, routes stay thin
          8. **Use built-in features** -- never install gems for things Tina4 already provides

          ## AI Workflow -- Available Skills

          When using an AI coding assistant with Tina4, these skills are available:

          | Skill | Description |
          |-------|-------------|
          | `/tina4-route` | Create a new route with proper decorators and auth |
          | `/tina4-orm` | Create an ORM model with migration |
          | `/tina4-crud` | Generate complete CRUD (migration, ORM, routes, template, tests) |
          | `/tina4-auth` | Set up JWT authentication with login/register |
          | `/tina4-api` | Create an external API integration |
          | `/tina4-queue` | Set up background job processing |
          | `/tina4-template` | Create a server-rendered template page |
          | `/tina4-graphql` | Set up a GraphQL endpoint |
          | `/tina4-websocket` | Set up WebSocket communication |
          | `/tina4-wsdl` | Create a SOAP/WSDL service |
          | `/tina4-messenger` | Set up email send/receive |
          | `/tina4-test` | Write tests for a feature |
          | `/tina4-migration` | Create a database migration |
          | `/tina4-seed` | Generate fake data for development |
          | `/tina4-i18n` | Set up internationalization |
          | `/tina4-scss` | Set up SCSS stylesheets |
          | `/tina4-frontend` | Set up a frontend framework |

          ## Common Patterns

          ### Route
          ```ruby
          Tina4.get "/api/widgets" do |request, response|
            response.json({ widgets: Widget.all })
          end

          Tina4.post "/api/widgets", auth: false do |request, response|
            widget = Widget.create(request.body)
            response.json({ created: true }, 201)
          end
          ```

          ### ORM Model
          ```ruby
          class Widget < Tina4::ORM
            integer_field :id, primary_key: true, auto_increment: true
            string_field :name
            numeric_field :price
          end
          ```

          ### Template
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
        CONTEXT
      end

      # Install context file for a single tool.
      #
      # @param root [String] absolute project root path
      # @param tool [Hash] tool entry from AI_TOOLS
      # @param context [String] generated context content
      # @return [Array<String>] list of created/updated relative file paths
      def install_for_tool(root, tool, context)
        created = []
        context_path = File.join(root, tool[:context_file])

        # Create directories
        if tool[:config_dir]
          FileUtils.mkdir_p(File.join(root, tool[:config_dir]))
        end
        FileUtils.mkdir_p(File.dirname(context_path))

        # Always overwrite -- user chose to install
        action = File.exist?(context_path) ? "Updated" : "Installed"
        File.write(context_path, context)
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
          if $?.success?
            puts "  \e[32m✓\e[0m Installed tina4-ai (mdview)"
            return
          else
            puts "  \e[33m!\e[0m #{cmd} failed: #{result.strip[0..100]}"
          end
        end
        puts "  \e[33m!\e[0m Python/pip not available -- skip tina4-ai"
      end
    end
  end
end
