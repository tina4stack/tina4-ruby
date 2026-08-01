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
# real pipeline, closes the real logger and hands back the real bytes an
# operator would grep. That also keeps the console quiet, which is the only
# legitimate reason the `allow(...)` stubs existed.
#
# The pattern is already proven in this repo by env_vars_spec.rb:141-216,
# debug_spec.rb:31 and mqtt_auth_tls_spec.rb:256-277; this is those three
# hand-rolled bodies factored into one helper with correct state restoration.
module RealLogCapture
  # Environment variables that steer the logger. Every one is set for REAL and
  # restored for real — no `allow(ENV).to receive(:[])`, which only intercepts
  # ENV#[] and lets ENV.fetch / ENV.key? through to the unstubbed value.
  LOG_ENV_KEYS = %w[
    TINA4_LOG_OUTPUT TINA4_LOG_LEVEL TINA4_DEBUG_LEVEL TINA4_LOG_FORMAT
    TINA4_LOG_STRICT TINA4_LOG_DIR TINA4_LOG_FILE TINA4_LOG_APPEND
    TINA4_DEBUG TINA4_LOG_ROTATE_SIZE TINA4_LOG_ROTATE_KEEP
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
      Tina4::Log.close_file_logger
      read_real_log(dir, error_log: error_log)
    end
  end

  # Lower-level form: gives the block the real log DIRECTORY so it can assert on
  # several real files, or read mid-run. The logger is real and configured; the
  # caller closes it (or calls read_real_log, which does).
  def with_real_log_dir(level: "DEBUG", strict: nil, format: nil)
    dir = Dir.mktmpdir("tina4-real-log-")
    saved_env = LOG_ENV_KEYS.to_h { |k| [k, ENV.key?(k) ? ENV[k] : :__unset__] }
    saved_state = Tina4::Log.instance_variables.to_h do |iv|
      [iv, Tina4::Log.instance_variable_get(iv)]
    end

    # Real environment, not a stubbed ENV#[].
    ENV["TINA4_LOG_OUTPUT"] = "file"     # file only — keeps the console quiet for real
    ENV["TINA4_LOG_LEVEL"] = level
    ENV["TINA4_DEBUG_LEVEL"] = level     # spec_helper pins this to [TINA4_LOG_NONE]
    ENV["TINA4_LOG_APPEND"] = "true"
    ENV.delete("TINA4_LOG_FILE")         # let configure() name tina4.log + error.log
    ENV.delete("TINA4_LOG_DIR")
    ENV["TINA4_LOG_FORMAT"] = format if format
    ENV["TINA4_LOG_STRICT"] = strict.to_s unless strict.nil?

    Tina4::Log.configure(dir)            # the REAL configure, real mkdir, real Logger
    yield dir
  ensure
    Tina4::Log.close_file_logger
    saved_env.each do |k, v|
      v == :__unset__ ? ENV.delete(k) : ENV[k] = v
    end
    # Restore the logger's real state so a randomly-ordered later spec is not
    # left writing into a deleted temp dir. Save/restore of the real object's
    # own state is not a double: no collaborator is substituted.
    #
    # EXCEPT the two ::Logger objects. Tina4::Log.configure calls
    # close_file_logger, so entering this helper CLOSES whatever @file_logger /
    # @error_logger the previous spec had open. Restoring those closed objects
    # hands the next spec a dead stream, and stdlib ::Logger swallows the
    # failure with a bare "log writing failed. closed stream" on stderr — the
    # suite stays green while every later log line is silently dropped.
    # (Observed for real in a full-suite run while building this helper.)
    #
    # Instead: drop them and clear @initialized, so the very next Tina4::Log
    # call runs the REAL configure() again against the now-restored real
    # environment. No stale handle, no substitution.
    logger_ivars = %i[@file_logger @error_logger]
    (Tina4::Log.instance_variables - saved_state.keys).each do |iv|
      Tina4::Log.send(:remove_instance_variable, iv)
    end
    saved_state.each do |iv, v|
      next if logger_ivars.include?(iv)

      Tina4::Log.instance_variable_set(iv, v)
    end
    logger_ivars.each { |iv| Tina4::Log.instance_variable_set(iv, nil) }
    Tina4::Log.instance_variable_set(:@initialized, false)
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # Read the real bytes off disk. Closes the real logger first so nothing is
  # sitting in a buffer.
  def read_real_log(dir, error_log: false)
    Tina4::Log.close_file_logger
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
