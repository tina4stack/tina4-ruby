# frozen_string_literal: true
#
# Feature 132 — inline testing conformance (INLINE-DEC-01 / INLINE-DEC-02).
#
# Shared contract: tina4-documentation/plan/v3/fixtures/inlinetesting_contract.json.
#
# No mocks, no doubles. Each case builds a real temp project, SPAWNS the real
# exe/tina4ruby entrypoint as a child process (chdir = the project) through the
# real cmd_test dispatch, and asserts the child's REAL exit status and the REAL
# filesystem side effects.
#
# Invariants proven here:
#   A inline-cli-real-exit-code            — the CLI runs a decorated inline test and
#                                            exits 0 on pass / non-zero on fail.
#   B inline-discovery-no-arbitrary-code   — discovery loads only the test/route dirs, so a
#                                            plain src file's side effect never runs.
#   C inline-assert-surfaces-do-not-collide — the module descriptor surface exposes expect_*
#                                            and NOT the colliding assert_equal (which is the
#                                            xUnit TestContext#assert_equal instead).

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "inline testing contract (132)" do
  PASSING_INLINE = <<~RUBY
    Tina4::Testing.tests(
      Tina4::Testing.expect_equal([5, 3], 8),
      Tina4::Testing.expect_equal([0, 0], 0),
      name: "add"
    ) { |a, b| a + b }
  RUBY

  FAILING_INLINE = <<~RUBY
    Tina4::Testing.tests(
      Tina4::Testing.expect_equal([5, 3], 999),
      name: "add"
    ) { |a, b| a + b }
  RUBY

  # A plain src file (NOT a route/orm/test file) with an observable side effect on
  # load. cmd_test loads only the test/route/orm dirs, so this must never run.
  SIDE_EFFECT = <<~RUBY
    File.write(File.join(__dir__, "..", "side_effect_ran.txt"), "ran")
  RUBY

  # Build a real project, spawn `exe/tina4ruby test` in it, return [output, exit, dir_kept?].
  # The block receives the project dir so a test can inspect it before it is removed.
  def run_inline_project(inline_source, side_effect: false)
    Dir.mktmpdir("tina4_inline_contract") do |dir|
      tests_dir = File.join(dir, "tests")
      FileUtils.mkdir_p(tests_dir)
      File.write(File.join(tests_dir, "inline_test.rb"), inline_source)

      if side_effect
        FileUtils.mkdir_p(File.join(dir, "src"))
        File.write(File.join(dir, "src", "side_effect.rb"), SIDE_EFFECT)
      end

      env = {
        "TINA4_DATABASE_URL" => nil,
        "TINA4_DATABASE_USERNAME" => nil,
        "TINA4_DATABASE_PASSWORD" => nil,
        "TINA4_AUTO_MIGRATE" => "false",
        "TINA4_DEBUG" => nil,
        "TINA4_SECRET" => "inline-contract-secret"
      }
      output, status = Open3.capture2e(env, RbConfig.ruby, EXE, "test", chdir: dir)
      yield(dir, output, status.exitstatus) if block_given?
      [output, status.exitstatus]
    end
  end

  # case: tina4 test exits zero when the inline test passes
  it "tina4 test exits zero when the inline test passes" do
    output, exit_status = run_inline_project(PASSING_INLINE)
    expect(output).to include("add"), "the inline test never ran; output:\n#{output}"
    expect(exit_status).to eq(0),
      "tina4ruby test must exit 0 on a passing inline test; output:\n#{output}"
  end

  # case: tina4 test exits non zero when the inline test fails
  it "tina4 test exits non zero when the inline test fails" do
    output, exit_status = run_inline_project(FAILING_INLINE)
    expect(exit_status).not_to eq(0),
      "tina4ruby test must exit non-zero on a failing inline test; output:\n#{output}"
  end

  # case: inline discovery does not run a non test file side effect
  it "inline discovery does not run a non test file side effect" do
    run_inline_project(PASSING_INLINE, side_effect: true) do |dir, output, exit_status|
      expect(exit_status).to eq(0), "passing project should exit 0; output:\n#{output}"
      expect(File.exist?(File.join(dir, "side_effect_ran.txt"))).to be(false),
        "a plain src file was loaded during discovery — discovery must not run arbitrary src code"
    end
  end

  # case: the descriptor expect builders and xunit assert are distinct
  it "the descriptor expect builders and xunit assert are distinct" do
    # The descriptor surface builds a spec; it does not assert.
    spec = Tina4::Testing.expect_equal([1], 1)
    expect(spec).to be_a(Hash)
    expect(spec[:type]).to eq(:equal)

    # The module descriptor surface exposes expect_* and NOT the colliding
    # assert_equal (that name now belongs only to the immediate xUnit TestContext).
    expect(Tina4::Testing.respond_to?(:expect_equal)).to be(true)
    expect(Tina4::Testing.respond_to?(:assert_equal)).to be(false)

    # The xUnit immediate assertion still lives on TestContext with (expected, actual).
    ctx = Tina4::Testing::TestContext.new
    expect { ctx.assert_equal(1, 1) }.not_to raise_error
    expect { ctx.assert_equal(1, 2) }.to raise_error(Tina4::Testing::TestFailure)
  end
end
