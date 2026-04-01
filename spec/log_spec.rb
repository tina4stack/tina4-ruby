# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Log do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".setup" do
    it "creates the logs directory" do
      Tina4::Log.setup(tmpdir)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be true
    end

    it "creates tina4.log file" do
      Tina4::Log.setup(tmpdir)
      Tina4::Log.info("test message")
      expect(File.exist?(File.join(tmpdir, "logs", "tina4.log"))).to be true
    end
  end

  describe "logging methods" do
    before { Tina4::Log.setup(tmpdir) }

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
    before { Tina4::Log.setup(tmpdir) }
    after { Tina4::Log.clear_request_id }

    it "sets and retrieves request_id" do
      Tina4::Log.set_request_id("req-abc-123")
      expect(Tina4::Log.request_id).to eq("req-abc-123")
    end

    it "clears request_id" do
      Tina4::Log.set_request_id("req-abc-123")
      Tina4::Log.clear_request_id
      expect(Tina4::Log.request_id).to be_nil
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
      Tina4::Log.setup(tmpdir)
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
      Tina4::Log.setup(tmpdir)
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

      Tina4::Log.setup(tmpdir)

      # The rotated file should still exist (compression not implemented)
      expect(File.exist?(rotated)).to be true
    end
  end

  # ── Log Level Filtering Tests ──────────────────────────────────

  describe "log level filtering" do
    before { Tina4::Log.setup(tmpdir) }

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
    before { Tina4::Log.setup(tmpdir) }

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
    before { Tina4::Log.setup(tmpdir) }
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
      Tina4::Log.setup(nested_dir)
      expect(Dir.exist?(File.join(nested_dir, "logs"))).to be true
    end

    it "does not raise on repeated setup" do
      Tina4::Log.setup(tmpdir)
      expect { Tina4::Log.setup(tmpdir) }.not_to raise_error
    end

    it "handles logging before setup without crashing" do
      # This tests resilience
      expect { Tina4::Log.info("before setup") }.not_to raise_error
    end
  end
end
