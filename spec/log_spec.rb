# frozen_string_literal: true

require "spec_helper"

# Tests for Tina4::Log (3.14 contract, black-box against the public surface
# only). Rewritten 2026-08-13 alongside the shared logger_contract.json
# conformance runner (spec/logger_fixture_contract_spec.rb): the old version
# reflected private methods (`resolve_level`, `normalize_level`,
# `console_level`, `colorize`, `SEVERITY_MAP`, bracket-string `LEVELS` keys)
# and a positional `configure(dir)` that no longer exist post-contract. Real
# files, real env vars, no doubles.
RSpec.describe Tina4::Log do
  let(:tmpdir) { Dir.mktmpdir }
  let(:log_path) { File.join(tmpdir, "tina4.log") }

  LOG_SPEC_ENV_KEYS = %w[
    TINA4_LOG_LEVEL TINA4_LOG_FILE_LEVEL TINA4_LOG_FORMAT TINA4_LOG_OUTPUT
    TINA4_LOG_DIR TINA4_LOG_FILE TINA4_LOG_ROTATE_SIZE TINA4_LOG_ROTATE_KEEP
    TINA4_LOG_STRICT TINA4_LOG_FUNC TINA4_DEBUG
  ].freeze

  around do |example|
    saved = LOG_SPEC_ENV_KEYS.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
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

  describe "levels" do
    it "logs INFO at info level" do
      Tina4::Log.configure(level: "info", output: "both")
      expect(Tina4::Log.enabled?("info")).to be true
    end

    it "does not log DEBUG at info level (file_level pinned equal)" do
      Tina4::Log.configure(level: "info", file_level: "info", output: "both")
      expect(Tina4::Log.enabled?("debug")).to be false
    end

    it "logs DEBUG when level is debug" do
      Tina4::Log.configure(level: "debug", output: "both")
      %w[debug info warning error].each { |l| expect(Tina4::Log.enabled?(l)).to be true }
    end
  end

  describe ".enabled?" do
    it "matches the threshold at info" do
      Tina4::Log.configure(level: "info", output: "both")
      expect(Tina4::Log.enabled?("debug")).to be false
      expect(Tina4::Log.enabled?("info")).to be true
      expect(Tina4::Log.enabled?("warning")).to be true
      expect(Tina4::Log.enabled?("error")).to be true
    end

    it "matches the threshold at error" do
      Tina4::Log.configure(level: "error", output: "both")
      expect(Tina4::Log.enabled?("info")).to be false
      expect(Tina4::Log.enabled?("warning")).to be false
      expect(Tina4::Log.enabled?("error")).to be true
    end

    it "is case-insensitive" do
      Tina4::Log.configure(level: "info", output: "both")
      expect(Tina4::Log.enabled?("INFO")).to be true
      expect(Tina4::Log.enabled?("Debug")).to be false
    end

    it "accepts symbols too" do
      Tina4::Log.configure(level: "info", output: "both")
      expect(Tina4::Log.enabled?(:info)).to be true
      expect(Tina4::Log.enabled?(:debug)).to be false
    end

    it "treats critical as the top level" do
      Tina4::Log.configure(level: "info", output: "both")
      expect(Tina4::Log.enabled?("critical")).to be true
      Tina4::Log.configure(level: "error", output: "both")
      expect(Tina4::Log.enabled?("critical")).to be true
    end

    it "is sink-aware (console gated by level, file independently by file_level)" do
      Tina4::Log.configure(level: "error", file_level: "debug", output: "both")
      expect(Tina4::Log.enabled?("info")).to be false
      expect(Tina4::Log.enabled?("info", sink: "file")).to be true
    end

    it "raises LogArgumentError for an unknown level" do
      Tina4::Log.configure(output: "both")
      expect { Tina4::Log.enabled?("verbose") }.to raise_error(Tina4::LogArgumentError)
    end
  end

  describe "format" do
    it "writes JSON entries when format: json" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      Tina4::Log.info("test message")
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["level"]).to eq("INFO")
      expect(entry["message"]).to eq("test message")
    end

    it "includes context in JSON entries" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      Tina4::Log.error("fail", { code: 500 })
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["context"]["code"]).to eq(500)
    end

    it "includes the request id when set" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      Tina4::Log.set_request_id("req-123")
      Tina4::Log.info("test")
      Tina4::Log.clear_request_id
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["request_id"]).to eq("req-123")
    end

    it "writes readable text for format: text" do
      Tina4::Log.configure(format: "text", output: "file", log_dir: tmpdir)
      Tina4::Log.info("hello world")
      content = File.read(log_path)
      expect(content).to include("INFO")
      expect(content).to include("hello world")
    end

    it "defaults to json without TINA4_DEBUG" do
      ENV.delete("TINA4_DEBUG")
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("prod line")
      expect { JSON.parse(File.read(log_path).lines.first) }.not_to raise_error
    end

    it "defaults to text with TINA4_DEBUG=true" do
      ENV["TINA4_DEBUG"] = "true"
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("dev line")
      expect { JSON.parse(File.read(log_path).lines.first) }.to raise_error(JSON::ParserError)
    end
  end

  describe "output" do
    it "writes INFO to the main file" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("file write test")
      expect(File.read(log_path)).to include("file write test")
    end

    it "writes ERROR to error.log" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.error("error write test")
      expect(File.read(File.join(tmpdir, "error.log"))).to include("error write test")
    end

    it "writes WARNING to error.log too" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.warning("warn into errors")
      expect(File.read(File.join(tmpdir, "error.log"))).to include("warn into errors")
    end

    it "always emits critical, no opt-in toggle" do
      Tina4::Log.configure(level: "error", output: "file", log_dir: tmpdir)
      Tina4::Log.critical("meltdown")
      content = File.read(log_path)
      expect(content).to include("meltdown")
      expect(content).to include("CRITICAL")
    end

    it "records every level in the file under the default ALL file_level" do
      Tina4::Log.configure(level: "info", output: "file", log_dir: tmpdir)
      Tina4::Log.debug("should still appear in file")
      expect(File.read(log_path)).to include("should still appear in file")
    end

    it "creates nested log directories" do
      nested = File.join(tmpdir, "deep", "nested", "logs")
      Tina4::Log.configure(output: "file", log_dir: nested)
      Tina4::Log.info("probe")
      expect(Dir.exist?(nested)).to be true
    end

    it "does not truncate or duplicate lines across a repeated configure" do
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("before-reconfigure")
      Tina4::Log.configure(output: "file", log_dir: tmpdir)
      Tina4::Log.info("after-reconfigure")
      content = File.read(log_path)
      expect(content).to include("before-reconfigure")
      expect(content.scan(/after-reconfigure/).length).to eq(1)
    end
  end

  describe "request id" do
    it "sets, gets and clears" do
      Tina4::Log.set_request_id("req-abc-123")
      expect(Tina4::Log.get_request_id).to eq("req-abc-123")
      Tina4::Log.clear_request_id
      expect(Tina4::Log.get_request_id).to be_nil
    end

    it "does not leak a cleared id into a later line" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      Tina4::Log.set_request_id("stale-rid")
      Tina4::Log.info("with-ctx-msg")
      Tina4::Log.clear_request_id
      Tina4::Log.info("no-ctx-msg")
      lines = File.read(log_path).lines.map { |l| JSON.parse(l) }
      with_ctx = lines.find { |e| e["message"] == "with-ctx-msg" }
      no_ctx = lines.find { |e| e["message"] == "no-ctx-msg" }
      expect(with_ctx["request_id"]).to eq("stale-rid")
      expect(no_ctx).not_to have_key("request_id")
    end
  end

  describe "TINA4_LOG_FUNC (caller capture, feature #41)" do
    def emit_info_from_named_method
      Tina4::Log.info("function-name probe")
    end

    it "does not inject the function name by default" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      emit_info_from_named_method
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry).not_to have_key("function")
    end

    it "injects the calling method name when enabled" do
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir, caller_capture: true)
      emit_info_from_named_method
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["function"]).to eq("emit_info_from_named_method")
    end

    it "env TINA4_LOG_FUNC=true also enables it" do
      ENV["TINA4_LOG_FUNC"] = "true"
      Tina4::Log.configure(format: "json", output: "file", log_dir: tmpdir)
      emit_info_from_named_method
      entry = JSON.parse(File.read(log_path).lines.first)
      expect(entry["function"]).to eq("emit_info_from_named_method")
    end

    it "rejects a non-boolean token (native booleans, not truth-token parsing)" do
      ENV["TINA4_LOG_FUNC"] = "1"
      expect { Tina4::Log.configure(output: "stdout") }.to raise_error(Tina4::LogConfigurationError)
    end
  end

  describe "stdout unbuffering (v3.13.14)" do
    it "sets $stdout.sync so docker logs sees output immediately" do
      original = $stdout.sync
      begin
        $stdout.sync = false
        Tina4::Log.configure(output: "stdout")
        Tina4::Log.info("probe")
        expect($stdout.sync).to be(true)
      ensure
        $stdout.sync = original
      end
    end
  end
end
