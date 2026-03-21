# frozen_string_literal: true

module Tina4
  # Detect AI coding assistants and scaffold Tina4 context files.
  #
  # Usage:
  #   tools = Tina4::AI.detect_ai("/path/to/project")
  #   files = Tina4::AI.install_ai_context("/path/to/project")
  #
  module AI
    AI_TOOLS = {
      "claude-code" => {
        description: "Claude Code (Anthropic CLI)",
        detect: ->(root) { Dir.exist?(File.join(root, ".claude")) || File.exist?(File.join(root, "CLAUDE.md")) },
        config_dir: ".claude",
        context_file: "CLAUDE.md"
      },
      "cursor" => {
        description: "Cursor IDE",
        detect: ->(root) { Dir.exist?(File.join(root, ".cursor")) || File.exist?(File.join(root, ".cursorules")) },
        config_dir: ".cursor",
        context_file: ".cursorules"
      },
      "copilot" => {
        description: "GitHub Copilot",
        detect: ->(root) { File.exist?(File.join(root, ".github", "copilot-instructions.md")) || Dir.exist?(File.join(root, ".github")) },
        config_dir: ".github",
        context_file: ".github/copilot-instructions.md"
      },
      "windsurf" => {
        description: "Windsurf (Codeium)",
        detect: ->(root) { File.exist?(File.join(root, ".windsurfrules")) },
        config_dir: nil,
        context_file: ".windsurfrules"
      },
      "aider" => {
        description: "Aider",
        detect: ->(root) { File.exist?(File.join(root, ".aider.conf.yml")) || File.exist?(File.join(root, "CONVENTIONS.md")) },
        config_dir: nil,
        context_file: "CONVENTIONS.md"
      },
      "cline" => {
        description: "Cline (VS Code)",
        detect: ->(root) { File.exist?(File.join(root, ".clinerules")) },
        config_dir: nil,
        context_file: ".clinerules"
      },
      "codex" => {
        description: "OpenAI Codex CLI",
        detect: ->(root) { File.exist?(File.join(root, "AGENTS.md")) || File.exist?(File.join(root, "codex.md")) },
        config_dir: nil,
        context_file: "AGENTS.md"
      }
    }.freeze

    class << self
      # Detect which AI coding tools are present in the project.
      #
      # @param root [String] project root directory (default: current directory)
      # @return [Array<Hash>] each hash has :name, :description, :config_file, :status
      def detect_ai(root = ".")
        root = File.expand_path(root)
        AI_TOOLS.map do |name, tool|
          installed = tool[:detect].call(root)
          {
            name: name,
            description: tool[:description],
            config_file: tool[:context_file],
            status: installed ? "detected" : "not detected"
          }
        end
      end

      # Return just the names of detected AI tools.
      #
      # @param root [String] project root directory
      # @return [Array<String>]
      def detect_ai_names(root = ".")
        detect_ai(root).select { |t| t[:status] == "detected" }.map { |t| t[:name] }
      end

      # Install Tina4 context files for detected (or all) AI tools.
      #
      # @param root [String] project root directory
      # @param tools [Array<String>, nil] specific tools to install for (nil = auto-detect)
      # @param force [Boolean] overwrite existing context files
      # @return [Array<String>] list of files created/updated
      def install_ai_context(root = ".", tools: nil, force: false)
        root = File.expand_path(root)
        created = []

        tool_names = tools || detect_ai_names(root)
        context = generate_context

        tool_names.each do |tool_name|
          tool = AI_TOOLS[tool_name]
          next unless tool

          files = install_for_tool(root, tool_name, tool, context, force)
          created.concat(files)
        end

        created
      end

      # Install Tina4 context for ALL known AI tools (not just detected ones).
      #
      # @param root [String] project root directory
      # @param force [Boolean] overwrite existing context files
      # @return [Array<String>] list of files created/updated
      def install_all(root = ".", force: false)
        root = File.expand_path(root)
        created = []
        context = generate_context

        AI_TOOLS.each do |tool_name, tool|
          files = install_for_tool(root, tool_name, tool, context, force)
          created.concat(files)
        end

        created
      end

      # Generate a human-readable status report of AI tool detection.
      #
      # @param root [String] project root directory
      # @return [String]
      def status_report(root = ".")
        tools = detect_ai(root)
        installed = tools.select { |t| t[:status] == "detected" }
        missing = tools.reject { |t| t[:status] == "detected" }

        lines = ["\nTina4 AI Context Status\n"]

        if installed.any?
          lines << "Detected AI tools:"
          installed.each { |t| lines << "  + #{t[:description]} (#{t[:name]})" }
        else
          lines << "No AI coding tools detected."
        end

        if missing.any?
          lines << "\nNot detected (install context with `tina4ruby ai --all`):"
          missing.each { |t| lines << "  - #{t[:description]} (#{t[:name]})" }
        end

        lines << ""
        lines.join("\n")
      end

      private

      def install_for_tool(root, name, tool, context, force)
        created = []
        context_path = File.join(root, tool[:context_file])

        # Create config directory if needed
        if tool[:config_dir]
          FileUtils.mkdir_p(File.join(root, tool[:config_dir]))
        end

        # Ensure parent directory exists for the context file
        FileUtils.mkdir_p(File.dirname(context_path))

        if !File.exist?(context_path) || force
          File.write(context_path, context)
          rel_path = context_path.sub("#{root}/", "")
          created << rel_path
        end

        # Install Claude Code skills if it's Claude
        if name == "claude-code"
          skills = install_claude_skills(root, force)
          created.concat(skills)
        end

        created
      end

      def install_claude_skills(root, force)
        created = []

        # Determine the framework root (where lib/tina4/ lives)
        framework_root = File.expand_path("../../..", __FILE__)

        # Copy .skill files from the framework's skills/ directory to project root
        skills_source = File.join(framework_root, "skills")
        if Dir.exist?(skills_source)
          Dir.glob(File.join(skills_source, "*.skill")).each do |skill_file|
            target = File.join(root, File.basename(skill_file))
            if !File.exist?(target) || force
              FileUtils.cp(skill_file, target)
              created << File.basename(skill_file)
            end
          end
        end

        # Copy skill directories from .claude/skills/ in the framework to the project
        framework_skills_dir = File.join(framework_root, ".claude", "skills")
        if Dir.exist?(framework_skills_dir)
          target_skills_dir = File.join(root, ".claude", "skills")
          FileUtils.mkdir_p(target_skills_dir)
          Dir.children(framework_skills_dir).each do |entry|
            skill_dir = File.join(framework_skills_dir, entry)
            next unless File.directory?(skill_dir)

            target_dir = File.join(target_skills_dir, entry)
            if !Dir.exist?(target_dir) || force
              FileUtils.rm_rf(target_dir) if Dir.exist?(target_dir)
              FileUtils.cp_r(skill_dir, target_dir)
              rel_path = target_dir.sub("#{root}/", "")
              created << rel_path
            end
          end
        end

        created
      end

      def generate_context
        <<~CONTEXT
          # Tina4 Ruby -- AI Context

          This project uses **Tina4 Ruby**, a lightweight, batteries-included web framework
          with zero third-party dependencies for core features.

          **Documentation:** https://tina4.com

          ## Quick Start

          ```bash
          tina4ruby init .          # Scaffold project
          tina4ruby start           # Start dev server on port 7147
          tina4ruby migrate         # Run database migrations
          tina4ruby test            # Run test suite
          tina4ruby routes          # List all registered routes
          ```

          ## Project Structure

          ```
          routes/           -- Route handlers (auto-discovered, one per resource)
          src/routes/       -- Alternative route location
          templates/        -- Twig/ERB templates (extends base template)
          public/           -- Static assets served at /
          scss/             -- SCSS files (auto-compiled to public/css/)
          migrations/       -- SQL migration files (sequential numbered)
          seeds/            -- Database seeder scripts
          spec/             -- RSpec test files
          ```

          ## Built-in Features (No External Gems Needed for Core)

          | Feature | Module |
          |---------|--------|
          | Routing | Tina4::Router |
          | ORM | Tina4::ORM |
          | Database | Tina4::Database |
          | Templates | Tina4::Template |
          | JWT Auth | Tina4::Auth |
          | REST API Client | Tina4::API |
          | GraphQL | Tina4::GraphQL |
          | WebSocket | Tina4::WebSocket |
          | SOAP/WSDL | Tina4::WSDL |
          | Email (SMTP+IMAP) | Tina4::Messenger |
          | Background Queue | Tina4::Queue |
          | SCSS Compilation | Tina4::ScssCompiler |
          | Migrations | Tina4::Migration |
          | Seeder | Tina4::FakeData |
          | i18n | Tina4::Localization |
          | Swagger/OpenAPI | Tina4::Swagger |
          | Sessions | Tina4::Session |
          | Middleware | Tina4::Middleware |

          ## Key Conventions

          1. **Routes use block handlers** with `|request, response|` params
          2. **GET routes are public**, POST/PUT/PATCH/DELETE require auth by default
          3. **Use `auth: false`** to make write routes public, `secure_get` to protect GET routes
          4. **Every template extends a base template** -- no standalone HTML pages
          5. **No inline styles** -- use SCSS with CSS variables
          6. **All schema changes via migrations** -- never create tables in route code
          7. **Service pattern** -- complex logic goes in service classes, routes stay thin
          8. **Use built-in features** -- never install gems for things Tina4 already provides

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
        CONTEXT
      end
    end
  end
end
