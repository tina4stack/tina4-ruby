# frozen_string_literal: true

# Cross-framework env-var parity for tina4-ruby v3.12.4.
#
# Every TINA4_* var listed in the v3.12.4 release notes must be readable
# from `ENV` and produce a sensible default when unset. Each var gets two
# examples: default + override. Plus log rotation tests proving the stdlib
# `Logger`-based rotation actually shifts files.

require "spec_helper"
require_relative "support/real_full_disk"
require "tmpdir"
require "fileutils"

# Helper to stash and restore env vars around a block. We don't want to
# leak overrides across tests — we already pull in ClimateControl-style
# behaviour but stay zero-dep with a tiny shim.
# The resolved path of the MAIN log file under a Tina4::Log.configuration
# hash. In "directory" layout (no explicit log_file named) the main file is
# always tina4.log under log_dir; in "single" layout log_file IS the path.
def main_log_path(cfg)
  cfg["log_file"] || File.join(cfg["log_dir"], "tina4.log")
end

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
        ws = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: SpecTmpdir.create))
        expect(ws.instance_variable_get(:@host)).to eq("0.0.0.0")
      end
    end

    it "uses the env value when set" do
      with_env("TINA4_HOST" => "127.0.0.1", "TINA4_PORT" => nil, "PORT" => nil) do
        ws = Tina4::WebServer.new(Tina4::RackApp.new(root_dir: SpecTmpdir.create))
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
  #
  # Rewritten 2026-08-13 alongside the shared logger_contract.json conformance
  # pass: Log.configure is keyword-only (log_dir:, not a positional arg),
  # Log.configuration (a Hash) replaces the individual log_dir/log_file_path/
  # json_mode? readers and every direct instance_variable_get poke,
  # Log.reset replaces close_file_logger, format is now DEBUG-DERIVED rather
  # than "text unless TINA4_LOG_FORMAT=json" (Decision 3), naming a file no
  # longer itself enables the file sink (LOG-C08), TINA4_LOG_ROTATE_SIZE has
  # a real minimum of 1024 (LOG-V02), and a write failure now raises the
  # structured Tina4::LogWriteError rather than the bare native error.
  describe "TINA4_LOG_DIR" do
    it "defaults to <cwd>/logs" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => nil, "TINA4_LOG_FILE" => nil) do
          # configure() with no argument defaults to <cwd>/logs.
          Dir.chdir(real) { Tina4::Log.configure }
          expect(Tina4::Log.configuration["log_dir"]).to eq(File.join(real, "logs"))
        end
        Tina4::Log.reset
      end
    end

    it "uses an explicit directory argument as the log directory" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => nil, "TINA4_LOG_FILE" => nil) do
          Tina4::Log.configure(log_dir: File.join(real, "somewhere"))
          expect(Tina4::Log.configuration["log_dir"]).to eq(File.join(real, "somewhere"))
        end
        Tina4::Log.reset
      end
    end

    it "uses an explicit relative dir, resolved against the working directory" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => "var/log", "TINA4_LOG_FILE" => nil) do
          # A relative TINA4_LOG_DIR resolves against the WORKING DIRECTORY.
          Dir.chdir(real) { Tina4::Log.configure }
          expect(Tina4::Log.configuration["log_dir"]).to eq(File.join(real, "var/log"))
        end
        Tina4::Log.reset
      end
    end
  end

  describe "TINA4_LOG_FILE" do
    it "defaults to tina4.log under log_dir" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FILE" => nil, "TINA4_LOG_DIR" => nil) do
          Dir.chdir(File.realpath(dir)) { Tina4::Log.configure }
          expect(main_log_path(Tina4::Log.configuration)).to eq(File.join(File.realpath(dir), "logs", "tina4.log"))
        end
        Tina4::Log.reset
      end
    end

    it "honours an absolute override" do
      Dir.mktmpdir do |dir|
        custom = File.join(dir, "weird.log")
        with_env("TINA4_LOG_FILE" => custom, "TINA4_LOG_DIR" => nil, "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(log_dir: dir)
          Tina4::Log.info("hello")
          expect(File.exist?(custom)).to be true
        end
        Tina4::Log.reset
      end
    end
  end

  describe "TINA4_LOG_FORMAT" do
    # Format is DEBUG-DERIVED (Decision 3, supersedes the 2026-08-01 "text
    # always unless TINA4_LOG_FORMAT=json" rule): explicit TINA4_LOG_FORMAT
    # wins; otherwise truthy TINA4_DEBUG selects text, a falsy/absent
    # TINA4_DEBUG selects json.
    it "defaults to text with TINA4_DEBUG truthy" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FORMAT" => nil, "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(log_dir: dir)
          expect(Tina4::Log.configuration["format"]).to eq("text")
        end
        Tina4::Log.reset
      end
    end

    it "defaults to json with TINA4_DEBUG falsy" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FORMAT" => nil, "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(log_dir: dir)
          expect(Tina4::Log.configuration["format"]).to eq("json")
        end
        Tina4::Log.reset
      end
    end

    it "is json when explicitly set, even with TINA4_DEBUG truthy" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FORMAT" => "json", "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(log_dir: dir)
          expect(Tina4::Log.configuration["format"]).to eq("json")
        end
        Tina4::Log.reset
      end
    end
  end

  describe "TINA4_LOG_OUTPUT" do
    # v3.13.39: the default (unset) is now DEV-GATED. stdout is always on; the
    # log FILE is written only in development (TINA4_DEBUG truthy). In
    # production / containers it's stdout-only — no file. Explicit
    # file/both still forces a file; naming a file ALONE does not (LOG-C08).
    it "writes the file by default in development (TINA4_DEBUG truthy)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(log_dir: dir)
          # File output enabled in dev — message should hit the file.
          expect { Tina4::Log.info("dev default test") }.not_to raise_error
          expect(File.read(main_log_path(Tina4::Log.configuration))).to include("dev default test")
        end
        Tina4::Log.reset
      end
    end

    it "writes NO file by default in production (TINA4_DEBUG falsy)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(log_dir: dir)
          Tina4::Log.info("prod default test")
          # Default resolves to stdout-only — no file logger, path empty/absent.
          path = main_log_path(Tina4::Log.configuration)
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
        end
        Tina4::Log.reset
      end
    end

    it "skips file output when set to stdout" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => "stdout") do
          Tina4::Log.configure(log_dir: dir)
          Tina4::Log.info("stdout-only")
          # File logger isn't created at all, so the path doesn't exist or stays empty.
          path = main_log_path(Tina4::Log.configuration)
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
        end
        Tina4::Log.reset
      end
    end
  end

  # ── Default log output is DEV-GATED (v3.13.39) ─────────────────────
  #
  # Unified contract (Python master, mirrored): when TINA4_LOG_OUTPUT is
  # UNSET, stdout is ALWAYS on, but the log FILE is written ONLY in
  # development (TINA4_DEBUG truthy). Production / containers (TINA4_DEBUG
  # falsy) → stdout ONLY, NO file. An explicit TINA4_LOG_OUTPUT=file/both
  # still forces a file even with TINA4_DEBUG off (explicit always wins) —
  # but naming a bare TINA4_LOG_FILE with no explicit output does NOT
  # (LOG-C08: a file name resolves WHERE logs would go, it does not itself
  # decide whether the file sink is on).
  describe "default log output (dev-gated file, v3.13.39)" do
    # (a) production / no TINA4_DEBUG → NO file written (neither tina4.log
    #     nor its error.log sibling).
    it "production (no TINA4_DEBUG): writes NO log file at all" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(log_dir: dir)
          cfg = Tina4::Log.configuration
          expect(cfg["output"]).to eq("stdout")
          expect(cfg["file_enabled"]).to be false
          Tina4::Log.error("prod error should not hit a file")
          Tina4::Log.critical("prod critical should not hit a file")
          path = main_log_path(cfg)
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
          # No stray *.log files at all under the log dir.
          stray = Dir.glob(File.join(dir, "logs", "*.log"))
          expect(stray.select { |f| File.size(f).positive? }).to be_empty
        end
        Tina4::Log.reset
      end
    end

    # (b) development / TINA4_DEBUG truthy → file IS written.
    it "development (TINA4_DEBUG truthy): writes the log file" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(log_dir: dir)
          cfg = Tina4::Log.configuration
          expect(cfg["output"]).to eq("both")
          Tina4::Log.info("dev info hits the file")
          expect(File.read(main_log_path(cfg))).to include("dev info hits the file")
        end
        Tina4::Log.reset
      end
    end

    # (c) explicit output=both with TINA4_DEBUG OFF → file STILL written
    #     (explicit always wins over the dev gate).
    it "explicit output=both wins even with TINA4_DEBUG off" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => "both", "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(log_dir: dir)
          cfg = Tina4::Log.configuration
          expect(cfg["output"]).to eq("both")
          Tina4::Log.info("explicit both in prod")
          expect(File.read(main_log_path(cfg))).to include("explicit both in prod")
        end
        Tina4::Log.reset
      end
    end

    # A bare TINA4_LOG_FILE name with output UNSET and TINA4_DEBUG off does
    # NOT itself enable the file sink (LOG-C08) — this is a DELIBERATE
    # change from the pre-3.13.99 "explicit file always wins" rule: naming a
    # target only decides WHERE, never WHETHER.
    it "naming TINA4_LOG_FILE alone does not enable the file sink" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_LOG_FILE" => "custom.log",
                 "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(log_dir: dir)
          cfg = Tina4::Log.configuration
          expect(cfg["output"]).to eq("stdout")
          expect(cfg["file_enabled"]).to be false
          # The path IS still resolved for introspection, just not written.
          expect(cfg["log_file"]).to end_with("custom.log")
        end
        Tina4::Log.reset
      end
    end

    # (d) stdout STILL receives logs in production (stdout is always on).
    it "production: stdout still receives logs" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil,
                 "TINA4_LOG_LEVEL" => "info") do
          Tina4::Log.configure(log_dir: dir)
          expect { Tina4::Log.info("prod stdout line") }
            .to output(/prod stdout line/).to_stdout
        end
        Tina4::Log.reset
      end
    end
  end

  # TINA4_LOG_STRICT — the raise-on-write-failure flag. `critical` is a
  # first-class log LEVEL, not a write-failure toggle (Python-master parity).
  describe "TINA4_LOG_STRICT" do
    it "defaults to false (silent on write failure)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_STRICT" => nil, "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(log_dir: dir)
          # Silent — no exception.
          expect { Tina4::Log.info("ok") }.not_to raise_error
          expect(Tina4::Log.configuration["strict"]).to be false
        end
        Tina4::Log.reset
      end
    end

    it "is read as true when set" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_STRICT" => "true", "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(log_dir: dir)
          expect(Tina4::Log.configuration["strict"]).to be true
        end
        Tina4::Log.reset
      end
    end

    it "raises Tina4::LogWriteError on a log-write failure when strict, swallows when not" do
      # REAL FRAMEWORK BEHAVIOUR, proven against a GENUINELY full filesystem —
      # never a stubbed sink. Rewritten 2026-08-13: the rewritten LogFileSink
      # rescues the real SystemCallError/IOError itself and re-raises the
      # STRUCTURED Tina4::LogWriteError (sink:, operation: "write") — never
      # the bare native error — so strict mode is catchable the same way in
      # every language and carries a diagnosable cause.
      with_real_tiny_filesystem do |dir, fill_it|
        with_env("TINA4_LOG_STRICT" => "true", "TINA4_LOG_OUTPUT" => "file",
                 "TINA4_LOG_LEVEL" => "DEBUG") do
          Tina4::Log.configure(log_dir: dir)   # opens the REAL log files while space remains
          Tina4::Log.info("first line still fits")
          fill_it.call                          # the REAL filesystem is now genuinely full
          expect { Tina4::Log.info("z" * 20_000) }.to raise_error(Tina4::LogWriteError)
        end
        Tina4::Log.reset
      end

      # strict OFF: a real write failure must be swallowed.
      with_real_tiny_filesystem do |dir, fill_it|
        with_env("TINA4_LOG_STRICT" => nil, "TINA4_LOG_OUTPUT" => "file",
                 "TINA4_LOG_LEVEL" => "DEBUG") do
          Tina4::Log.configure(log_dir: dir)
          Tina4::Log.info("first line still fits")
          fill_it.call
          expect { Tina4::Log.info("z" * 20_000) }.not_to raise_error
        end
        Tina4::Log.reset
      end
    end

    it "TINA4_LOG_CRITICAL is a removed setting that now hard-fails configuration" do
      # BREAKING (Decision 19 / LOG-V04): TINA4_LOG_CRITICAL used to be
      # silently inert once `critical` became a first-class level. It is now
      # a REMOVED setting — merely being present in the environment fails
      # configure() loud, naming the removed setting, rather than being
      # tolerated as a harmless no-op.
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_CRITICAL" => "true", "TINA4_LOG_STRICT" => nil,
                 "TINA4_LOG_OUTPUT" => "file", "TINA4_LOG_LEVEL" => "DEBUG") do
          expect { Tina4::Log.configure(log_dir: dir) }
            .to raise_error(Tina4::LogConfigurationError, /TINA4_LOG_CRITICAL/)
        end
        Tina4::Log.reset
      end
    end
  end

  # ── Log rotation (TINA4_LOG_ROTATE_SIZE / KEEP) ────────────────────
  #
  # TINA4_LOG_ROTATE_SIZE now has a REAL minimum of 1024 bytes (LOG-V02) —
  # below that (including the old "0 disables rotation" spelling) now FAILS
  # configuration rather than being silently accepted, so every positive case
  # here uses >= 1024.
  describe "log rotation" do
    it "rotates the log when size threshold is crossed" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "1024",
                 "TINA4_LOG_ROTATE_KEEP" => "3",
                 "TINA4_LOG_OUTPUT" => "file") do
          # TINA4_LOG_DIR is relative, so it resolves against the working directory.
          real = File.realpath(dir)
          Dir.chdir(real) { Tina4::Log.configure }
          # Force the file size well past the threshold by writing many lines.
          120.times { |i| Tina4::Log.info("rotation line #{i} " + ("x" * 30)) }
          Tina4::Log.reset

          rotated = Dir.glob(File.join(real, "logs", "tina4.log.*"))
          expect(rotated).not_to be_empty
        end
      end
    end

    it "honours TINA4_LOG_ROTATE_KEEP cap" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "1024",
                 "TINA4_LOG_ROTATE_KEEP" => "2",
                 "TINA4_LOG_OUTPUT" => "file") do
          Tina4::Log.configure(log_dir: dir)
          400.times { |i| Tina4::Log.info("keep test #{i} " + ("x" * 40)) }
          Tina4::Log.reset

          rotated = Dir.glob(File.join(dir, "logs", "tina4.log.*"))
          # KEEP=2 means at most 2 backup files retained.
          expect(rotated.size).to be <= 2
        end
      end
    end

    it "rejects TINA4_LOG_ROTATE_SIZE below the 1024-byte minimum" do
      # NEGATIVE (LOG-V02): the pre-3.13.99 "0 disables rotation" spelling
      # is now an configuration error, not a silently-honoured escape hatch.
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_DIR" => "logs",
                 "TINA4_LOG_FILE" => nil,
                 "TINA4_LOG_ROTATE_SIZE" => "0",
                 "TINA4_LOG_OUTPUT" => "file") do
          expect { Tina4::Log.configure(log_dir: dir) }
            .to raise_error(Tina4::LogConfigurationError, /TINA4_LOG_ROTATE_SIZE/)
        end
        Tina4::Log.reset
      end
    end
  end

  # ── TINA4_SESSION_HTTPONLY / NAME / SECURE ─────────────────────────
  describe "TINA4_SESSION_HTTPONLY" do
    it "defaults to true (HttpOnly present)" do
      with_env("TINA4_SESSION_HTTPONLY" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
        expect(sess.cookie_header).to include("HttpOnly")
      end
    end

    it "drops HttpOnly when explicitly false" do
      with_env("TINA4_SESSION_HTTPONLY" => "false") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
        expect(sess.cookie_header).not_to include("HttpOnly")
      end
    end
  end

  describe "TINA4_SESSION_NAME" do
    it "defaults to tina4_session" do
      with_env("TINA4_SESSION_NAME" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
        expect(sess.cookie_header).to start_with("tina4_session=")
      end
    end

    it "uses the override" do
      with_env("TINA4_SESSION_NAME" => "myapp_sess") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
        expect(sess.cookie_header).to start_with("myapp_sess=")
      end
    end
  end

  describe "TINA4_SESSION_SECURE" do
    it "defaults to false (no Secure flag)" do
      with_env("TINA4_SESSION_SECURE" => nil) do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
        expect(sess.cookie_header).not_to include("Secure")
      end
    end

    it "adds the Secure flag when truthy" do
      with_env("TINA4_SESSION_SECURE" => "true") do
        sess = Tina4::Session.new({}, handler: :file, handler_options: { dir: SpecTmpdir.create })
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
          db = Tina4::Database.new("sqlite:///#{db_path}")
          expect(db.instance_variable_get(:@pool_size)).to eq(0)
          db.close
        end
      end
    end

    it "uses pooled mode when set > 0" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "p.db")
        with_env("TINA4_DB_POOL" => "4") do
          db = Tina4::Database.new("sqlite:///#{db_path}")
          expect(db.instance_variable_get(:@pool_size)).to eq(4)
          expect(db.pool).to be_a(Tina4::ConnectionPool)
          db.close
        end
      end
    end
  end
end
