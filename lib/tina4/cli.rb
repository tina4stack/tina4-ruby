# frozen_string_literal: true
require "thor"
require "fileutils"

module Tina4
  class CLI < Thor
    desc "init [NAME]", "Initialize a new Tina4 project"
    option :template, type: :string, default: "default", desc: "Project template"
    def init(name = ".")
      dir = name == "." ? Dir.pwd : File.join(Dir.pwd, name)
      FileUtils.mkdir_p(dir)

      create_project_structure(dir)
      create_sample_files(dir, name == "." ? File.basename(Dir.pwd) : name)

      puts "Tina4 project initialized in #{dir}"
      puts "Run 'cd #{name} && bundle install && tina4 start' to get started" unless name == "."
    end

    desc "start", "Start the Tina4 web server"
    option :port, type: :numeric, default: 7145, aliases: "-p"
    option :host, type: :string, default: "0.0.0.0", aliases: "-h"
    option :dev, type: :boolean, default: false, aliases: "-d", desc: "Enable dev mode with auto-reload"
    def start
      require_relative "../tina4"

      root_dir = Dir.pwd
      Tina4.initialize!(root_dir)

      # Load route files
      load_routes(root_dir)

      if options[:dev]
        Tina4::DevReload.start(root_dir: root_dir)
        Tina4::ScssCompiler.compile_all(root_dir)
      end

      app = Tina4::RackApp.new(root_dir: root_dir)

      # Try Puma first (production-grade), fall back to WEBrick
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
          user_config.environment "development"
          user_config.log_requests false
          user_config.quiet
        end

        Tina4::Debug.info("Starting Puma server on http://#{puma_host}:#{puma_port}")
        launcher = Puma::Launcher.new(config)
        launcher.run
      rescue LoadError
        Tina4::Debug.info("Puma not found, falling back to WEBrick")
        server = Tina4::WebServer.new(app, host: options[:host], port: options[:port])
        server.start
      end
    end

    desc "migrate", "Run database migrations"
    option :create, type: :string, desc: "Create a new migration"
    option :rollback, type: :numeric, desc: "Rollback N migrations"
    def migrate
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

    desc "test", "Run inline tests"
    def test
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

    desc "version", "Show Tina4 version"
    def version
      require_relative "version"
      puts "Tina4 Ruby v#{Tina4::VERSION}"
    end

    desc "routes", "List all registered routes"
    def routes
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

    desc "seed", "Run all seed files in seeds/"
    option :clear, type: :boolean, default: false, desc: "Clear tables before seeding"
    def seed
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)
      load_routes(Dir.pwd)
      Tina4.seed(seed_folder: "seeds", clear: options[:clear])
    end

    desc "seed:create NAME", "Create a new seed file"
    def seed_create(name)
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
        # This file is executed by `tina4 seed`.
        # Use Tina4.seed_orm or Tina4.seed_table to populate data.
        #
        # Examples:
        #   Tina4.seed_orm(User, count: 50)
        #   Tina4.seed_table("audit_log", { action: :string, created_at: :datetime }, count: 100)
      RUBY

      puts "Created seed file: #{filepath}"
    end

    desc "console", "Start an interactive console"
    def console
      require_relative "../tina4"
      Tina4.initialize!(Dir.pwd)
      load_routes(Dir.pwd)

      require "irb"
      IRB.start
    end

    private

    def load_routes(root_dir)
      route_dirs = %w[routes src/routes src/api api]
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
        routes templates public public/css public/js public/images
        migrations src logs
      ].each do |subdir|
        FileUtils.mkdir_p(File.join(dir, subdir))
      end
    end

    def create_sample_files(dir, project_name)
      # app.rb
      unless File.exist?(File.join(dir, "app.rb"))
        File.write(File.join(dir, "app.rb"), <<~RUBY)
          require "tina4"

          Tina4.get "/" do |request, response|
            response.html "<h1>Welcome to #{project_name}!</h1><p>Powered by Tina4 Ruby</p>"
          end

          Tina4.get "/api/hello" do |request, response|
            response.json({ message: "Hello from Tina4!", timestamp: Time.now.iso8601 })
          end
        RUBY
      end

      # Gemfile
      unless File.exist?(File.join(dir, "Gemfile"))
        File.write(File.join(dir, "Gemfile"), <<~RUBY)
          source "https://rubygems.org"
          gem "tina4"
        RUBY
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

          EXPOSE 7145

          # Swagger defaults (override with env vars in docker-compose/k8s if needed)
          ENV SWAGGER_TITLE="Tina4 API"
          ENV SWAGGER_VERSION="0.1.0"
          ENV SWAGGER_DESCRIPTION="Auto-generated API documentation"

          # Start the server on all interfaces
          CMD ["bundle", "exec", "tina4", "start", "-p", "7145", "-h", "0.0.0.0"]
        DOCKERFILE
        puts "  Created Dockerfile"
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
        puts "  Created .dockerignore"
      end

      # Base template
      templates_dir = File.join(dir, "templates")
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
            <script src="/js/tina4.js"></script>
            <script src="/js/tina4helper.js"></script>
            {% block scripts %}{% endblock %}
          </body>
          </html>
        HTML
      end
    end
  end
end
