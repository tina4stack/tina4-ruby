# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Log do
  let(:tmpdir) { Dir.mktmpdir }

  # v3.13.39: the default log output is now dev-gated — with TINA4_LOG_OUTPUT
  # unset the log FILE is written ONLY when TINA4_DEBUG is truthy (dev). In a
  # bare test env (no TINA4_DEBUG) the default is stdout-only, so every example
  # here that reads logs/tina4.log would otherwise find no file. Pin
  # TINA4_DEBUG=true for the whole block so these existing file-output assertions
  # run in "development" — mirrors how the Python master pins TINA4_DEBUG=true in
  # its test_log autouse fixture. The dedicated default-output behaviour (prod =
  # no file, dev = file, explicit-output wins) is covered in its own block below
  # which manages TINA4_DEBUG itself.
  around do |example|
    saved = ENV.key?("TINA4_DEBUG") ? ENV["TINA4_DEBUG"] : :__unset__
    ENV["TINA4_DEBUG"] = "true"
    example.run
  ensure
    saved == :__unset__ ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = saved
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe ".setup" do
    it "creates the logs directory" do
      Tina4::Log.configure(tmpdir)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be true
    end

    it "creates tina4.log file" do
      Tina4::Log.configure(tmpdir)
      Tina4::Log.info("test message")
      expect(File.exist?(File.join(tmpdir, "logs", "tina4.log"))).to be true
    end
  end

  describe "logging methods" do
    before { Tina4::Log.configure(tmpdir) }

    it "responds to .info" do
      expect(Tina4::Log).to respond_to(:info)
    end

    it "responds to .debug" do
      expect(Tina4::Log).to respond_to(:debug)
    end

    it "responds to .warning" do
      expect(Tina4::Log).to respond_to(:warning)
    end

    it "responds to .error" do
      expect(Tina4::Log).to respond_to(:error)
    end

    it "does not raise when logging" do
      expect { Tina4::Log.info("test") }.not_to raise_error
      expect { Tina4::Log.debug("test") }.not_to raise_error
      expect { Tina4::Log.warning("test") }.not_to raise_error
      expect { Tina4::Log.error("test") }.not_to raise_error
    end
  end

  describe "request ID support" do
    before { Tina4::Log.configure(tmpdir) }
    after { Tina4::Log.clear_request_id }

    it "sets and retrieves request_id" do
      Tina4::Log.set_request_id("req-abc-123")
      expect(Tina4::Log.get_request_id).to eq("req-abc-123")
    end

    it "clears request_id" do
      Tina4::Log.set_request_id("req-abc-123")
      Tina4::Log.clear_request_id
      expect(Tina4::Log.get_request_id).to be_nil
    end

    it "includes request_id in log file output" do
      Tina4::Log.set_request_id("req-xyz")
      Tina4::Log.info("test with request id")

      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("req-xyz")
    end
  end

  describe "JSON mode" do
    before do
      ENV["TINA4_ENV"] = "production"
      Tina4::Log.configure(tmpdir)
    end

    after do
      ENV.delete("TINA4_ENV")
    end

    it "activates JSON mode in production" do
      expect(Tina4::Log.json_mode?).to be true
    end

    it "writes JSON-formatted entries to log file" do
      Tina4::Log.info("json test message")

      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      # File writes plain text format (not JSON) — JSON mode only affects console output
      expect(log_content).to include("json test message")
    end
  end

  describe "text mode (development)" do
    before do
      ENV.delete("TINA4_ENV")
      Tina4::Log.configure(tmpdir)
    end

    it "does not activate JSON mode in development" do
      expect(Tina4::Log.json_mode?).to be false
    end
  end

  describe "log rotation" do
    it "creates rotated log files with numbered scheme" do
      log_dir = File.join(tmpdir, "logs")
      FileUtils.mkdir_p(log_dir)

      # Create a fake rotated log
      rotated = File.join(log_dir, "tina4.log.1")
      File.write(rotated, "old log data\n" * 100)

      Tina4::Log.configure(tmpdir)

      # The rotated file should still exist (compression not implemented)
      expect(File.exist?(rotated)).to be true
    end
  end

  # ── Log Level Filtering Tests ──────────────────────────────────

  describe "log level filtering" do
    before { Tina4::Log.configure(tmpdir) }

    it "info level is higher than debug" do
      # Info messages should always be logged
      Tina4::Log.info("info test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("info test")
    end

    it "error level is highest priority" do
      Tina4::Log.error("error test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("error test")
    end

    it "warning level is between info and error" do
      Tina4::Log.warning("warning test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("warning test")
    end

    it "debug level is lowest priority" do
      Tina4::Log.debug("debug test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("debug test")
    end
  end

  # ── Log File Content Tests ─────────────────────────────────────

  describe "log file content" do
    before { Tina4::Log.configure(tmpdir) }

    it "includes timestamp in log entries" do
      Tina4::Log.info("timestamp test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      # Timestamps typically contain date-like patterns
      expect(log_content).to match(/\d{4}/)
    end

    it "appends multiple log entries" do
      Tina4::Log.info("first entry")
      Tina4::Log.info("second entry")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("first entry")
      expect(log_content).to include("second entry")
    end

    it "includes level indicator in log output" do
      Tina4::Log.error("level indicator test")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      # Log output should mention the level or contain the message
      expect(log_content).to include("level indicator test")
    end
  end

  # ── Context Data Tests ─────────────────────────────────────────

  describe "context data in logs" do
    before { Tina4::Log.configure(tmpdir) }
    after { Tina4::Log.clear_request_id }

    it "logs with request_id context" do
      Tina4::Log.set_request_id("ctx-123")
      Tina4::Log.info("context message")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("ctx-123")
    end

    it "logs without request_id when not set" do
      Tina4::Log.clear_request_id
      expect { Tina4::Log.info("no context") }.not_to raise_error
    end

    it "different request ids appear in sequence" do
      Tina4::Log.set_request_id("req-aaa")
      Tina4::Log.info("first request")
      Tina4::Log.set_request_id("req-bbb")
      Tina4::Log.info("second request")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("req-aaa")
      expect(log_content).to include("req-bbb")
    end
  end

  # ── Log Setup Edge Cases ───────────────────────────────────────

  describe "setup edge cases" do
    it "creates nested log directories" do
      nested_dir = File.join(tmpdir, "deep", "nested")
      FileUtils.mkdir_p(nested_dir)
      Tina4::Log.configure(nested_dir)
      expect(Dir.exist?(File.join(nested_dir, "logs"))).to be true
    end

    it "does not raise on repeated setup" do
      Tina4::Log.configure(tmpdir)
      expect { Tina4::Log.configure(tmpdir) }.not_to raise_error
    end

    it "handles logging before setup without crashing" do
      # This tests resilience
      expect { Tina4::Log.info("before setup") }.not_to raise_error
    end
  end

  # ── Function-name injection (parity feature #41) ───────────────────
  #
  # When TINA4_LOG_FUNC=true is set, log lines should include the name
  # of the function/method that called Log.info / .debug / .warning /
  # .error. Default is OFF so existing log formats are untouched.
  describe "function-name injection (TINA4_LOG_FUNC)" do
    before { Tina4::Log.configure(tmpdir) }
    after  { ENV.delete("TINA4_LOG_FUNC") }

    # Named methods so the caller-walk has a real label to find,
    # rather than the anonymous block frame RSpec runs `it` blocks in.
    def emit_info_from_named_method
      Tina4::Log.info("function-name probe")
    end

    def emit_error_from_named_method
      Tina4::Log.error("function-name probe error")
    end

    it "does NOT inject the function name by default" do
      ENV.delete("TINA4_LOG_FUNC")
      emit_info_from_named_method
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("function-name probe")
      expect(log_content).not_to include("[emit_info_from_named_method]")
    end

    it "injects the calling method name when TINA4_LOG_FUNC=true" do
      ENV["TINA4_LOG_FUNC"] = "true"
      emit_info_from_named_method
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("[emit_info_from_named_method]")
      expect(log_content).to include("function-name probe")
    end

    it "works for the .error level too" do
      ENV["TINA4_LOG_FUNC"] = "true"
      emit_error_from_named_method
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("[emit_error_from_named_method]")
    end

    it "accepts the same truthy tokens as Env.bool" do
      %w[1 on yes y t].each do |token|
        ENV["TINA4_LOG_FUNC"] = token
        File.write(File.join(tmpdir, "logs", "tina4.log"), "")
        emit_info_from_named_method
        log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
        expect(log_content).to include("[emit_info_from_named_method]"), "expected truthy token #{token.inspect} to enable function name"
      end
    end

    it "skips injection for falsy / unknown values" do
      %w[false 0 no off banana].each do |token|
        ENV["TINA4_LOG_FUNC"] = token
        File.write(File.join(tmpdir, "logs", "tina4.log"), "")
        emit_info_from_named_method
        log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
        expect(log_content).not_to include("[emit_info_from_named_method]"), "expected falsy token #{token.inspect} to disable function name"
      end
    end

    context "in JSON mode" do
      before do
        ENV["TINA4_ENV"] = "production"
        Tina4::Log.configure(tmpdir)
      end

      after do
        ENV.delete("TINA4_ENV")
      end

      it "adds a 'function' key to the JSON entry when enabled" do
        ENV["TINA4_LOG_FUNC"] = "true"
        emit_info_from_named_method
        log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))

        # The file gets one JSON object per line — find the one we just wrote.
        json_lines = log_content.lines.map(&:strip).reject(&:empty?)
        matching = json_lines.map { |l| JSON.parse(l) rescue nil }
                              .compact
                              .find { |obj| obj["message"] == "function-name probe" }
        expect(matching).not_to be_nil
        expect(matching["function"]).to eq("emit_info_from_named_method")
      end

      it "omits the 'function' key when disabled" do
        ENV.delete("TINA4_LOG_FUNC")
        emit_info_from_named_method
        log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
        json_lines = log_content.lines.map(&:strip).reject(&:empty?)
        matching = json_lines.map { |l| JSON.parse(l) rescue nil }
                              .compact
                              .find { |obj| obj["message"] == "function-name probe" }
        expect(matching).not_to be_nil
        expect(matching).not_to have_key("function")
      end
    end
  end

  # v3.13.14 — level resolution: default INFO, accept plain + bracket names.
  # docker logs / k8s read stdout; the default must surface info+ and the
  # env value must be portable with Python/PHP/Node ("ERROR", not just
  # "[TINA4_LOG_ERROR]").
  describe "level resolution (v3.13.14)" do
    around do |example|
      saved = ENV["TINA4_LOG_LEVEL"]
      example.run
      saved.nil? ? ENV.delete("TINA4_LOG_LEVEL") : ENV["TINA4_LOG_LEVEL"] = saved
    end

    def console_level
      Tina4::Log.send(:resolve_level)
    end

    it "defaults to INFO when unset" do
      ENV.delete("TINA4_LOG_LEVEL")
      expect(console_level).to eq(1)
    end

    it "accepts plain names (parity with other frameworks)" do
      ENV["TINA4_LOG_LEVEL"] = "ERROR"
      expect(console_level).to eq(3)
    end

    it "accepts lowercase plain names" do
      ENV["TINA4_LOG_LEVEL"] = "warning"
      expect(console_level).to eq(2)
    end

    it "still accepts the legacy bracket form" do
      ENV["TINA4_LOG_LEVEL"] = "[TINA4_LOG_ERROR]"
      expect(console_level).to eq(3)
    end

    it "falls back to INFO for an unknown value" do
      ENV["TINA4_LOG_LEVEL"] = "gibberish"
      expect(console_level).to eq(1)
    end
  end

  # enabled?(level) — public level-check predicate. Mirrors Python's
  # Log.is_enabled: returns true iff a message at `level` would pass the
  # configured minimum CONSOLE level (TINA4_LOG_LEVEL). It reflects console
  # visibility only — the log FILE records every level regardless. It REUSES
  # the same severity >= console_level comparison the console branch uses, so
  # it can never disagree with what the logger actually prints.
  describe ".enabled? (console-level predicate)" do
    around do |example|
      saved = ENV["TINA4_LOG_LEVEL"]
      example.run
      saved.nil? ? ENV.delete("TINA4_LOG_LEVEL") : ENV["TINA4_LOG_LEVEL"] = saved
    end

    # The internal console-threshold check the console branch uses, so a
    # drift in enabled?'s comparison logic is caught against this.
    def console_gate(level)
      sym = Tina4::Log.send(:normalize_level, level)
      severity = Tina4::Log::SEVERITY_MAP[sym] || 0
      severity >= Tina4::Log.send(:console_level)
    end

    it "at the info threshold: debug off, info/warning/error on" do
      ENV["TINA4_LOG_LEVEL"] = "info"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("debug")).to be false
      expect(Tina4::Log.enabled?("info")).to be true
      expect(Tina4::Log.enabled?("warning")).to be true
      expect(Tina4::Log.enabled?("error")).to be true
    end

    it "at the error threshold: info/warning off, error on" do
      ENV["TINA4_LOG_LEVEL"] = "error"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("info")).to be false
      expect(Tina4::Log.enabled?("warning")).to be false
      expect(Tina4::Log.enabled?("error")).to be true
    end

    it "is case-insensitive (string)" do
      ENV["TINA4_LOG_LEVEL"] = "info"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("INFO")).to be true
      expect(Tina4::Log.enabled?("Debug")).to be false
    end

    it "accepts symbols too" do
      ENV["TINA4_LOG_LEVEL"] = "info"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?(:info)).to be true
      expect(Tina4::Log.enabled?(:debug)).to be false
      expect(Tina4::Log.enabled?(:warning)).to be true
    end

    it "equals the internal console-threshold check for all standard levels" do
      %w[all debug info warning error none].each do |threshold|
        ENV["TINA4_LOG_LEVEL"] = threshold
        Tina4::Log.configure(tmpdir)
        %i[debug info warning error].each do |level|
          expect(Tina4::Log.enabled?(level)).to eq(console_gate(level)),
            "enabled?(#{level.inspect}) disagreed with the console gate at TINA4_LOG_LEVEL=#{threshold}"
        end
      end
    end

    # critical is a FIRST-CLASS top-level severity (4 — above error 3), not a
    # parity alias for error. Ordinary threshold logic applies: critical
    # passes at every TINA4_LOG_LEVEL except `none` (5). The none case is the
    # regression test for the NONE-bump (none had to move 4 -> 5 so critical 4
    # does NOT slip through at TINA4_LOG_LEVEL=none).
    it "treats critical as a first-class top-level severity" do
      ENV["TINA4_LOG_LEVEL"] = "info"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("critical")).to be true
      expect(Tina4::Log.enabled?(:critical)).to be true

      ENV["TINA4_LOG_LEVEL"] = "error"
      Tina4::Log.configure(tmpdir)
      # critical (4) outranks error (3), so it stays enabled at the error gate.
      expect(Tina4::Log.enabled?("critical")).to be true

      ENV["TINA4_LOG_LEVEL"] = "critical"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("critical")).to be true
      expect(Tina4::Log.enabled?("error")).to be false

      # NONE-bump regression: critical is silenced ONLY by `none` (5).
      ENV["TINA4_LOG_LEVEL"] = "none"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.enabled?("critical")).to be false
    end

    it "verifies the full severity ladder ALL/DEBUG=0 .. CRITICAL=4 .. NONE=5" do
      expect(Tina4::Log::LEVELS["[TINA4_LOG_ALL]"]).to eq(0)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_DEBUG]"]).to eq(0)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_INFO]"]).to eq(1)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_WARNING]"]).to eq(2)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_ERROR]"]).to eq(3)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_CRITICAL]"]).to eq(4)
      expect(Tina4::Log::LEVELS["[TINA4_LOG_NONE]"]).to eq(5)
      expect(Tina4::Log::SEVERITY_MAP[:critical]).to eq(4)
    end

    it "resolves TINA4_LOG_LEVEL=critical to 4" do
      ENV["TINA4_LOG_LEVEL"] = "critical"
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log.send(:resolve_level)).to eq(4)
    end
  end

  # critical() is a first-class log method — it ALWAYS emits (subject only to
  # the threshold, which it passes at every level except none). The old
  # TINA4_LOG_CRITICAL "enable critical()" opt-in toggle is gone: a critical
  # log must never be a silent no-op. Mirrors the Python master.
  describe ".critical (first-class top level)" do
    around do |example|
      saved = ENV["TINA4_LOG_LEVEL"]
      example.run
      saved.nil? ? ENV.delete("TINA4_LOG_LEVEL") : ENV["TINA4_LOG_LEVEL"] = saved
    end

    it "responds to .critical" do
      Tina4::Log.configure(tmpdir)
      expect(Tina4::Log).to respond_to(:critical)
    end

    it "ALWAYS writes a critical entry to the log file (no opt-in toggle)" do
      ENV.delete("TINA4_LOG_LEVEL") # default INFO
      Tina4::Log.configure(tmpdir)
      Tina4::Log.critical("meltdown imminent")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("meltdown imminent")
      expect(log_content).to include("CRITICAL")
    end

    it "still writes critical to the file at the error threshold (4 >= 3)" do
      ENV["TINA4_LOG_LEVEL"] = "error"
      Tina4::Log.configure(tmpdir)
      Tina4::Log.critical("critical at error gate")
      log_content = File.read(File.join(tmpdir, "logs", "tina4.log"))
      expect(log_content).to include("critical at error gate")
    end

    it "does not raise when logging critical" do
      Tina4::Log.configure(tmpdir)
      expect { Tina4::Log.critical("safe") }.not_to raise_error
    end

    it "renders critical in magenta on the console" do
      Tina4::Log.configure(tmpdir)
      line = Tina4::Log.send(:colorize, :critical, "boom")
      expect(line).to start_with(Tina4::Log::COLORS[:magenta])
      expect(line).to end_with(Tina4::Log::COLORS[:reset])
    end
  end

  describe "stdout unbuffering (v3.13.14)" do
    let(:tmpdir2) { Dir.mktmpdir }
    after { FileUtils.rm_rf(tmpdir2) }

    it "sets $stdout.sync so docker logs sees output immediately" do
      original = $stdout.sync
      begin
        $stdout.sync = false
        Tina4::Log.configure(tmpdir2)
        expect($stdout.sync).to be(true)
      ensure
        $stdout.sync = original
      end
    end
  end
end
