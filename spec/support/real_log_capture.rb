# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# ── Real log capture — the no-mock replacement for logger message expectations ─
#
# `expect(Tina4::Log).to receive(:error)` REPLACES Tina4::Log.error for the
# duration of the example, so the real coercion, formatting, level filtering,
# stdout branch and file write never run. A regression that drops the message
# before it reaches any sink passes such a test. `allow(Tina4::Log).to
# receive(:error)` (used for "keep it quiet") is the same substitution with the
# assertion removed.
#
# This helper substitutes NOTHING. It points the REAL logger at a REAL file in a
# real temp dir via the REAL Tina4::Log.configure, runs the scenario through the
# real pipeline, resets the real logger and hands back the real bytes an
# operator would grep.
#
# Rewritten 2026-08-13 alongside the shared logger_contract.json conformance
# pass: Log's internal state shrank to two ivars (@snapshot, @pid), configure()
# is keyword-args only, and close_file_logger is gone (reset() is the one
# lifecycle method now) -- this helper's PUBLIC interface (capture_real_log /
# with_real_log_dir / read_real_log) is unchanged so its six existing callers
# need no changes.
module RealLogCapture
  # Environment variables that steer the logger. Every one is set for REAL and
  # restored for real — no `allow(ENV).to receive(:[])`.
  LOG_ENV_KEYS = %w[
    TINA4_LOG_OUTPUT TINA4_LOG_LEVEL TINA4_LOG_FILE_LEVEL TINA4_LOG_FORMAT
    TINA4_LOG_STRICT TINA4_LOG_DIR TINA4_LOG_FILE
    TINA4_DEBUG TINA4_LOG_ROTATE_SIZE TINA4_LOG_ROTATE_KEEP TINA4_LOG_FUNC
  ].freeze

  # Run `block` with the real Tina4::Log writing to a real file, then yield the
  # real contents of that file back to the caller.
  #
  #   text = capture_real_log { Tina4::Events.emit("evt") }
  #   expect(text).to include("kaboom")
  #
  # Returns the full text of the real tina4.log. `error_log:` true returns the
  # real error.log sibling instead (warning and above only).
  #
  # @param level [String] real TINA4_LOG_LEVEL for the run (default DEBUG so
  #   nothing is filtered out before it reaches the file).
  # @param strict [Boolean, nil] real TINA4_LOG_STRICT.
  # @param format [String, nil] real TINA4_LOG_FORMAT ("text" or "json").
  # @param error_log [Boolean] read error.log instead of tina4.log.
  def capture_real_log(level: "DEBUG", strict: nil, format: nil, error_log: false)
    with_real_log_dir(level: level, strict: strict, format: format) do |dir|
      yield if block_given?
      Tina4::Log.reset
      read_real_log(dir, error_log: error_log)
    end
  end

  # Lower-level form: gives the block the real log DIRECTORY so it can assert on
  # several real files, or read mid-run. The logger is real and configured; the
  # caller closes it (or calls read_real_log, which does).
  def with_real_log_dir(level: "DEBUG", strict: nil, format: nil)
    dir = Dir.mktmpdir("tina4-real-log-")
    saved_env = LOG_ENV_KEYS.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    saved_pwd = Dir.pwd

    # Real environment, not a stubbed ENV#[].
    ENV["TINA4_LOG_OUTPUT"] = "file" # file only — keeps the console quiet for real
    ENV["TINA4_LOG_LEVEL"] = level
    ENV["TINA4_LOG_FILE_LEVEL"] = "ALL"
    ENV.delete("TINA4_LOG_FILE") # let configure() name tina4.log + error.log
    ENV.delete("TINA4_LOG_DIR")
    ENV["TINA4_LOG_FORMAT"] = format if format
    ENV["TINA4_LOG_STRICT"] = strict.to_s unless strict.nil?

    Dir.chdir(dir) # `log_dir:` resolves relative to the project root (cwd)
    Tina4::Log.reset
    Tina4::Log.configure(log_dir: dir) # the REAL configure, real mkdir, real sinks
    yield dir
  ensure
    Tina4::Log.reset
    Dir.chdir(saved_pwd)
    saved_env.each do |k, v|
      v == :__unset__ ? ENV.delete(k) : ENV[k] = v
    end
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # Read the real bytes off disk. Resets the real logger first so nothing is
  # sitting in a buffer.
  def read_real_log(dir, error_log: false)
    Tina4::Log.reset
    path = File.join(dir, error_log ? "error.log" : "tina4.log")
    return "" unless File.exist?(path)

    # Read the REAL bytes and force UTF-8. Ruby's default external encoding here
    # is US-ASCII, so a plain File.read raises "invalid byte sequence in
    # US-ASCII" the moment a real log line carries a non-ASCII byte (a driver
    # error message, a smart quote, any UTF-8 payload). Reading binary and
    # scrubbing keeps the assertion about the log CONTENT, not the locale.
    File.binread(path).force_encoding(Encoding::UTF_8).scrub("?")
  end
end

RSpec.configure do |config|
  config.include RealLogCapture
end
