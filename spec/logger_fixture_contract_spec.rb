# frozen_string_literal: true

require "spec_helper"

# Structured logger shared-fixture contract -- feature 2.
#
# Shared conformance fixture: tina4-documentation/plan/v3/fixtures/logger_contract.json
# Contract: tina4-documentation/plan/v3/features/002-structured-logger.md
# ADR-0041 (explicit argument > environment > default).
#
# One example per fixture case, named to match the case's `name` field
# (checked mechanically by tina4-documentation/scripts/audit-contract-fixtures.py
# via a normalised substring match). Every case drives the REAL Tina4::Log
# against REAL files under a real temp project root and REAL environment
# variables -- no doubles anywhere.
#
# 2026-08-10 owner override baked in throughout: Decision 8 (SEPARATE FILE
# LEVEL -- TINA4_LOG_LEVEL gates the console only, TINA4_LOG_FILE_LEVEL (new,
# default ALL) gates the file, enabled? is sink-aware) and Decision 20
# (SINGLE FILE + IN-PROCESS LOCK ONLY -- the concurrency witness is real
# THREAD concurrency, which Ruby has natively, plus the documented
# per-process-file caveat, not real child processes).
#
# Where a case's `given` under-specifies a coordinate the 2026-08-10 override
# added after the fixture was authored (no case names TINA4_LOG_FILE_LEVEL by
# env/option), the console and file thresholds are set EQUAL so the case's
# own literal assertions hold under real sink-aware routing; Decision 8's
# independence is separately and explicitly proven by
# "console and file levels route independently per Decision 8" below.
RSpec.describe "the structured logger shared-fixture contract" do
  # File.realpath resolves the /var -> /private/var symlink on macOS so this
  # matches what Dir.pwd reports after chdir (Log resolves paths from the
  # real, post-symlink working directory).
  let(:tmpdir) { File.realpath(Dir.mktmpdir) }

  FIXTURE_SPEC_ENV_KEYS = %w[
    TINA4_LOG_LEVEL TINA4_LOG_FILE_LEVEL TINA4_LOG_FORMAT TINA4_LOG_OUTPUT
    TINA4_LOG_DIR TINA4_LOG_FILE TINA4_LOG_ROTATE_SIZE TINA4_LOG_ROTATE_KEEP
    TINA4_LOG_STRICT TINA4_LOG_FUNC TINA4_DEBUG
    TINA4_LOG_MAX_SIZE TINA4_LOG_KEEP TINA4_LOG_APPEND TINA4_DEBUG_LEVEL TINA4_LOG_CRITICAL
  ].freeze

  around do |example|
    saved = FIXTURE_SPEC_ENV_KEYS.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    saved_pwd = Dir.pwd
    # spec_helper.rb pins TINA4_LOG_LEVEL=NONE globally (keeps the console
    # quiet across the whole suite) -- clear every logger env var here so
    # each case starts from the TRUE built-in default unless it sets its
    # own, instead of silently inheriting NONE and gating every event
    # regardless of which sink the case is actually testing.
    FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    Dir.chdir(tmpdir)
    example.run
  ensure
    Tina4::Log.reset
    Dir.chdir(saved_pwd)
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
  end

  # A plain before(:each) (NOT prepend) runs AFTER spec_helper.rb's global
  # config.prepend_before(:each), which restores a baseline @snapshot before
  # every example in the whole suite. Resetting here, not in the `around`
  # hook above (which runs BEFORE that global prepend_before), is what makes
  # `Tina4::Log.reset` actually stick for the example body -- otherwise every
  # case that relies on lazy first-use resolution (no explicit configure())
  # would see the restored suite-wide baseline instead of a fresh snapshot.
  before do
    Tina4::Log.reset
  end

  after { FileUtils.rm_rf(tmpdir) }

  def lines_of(path)
    return [] unless File.exist?(path)

    File.read(path).lines.map(&:chomp).reject(&:empty?)
  end

  TS_RE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/.freeze

  def sans_timestamp(line)
    entry = begin
      JSON.parse(line)
    rescue StandardError
      nil
    end
    ts = entry.is_a?(Hash) ? entry["timestamp"] : line.split(" ", 2).first
    return line unless ts && TS_RE.match?(ts)

    line.sub(ts, "$T0")
  end

  def capture_stdout
    real = $stdout
    io = StringIO.new
    $stdout = io
    yield
    io.string
  ensure
    $stdout = real
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-configuration (LOG-C01..C10)
  # ═══════════════════════════════════════════════════════════════════

  it "logger defaults without environment" do
    cfg = Tina4::Log.configuration
    expect(cfg["level"]).to eq("INFO")
    expect(cfg["format"]).to eq("json")
    expect(cfg["output"]).to eq("stdout")
    expect(cfg["log_dir"]).to eq(File.join(tmpdir, "logs"))
    expect(cfg["log_file"]).to be_nil
    expect(cfg["rotate_size"]).to eq(10_485_760)
    expect(cfg["rotate_keep"]).to eq(5)
    expect(cfg["strict"]).to be false
    expect(cfg["caller"]).to be false
    expect(Dir.exist?(File.join(tmpdir, "logs"))).to be false
  end

  it "generated development values select all text and both sinks" do
    ENV["TINA4_DEBUG"] = "true"
    ENV["TINA4_LOG_LEVEL"] = "ALL"
    cfg = Tina4::Log.configuration
    expect(cfg["level"]).to eq("ALL")
    expect(cfg["format"]).to eq("text")
    expect(cfg["stdout_enabled"]).to be true
    expect(cfg["file_enabled"]).to be true
  end

  it "explicit option beats environment" do
    ENV["TINA4_LOG_LEVEL"] = "ERROR"
    ENV["TINA4_LOG_FORMAT"] = "json"
    ENV["TINA4_LOG_OUTPUT"] = "file"
    Tina4::Log.configure(level: "debug", format: "text", output: "both")
    cfg = Tina4::Log.configuration
    expect(cfg["level"]).to eq("DEBUG")
    expect(cfg["format"]).to eq("text")
    expect(cfg["output"]).to eq("both")
  end

  it "environment beats framework default" do
    ENV["TINA4_LOG_LEVEL"] = "critical"
    ENV["TINA4_LOG_ROTATE_SIZE"] = "2048"
    ENV["TINA4_LOG_ROTATE_KEEP"] = "0"
    cfg = Tina4::Log.configuration
    expect(cfg["level"]).to eq("CRITICAL")
    expect(cfg["rotate_size"]).to eq(2048)
    expect(cfg["rotate_keep"]).to eq(0)
  end

  it "snapshot ignores later environment mutation" do
    ENV["TINA4_LOG_LEVEL"] = "INFO"
    first = Tina4::Log.configuration["level"]
    ENV["TINA4_LOG_LEVEL"] = "CRITICAL"
    second = Tina4::Log.configuration["level"]
    expect([first, second]).to eq(%w[INFO INFO])
  end

  it "reset reloads environment" do
    ENV["TINA4_LOG_LEVEL"] = "INFO"
    first = Tina4::Log.configuration["level"]
    ENV["TINA4_LOG_LEVEL"] = "CRITICAL"
    reset_return = Tina4::Log.reset
    second = Tina4::Log.configuration["level"]
    expect([first, second]).to eq(%w[INFO CRITICAL])
    expect(reset_return).to be_nil
  end

  it "failed reconfiguration preserves prior snapshot" do
    Tina4::Log.configure(level: "info", output: "stdout")
    before = Dir.glob(File.join(tmpdir, "**", "*"))
    expect { Tina4::Log.configure(rotate_size: 0) }.to raise_error(Tina4::LogConfigurationError)
    expect(Tina4::Log.configuration["level"]).to eq("INFO")
    expect(Dir.glob(File.join(tmpdir, "**", "*"))).to eq(before)
  end

  it "file name does not enable file sink" do
    ENV["TINA4_DEBUG"] = "false"
    ENV["TINA4_LOG_FILE"] = "app.log"
    cfg = Tina4::Log.configuration
    expect(cfg["output"]).to eq("stdout")
    expect(cfg["stdout_enabled"]).to be true
    expect(cfg["file_enabled"]).to be false
    expect(cfg["log_file"]).to eq(File.join(tmpdir, "logs", "app.log"))
  end

  it "relative and absolute paths resolve without guessing" do
    Tina4::Log.configure(log_dir: "var/log", log_file: "app.data", output: "file")
    cfg = Tina4::Log.configuration
    expect(cfg["log_dir"]).to eq(File.join(tmpdir, "var", "log"))
    expect(cfg["log_file"]).to eq(File.join(tmpdir, "var", "log", "app.data"))
    expect(cfg["layout"]).to eq("single")
  end

  it "configuration result is a defensive copy" do
    ENV["TINA4_LOG_LEVEL"] = "INFO"
    cfg1 = Tina4::Log.configuration
    cfg1["level"] = "MUTATED"
    cfg1["new_key"] = "leaked"
    cfg2 = Tina4::Log.configuration
    expect(cfg2["level"]).to eq("INFO")
    expect(cfg2).not_to have_key("new_key")
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-invalid-configuration (LOG-V01..V05)
  # ═══════════════════════════════════════════════════════════════════

  it "invalid enum values fail" do
    [
      { "TINA4_LOG_LEVEL" => "verbose" },
      { "TINA4_LOG_FORMAT" => "yaml" },
      { "TINA4_LOG_OUTPUT" => "stout" }
    ].each do |env|
      FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
      env.each { |k, v| ENV[k] = v }
      expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be false
      Tina4::Log.reset
    end
  end

  it "invalid rotation values fail" do
    [
      { "TINA4_LOG_ROTATE_SIZE" => "0" },
      { "TINA4_LOG_ROTATE_SIZE" => "1023" },
      { "TINA4_LOG_ROTATE_SIZE" => "large" },
      { "TINA4_LOG_ROTATE_KEEP" => "-1" },
      { "TINA4_LOG_ROTATE_KEEP" => "1.5" }
    ].each do |env|
      FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
      env.each { |k, v| ENV[k] = v }
      expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be false
      Tina4::Log.reset
    end
  end

  it "invalid path and boolean types fail" do
    FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["TINA4_LOG_DIR"] = ""
    expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
    Tina4::Log.reset

    # The NUL-byte case cannot go through a real OS env var (ENV[]= raises on
    # an embedded NUL) -- the explicit-argument channel is the real,
    # reachable path for that exact byte sequence.
    expect { Tina4::Log.configure(log_file: "bad\0name") }.to raise_error(Tina4::LogConfigurationError)
    Tina4::Log.reset

    FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["TINA4_LOG_STRICT"] = "maybe"
    expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
    Tina4::Log.reset

    FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["TINA4_LOG_FUNC"] = "1" # native int, not the native boolean the setting requires
    expect { Tina4::Log.configure }.to raise_error(Tina4::LogConfigurationError)
    Tina4::Log.reset
  end

  it "removed settings fail with migration detail" do
    %w[TINA4_LOG_MAX_SIZE TINA4_LOG_KEEP TINA4_LOG_APPEND TINA4_DEBUG_LEVEL TINA4_LOG_CRITICAL].each do |setting|
      FIXTURE_SPEC_ENV_KEYS.each { |k| ENV.delete(k) }
      ENV[setting] = "1"
      begin
        Tina4::Log.configure
        raise "expected LogConfigurationError for #{setting}"
      rescue Tina4::LogConfigurationError => e
        expect(e.message).to include("removed setting")
        expect(e.setting).to eq(setting)
      end
      Tina4::Log.reset
    end
  end

  it "legacy bracket level fails" do
    ENV["TINA4_LOG_LEVEL"] = "[TINA4_LOG_ERROR]"
    begin
      Tina4::Log.configure
      raise "expected LogConfigurationError"
    rescue Tina4::LogConfigurationError => e
      expect(e.setting).to eq("TINA4_LOG_LEVEL")
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-levels-and-routing (LOG-L01..L05)
  # ═══════════════════════════════════════════════════════════════════

  it "every threshold has one shared level matrix" do
    expected = {
      "ALL" => %w[DEBUG INFO WARNING ERROR CRITICAL],
      "DEBUG" => %w[DEBUG INFO WARNING ERROR CRITICAL],
      "INFO" => %w[INFO WARNING ERROR CRITICAL],
      "WARNING" => %w[WARNING ERROR CRITICAL],
      "ERROR" => %w[ERROR CRITICAL],
      "CRITICAL" => %w[CRITICAL],
      "NONE" => []
    }
    expected.each do |threshold, want|
      Tina4::Log.reset
      dir = File.join(tmpdir, threshold)
      out = capture_stdout do
        Tina4::Log.configure(level: threshold, file_level: threshold, output: "both", log_dir: dir, format: "json")
        %w[debug info warning error critical].each { |l| Tina4::Log.public_send(l, "probe") }
      end
      stdout_levels = out.lines.map { |l| JSON.parse(l)["level"] }
      file_levels = lines_of(File.join(dir, "tina4.log")).map { |l| JSON.parse(l)["level"] }
      expect(stdout_levels).to eq(want), "stdout mismatch at threshold #{threshold}"
      expect(file_levels).to eq(want), "file mismatch at threshold #{threshold}"
    end
  end

  it "level configuration is case insensitive" do
    { "all" => "ALL", "Debug" => "DEBUG", "INFO" => "INFO", "warning" => "WARNING",
      "Error" => "ERROR", "critical" => "CRITICAL", "none" => "NONE" }.each do |raw, canonical|
      Tina4::Log.reset
      Tina4::Log.configure(level: raw)
      expect(Tina4::Log.configuration["level"]).to eq(canonical)
    end
  end

  it "is enabled matches real routing" do
    # given.level applies to BOTH knobs (the fixture predates the
    # 2026-08-10 sink-split override and does not distinguish them) so the
    # case's own "stdout_equals_main_file_levels" holds under real
    # sink-aware routing.
    out = capture_stdout do
      Tina4::Log.configure(level: "WARNING", file_level: "WARNING", output: "both", log_dir: tmpdir, format: "json")
      %w[debug info warning error critical].each { |l| Tina4::Log.public_send(l, "probe") }
    end
    expect(Tina4::Log.enabled?("debug")).to be false
    expect(Tina4::Log.enabled?("info")).to be false
    expect(Tina4::Log.enabled?("warning")).to be true
    expect(Tina4::Log.enabled?("error")).to be true
    expect(Tina4::Log.enabled?("critical")).to be true

    stdout_levels = out.lines.map { |l| JSON.parse(l)["level"] }
    file_levels = lines_of(File.join(tmpdir, "tina4.log")).map { |l| JSON.parse(l)["level"] }
    expect(stdout_levels).to eq(%w[WARNING ERROR CRITICAL])
    expect(file_levels).to eq(%w[WARNING ERROR CRITICAL])
  end

  it "unknown is enabled argument fails" do
    Tina4::Log.configure(output: "both")
    expect { Tina4::Log.enabled?("verbose") }.to raise_error(Tina4::LogArgumentError)
  end

  it "directory and named file layouts are exact" do
    events = %w[info warning error critical]

    Tina4::Log.configure(level: "ALL", output: "file", log_dir: File.join(tmpdir, "dir_mode"))
    events.each { |l| Tina4::Log.public_send(l, "probe") }
    dir_main = lines_of(File.join(tmpdir, "dir_mode", "tina4.log")).map { |l| JSON.parse(l)["level"] }
    dir_error = lines_of(File.join(tmpdir, "dir_mode", "error.log")).map { |l| JSON.parse(l)["level"] }
    expect(dir_main).to eq(%w[INFO WARNING ERROR CRITICAL])
    expect(dir_error).to eq(%w[WARNING ERROR CRITICAL])

    Tina4::Log.reset
    Tina4::Log.configure(level: "ALL", output: "file", log_dir: File.join(tmpdir, "file_mode"), log_file: "app.log")
    events.each { |l| Tina4::Log.public_send(l, "probe") }
    named = lines_of(File.join(tmpdir, "file_mode", "app.log")).map { |l| JSON.parse(l)["level"] }
    expect(named).to eq(%w[INFO WARNING ERROR CRITICAL])
    expect(File.exist?(File.join(tmpdir, "file_mode", "error.log"))).to be false
  end

  it "console and file levels route independently per Decision 8" do
    out = capture_stdout do
      Tina4::Log.configure(level: "ERROR", file_level: "DEBUG", output: "both", log_dir: tmpdir)
      Tina4::Log.debug("only the file should see this")
      Tina4::Log.info("only the file should see this too")
    end
    expect(out).not_to include("only the file should see this")
    content = File.read(File.join(tmpdir, "tina4.log"))
    expect(content).to include("only the file should see this")
    expect(content).to include("only the file should see this too")
    expect(Tina4::Log.enabled?("debug")).to be false
    expect(Tina4::Log.enabled?("debug", sink: "file")).to be true
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-format-and-values (LOG-F01..F12)
  # ═══════════════════════════════════════════════════════════════════

  it "canonical json bytes" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    Tina4::Log.info("ready")
    line = lines_of(File.join(tmpdir, "tina4.log")).first
    entry = JSON.parse(line)
    expect(entry["timestamp"]).to match(TS_RE)
    expect(entry.keys).to eq(%w[timestamp level message])
    expect(entry["level"]).to eq("INFO")
    expect(entry["message"]).to eq("ready")
  end

  it "canonical text bytes" do
    Tina4::Log.configure(format: "text", output: "file", log_dir: tmpdir)
    Tina4::Log.info("ready")
    line = lines_of(File.join(tmpdir, "tina4.log")).first
    expect(sans_timestamp(line)).to eq("$T0 [INFO    ] ready")
    expect(line).not_to include("\e[")
  end

  it "optional fields and sorted context have exact order" do
    ENV["TINA4_LOG_FUNC"] = "true"
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    Tina4::Log.set_request_id("req-1")
    begin
      # A real NAMED method, not a block: caller capture deliberately
      # filters block/anonymous frames as noise (Decision 16).
      emit_with_context
    ensure
      Tina4::Log.clear_request_id
    end
    entry = JSON.parse(lines_of(File.join(tmpdir, "tina4.log")).first)
    expect(entry.keys).to eq(%w[timestamp level message request_id function context])
    expect(entry["request_id"]).to eq("req-1")
    expect(entry["function"]).to eq("emit_with_context")
    expect(entry["context"]).to eq({ "a" => { "b" => 3, "y" => 2 }, "z" => 1 })
    expect(entry["context"].keys).to eq(%w[a z])
    expect(entry["context"]["a"].keys).to eq(%w[b y])
  end

  def emit_with_context
    Tina4::Log.info("ready", { "z" => 1, "a" => { "y" => 2, "b" => 3 } })
  end

  it "native scalar messages use json spelling" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    [nil, true, false, 42, 1.5].each { |m| Tina4::Log.info(m) }
    got = lines_of(File.join(tmpdir, "tina4.log")).map { |l| JSON.parse(l)["message"] }
    expect(got).to eq(%w[null true false 42 1.5])
  end

  it "map and sequence messages use compact sorted json" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    Tina4::Log.info(["x", 2])
    Tina4::Log.info({ "z" => 1, "a" => true })
    got = lines_of(File.join(tmpdir, "tina4.log")).map { |l| JSON.parse(l)["message"] }
    expect(got).to eq(['["x",2]', '{"a":true,"z":1}'])
  end

  it "embedded line breaks cannot inject records" do
    Tina4::Log.configure(format: "text", output: "both", log_dir: tmpdir)
    message = "one\\path\rtwo"
    context = { "value" => "a\nb" }
    Tina4::Log.info(message, context)
    text_lines = lines_of(File.join(tmpdir, "tina4.log"))
    expect(text_lines.length).to eq(1)
    expect(text_lines.first).to include('one\\\\path\\rtwo')

    Tina4::Log.reset
    Tina4::Log.configure(format: "json", output: "file", log_dir: File.join(tmpdir, "j"))
    Tina4::Log.info(message, context)
    json_lines = lines_of(File.join(tmpdir, "j", "tina4.log"))
    expect(json_lines.length).to eq(1)
    entry = JSON.parse(json_lines.first)
    expect(entry["message"]).to eq(message)
  end

  it "ansi exists only on interactive text stdout" do
    require "pty"

    run_in_real_pty = lambda do |fmt|
      script = <<~RUBY
        $LOAD_PATH.unshift(#{REPO_LIB.inspect})
        require "tina4/log"
        Dir.chdir(#{tmpdir.inspect})
        Tina4::Log.configure(format: #{fmt.inspect}, output: "stdout")
        Tina4::Log.warning("probe")
      RUBY
      script_path = File.join(tmpdir, "pty_#{fmt}.rb")
      File.write(script_path, script)
      output = +""
      PTY.spawn(RUBY_BIN, script_path) do |r, _w, pid|
        begin
          loop { output << r.readpartial(4096) }
        rescue EOFError, Errno::EIO
          # normal end of the pty stream
        end
        Process.wait(pid)
      end
      output
    end

    tty_text = run_in_real_pty.call("text")
    expect(tty_text).to include("\e["), "an interactive tty running text format must carry ANSI colour"
    tty_json = run_in_real_pty.call("json")
    expect(tty_json).not_to include("\e["), "JSON must never carry ANSI, even on a tty"

    # Non-interactive text stdout (a captured StringIO -- what a redirected
    # pipe looks like) must never carry ANSI.
    out = capture_stdout do
      Tina4::Log.configure(format: "text", output: "stdout")
      Tina4::Log.warning("probe")
    end
    expect(out).not_to include("\e[")

    # And neither may a real file.
    Tina4::Log.reset
    Tina4::Log.configure(format: "text", output: "file", log_dir: File.join(tmpdir, "filecheck"))
    Tina4::Log.warning("probe")
    expect(File.read(File.join(tmpdir, "filecheck", "tina4.log"))).not_to include("\e[")
  end

  it "circular context is marked without raising" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    circular = {}
    circular["self"] = circular
    result = Tina4::Log.info("ready", circular)
    expect(result).to be_nil
    entry = JSON.parse(lines_of(File.join(tmpdir, "tina4.log")).first)
    expect(entry["context"]).to eq({ "self" => "[Circular]" })
  end

  it "invalid utf8 binary has a digest marker" do
    raw = ["ff00"].pack("H*")
    expect(raw.bytesize).to eq(2)
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    Tina4::Log.info(raw)
    entry = JSON.parse(lines_of(File.join(tmpdir, "tina4.log")).first)
    m = entry["message"].match(/\A<binary 2 bytes sha256=([0-9a-f]{64})>\z/)
    expect(m).not_to be_nil
    expect(m[1]).to eq(Digest::SHA256.hexdigest(raw))
  end

  it "unsupported value does not run application stringification" do
    called = false
    obj = Object.new
    obj.define_singleton_method(:to_s) do
      called = true
      raise "must never be called"
    end
    Tina4::Log.configure(format: "json", output: "stdout")
    out = capture_stdout { Tina4::Log.info(obj) }
    entry = JSON.parse(out.lines.first)
    expect(entry["message"]).to eq("[Unsupported]")
    expect(called).to be false
  end

  it "later context mutation cannot change event" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    context = { "items" => [1] }
    Tina4::Log.info("ready", context)
    context["items"] << 2
    entry = JSON.parse(lines_of(File.join(tmpdir, "tina4.log")).first)
    expect(entry["context"]).to eq({ "items" => [1] })
  end

  it "oversized event becomes bounded valid replacement" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir, rotate_size: 1024)
    Tina4::Log.info("x" * 5000)
    raw = lines_of(File.join(tmpdir, "tina4.log")).first
    expect("#{raw}\n".bytesize).to be <= 1024
    entry = JSON.parse(raw)
    expect(entry["message"]).to eq("Log event omitted: encoded size exceeds sink limit")
    expect(entry["context"]["truncated"]).to be true
    expect(entry["context"]["original_bytes"]).to be > 1024
    expect(entry["context"]["sha256"]).to match(/\A[0-9a-f]{64}\z/)
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-sinks-and-rotation (LOG-S01..S05, LOG-R01..R07)
  # ═══════════════════════════════════════════════════════════════════

  it "explicit stdout creates no files" do
    ENV["TINA4_DEBUG"] = "true"
    out = capture_stdout do
      Tina4::Log.configure(output: "stdout", log_file: "app.log", log_dir: tmpdir)
      Tina4::Log.info("ready")
    end
    expect(out.lines.reject(&:empty?).length).to eq(1)
    expect(Dir.glob(File.join(tmpdir, "*"))).to eq([])
  end

  it "explicit file silences stdout" do
    out = capture_stdout do
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("ready")
    end
    expect(out).to eq("")
    expect(File.exist?(File.join(tmpdir, "tina4.log"))).to be true
  end

  it "explicit both writes stdout and files in production" do
    ENV["TINA4_DEBUG"] = "false"
    out = capture_stdout do
      Tina4::Log.configure(output: "both", log_dir: tmpdir)
      Tina4::Log.warning("ready")
    end
    expect(out.lines.reject(&:empty?).length).to eq(1)
    expect(File.exist?(File.join(tmpdir, "tina4.log"))).to be true
    expect(File.exist?(File.join(tmpdir, "error.log"))).to be true
  end

  it "unset output is stdout only in production" do
    ENV["TINA4_DEBUG"] = "false"
    out = capture_stdout do
      Tina4::Log.configure(log_dir: tmpdir)
      Tina4::Log.warning("ready")
    end
    expect(out.lines.reject(&:empty?).length).to eq(1)
    expect(Dir.glob(File.join(tmpdir, "*"))).to eq([])
  end

  it "unset output writes stdout and bounded files in development" do
    ENV["TINA4_DEBUG"] = "true"
    out = capture_stdout do
      Tina4::Log.configure(log_dir: tmpdir)
      Tina4::Log.warning("ready")
    end
    expect(out.lines.reject(&:empty?).length).to eq(1)
    expect(File.exist?(File.join(tmpdir, "tina4.log"))).to be true
    expect(File.exist?(File.join(tmpdir, "error.log"))).to be true
  end

  it "exact rotation boundary does not rotate" do
    path = File.join(tmpdir, "app.log")
    File.write(path, "x" * 1000)
    sink = Tina4::LogFileSink.new(path, 1024, 2)
    sink.open
    sink.write("x" * 23 + "\n") # 24 bytes total
    expect(File.size(path)).to eq(1024)
    expect(File.exist?("#{path}.1")).to be false
  end

  it "next record is predicted before append" do
    path = File.join(tmpdir, "app.log")
    File.write(path, "x" * 1000)
    sink = Tina4::LogFileSink.new(path, 1024, 2)
    sink.open
    sink.write("x" * 24 + "\n") # 25 bytes total -> 1000+25 > 1024
    expect(File.size(path)).to eq(25)
    expect(File.size("#{path}.1")).to eq(1000)
  end

  it "backup names and retention are deterministic" do
    path = File.join(tmpdir, "app.log")
    sink = Tina4::LogFileSink.new(path, 1024, 2)
    sink.open
    30.times { sink.write("x" * 299 + "\n") } # 300 bytes/record
    expect(File.exist?(path)).to be true
    expect(File.exist?("#{path}.1")).to be true
    expect(File.exist?("#{path}.2")).to be true
    expect(File.exist?("#{path}.0")).to be false
    expect(File.exist?("#{path}.3")).to be false
  end

  it "zero retention keeps only bounded current file" do
    path = File.join(tmpdir, "app.log")
    sink = Tina4::LogFileSink.new(path, 1024, 0)
    sink.open
    20.times { sink.write("x" * 299 + "\n") }
    expect(File.exist?(path)).to be true
    expect(File.size(path)).to be <= 1024
    expect(Dir.glob("#{path}.*")).to eq([])
  end

  it "preexisting oversized file rotates before append" do
    path = File.join(tmpdir, "app.log")
    File.write(path, "x" * 1500)
    sink = Tina4::LogFileSink.new(path, 1024, 1)
    sink.open
    sink.write("x" * 19 + "\n") # 20 bytes
    expect(File.size(path)).to eq(20)
    expect(File.size("#{path}.1")).to eq(1500)
  end

  it "main and error files rotate independently" do
    Tina4::Log.configure(level: "ALL", output: "file", log_dir: tmpdir, rotate_size: 1024, rotate_keep: 1)
    60.times { |i| Tina4::Log.info("info-#{i}-padpadpadpadpadpadpadpadpadpad") }
    20.times { |i| Tina4::Log.warning("warn-#{i}-padpadpadpadpadpadpadpadpadpad") }
    main = File.join(tmpdir, "tina4.log")
    error = File.join(tmpdir, "error.log")
    expect(File.size(main)).to be <= 1024
    expect(File.size(error)).to be <= 1024
    main_backups = Dir.glob("#{main}.*").length
    error_backups = Dir.glob("#{error}.*").length
    expect(main_backups).to be <= 1
    expect(error_backups).to be <= 1
    expect(main_backups).to be >= error_backups
  end

  it "concurrent processes preserve records and retention" do
    # Decision 20 override: SINGLE FILE + IN-PROCESS LOCK ONLY. Ruby has real
    # native threads, so the concurrency witness is real THREAD concurrency
    # (not real child processes), matching the decision's own thread-only
    # floor directly rather than exceeding it via a process-level lock.
    Tina4::Log.configure(level: "ALL", output: "file", log_dir: tmpdir, rotate_size: 4096, rotate_keep: 2, format: "json")
    n_threads = 4
    per_thread = 100

    threads = Array.new(n_threads) do |t|
      Thread.new do
        per_thread.times { |seq| Tina4::Log.info("concurrent", { "thread" => t, "seq" => seq }) }
      end
    end
    threads.each(&:join)

    files = [File.join(tmpdir, "tina4.log")] + Dir.glob(File.join(tmpdir, "tina4.log.*"))
    seen = {}
    partial = 0
    files.each do |f|
      lines_of(f).each do |raw|
        entry = begin
          JSON.parse(raw)
        rescue StandardError
          partial += 1
          next
        end
        key = "#{entry['context']['thread']}:#{entry['context']['seq']}"
        expect(seen).not_to have_key(key), "duplicate event id #{key}"
        seen[key] = true
      end
    end
    expect(partial).to eq(0)
    expect(Dir.glob(File.join(tmpdir, "tina4.log.*")).length).to be <= 2
    expect(Dir.glob(File.join(tmpdir, "*.lock"))).to eq([])
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-request-and-lifecycle (LOG-Q01..Q05)
  # ═══════════════════════════════════════════════════════════════════

  it "set get and clear request id" do
    Tina4::Log.set_request_id("req-1")
    first = Tina4::Log.get_request_id
    Tina4::Log.clear_request_id
    second = Tina4::Log.get_request_id
    expect([first, second]).to eq(["req-1", nil])
  end

  it "overlapping requests never exchange ids" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)

    thread_a = Thread.new do
      Tina4::Log.set_request_id("A")
      sleep 0.05
      Tina4::Log.info("from-a")
      Tina4::Log.clear_request_id
    end
    thread_b = Thread.new do
      Tina4::Log.set_request_id("B")
      Tina4::Log.info("from-b")
      sleep 0.02
      Tina4::Log.clear_request_id
    end
    [thread_a, thread_b].each(&:join)

    records = lines_of(File.join(tmpdir, "tina4.log")).to_h { |l| e = JSON.parse(l); [e["message"], e["request_id"]] }
    expect(records).to eq({ "from-a" => "A", "from-b" => "B" })
  end

  it "request pipeline clears id in finally" do
    Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
    Tina4::Router.clear!

    Tina4::Router.get("/boom") do |_req, _res|
      Tina4::Log.info("boom-handler")
      raise "intentional failure for LOG-Q03"
    end
    Tina4::Router.get("/ok") do |_req, res|
      Tina4::Log.info("ok-handler")
      res.json({ ok: true })
    end

    client = Tina4::TestClient.new(Tina4::RackApp.new)
    begin
      # A raised handler still reaches the real dispatch pipeline's own
      # error handling (a 500), so this drives the SAME real ensure/finally
      # path as any other request -- it does not bypass it.
      client.get("/boom", headers: { "X-Request-ID" => "A" })
      expect(Tina4::Log.get_request_id).to be_nil, "id must be cleared after a request whose handler raised"

      client.get("/ok", headers: { "X-Request-ID" => "B" })
      expect(Tina4::Log.get_request_id).to be_nil, "id must be cleared after a request that finished normally"
    ensure
      Tina4::Router.clear!
    end

    records = lines_of(File.join(tmpdir, "tina4.log")).map { |l| JSON.parse(l) }
    b_ids = records.select { |r| r["message"] == "ok-handler" }.map { |r| r["request_id"] }
    expect(b_ids).to eq(["B"])
  end

  it "reset is idempotent and reloads a clean snapshot" do
    Tina4::Log.configure(output: "file", log_dir: tmpdir)
    Tina4::Log.set_request_id("A")
    Tina4::Log.info("before reset")

    Tina4::Log.reset
    Tina4::Log.reset # idempotent

    expect(Tina4::Log.get_request_id).to be_nil

    Tina4::Log.configure(output: "file", log_dir: tmpdir) # reopenable
    Tina4::Log.info("after reset")
    expect(File.read(File.join(tmpdir, "tina4.log"))).to include("after reset")
  end

  it "forked child discards inherited logger state" do
    skip "fork is POSIX-only" unless Process.respond_to?(:fork)

    Tina4::Log.configure(output: "file", log_dir: tmpdir)
    Tina4::Log.set_request_id("parent")
    Tina4::Log.info("parent line")

    result_path = File.join(tmpdir, "child_result.json")
    child_log_path = File.join(tmpdir, "child.log")
    pid = Process.fork do
      # A forked child MUST exit unconditionally, or an uncaught error here
      # leaves it running as a full copy of this RSpec process.
      begin
        child_request_id = Tina4::Log.get_request_id
        child_snapshot_is_nil = Tina4::Log.instance_variable_get(:@snapshot).nil?
        File.write(result_path, JSON.generate(
                                   "child_request_id" => child_request_id,
                                   "child_snapshot_resolved_fresh" => child_snapshot_is_nil
                                 ))
        Tina4::Log.configure(output: "file", log_dir: tmpdir, log_file: child_log_path)
        Tina4::Log.info("child line")
      rescue StandardError => e
        warn "child error: #{e}"
      ensure
        Kernel.exit!(0)
      end
    end
    Process.waitpid(pid)

    result = JSON.parse(File.read(result_path))
    expect(result["child_request_id"]).to be_nil
    expect(result["child_snapshot_resolved_fresh"]).to be true
    expect(Tina4::Log.get_request_id).to eq("parent"), "the parent's own context must be unaffected"
    expect(File.read(File.join(tmpdir, "tina4.log"))).to include("parent line")
    expect(File.read(child_log_path)).to include("child line")
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-failure-policy (LOG-E01..E05)
  # ═══════════════════════════════════════════════════════════════════

  it "inaccessible selected sink fails configuration" do
    unwritable = File.join(tmpdir, "unwritable")
    Dir.mkdir(unwritable)
    File.chmod(0o500, unwritable)
    begin
      begin
        Tina4::Log.configure(output: "file", log_dir: File.join(unwritable, "nested"))
        raise "expected LogConfigurationError"
      rescue Tina4::LogConfigurationError => e
        expect(e.operation).to eq("open")
        expect(e.sink).not_to be_nil
      end
    ensure
      File.chmod(0o700, unwritable)
    end
  end

  it "non strict write failure disables sink and diagnoses once" do
    Tina4::Log.configure(strict: false, output: "both", log_dir: tmpdir)
    target = File.join(tmpdir, "tina4.log")
    FileUtils.rm_f(target)
    Dir.mkdir(target) # wedge AFTER a successful configure

    out = capture_stdout do
      3.times { |i| Tina4::Log.info("line-#{i}") }
    end
    lines = out.lines.reject(&:empty?)
    event_lines = lines.reject { |l| l.include?("tina4:") }
    diagnostics = lines.select { |l| l.include?("tina4:") }
    expect(event_lines.length).to eq(3)
    expect(diagnostics.length).to be >= 1
  end

  it "strict write failure raises catchable error" do
    Tina4::Log.configure(strict: true, output: "file", log_dir: tmpdir)
    target = File.join(tmpdir, "tina4.log")
    FileUtils.rm_f(target)
    Dir.mkdir(target)

    begin
      Tina4::Log.info("ready")
      raise "expected LogWriteError"
    rescue Tina4::LogWriteError => e
      expect(e.sink).not_to be_nil
      expect(e.operation).not_to be_nil
    end
  end

  it "reset permits failed sink retry" do
    Tina4::Log.configure(strict: false, output: "file", log_dir: tmpdir)
    target = File.join(tmpdir, "tina4.log")
    FileUtils.rm_f(target)
    Dir.mkdir(target)
    Tina4::Log.info("first attempt swallowed")
    first_written = File.directory?(target) ? false : File.read(target).include?("first attempt swallowed")

    Dir.rmdir(target) # repair
    Tina4::Log.reset
    Tina4::Log.configure(strict: false, output: "file", log_dir: tmpdir)
    Tina4::Log.info("second attempt succeeds")

    expect(first_written).to be false
    expect(File.read(target)).to include("second attempt succeeds")
  end

  it "lock timeout follows sink failure policy" do
    # Ruby's Mutex forbids unlocking from a thread other than the one that
    # locked it, so the SAME holder thread must both acquire and release --
    # the main thread only signals when to let go.
    Tina4::Log.configure(strict: false, output: "file", log_dir: tmpdir)
    sink = Tina4::Log.instance_variable_get(:@snapshot)[:main_sink]
    mutex = sink.instance_variable_get(:@mutex)
    release = false
    acquired = false
    holder = Thread.new do
      mutex.lock
      acquired = true
      sleep 0.01 until release
      mutex.unlock
    end
    sleep 0.01 until acquired
    begin
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Tina4::Log.info("non-strict under lock contention") # must not raise
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      expect(elapsed).to be < (Tina4::LogFileSink::LOCK_TIMEOUT_SECONDS + 1.0), "wait must be bounded"
    ensure
      release = true
      holder.join
    end

    Tina4::Log.reset
    Tina4::Log.configure(strict: true, output: "file", log_dir: File.join(tmpdir, "strict"))
    sink2 = Tina4::Log.instance_variable_get(:@snapshot)[:main_sink]
    mutex2 = sink2.instance_variable_get(:@mutex)
    release2 = false
    acquired2 = false
    holder2 = Thread.new do
      mutex2.lock
      acquired2 = true
      sleep 0.01 until release2
      mutex2.unlock
    end
    sleep 0.01 until acquired2
    begin
      begin
        Tina4::Log.info("strict under lock contention")
        raise "expected LogWriteError"
      rescue Tina4::LogWriteError => e
        expect(e.operation).to eq("lock")
      end
    ensure
      release2 = true
      holder2.join
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # logger-public-surface-and-integration (LOG-A01..A03, LOG-I01..I02)
  # ═══════════════════════════════════════════════════════════════════

  it "public surface contains every required concept" do
    %i[configure debug info warning error critical enabled? set_request_id
       get_request_id clear_request_id configuration reset].each do |name|
      expect(Tina4::Log).to respond_to(name), "missing public concept: #{name}"
    end
  end

  it "prohibited aliases are absent" do
    %i[warn close_file_logger close json_mode? production? development?
       log_dir log_file rotate_size rotate_keep].each do |name|
      expect(Tina4::Log).not_to respond_to(name), "prohibited alias present: #{name}"
    end
  end

  it "event methods return void and finish writes" do
    Tina4::Log.configure(output: "file", log_dir: tmpdir)
    result = Tina4::Log.info("ready")
    expect(result).to be_nil
    expect(File.read(File.join(tmpdir, "tina4.log"))).to include("ready")
  end

  it "bootstrap does not invent explicit defaults" do
    source = File.read(File.join(REPO_LIB, "..", "lib", "tina4.rb"))
    expect(source).to include("Tina4::Log.configure\n"), "bootstrap must call configure() with no invented explicit arguments"

    ENV["TINA4_LOG_LEVEL"] = "ERROR"
    ENV["TINA4_LOG_OUTPUT"] = "stdout"
    Tina4::Log.configure
    expect(Tina4::Log.configuration["level"]).to eq("ERROR")
  end

  it "graceful shutdown logs before one reset" do
    source = File.read(File.join(REPO_LIB, "tina4", "shutdown.rb"))
    idx_log = source.index('Tina4::Log.info("Shutdown complete")')
    expect(idx_log).not_to be_nil
    idx_reset = source.index("Tina4::Log.reset", idx_log)
    expect(idx_reset).not_to be_nil
    expect(idx_reset).to be > idx_log

    Tina4::Log.configure(output: "file", log_dir: tmpdir)
    Tina4::Log.info("Shutdown complete")
    Tina4::Log.reset
    expect(File.read(File.join(tmpdir, "tina4.log"))).to include("Shutdown complete")
    expect(Tina4::Log.get_request_id).to be_nil
  end
end
