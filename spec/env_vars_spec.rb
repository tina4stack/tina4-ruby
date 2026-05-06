# frozen_string_literal: true

# Cross-framework env-var parity for tina4-ruby v3.12.4.
#
# Every TINA4_* var listed in the v3.12.4 release notes must be readable
# from `ENV` and produce a sensible default when unset. Each var gets two
# examples: default + override. Plus log rotation tests proving the stdlib
# `Logger`-based rotation actually shifts files.

require "spec_helper"
require "tmpdir"
require "fileutils"

# Helper to stash and restore env vars around a block. We don't want to
# leak overrides across tests — we already pull in ClimateControl-style
# behaviour but stay zero-dep with a tiny shim.
def with_env(overrides)
  original = {}
  overrides.each do |k, v|
    original[k] = ENV.key?(k) ? ENV[k] : :__unset__
    if v.nil?
      ENV.delete(k)
    else
      ENV[k] = v.to_s
    end
  end
  yield
ensure
  original.each do |k, v|
    if v == :__unset__
      ENV.delete(k)
    else
      ENV[k] = v
    end
  end
end

RSpec.describe "TINA4 environment variables (v3.12.4 parity)" do
  # ── TINA4_HOST ─────────────────────────────────────────────────────
  describe "TINA4_HOST" do
    it "defaults to 0.0.0.0 when unset" do
      with_env("TINA4_HOST" => nil, "TINA4_PORT" => nil, "PORT" => nil) do
        ws = Tina4::WebServer.new(double("app"))
        expect(ws.instance_variable_get(:@host)).to eq("0.0.0.0")
      end
    end

    it "uses the env value when set" do
      with_env("TINA4_HOST" => "127.0.0.1", "TINA4_PORT" => nil, "PORT" => nil) do
        ws = Tina4::WebServer.new(double("app"))
        expect(ws.instance_variable_get(:@host)).to eq("127.0.0.1")
      end
    end
  end

  # ── TINA4_SUPPRESS ─────────────────────────────────────────────────
  describe "TINA4_SUPPRESS" do
    it "prints the banner when unset" do
      with_env("TINA4_SUPPRESS" => nil) do
        expect { Tina4.print_banner(host: "0.0.0.0", port: 9999, server_name: "test") }
          .to output(/TINA4|Server/).to_stdout
      end
    end

    it "suppresses banner output when truthy" do
      with_env("TINA4_SUPPRESS" => "true") do
        expect { Tina4.print_banner(host: "0.0.0.0", port: 9999, server_name: "test") }
          .not_to output.to_stdout
      end
    end
  end

  # ── TINA4_ENV_FILE ─────────────────────────────────────────────────
  describe "TINA4_ENV_FILE" do
    it "defaults to .env" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_ENV_FILE" => nil, "ENVIRONMENT" => nil) do
          resolved = Tina4::Env.send(:resolve_env_file, dir)
          expect(resolved).to eq(File.join(dir, ".env"))
        end
      end
    end

    it "honours an absolute path override" do
      Dir.mktmpdir do |dir|
        custom = File.join(dir, "config", "custom.env")
        FileUtils.mkdir_p(File.dirname(custom))
        File.write(custom, "FOO=bar\n")
        with_env("TINA4_ENV_FILE" => custom, "ENVIRONMENT" => nil) do
          expect(Tina4::Env.send(:resolve_env_file, dir)).to eq(custom)
        end
      end
    end
  end

  # ── TINA4_HEALTH_PATH ──────────────────────────────────────────────
  describe "TINA4_HEALTH_PATH" do
    it "defaults to /__health" do
      with_env("TINA4_HEALTH_PATH" => nil) do
        expect(Tina4::Health.path).to eq("/__health")
      end
    end

    it "uses the override path" do
      with_env("TINA4_HEALTH_PATH" => "/healthz") do
        expect(Tina4::Health.path).to eq("/healthz")
      end
    end

    it "prepends a leading slash if missing" do
      with_env("TINA4_HEALTH_PATH" => "ping") do
        expect(Tina4::Health.path).to eq("/ping")
      end
    end
  end

  # ── TINA4_TRAILING_SLASH_REDIRECT ─────────────────────────────────
  describe "TINA4_TRAILING_SLASH_REDIRECT" do
    it "defaults to false" do
      with_env("TINA4_TRAILING_SLASH_REDIRECT" => nil) do
        expect(Tina4::Router.trailing_slash_redirect?).to be false
      end
    end

    it "is true when set to truthy" do
      with_env("TINA4_TRAILING_SLASH_REDIRECT" => "true") do
        expect(Tina4::Router.trailing_slash_redirect?).to be true
      end
    end
  end

  # ── TINA4_LOG_FILE / DIR / FORMAT / OUTPUT / CRITICAL ─────────────
  describe "TINA4_LOG_DIR" do
    it "defaults to <root>/logs" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => nil, "TINA4_LOG_FILE" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.log_dir).to eq(File.join(dir, "logs"))
        end
        Tina4::Log.close_file_logger
      end
    end

    it "uses an explicit relative dir" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "var/log", "TINA4_LOG_FILE" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.log_dir).to eq(File.join(dir, "var/log"))
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  describe "TINA4_LOG_FILE" do
    it "defaults to tina4.log under log_dir" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FILE" => nil, "TINA4_LOG_DIR" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.log_file_path).to eq(File.join(dir, "logs", "tina4.log"))
        end
        Tina4::Log.close_file_logger
      end
    end

    it "honours an absolute override" do
      Dir.mktmpdir do |dir|
        custom = File.join(dir, "weird.log")
        with_env("TINA4_LOG_FILE" => custom, "TINA4_LOG_DIR" => nil) do
          Tina4::Log.configure(dir)
          Tina4::Log.info("hello")
          expect(File.exist?(custom)).to be true
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  describe "TINA4_LOG_FORMAT" do
    it "defaults to text in development" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FORMAT" => nil, "TINA4_ENV" => "development",
                 "RACK_ENV" => nil, "RUBY_ENV" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.json_mode?).to be false
        end
        Tina4::Log.close_file_logger
      end
    end

    it "is json when explicitly set" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FORMAT" => "json") do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.json_mode?).to be true
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  describe "TINA4_LOG_OUTPUT" do
    it "defaults to both" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil) do
          Tina4::Log.configure(dir)
          # File output enabled — message should hit the file.
          expect { Tina4::Log.info("both test") }.not_to raise_error
          expect(File.read(Tina4::Log.log_file_path)).to include("both test")
        end
        Tina4::Log.close_file_logger
      end
    end

    it "skips file output when set to stdout" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => "stdout") do
          Tina4::Log.configure(dir)
          Tina4::Log.info("stdout-only")
          # File logger isn't created at all, so the path doesn't exist or stays empty.
          path = Tina4::Log.log_file_path
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  describe "TINA4_LOG_CRITICAL" do
    it "defaults to false (silent on write failure)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_CRITICAL" => nil) do
          Tina4::Log.configure(dir)
          # Silent — no exception.
          expect { Tina4::Log.info("ok") }.not_to raise_error
        end
        Tina4::Log.close_file_logger
      end
    end

    it "is read as true when set" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_CRITICAL" => "true") do
          Tina4::Log.configure(dir)
          # truthy? helper inside Log is private — confirm via behaviour:
          # set @critical to true and a write_to_file IOError would propagate.
          # We just confirm configure doesn't raise & the writer is set.
          expect(Tina4::Log.instance_variable_get(:@critical)).to be true
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  # ── Log rotation (TINA4_LOG_ROTATE_SIZE / KEEP) ────────────────────
  describe "log rotation" do
    it "rotates the log when size threshold is crossed" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "200",
                 "TINA4_LOG_ROTATE_KEEP" => "3",
                 "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(dir)
          # Force the file size past the threshold by writing many lines.
          80.times { |i| Tina4::Log.info("rotation line #{i} " + ("x" * 30)) }
          Tina4::Log.close_file_logger

          rotated = Dir.glob(File.join(dir, "logs", "tina4.log.*"))
          expect(rotated).not_to be_empty
        end
      end
    end

    it "honours TINA4_LOG_ROTATE_KEEP cap" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "200",
                 "TINA4_LOG_ROTATE_KEEP" => "2",
                 "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(dir)
          200.times { |i| Tina4::Log.info("keep test #{i} " + ("x" * 40)) }
          Tina4::Log.close_file_logger

          rotated = Dir.glob(File.join(dir, "logs", "tina4.log.*"))
          # KEEP=2 means at most 2 backup files retained (Logger.shift_age semantics).
          expect(rotated.size).to be <= 2
        end
      end
    end

    it "skips rotation entirely when TINA4_LOG_ROTATE_SIZE=0" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "0",
                 "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(dir)
          500.times { |i| Tina4::Log.info("no-rotate #{i} " + ("y" * 50)) }
          Tina4::Log.close_file_logger

          rotated = Dir.glob(File.join(dir, "logs", "tina4.log.*"))
          expect(rotated).to be_empty
        end
      end
    end
  end

  # ── TINA4_SESSION_HTTPONLY / NAME / SECURE ─────────────────────────
  describe "TINA4_SESSION_HTTPONLY" do
    it "defaults to true (HttpOnly present)" do
      with_env("TINA4_SESSION_HTTPONLY" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).to include("HttpOnly")
      end
    end

    it "drops HttpOnly when explicitly false" do
      with_env("TINA4_SESSION_HTTPONLY" => "false") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).not_to include("HttpOnly")
      end
    end
  end

  describe "TINA4_SESSION_NAME" do
    it "defaults to tina4_session" do
      with_env("TINA4_SESSION_NAME" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).to start_with("tina4_session=")
      end
    end

    it "uses the override" do
      with_env("TINA4_SESSION_NAME" => "myapp_sess") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).to start_with("myapp_sess=")
      end
    end
  end

  describe "TINA4_SESSION_SECURE" do
    it "defaults to false (no Secure flag)" do
      with_env("TINA4_SESSION_SECURE" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).not_to include("Secure")
      end
    end

    it "adds the Secure flag when truthy" do
      with_env("TINA4_SESSION_SECURE" => "true") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: Dir.mktmpdir })
        expect(sess.cookie_header).to include("Secure")
      end
    end
  end

  # ── TINA4_TEMPLATE_CACHE_TTL ───────────────────────────────────────
  describe "TINA4_TEMPLATE_CACHE_TTL" do
    it "uses permanent cache by default (TTL=0)" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "page.twig"), "Hello {{ name }}")
        with_env("TINA4_TEMPLATE_CACHE_TTL" => nil, "TINA4_DEBUG" => "false") do
          frond = Tina4::Frond.new(template_dir: dir)
          expect(frond.render("page.twig", name: "world")).to include("Hello world")
          # Mutating the file does NOT invalidate the cache when TTL=0.
          File.write(File.join(dir, "page.twig"), "Goodbye {{ name }}")
          expect(frond.render("page.twig", name: "world")).to include("Hello world")
        end
      end
    end

    it "expires entries when TTL elapses" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "page.twig"), "v1 {{ name }}")
        with_env("TINA4_TEMPLATE_CACHE_TTL" => "1", "TINA4_DEBUG" => "false") do
          frond = Tina4::Frond.new(template_dir: dir)
          expect(frond.render("page.twig", name: "x")).to include("v1 x")
          # Backdate the cache entry and update the file.
          cache = frond.instance_variable_get(:@compiled)
          tokens, mtime, _cached_at = cache["page.twig"]
          cache["page.twig"] = [tokens, mtime, Time.now.to_i - 5]
          File.write(File.join(dir, "page.twig"), "v2 {{ name }}")
          expect(frond.render("page.twig", name: "x")).to include("v2 x")
        end
      end
    end
  end

  # ── TINA4_GRAPHQL_AUTO_SCHEMA / ENDPOINT ───────────────────────────
  describe "TINA4_GRAPHQL_AUTO_SCHEMA" do
    it "defaults to true" do
      with_env("TINA4_GRAPHQL_AUTO_SCHEMA" => nil) do
        expect(Tina4::GraphQL.auto_schema_enabled?).to be true
      end
    end

    it "honours an explicit false" do
      with_env("TINA4_GRAPHQL_AUTO_SCHEMA" => "false") do
        expect(Tina4::GraphQL.auto_schema_enabled?).to be false
      end
    end
  end

  describe "TINA4_GRAPHQL_ENDPOINT" do
    after { Tina4::Router.clear! }

    it "defaults to /graphql" do
      with_env("TINA4_GRAPHQL_ENDPOINT" => nil) do
        gql = Tina4::GraphQL.new
        gql.register_route
        paths = Tina4::Router.routes.map(&:path)
        expect(paths).to include("/graphql")
      end
    end

    it "uses the override path" do
      with_env("TINA4_GRAPHQL_ENDPOINT" => "/api/v2/gql") do
        gql = Tina4::GraphQL.new
        gql.register_route
        paths = Tina4::Router.routes.map(&:path)
        expect(paths).to include("/api/v2/gql")
      end
    end
  end

  # ── TINA4_MAIL_IMAP_ENCRYPTION ─────────────────────────────────────
  describe "TINA4_MAIL_IMAP_ENCRYPTION" do
    it "defaults to tls" do
      with_env("TINA4_MAIL_IMAP_ENCRYPTION" => nil) do
        m = Tina4::Messenger.new
        expect(m.imap_encryption).to eq("tls")
        expect(m.imap_use_tls).to be true
      end
    end

    it "honours starttls" do
      with_env("TINA4_MAIL_IMAP_ENCRYPTION" => "starttls") do
        m = Tina4::Messenger.new
        expect(m.imap_encryption).to eq("starttls")
        expect(m.imap_use_tls).to be true
      end
    end

    it "respects none → no TLS" do
      with_env("TINA4_MAIL_IMAP_ENCRYPTION" => "none") do
        m = Tina4::Messenger.new
        expect(m.imap_encryption).to eq("none")
        expect(m.imap_use_tls).to be false
      end
    end
  end

  # ── TINA4_MCP / PORT ───────────────────────────────────────────────
  describe "TINA4_MCP" do
    it "defaults to debug-mode value when unset" do
      with_env("TINA4_MCP" => nil, "TINA4_DEBUG" => "true") do
        expect(Tina4.mcp_enabled?).to be true
      end
      with_env("TINA4_MCP" => nil, "TINA4_DEBUG" => "false") do
        expect(Tina4.mcp_enabled?).to be false
      end
    end

    it "honours explicit override" do
      with_env("TINA4_MCP" => "false", "TINA4_DEBUG" => "true") do
        expect(Tina4.mcp_enabled?).to be false
      end
    end
  end

  describe "TINA4_MCP_PORT" do
    it "defaults to base port + 2000" do
      with_env("TINA4_MCP_PORT" => nil, "TINA4_PORT" => "7147", "PORT" => nil) do
        expect(Tina4.mcp_port).to eq(9147)
      end
    end

    it "uses the explicit override" do
      with_env("TINA4_MCP_PORT" => "9001") do
        expect(Tina4.mcp_port).to eq(9001)
      end
    end
  end

  # ── TINA4_SWAGGER_CONTACT_EMAIL / LICENSE / ENABLED ───────────────
  describe "TINA4_SWAGGER_CONTACT_EMAIL" do
    it "is omitted when unset" do
      with_env("TINA4_SWAGGER_CONTACT_EMAIL" => nil,
               "TINA4_SWAGGER_CONTACT_TEAM" => nil, "TINA4_SWAGGER_CONTACT_URL" => nil,
               "SWAGGER_CONTACT_TEAM" => nil, "SWAGGER_CONTACT_URL" => nil) do
        spec = Tina4::Swagger.generate
        expect(spec["info"]).not_to have_key("contact")
      end
    end

    it "appears in info.contact.email when set" do
      with_env("TINA4_SWAGGER_CONTACT_EMAIL" => "ops@example.com",
               "TINA4_SWAGGER_CONTACT_TEAM" => nil, "TINA4_SWAGGER_CONTACT_URL" => nil,
               "SWAGGER_CONTACT_TEAM" => nil, "SWAGGER_CONTACT_URL" => nil) do
        spec = Tina4::Swagger.generate
        expect(spec["info"]["contact"]["email"]).to eq("ops@example.com")
      end
    end
  end

  describe "TINA4_SWAGGER_LICENSE" do
    it "is omitted when unset" do
      with_env("TINA4_SWAGGER_LICENSE" => nil) do
        spec = Tina4::Swagger.generate
        expect(spec["info"]).not_to have_key("license")
      end
    end

    it "appears in info.license.name when set" do
      with_env("TINA4_SWAGGER_LICENSE" => "MIT") do
        spec = Tina4::Swagger.generate
        expect(spec["info"]["license"]).to eq({ "name" => "MIT" })
      end
    end
  end

  describe "TINA4_SWAGGER_ENABLED" do
    it "defaults to TINA4_DEBUG" do
      with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "true") do
        expect(Tina4::Swagger.enabled?).to be true
      end
      with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "false") do
        expect(Tina4::Swagger.enabled?).to be false
      end
    end

    it "honours explicit override" do
      with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "false") do
        expect(Tina4::Swagger.enabled?).to be true
      end
    end
  end

  # ── TINA4_DB_POOL ──────────────────────────────────────────────────
  describe "TINA4_DB_POOL" do
    it "defaults to single connection (pool_size 0)" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "p.db")
        with_env("TINA4_DB_POOL" => nil) do
          db = Tina4::Database.new("sqlite://#{db_path}")
          expect(db.instance_variable_get(:@pool_size)).to eq(0)
          db.close
        end
      end
    end

    it "uses pooled mode when set > 0" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "p.db")
        with_env("TINA4_DB_POOL" => "4") do
          db = Tina4::Database.new("sqlite://#{db_path}")
          expect(db.instance_variable_get(:@pool_size)).to eq(4)
          expect(db.pool).to be_a(Tina4::ConnectionPool)
          db.close
        end
      end
    end
  end
end
