# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Debug do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".setup" do
    it "creates the logs directory" do
      Tina4::Debug.setup(tmpdir)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be true
    end

    it "creates debug.log file" do
      Tina4::Debug.setup(tmpdir)
      Tina4::Debug.info("test message")
      expect(File.exist?(File.join(tmpdir, "logs", "debug.log"))).to be true
    end
  end

  describe "logging methods" do
    before { Tina4::Debug.setup(tmpdir) }

    it "responds to .info" do
      expect(Tina4::Debug).to respond_to(:info)
    end

    it "responds to .debug" do
      expect(Tina4::Debug).to respond_to(:debug)
    end

    it "responds to .warning" do
      expect(Tina4::Debug).to respond_to(:warning)
    end

    it "responds to .error" do
      expect(Tina4::Debug).to respond_to(:error)
    end

    it "does not raise when logging" do
      expect { Tina4::Debug.info("test") }.not_to raise_error
      expect { Tina4::Debug.debug("test") }.not_to raise_error
      expect { Tina4::Debug.warning("test") }.not_to raise_error
      expect { Tina4::Debug.error("test") }.not_to raise_error
    end
  end

  describe "request ID support" do
    before { Tina4::Debug.setup(tmpdir) }
    after { Tina4::Debug.clear_request_id }

    it "sets and retrieves request_id" do
      Tina4::Debug.set_request_id("req-abc-123")
      expect(Tina4::Debug.request_id).to eq("req-abc-123")
    end

    it "clears request_id" do
      Tina4::Debug.set_request_id("req-abc-123")
      Tina4::Debug.clear_request_id
      expect(Tina4::Debug.request_id).to be_nil
    end

    it "includes request_id in log file output" do
      Tina4::Debug.set_request_id("req-xyz")
      Tina4::Debug.info("test with request id")

      log_content = File.read(File.join(tmpdir, "logs", "debug.log"))
      expect(log_content).to include("req-xyz")
    end
  end

  describe "JSON mode" do
    before do
      ENV["TINA4_ENV"] = "production"
      Tina4::Debug.setup(tmpdir)
    end

    after do
      ENV.delete("TINA4_ENV")
    end

    it "activates JSON mode in production" do
      expect(Tina4::Debug.json_mode?).to be true
    end

    it "writes JSON-formatted entries to log file" do
      Tina4::Debug.info("json test message")

      log_content = File.read(File.join(tmpdir, "logs", "debug.log"))
      lines = log_content.strip.split("\n").reject(&:empty?)
      last_line = lines.last

      parsed = JSON.parse(last_line)
      expect(parsed["level"]).to eq("info")
      expect(parsed["message"]).to eq("json test message")
      expect(parsed["framework"]).to eq("tina4-ruby")
      expect(parsed).to have_key("timestamp")
    end
  end

  describe "text mode (development)" do
    before do
      ENV.delete("TINA4_ENV")
      Tina4::Debug.setup(tmpdir)
    end

    it "does not activate JSON mode in development" do
      expect(Tina4::Debug.json_mode?).to be false
    end
  end

  describe "log compression" do
    it "compresses .log.N files to .gz on setup" do
      log_dir = File.join(tmpdir, "logs")
      FileUtils.mkdir_p(log_dir)

      # Create a fake rotated log
      rotated = File.join(log_dir, "debug.log.1")
      File.write(rotated, "old log data\n" * 100)

      Tina4::Debug.setup(tmpdir)

      # The rotated file should be compressed
      expect(File.exist?("#{rotated}.gz")).to be true
      expect(File.exist?(rotated)).to be false
    end
  end
end
