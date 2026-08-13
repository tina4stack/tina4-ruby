# frozen_string_literal: true

require "spec_helper"

# The settled structured-logger contract (owner decision 2026-08-09/10),
# superseding the 2026-08-01 pass this file used to pin.
#
# L1  FORMAT IS DEBUG-DERIVED (Decision 3, supersedes the 2026-08-01 "text
#     always" rule): explicit TINA4_LOG_FORMAT wins; otherwise truthy
#     TINA4_DEBUG selects text and a false/absent TINA4_DEBUG selects JSON.
# L2  THE ENV IS READ LAZILY, ON FIRST USE.
# L3  TINA4_LOG_STRICT raises Tina4::LogWriteError on a real write failure.
# L4  REMOVED SETTINGS NOW HARD-FAIL CONFIGURATION (Decision 19; STRICTER
#     than the 2026-08-01 "the old names have no effect" pass).
# L5  The log file contains log lines only (no stdlib ::Logger banner --
#     moot now: LogFileSink is hand-written and never writes one).
# L6  Explicit argument beats environment, which beats default (ADR-0041).
RSpec.describe "the settled logger contract" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:log_path) { File.join(tmpdir, "tina4.log") }

  LOGGER_CONTRACT_SPEC_ENV_KEYS = %w[
    TINA4_LOG_FILE TINA4_LOG_DIR TINA4_LOG_FORMAT TINA4_LOG_OUTPUT
    TINA4_LOG_LEVEL TINA4_LOG_FILE_LEVEL TINA4_LOG_ROTATE_SIZE TINA4_LOG_ROTATE_KEEP
    TINA4_LOG_STRICT TINA4_LOG_FUNC TINA4_LOG_MAX_SIZE TINA4_LOG_KEEP
    TINA4_LOG_APPEND TINA4_DEBUG_LEVEL TINA4_LOG_CRITICAL TINA4_DEBUG
  ].freeze

  around do |example|
    saved = LOGGER_CONTRACT_SPEC_ENV_KEYS.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    saved_pwd = Dir.pwd
    Dir.chdir(tmpdir)
    Tina4::Log.reset
    example.run
  ensure
    Tina4::Log.reset
    Dir.chdir(saved_pwd)
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "L1 format is debug-derived" do
    it "selects JSON by default without TINA4_DEBUG" do
      ENV.delete("TINA4_DEBUG")
      Tina4::Log.configure(output: "file", log_dir: tmpdir, level: "info")
      Tina4::Log.info("prod default is json")
      expect { JSON.parse(File.read(log_path).lines.first) }.not_to raise_error
    end

    it "selects TEXT by default with TINA4_DEBUG=true" do
      ENV["TINA4_DEBUG"] = "true"
      Tina4::Log.configure(output: "file", log_dir: tmpdir, level: "info")
      Tina4::Log.info("dev default is text")
      line = File.read(log_path).lines.first
      expect(line).to include("[INFO")
      expect { JSON.parse(line) }.to raise_error(JSON::ParserError)
    end

    it "NEGATIVE: explicit TINA4_LOG_FORMAT=text wins even without TINA4_DEBUG" do
      ENV.delete("TINA4_DEBUG")
      ENV["TINA4_LOG_FORMAT"] = "text"
      Tina4::Log.configure(output: "file", log_dir: tmpdir, level: "info")
      Tina4::Log.info("still text")
      expect(File.read(log_path).lines.first).to include("[INFO")
    end

    it "NEGATIVE: explicit TINA4_LOG_FORMAT=json wins even with TINA4_DEBUG" do
      ENV["TINA4_DEBUG"] = "true"
      ENV["TINA4_LOG_FORMAT"] = "json"
      Tina4::Log.configure(output: "file", log_dir: tmpdir, level: "info")
      Tina4::Log.error("boom", { code: 500 })
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["level"]).to eq("ERROR")
      expect(entry["context"]["code"]).to eq(500)
    end

    it "JSON-encodes an OBJECT message inline inside the text line" do
      ENV["TINA4_DEBUG"] = "true"
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info({ user: "alice", id: 7 })
      line = File.read(log_path).lines.first
      expect(line).to include('{"id":7,"user":"alice"}')
      expect(line).to include("[INFO")
    end

    it "NEGATIVE: a plain String message is not re-encoded" do
      ENV["TINA4_DEBUG"] = "true"
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("just a string")
      expect(File.read(log_path).lines.first.chomp).to end_with("just a string")
    end
  end

  describe "L2 the env is resolved on FIRST USE" do
    # spec_helper.rb's global prepend_before(:each) restores a suite-wide
    # baseline @snapshot (level=NONE, to keep the console quiet across the
    # whole suite) -- it runs AFTER this file's own `around` hook calls
    # Tina4::Log.reset but BEFORE the example body, so these two cases (which
    # exist specifically to prove "no explicit configure() needed") must
    # reset again for real, inside the body, to observe an actually-nil
    # snapshot before setting the env and reading it lazily.
    it "honours TINA4_LOG_FORMAT=json without an explicit configure call" do
      Tina4::Log.reset
      ENV["TINA4_LOG_FORMAT"] = "json"
      ENV["TINA4_LOG_OUTPUT"] = "file"
      ENV["TINA4_LOG_DIR"] = tmpdir
      Tina4::Log.info("from a script that never called configure")
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["message"]).to eq("from a script that never called configure")
    end

    it "honours TINA4_LOG_LEVEL without an explicit configure call" do
      Tina4::Log.reset
      ENV["TINA4_LOG_LEVEL"] = "error"
      ENV["TINA4_LOG_OUTPUT"] = "both"
      expect(Tina4::Log.enabled?("info")).to be false
      expect(Tina4::Log.enabled?("error")).to be true
    end

    it "NEGATIVE: an explicit configure() level beats the env level" do
      ENV["TINA4_LOG_LEVEL"] = "error"
      Tina4::Log.configure(level: "debug", output: "both")
      expect(Tina4::Log.enabled?("debug")).to be true
    end
  end

  describe "L3 TINA4_LOG_STRICT raises on a REAL log-write failure" do
    def wedge_after_configure
      FileUtils.rm_f(log_path)
      FileUtils.mkdir(log_path)
    end

    it "raises Tina4::LogWriteError when strict is true" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir, strict: true)
      wedge_after_configure
      expect { Tina4::Log.info("this cannot be written") }.to raise_error(Tina4::LogWriteError)
    end

    it "NEGATIVE: swallows the identical failure when strict is off" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir, strict: false)
      wedge_after_configure
      expect { Tina4::Log.info("this cannot be written either") }.not_to raise_error
    end
  end

  describe "L4 removed settings now hard-fail configuration (BREAKING)" do
    %w[TINA4_LOG_MAX_SIZE TINA4_LOG_KEEP TINA4_LOG_APPEND TINA4_DEBUG_LEVEL TINA4_LOG_CRITICAL].each do |name|
      it "raises LogConfigurationError for #{name}" do
        ENV[name] = "1"
        expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
      end
    end

    it "NEGATIVE: TINA4_LOG_ROTATE_SIZE (the canonical name) still rotates" do
      ENV["TINA4_LOG_OUTPUT"] = "file"
      ENV["TINA4_LOG_DIR"] = tmpdir
      ENV["TINA4_LOG_FILE"] = "canonical.log"
      ENV["TINA4_LOG_ROTATE_SIZE"] = "1024"
      Tina4::Log.configure(level: "info")
      120.times { |i| Tina4::Log.info("canonical-line-#{i}-padding-padding-padding") }
      expect(Dir.glob(File.join(tmpdir, "canonical.log.*"))).not_to be_empty
    end
  end

  describe "L5 the log file contains log lines only" do
    it "opens a JSON log file with JSON on line 1 (no banner)" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      Tina4::Log.info("first line")
      first_line = File.read(log_path).lines.first
      expect { JSON.parse(first_line) }.not_to raise_error
    end

    it "opens a TEXT log file with a log line on line 1 (no banner)" do
      Tina4::Log.configure(format: "text", output: "file", log_dir: tmpdir)
      Tina4::Log.info("first line")
      first_line = File.read(log_path).lines.first
      expect(first_line).to include("[INFO")
      expect(first_line).not_to include("Logfile created")
    end
  end

  describe "L6 explicit argument beats environment (ADR-0041)" do
    it "writes to the configure() argument, not to TINA4_LOG_DIR" do
      env_dir = File.join(tmpdir, "from_env")
      arg_dir = File.join(tmpdir, "from_argument")
      FileUtils.mkdir_p(env_dir)
      FileUtils.mkdir_p(arg_dir)
      ENV["TINA4_LOG_OUTPUT"] = "file"
      ENV["TINA4_LOG_DIR"] = env_dir

      Tina4::Log.configure(log_dir: arg_dir, level: "info")
      Tina4::Log.info("which directory won?")

      expect(File.exist?(File.join(arg_dir, "tina4.log"))).to be true
      expect(File.exist?(File.join(env_dir, "tina4.log"))).to be false
    end

    it "NEGATIVE: TINA4_LOG_DIR still applies when configure() is given no directory" do
      env_dir = File.join(tmpdir, "from_env")
      FileUtils.mkdir_p(env_dir)
      ENV["TINA4_LOG_OUTPUT"] = "file"
      ENV["TINA4_LOG_DIR"] = env_dir

      Tina4::Log.configure(level: "info")
      Tina4::Log.info("the env should win here")

      expect(File.exist?(File.join(env_dir, "tina4.log"))).to be true
    end
  end
end
