# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tina4::Debug backward compatibility" do
  let(:tmpdir) { Dir.mktmpdir }

  # The default log FILE is dev-gated (v3.13.39): with TINA4_LOG_OUTPUT unset
  # the file is written only when TINA4_DEBUG is truthy. Pin TINA4_DEBUG=true so
  # configure() builds a real file logger and these end-to-end file assertions
  # actually have a file to read — same approach log_spec.rb uses.
  around do |example|
    saved_debug = ENV.key?("TINA4_DEBUG") ? ENV["TINA4_DEBUG"] : :__unset__
    saved_level = ENV.key?("TINA4_LOG_LEVEL") ? ENV["TINA4_LOG_LEVEL"] : :__unset__
    ENV["TINA4_DEBUG"] = "true"
    example.run
  ensure
    saved_debug == :__unset__ ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = saved_debug
    saved_level == :__unset__ ? ENV.delete("TINA4_LOG_LEVEL") : ENV["TINA4_LOG_LEVEL"] = saved_level
    Tina4::Log.reset
    FileUtils.rm_rf(tmpdir)
  end

  it "routes Tina4::Debug.error through Tina4::Log's real file machinery" do
    # Beyond constant identity, exercise the alias end-to-end: a call through
    # Tina4::Debug must actually write through Log's file logger, not merely
    # point at the same object. Configure a real on-disk log and assert the
    # line emitted via the alias lands in it at ERROR level.
    expect(Tina4::Debug).to equal(Tina4::Log) # same object, so a write here = a write there

    Tina4::Log.configure(log_dir: File.join(tmpdir, "logs"))
    Tina4::Debug.error("via-debug-alias")

    log_file = File.join(tmpdir, "logs", "tina4.log")
    expect(File.exist?(log_file)).to be true
    content = File.read(log_file)
    expect(content).to include("via-debug-alias")
    expect(content).to include("ERROR")
  end

  it "forwards each Log level through Debug and does the real logging work" do
    # Replace the respond_to? checks with real calls through the alias. With
    # the console threshold at warning, enabled? must report the real gate, and
    # each forwarded level (warning + error pass, info + debug are below the
    # gate) must record its message in the file the same as a direct Log call.
    ENV["TINA4_LOG_LEVEL"] = "warning"
    Tina4::Log.configure(log_dir: File.join(tmpdir, "logs"))

    # enabled? reflects the real console gate, reached via the alias.
    expect(Tina4::Debug.enabled?("warning")).to be true
    expect(Tina4::Debug.enabled?("error")).to be true
    expect(Tina4::Debug.enabled?("info")).to be false
    expect(Tina4::Debug.enabled?("debug")).to be false

    # The file records EVERY level regardless of the console threshold, so each
    # forwarded method must actually write its line.
    Tina4::Debug.info("info-via-debug")
    Tina4::Debug.debug("debug-via-debug")
    Tina4::Debug.warning("hot")
    Tina4::Debug.error("error-via-debug")

    content = File.read(File.join(tmpdir, "logs", "tina4.log"))
    expect(content).to include("info-via-debug")
    expect(content).to include("debug-via-debug")
    expect(content).to include("error-via-debug")
    # The flagged "hot" line lands at WARNING level via the alias.
    warning_line = content.lines.find { |l| l.include?("hot") }
    expect(warning_line).not_to be_nil
    expect(warning_line).to include("WARNING")

    # configure is reachable through the alias too (it's the same module).
    expect(Tina4::Debug).to respond_to(:configure)
  end
end
