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

      # Try rackup first, fall back to WEBrick
      app = Tina4::RackApp.new(root_dir: root_dir)

      begin
        require "rackup"
        Rackup::Handler::WEBrick.run(app, Host: options[:host], Port: options[:port])
      rescue LoadError
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
            <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
            {% block head %}{% endblock %}
          </head>
          <body>
            {% block content %}{% endblock %}
            <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
            {% block scripts %}{% endblock %}
          </body>
          </html>
        HTML
      end
    end
  end
end
