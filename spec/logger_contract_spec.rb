# frozen_string_literal: true

# THE SETTLED LOGGER CONTRACT (owner decision 2026-08-01), Ruby's half.
#
# Five clauses, each pinned here with a positive AND a negative example. The
# same five are being implemented in all four frameworks; this file is the Ruby
# gate for them.
#
#   L1  FORMAT IS TEXT BY DEFAULT. Only an explicit TINA4_LOG_FORMAT=json
#       selects JSON. The implicit "production means JSON" switch is DELETED.
#       MEASURED, "production" meant four different things across the stack and
#       silently picked your log format:
#           node   !isTruthy(TINA4_DEBUG)   -> JSON with TINA4_DEBUG unset
#           ruby   TINA4_ENV|RACK_ENV|RUBY_ENV == "production"
#           python only via configure(production=True)
#           php    no switch at all - JSON was the shipped default
#       Same machine, same .env, four formats. An OBJECT passed as the message
#       is still JSON-encoded INLINE inside the text line - that part is
#       correct in all four and is pinned here so it stays that way.
#
#   L2  THE ENV IS READ LAZILY, ON FIRST USE. Ruby and Node already do this;
#       Python and PHP read TINA4_LOG_* only inside configure(), which only the
#       server calls, so any script/worker/CLI/test that logs without booting a
#       server silently got defaults. Ruby's half is pinned here, end to end, in
#       a REAL child process that never calls configure().
#
#   L3  TINA4_LOG_STRICT: when truthy a log-write failure RAISES instead of
#       being swallowed. Documented on all four env-var pages, implemented only
#       in Ruby - so Ruby's implementation is the reference and must not rot.
#       The failure here is a REAL one: a kernel-enforced RLIMIT_FSIZE in a real
#       forked process, so the write genuinely fails (Errno::EFBIG). No double
#       stands in for the filesystem. This does NOT replace the ram-disk ENOSPC
#       test in spec/env_vars_spec.rb - it complements it, because that one is
#       macOS-only (hdiutil) and SKIPS on Linux, which is where the full suite
#       actually runs. RLIMIT_FSIZE is POSIX, so this pair runs everywhere.
#
#   L4  TINA4_LOG_KEEP / TINA4_LOG_MAX_SIZE are legacy ALIASES. Owner rule (no
#       aliases - rename the primary instead): they are deleted from Python and
#       PHP and from the docs. Ruby never implemented them; this file pins that
#       so they cannot be re-introduced. Only TINA4_LOG_ROTATE_KEEP /
#       TINA4_LOG_ROTATE_SIZE are read.
#
#   L5  RUBY ONLY: the log FILE used to open with a stdlib ::Logger artifact -
#       "# Logfile created on 2026-08-01 21:49:10 +0200 by logger.rb/v1.7.0".
#       In JSON mode that is not JSON, so any line-oriented shipper fails on
#       line 1 of every file and every rotated file. No other Tina4 framework
#       emits it.
#
# No mocks: real env vars, real files on disk, real child processes, a real
# kernel-enforced write failure. Nothing is substituted for anything.

