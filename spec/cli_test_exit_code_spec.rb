# frozen_string_literal: true
#
# Lock-in spec for python#96 parity: `tina4ruby test` MUST exit non-zero when a
# discovered test fails, and exit zero when every discovered test passes.
#
# No mocks, no doubles, no stubs. This spawns the REAL exe/tina4ruby entrypoint
# as a child process in a real temp project dir whose tests/ folder holds one
# real Tina4::Testing test. The child runs the REAL Tina4::Testing.run_all
# through the REAL cmd_test dispatch, and we assert on the child process's REAL
# exit status.
#
#   * a FAILING discovered test -> child exit status is NON-ZERO
#   * a PASSING discovered test -> child exit status is ZERO
#
# This pins cmd_test's
#   exit(1) if results[:failed] > 0 || results[:errors] > 0
# (lib/tina4/cli.rb) so a future refactor cannot silently swallow a test failure
# and leave CI reporting green on a red suite.

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "tina4ruby test exit code" do
  REPO_ROOT = File.expand_path("..", __dir__)
  EXE = File.join(REPO_ROOT, "exe", "tina4ruby")

  # A single real Tina4::Testing test whose assertion FAILS.
  FAILING_TEST = <<~RUBY
    Tina4::Testing.describe "exit-code lock-in (failing)" do
      it "fails on purpose" do
        assert_equal(1, 2, "intentional failure to force a non-zero exit")
      end
    end
  RUBY

  # A single real Tina4::Testing test whose assertion PASSES.
  PASSING_TEST = <<~RUBY
    Tina4::Testing.describe "exit-code lock-in (passing)" do
      it "passes" do
        assert_equal(2, 1 + 1)
      end
    end
  RUBY

  # Build a minimal real project dir with tests/<name>_test.rb, spawn the REAL
  # `exe/tina4ruby test` with Dir.pwd set to it, and return [output, exitstatus].
  #
  # The child inherits the current Bundler env on purpose: `tina4ruby test`
  # requires the full framework (jwt/bcrypt), exactly as a developer running it
  # inside their bundled project would. Only a few TINA4_* vars are overridden to
  # keep the temp project database-free and non-writing (a nil value UNSETS the
  # key for the child; the other keys merge onto the inherited parent env).
  def run_tina4_test(test_source)
    Dir.mktmpdir("tina4_test_exit_code") do |dir|
      tests_dir = File.join(dir, "tests")
      FileUtils.mkdir_p(tests_dir)
      File.write(File.join(tests_dir, "exit_code_test.rb"), test_source)

      env = {
        "TINA4_DATABASE_URL" => nil,
        "TINA4_DATABASE_USERNAME" => nil,
        "TINA4_DATABASE_PASSWORD" => nil,
        "TINA4_AUTO_MIGRATE" => "false",
        "TINA4_DEBUG" => nil,
        # A non-blank secret so the fail-safe dev-secret bootstrap never warns
        # about (or writes) a generated secret into the temp project.
        "TINA4_SECRET" => "exit-code-spec-secret"
      }
      output, status = Open3.capture2e(env, RbConfig.ruby, EXE, "test", chdir: dir)
      [output, status.exitstatus]
    end
  end

  it "exits NON-ZERO when a discovered test fails" do
    output, exitstatus = run_tina4_test(FAILING_TEST)
    # Sanity: the test actually ran (boot did not crash before run_all), so the
    # non-zero exit is genuinely the failed-test path, not a boot error.
    expect(output).to include("exit-code lock-in (failing)"),
                      "the failing test never ran; output:\n#{output}"
    expect(exitstatus).not_to eq(0),
                      "tina4ruby test swallowed a failing test (exited 0); output:\n#{output}"
  end

  it "exits ZERO when every discovered test passes" do
    output, exitstatus = run_tina4_test(PASSING_TEST)
    expect(output).to include("exit-code lock-in (passing)"),
                      "the passing test never ran; output:\n#{output}"
    expect(exitstatus).to eq(0),
                      "tina4ruby test exited non-zero on an all-passing suite; output:\n#{output}"
  end
end
