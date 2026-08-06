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
  describe "TINA4_LOG_DIR" do
    it "defaults to <cwd>/logs" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => nil, "TINA4_LOG_FILE" => nil) do
          # configure() with no argument defaults to <cwd>/logs. It used to take
          # a project ROOT and append logs/, which made "put the logs exactly
          # here" impossible to say (feature 2 of the feature audit).
          Dir.chdir(real) { Tina4::Log.configure }
          expect(Tina4::Log.log_dir).to eq(File.join(real, "logs"))
        end
        Tina4::Log.close_file_logger
      end
    end

    it "uses an explicit directory argument as the log directory" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => nil, "TINA4_LOG_FILE" => nil) do
          Tina4::Log.configure(File.join(real, "somewhere"))
          expect(Tina4::Log.log_dir).to eq(File.join(real, "somewhere"))
        end
        Tina4::Log.close_file_logger
      end
    end

    it "uses an explicit relative dir, resolved against the working directory" do
      Dir.mktmpdir do |dir|
        real = File.realpath(dir)
        with_env("TINA4_LOG_DIR" => "var/log", "TINA4_LOG_FILE" => nil) do
          # A relative TINA4_LOG_DIR resolves against the WORKING DIRECTORY.
          # It used to resolve against the configure() argument, which only made
          # sense while that argument was a project root.
          Dir.chdir(real) { Tina4::Log.configure }
          expect(Tina4::Log.log_dir).to eq(File.join(real, "var/log"))
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  describe "TINA4_LOG_FILE" do
    it "defaults to tina4.log under log_dir" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_FILE" => nil, "TINA4_LOG_DIR" => nil) do
          Dir.chdir(File.realpath(dir)) { Tina4::Log.configure }
          expect(Tina4::Log.log_file_path).to eq(File.join(File.realpath(dir), "logs", "tina4.log"))
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
    # v3.13.39: the default (unset) is now DEV-GATED. stdout is always on; the
    # log FILE is written only in development (TINA4_DEBUG truthy). In
    # production / containers it's stdout-only — no file. Explicit
    # file/both (or an explicit TINA4_LOG_FILE) still forces a file.
    # Mirrors the Python master.
    it "writes the file by default in development (TINA4_DEBUG truthy)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(dir)
          # File output enabled in dev — message should hit the file.
          expect { Tina4::Log.info("dev default test") }.not_to raise_error
          expect(File.read(Tina4::Log.log_file_path)).to include("dev default test")
        end
        Tina4::Log.close_file_logger
      end
    end

    it "writes NO file by default in production (TINA4_DEBUG falsy)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(dir)
          Tina4::Log.info("prod default test")
          # Default resolves to stdout-only — no file logger, path empty/absent.
          path = Tina4::Log.log_file_path
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
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

  # ── Default log output is DEV-GATED (v3.13.39) ─────────────────────
  #
  # Unified contract (Python master 4c6d881, mirrored): when
  # TINA4_LOG_OUTPUT is UNSET, stdout is ALWAYS on, but the log FILE is
  # written ONLY in development (TINA4_DEBUG truthy). Production /
  # containers (TINA4_DEBUG falsy) → stdout ONLY, NO file — a log file
  # inside a container bloats the writable layer + disk and 12-factor
  # wants logs on stdout. An explicit TINA4_LOG_OUTPUT=file/both still
  # forces a file even with TINA4_DEBUG off (explicit always wins).
  describe "default log output (dev-gated file, v3.13.39)" do
    # (a) production / no TINA4_DEBUG → NO file written (neither tina4.log
    #     nor any sibling error log — Ruby has a single tina4.log writer).
    it "production (no TINA4_DEBUG): writes NO log file at all" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.instance_variable_get(:@output)).to eq("stdout")
          # No file logger is constructed in stdout-only mode.
          expect(Tina4::Log.instance_variable_get(:@file_logger)).to be_nil
          Tina4::Log.error("prod error should not hit a file")
          Tina4::Log.critical("prod critical should not hit a file")
          path = Tina4::Log.log_file_path
          expect(File.exist?(path) ? File.size(path) : 0).to eq(0)
          # No stray *.log files at all under the log dir.
          stray = Dir.glob(File.join(dir, "logs", "*.log"))
          expect(stray.select { |f| File.size(f).positive? }).to be_empty
        end
        Tina4::Log.close_file_logger
      end
    end

    # (b) development / TINA4_DEBUG truthy → file IS written.
    it "development (TINA4_DEBUG truthy): writes the log file" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => "true") do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.instance_variable_get(:@output)).to eq("both")
          Tina4::Log.info("dev info hits the file")
          expect(File.read(Tina4::Log.log_file_path)).to include("dev info hits the file")
        end
        Tina4::Log.close_file_logger
      end
    end

    # (c) explicit output=both with TINA4_DEBUG OFF → file STILL written
    #     (explicit always wins over the dev gate).
    it "explicit output=both wins even with TINA4_DEBUG off" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => "both", "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.instance_variable_get(:@output)).to eq("both")
          Tina4::Log.info("explicit both in prod")
          expect(File.read(Tina4::Log.log_file_path)).to include("explicit both in prod")
        end
        Tina4::Log.close_file_logger
      end
    end

    # An explicit TINA4_LOG_FILE path alone forces a file with debug off and
    # TINA4_LOG_OUTPUT UNSET — "explicit always wins" (Python-master parity:
    # an explicit log_file builds a writer unconditionally).
    it "explicit TINA4_LOG_FILE forces a file with TINA4_DEBUG off and output unset" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_LOG_FILE" => "custom.log",
                 "TINA4_DEBUG" => nil) do
          Tina4::Log.configure(dir)
          # Default resolves to "both" because an explicit file path was named.
          expect(Tina4::Log.instance_variable_get(:@output)).to eq("both")
          Tina4::Log.info("explicit file path in prod")
          expect(File.read(Tina4::Log.log_file_path)).to include("explicit file path in prod")
          expect(Tina4::Log.log_file_path).to end_with("custom.log")
        end
        Tina4::Log.close_file_logger
      end
    end

    # (d) stdout STILL receives logs in production (stdout is always on).
    it "production: stdout still receives logs" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_OUTPUT" => nil, "TINA4_DEBUG" => nil,
                 "TINA4_LOG_LEVEL" => "info") do
          Tina4::Log.configure(dir)
          expect { Tina4::Log.info("prod stdout line") }
            .to output(/prod stdout line/).to_stdout
        end
        Tina4::Log.close_file_logger
      end
    end
  end

  # TINA4_LOG_STRICT — the raise-on-write-failure flag. Renamed from the
  # old TINA4_LOG_CRITICAL in v3.13.39 to free that env var: `critical` is now
  # a first-class log LEVEL, not a write-failure toggle (Python-master parity).
  describe "TINA4_LOG_STRICT" do
    it "defaults to false (silent on write failure)" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_STRICT" => nil) do
          Tina4::Log.configure(dir)
          # Silent — no exception.
          expect { Tina4::Log.info("ok") }.not_to raise_error
          expect(Tina4::Log.instance_variable_get(:@strict)).to be false
        end
        Tina4::Log.close_file_logger
      end
    end

    it "is read as true when set" do
      Dir.mktmpdir do |dir|
        with_env("TINA4_LOG_STRICT" => "true") do
          Tina4::Log.configure(dir)
          # truthy? helper inside Log is private — confirm via the ivar:
          # @strict true means a write_to_file IOError would propagate.
          expect(Tina4::Log.instance_variable_get(:@strict)).to be true
        end
        Tina4::Log.close_file_logger
      end
    end

    it "raises on a log-write failure when strict, swallows when not" do
      # !! WAS FAILING — TRUE POSITIVE, NOT A BROKEN TEST. NOW FIXED IN THE CODE. !!
      #
      # REAL FRAMEWORK BUG found by the no-mock conversion, fixed 2026-08-01 in
      # lib/tina4/log.rb:
      #
      #   TINA4_LOG_STRICT=true is documented as "raise on log write failures
      #   instead of swallowing" (CLAUDE.md). Against a GENUINELY full
      #   filesystem it did NOT raise.
      #
      #   Why: Tina4::Log#write_to_file rescues IOError/SystemCallError around
      #   `@file_logger << line` and re-raises when @strict. But @file_logger is
      #   a stdlib ::Logger, and ::Logger::LogDevice wraps every device write in
      #   its own `handle_write_errors`, which rescues and turns the failure into
      #   a bare `warn` on stderr. So the real Errno::ENOSPC was swallowed one
      #   layer BELOW Tina4 and never reached Tina4's rescue at all — the
      #   operator got a stderr warning and strict mode was a no-op.
      #
      #   MEASURED 2026-08-01 on a real 1MB HFS+ ram disk filled to 0 KB free,
      #   Ruby 4.0.2: `Tina4::Log.info(...)` printed "log writing failed. No
      #   space left on device @ rb_sys_fail_on_write" to stderr and returned
      #   normally, with TINA4_LOG_STRICT=true set.
      #
      #   The old test could never see this: it stubbed @file_logger.<< to
      #   raise IOError directly, which BYPASSES ::Logger's internal rescue
      #   entirely. It also asserted IOError, while the real failure is
      #   Errno::ENOSPC — a SystemCallError, not an IOError.
      #
      #   The fix uses ::Logger's own seam: build_file_logger passes
      #   `reraise_write_errors: [IOError, SystemCallError]` when @strict, so
      #   handle_write_errors re-raises instead of warning and write_to_file's
      #   `raise if @strict` finally has something to act on. Non-strict is
      #   untouched (empty list = the stdlib default).
      #
      # This example asserts the DOCUMENTED behaviour. It must NEVER be "fixed"
      # by asserting that nothing raises — that would lock the bug back in.
      with_real_tiny_filesystem do |dir, fill_it|
        with_env("TINA4_LOG_STRICT" => "true", "TINA4_LOG_OUTPUT" => "file",
                 "TINA4_LOG_LEVEL" => "DEBUG", "TINA4_DEBUG_LEVEL" => "DEBUG") do
          Tina4::Log.configure(dir)   # opens the REAL log files while space remains
          Tina4::Log.info("first line still fits")
          fill_it.call                # the REAL filesystem is now genuinely full
          expect { Tina4::Log.info("z" * 20_000) }.to raise_error(SystemCallError)
        end
        Tina4::Log.close_file_logger
      end

      # strict OFF: a real write failure must be swallowed. (This half passes
      # today — for the wrong reason: everything is swallowed, strict or not.)
      with_real_tiny_filesystem do |dir, fill_it|
        with_env("TINA4_LOG_STRICT" => nil, "TINA4_LOG_OUTPUT" => "file",
                 "TINA4_LOG_LEVEL" => "DEBUG", "TINA4_DEBUG_LEVEL" => "DEBUG") do
          Tina4::Log.configure(dir)
          Tina4::Log.info("first line still fits")
          fill_it.call
          expect { Tina4::Log.info("z" * 20_000) }.not_to raise_error
        end
        Tina4::Log.close_file_logger
      end
    end

    it "TINA4_LOG_CRITICAL no longer controls strict write behaviour" do
      # The retired env var must NOT flip @strict — it is now a no-op for
      # write-failure handling (it no longer exists as a toggle). Driven with a
      # REAL full filesystem instead of a stubbed @file_logger.<<, so the write
      # failure is a genuine Errno::ENOSPC from the kernel.
      with_real_tiny_filesystem do |dir, fill_it|
        with_env("TINA4_LOG_CRITICAL" => "true", "TINA4_LOG_STRICT" => nil,
                 "TINA4_LOG_OUTPUT" => "file",
                 "TINA4_LOG_LEVEL" => "DEBUG", "TINA4_DEBUG_LEVEL" => "DEBUG") do
          Tina4::Log.configure(dir)
          expect(Tina4::Log.instance_variable_get(:@strict)).to be false
          Tina4::Log.info("first line still fits")
          fill_it.call
          expect { Tina4::Log.info("z" * 20_000) }.not_to raise_error
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
          # TINA4_LOG_DIR is relative, so it resolves against the working
          # directory (the configure() argument is a log directory now, not a
          # project root).
          real = File.realpath(dir)
          Dir.chdir(real) { Tina4::Log.configure }
          # Force the file size past the threshold by writing many lines.
          80.times { |i| Tina4::Log.info("rotation line #{i} " + ("x" * 30)) }
          Tina4::Log.close_file_logger

          rotated = Dir.glob(File.join(real, "logs", "tina4.log.*"))
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