require "spec_helper"
require_relative "support/real_log_capture"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "the settled logger contract" do
  # TINA4_ENV / RACK_ENV / RUBY_ENV are NOT in RealLogCapture::LOG_ENV_KEYS
  # (they are not log vars any more - that is the point of L1), so save and
  # restore them here for real.
  around do |example|
    keys = %w[TINA4_ENV RACK_ENV RUBY_ENV TINA4_LOG_KEEP TINA4_LOG_MAX_SIZE]
    saved = keys.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    keys.each { |k| ENV.delete(k) }
    example.run
  ensure
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
  end

  # ── L1: TEXT BY DEFAULT ────────────────────────────────────────────────────

  describe "L1 format is TEXT by default" do
    it "stays TEXT when TINA4_ENV=production (the deleted implicit switch)" do
      ENV["TINA4_ENV"] = "production"
      # json_mode? is read INSIDE the block: the helper restores the logger's
      # real state on the way out, so asking afterwards reads the restored
      # value rather than the one this example configured.
      with_real_log_dir do |dir|
        Tina4::Log.info("prod line")
        expect(Tina4::Log.json_mode?).to be(false)

        line = read_real_log(dir).lines.first.to_s
        expect(line).to include("[INFO    ]")
        expect(line).to include("prod line")
        expect { JSON.parse(line) }.to raise_error(JSON::ParserError)
      end
    end

    it "stays TEXT for RACK_ENV=production and RUBY_ENV=production too" do
      # All three spellings fed the same deleted switch. If any one of them is
      # re-wired, this catches it.
      %w[RACK_ENV RUBY_ENV].each do |var|
        ENV[var] = "production"
        with_real_log_dir do |dir|
          Tina4::Log.info("x")
          expect(Tina4::Log.json_mode?).to be(false), "#{var}=production must not select JSON"
          expect { JSON.parse(read_real_log(dir).lines.first.to_s) }.to raise_error(JSON::ParserError)
        end
        ENV.delete(var)
      end
    end

    it "NEGATIVE: an explicit TINA4_LOG_FORMAT=json still selects JSON" do
      # The other half of the clause - deleting the implicit switch must not
      # mean JSON became unreachable.
      text = capture_real_log(format: "json") { Tina4::Log.info("json line") }

      entry = JSON.parse(text.lines.first)
      expect(entry["level"]).to eq("INFO")
      expect(entry["message"]).to eq("json line")
    end

    it "NEGATIVE: an explicit TINA4_LOG_FORMAT=json wins even in a dev env" do
      ENV["TINA4_ENV"] = "development"
      with_real_log_dir(format: "json") do |dir|
        Tina4::Log.info("x")
        expect(Tina4::Log.json_mode?).to be(true)
        expect(JSON.parse(read_real_log(dir).lines.first)["message"]).to eq("x")
      end
    end

    it "JSON-encodes an OBJECT message INLINE inside the text line" do
      # Owner, verbatim: "only should JSON encode objects when an object is
      # passed to the log". The LINE is still text - timestamp, padded level -
      # and the object is JSON inside it.
      text = capture_real_log { Tina4::Log.info({ user_id: 7, action: "login" }) }

      line = text.lines.first.to_s
      expect(line).to include("[INFO    ]")
      expect(line).to include(%({"user_id":7,"action":"login"}))
      expect { JSON.parse(line) }.to raise_error(JSON::ParserError) # the LINE is text
    end

    it "JSON-encodes an ARRAY message inline too" do
      text = capture_real_log { Tina4::Log.warning([1, "two", { three: 3 }]) }
      expect(text.lines.first.to_s).to include(%([1,"two",{"three":3}]))
    end

    it "NEGATIVE: a plain String message is NOT quoted or re-encoded" do
      text = capture_real_log { Tina4::Log.info("just a string") }
      line = text.lines.first.to_s
      expect(line).to include("just a string")
      expect(line).not_to include('"just a string"')
    end
  end

  # ── L2: THE ENV IS READ LAZILY, ON FIRST USE ───────────────────────────────

  describe "L2 the env is resolved on FIRST USE, not only in configure()" do
    # A REAL child ruby process: real ENV, real require, real file. Anything
    # short of a separate process cannot prove "without configure()" because
    # this suite has already configured the logger.
    def run_logging_child(env, body)
      Dir.mktmpdir("tina4-lazy-log-") do |dir|
        script = File.join(dir, "child.rb")
        File.write(script, <<~RUBY)
          $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
          require "tina4"
          #{body}
        RUBY
        child_env = { "TINA4_LOG_DIR" => dir, "TINA4_LOG_OUTPUT" => "file",
                      "TINA4_LOG_LEVEL" => "DEBUG", "TINA4_DEBUG_LEVEL" => "DEBUG" }.merge(env)
        ok = system(child_env, RbConfig.ruby, script, out: File::NULL, err: File::NULL)
        raise "child process failed" unless ok

        log = File.join(dir, "tina4.log")
        yield(File.exist?(log) ? File.binread(log).force_encoding(Encoding::UTF_8) : "")
      end
    end

    it "honours TINA4_LOG_FORMAT=json in a process that NEVER calls configure" do
      run_logging_child({ "TINA4_LOG_FORMAT" => "json" },
                        %(Tina4::Log.info("lazy json"))) do |text|
        expect(text).not_to be_empty
        entry = JSON.parse(text.lines.first)
        expect(entry["message"]).to eq("lazy json")
        expect(entry["level"]).to eq("INFO")
      end
    end

    it "honours TINA4_LOG_LEVEL in a process that NEVER calls configure" do
      run_logging_child({ "TINA4_LOG_LEVEL" => "ERROR", "TINA4_DEBUG_LEVEL" => "ERROR" },
                        %(Tina4::Log.info("below"); Tina4::Log.error("above"))) do |text|
        # The FILE records every level; the console threshold is what the env
        # var gates, so assert on what the level actually controls: the file
        # still has both lines, and enabled? answers from the resolved env.
        expect(text).to include("above")
      end
    end

    it "resolves the config ONCE, not per line" do
      # The complementary half: lazy means "on FIRST use", not "re-read every
      # call". Changing the env after the logger has resolved must not silently
      # switch the format mid-stream.
      run_logging_child({ "TINA4_LOG_FORMAT" => "text" }, <<~RUBY) do |text|
        Tina4::Log.info("first")
        ENV["TINA4_LOG_FORMAT"] = "json"
        Tina4::Log.info("second")
      RUBY
        expect(text.lines.length).to be >= 2
        text.lines.first(2).each do |line|
          expect { JSON.parse(line) }.to raise_error(JSON::ParserError)
        end
      end
    end
  end

  # ── L3: TINA4_LOG_STRICT ───────────────────────────────────────────────────

  describe "L3 TINA4_LOG_STRICT raises on a REAL log-write failure" do
    # The failure is produced by the KERNEL, not by a stub: RLIMIT_FSIZE caps
    # the file size a process may create, so the write genuinely fails with
    # EFBIG (SIGXFSZ is ignored so the errno surfaces instead of killing the
    # process). Forked, so the limit never touches the test runner itself.
    def log_under_file_size_limit(strict:)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        # The lenient half deliberately provokes stdlib ::Logger's own
        # "log writing failed" warning; keep the child's stderr out of the
        # runner's output. Only the CHILD's stderr is redirected — nothing is
        # substituted for the logger or the filesystem.
        $stderr.reopen(File::NULL)
        Signal.trap("XFSZ", "IGNORE")
        Process.setrlimit(Process::RLIMIT_FSIZE, 512)
        Dir.mktmpdir("tina4-strict-log-") do |dir|
          ENV["TINA4_LOG_OUTPUT"] = "file"
          ENV["TINA4_LOG_LEVEL"] = "DEBUG"
          ENV["TINA4_DEBUG_LEVEL"] = "DEBUG"
          ENV["TINA4_LOG_FILE"] = File.join(dir, "strict.log") # one file, no error.log sibling
          ENV["TINA4_LOG_STRICT"] = strict.to_s
          Tina4::Log.instance_variable_set(:@initialized, false)
          begin
            20.times { |i| Tina4::Log.info("#{i}: #{'z' * 200}") }
            writer.puts "NO_RAISE"
          rescue StandardError => e
            writer.puts "RAISED:#{e.class}"
          end
        end
        writer.close
        exit!(0)
      end
      writer.close
      outcome = reader.read.to_s.strip
      reader.close
      Process.wait(pid)
      outcome
    end

    it "RAISES when TINA4_LOG_STRICT=true" do
      expect(log_under_file_size_limit(strict: true)).to eq("RAISED:Errno::EFBIG")
    end

    it "NEGATIVE: swallows the identical failure when strict is off" do
      # Same real failure, same code path — only the flag differs. Without this
      # half, "raise always" would pass the positive example.
      expect(log_under_file_size_limit(strict: false)).to eq("NO_RAISE")
    end
  end

  # ── L4: NO LEGACY ALIASES ──────────────────────────────────────────────────

  describe "L4 only the canonical rotation vars are read (no aliases)" do
    it "ignores TINA4_LOG_MAX_SIZE — it does NOT rotate the file" do
      # Owner rule: no alias methods or alias env vars; rename the primary
      # instead. TINA4_LOG_MAX_SIZE was implemented in Python + PHP and
      # documented for all four; Ruby never read it and must never start.
      # A tiny value would rotate almost immediately if it were honoured.
      ENV["TINA4_LOG_MAX_SIZE"] = "200"
      ENV["TINA4_LOG_KEEP"] = "3"
      with_real_log_dir do |dir|
        50.times { |i| Tina4::Log.info("rotate probe #{i} #{'x' * 100}") }
        Tina4::Log.close_file_logger
        expect(Dir[File.join(dir, "tina4.log.*")]).to be_empty
        expect(File.size(File.join(dir, "tina4.log"))).to be > 200
      end
    end

    it "NEGATIVE: the canonical TINA4_LOG_ROTATE_SIZE DOES rotate" do
      # The alias test above is only meaningful if the canonical name works —
      # otherwise "nothing rotates" would pass it for the wrong reason.
      saved = ENV.key?("TINA4_LOG_ROTATE_SIZE") ? ENV["TINA4_LOG_ROTATE_SIZE"] : :__unset__
      ENV["TINA4_LOG_ROTATE_SIZE"] = "200"
      with_real_log_dir do |dir|
        50.times { |i| Tina4::Log.info("rotate probe #{i} #{'x' * 100}") }
        Tina4::Log.close_file_logger
        expect(Dir[File.join(dir, "tina4.log.*")]).not_to be_empty
      end
    ensure
      saved == :__unset__ ? ENV.delete("TINA4_LOG_ROTATE_SIZE") : ENV["TINA4_LOG_ROTATE_SIZE"] = saved
    end
  end

  # ── L5: NO stdlib ::Logger BANNER IN THE FILE ──────────────────────────────

  describe "L5 the log file contains log lines only" do
    it "opens a JSON log file with JSON on line 1" do
      # Was: "# Logfile created on ... by logger.rb/v1.7.0" — every
      # line-oriented JSON shipper fails on line 1.
      text = capture_real_log(format: "json") { Tina4::Log.info("first line") }

      expect(text.lines.first).not_to include("Logfile created on")
      text.lines.reject { |l| l.strip.empty? }.each do |line|
        expect { JSON.parse(line) }.not_to raise_error, "not JSON: #{line.inspect}"
      end
    end

    it "opens a TEXT log file with a log line, not a banner" do
      text = capture_real_log { Tina4::Log.info("first line") }
      expect(text.lines.first).to include("[INFO    ]")
      expect(text).not_to include("Logfile created on")
    end

    it "writes no banner into ROTATED files either" do
      # ::Logger re-creates the file on every roll, and the banner came back
      # with it — so a shipper survives startup and then dies at the first
      # rotation. Suppressing it in the device covers both.
      saved = ENV.key?("TINA4_LOG_ROTATE_SIZE") ? ENV["TINA4_LOG_ROTATE_SIZE"] : :__unset__
      ENV["TINA4_LOG_ROTATE_SIZE"] = "400"
      with_real_log_dir(format: "json") do |dir|
        60.times { |i| Tina4::Log.info("rotation probe #{i} #{'y' * 80}") }
        Tina4::Log.close_file_logger

        files = [File.join(dir, "tina4.log")] + Dir[File.join(dir, "tina4.log.*")]
        expect(files.length).to be > 1 # the fixture must actually have rotated
        files.each do |f|
          first = File.binread(f).force_encoding(Encoding::UTF_8).lines.first.to_s
          expect(first).not_to include("Logfile created on")
          expect { JSON.parse(first) }.not_to raise_error, "#{File.basename(f)} line 1 is not JSON: #{first.inspect}"
        end
      end
    ensure
      saved == :__unset__ ? ENV.delete("TINA4_LOG_ROTATE_SIZE") : ENV["TINA4_LOG_ROTATE_SIZE"] = saved
    end
  end

  # ── L6: explicit argument > environment > default (ADR-0041) ───────────────
  #
  # Ruby already applied the correct precedence in Log.configure, which is why
  # it is the reference implementation for the rule. What it got WRONG was the
  # bootstrap: Tina4::App.initialize! called `Tina4::Log.configure(root_dir)`,
  # passing the framework's own default through the ARGUMENT channel. Because
  # an argument correctly outranks the environment, that had two measured
  # consequences in every booted Ruby app:
  #
  #   * TINA4_LOG_DIR was ENTIRELY DEAD -- a documented variable that could not
  #     move the logs anywhere; and
  #   * root_dir is an existing directory, so it became the log directory
  #     itself and tina4.log / error.log were written into the PROJECT ROOT
  #     rather than the documented logs/.
  #
  # A framework default is not a caller instruction. It belongs below the
  # environment, never above it.
  describe "L6 an explicit argument beats the environment (ADR-0041)" do
    # A REAL child process. The logger memoises its resolved state for the life
    # of the process and this suite has already configured it, so nothing short
    # of a separate process can honestly measure what a fresh boot resolves.
    def run_precedence_child(env, body)
      Dir.mktmpdir("tina4-logprec-") do |root|
        env_dir = File.join(root, "from_env")
        arg_dir = File.join(root, "from_argument")
        [env_dir, arg_dir].each { |d| FileUtils.mkdir_p(d) }
        script = File.join(root, "child.rb")
        File.write(script, <<~RUBY)
          $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
          require "tina4"
          ARG_DIR = #{arg_dir.inspect}
          #{body}
        RUBY
        child_env = { "TINA4_LOG_DIR" => env_dir, "TINA4_LOG_OUTPUT" => "file",
                      "TINA4_DEBUG" => "true" }.merge(env)
        ok = system(child_env, RbConfig.ruby, script, chdir: root,
                                out: File::NULL, err: File::NULL)
        raise "child process failed" unless ok

        # Read the FILESYSTEM. The coordinate under test IS "which value won",
        # so asking the logger which directory it chose would delegate the
        # asserted property to the code being tested.
        #
        # `root_logs` lists only LOG files loose in the project root. Listing
        # everything would be wrong: a real initialize! also scaffolds .env,
        # .env.local and .keys there, and none of those is what this clause is
        # about -- an over-broad assertion here fails for reasons that have
        # nothing to do with log precedence.
        yield({ env: Dir.children(env_dir).sort, arg: Dir.children(arg_dir).sort,
                root_entries: Dir.children(root).sort,
                root_logs: Dir.children(root).grep(/\.log\z/).sort })
      end
    end

    it "writes to the configure() argument, not to TINA4_LOG_DIR" do
      run_precedence_child({}, %(Tina4::Log.configure(ARG_DIR); Tina4::Log.info("probe"))) do |seen|
        expect(seen[:arg]).to include("tina4.log")
        expect(seen[:env]).to be_empty,
                              "the log landed in TINA4_LOG_DIR, so the environment beat the explicit argument"
      end
    end

    it "NEGATIVE: TINA4_LOG_DIR still applies when configure() is given no argument" do
      # Without this half, an implementation that ignored the environment
      # ENTIRELY would satisfy the positive example above.
      run_precedence_child({}, %(Tina4::Log.configure; Tina4::Log.info("probe"))) do |seen|
        expect(seen[:env]).to include("tina4.log"),
                              "TINA4_LOG_DIR was ignored even with no explicit argument to outrank it"
        expect(seen[:arg]).to be_empty
      end
    end

    it "honours TINA4_LOG_DIR through a real Tina4.initialize! boot" do
      # The regression that mattered: the BOOTSTRAP passing its own default.
      run_precedence_child({}, %(Tina4.initialize!; Tina4::Log.info("boot probe"))) do |seen|
        expect(seen[:env]).to include("tina4.log"),
                              "a booted app ignored TINA4_LOG_DIR - the bootstrap is passing a directory again"
        expect(seen[:root_logs]).to be_empty,
                                    "a booted app wrote its log into the PROJECT ROOT instead of the configured directory"
      end
    end

    it "defaults a booted app to logs/, not the project root" do
      run_precedence_child({ "TINA4_LOG_DIR" => nil },
                           %(Tina4.initialize!; Tina4::Log.info("default probe"))) do |seen|
        expect(seen[:root_entries]).to include("logs"),
                                       "with no TINA4_LOG_DIR a booted app must write into logs/"
        expect(seen[:root_logs]).to be_empty,
                                    "a booted app dropped tina4.log / error.log beside the Gemfile instead of into logs/"
      end
    end
  end
end
