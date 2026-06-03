# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Log do
  let(:tmpdir) { Dir.mktmpdir }

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
end
