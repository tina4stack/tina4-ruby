# frozen_string_literal: true
#
# Real tests for `tina4ruby lint` — the Ruby mirror of the Python master's
# `_lint` (tina4-python/tina4_python/cli/__init__.py + tests/test_cli_lint.py).
#
# The framework ships NO linter: `tina4ruby lint` runs the project's own rubocop
# and INSTALLS it as a DEV dependency on demand (`bundle add rubocop --group
# development`), with a zero-dependency `ruby -c` syntax baseline as the fallback
# (used with --no-install or when bundler/Gemfile is absent).
#
# NO mocks, no doubles, no stubs.
#   * Baseline: runs the REAL `ruby -c` parse over real files in a real temp dir.
#   * Registration: reads the REAL COMMANDS table.
#   * On-demand install: runs a REAL `bundle add rubocop --group development` in a
#     REAL throwaway project (bundler is present in the dev env) via the REAL
#     exe/tina4ruby child, then reads the mutated Gemfile back off disk and
#     asserts rubocop — not the `ruby -c` baseline — actually ran. Real bundler,
#     real network, real Gemfile mutation.

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "rbconfig"
require "bundler"

RSpec.describe "tina4ruby lint" do
  let(:cli) { Tina4::CLI.new }

  CLEAN_RB  = "def add(a, b)\n  a + b\nend\n"
  BROKEN_RB = "def add(a, b)\n  a + b\n" # missing `end` -> SyntaxError

  around(:each) do |example|
    Dir.mktmpdir("tina4clilint") do |dir|
      @tmp = dir
      Dir.chdir(dir) { example.run }
    end
  end

  # Drive cmd_lint in-process, capturing stdout and the SystemExit status — the
  # same pattern spec/cli_build_spec.rb uses for the exiting `build` command.
  def run_lint(args)
    out = +""
    status = 0
    orig = $stdout
    $stdout = StringIO.new
    begin
      cli.run(["lint", *args])
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      $stdout = orig
    end
    [out, status]
  end

  # resolve_rubocop only honours the PROJECT's bundled rubocop, so a stray global
  # rubocop on PATH can no longer preempt the --no-install baseline. The baseline
  # is therefore always reachable in a temp project with no bundled rubocop -- no
  # skip guard needed, on any machine (dev box, CI, or the lab).
  describe "zero-dependency baseline (ruby -c)" do
    it "passes a clean src file (--no-install) with exit 0" do
      FileUtils.mkdir_p("src")
      File.write("src/ok.rb", CLEAN_RB)
      out, status = run_lint(["--no-install"])
      # Proves the baseline (not rubocop) ran, and that it passed clean.
      expect(out).to include("[ruby -c")
      expect(status).to eq(0)
    end

    it "fails a src file with a syntax error (exit 1)" do
      FileUtils.mkdir_p("src")
      File.write("src/bad.rb", BROKEN_RB)
      out, status = run_lint(["--no-install"])
      expect(out).to include("src/bad.rb") # names the offending file + line
      expect(out).to include("[ruby -c]")
      expect(status).to eq(1)
    end

    it "includes app.rb in scope (a broken app.rb fails, exit 1)" do
      File.write("app.rb", BROKEN_RB)
      out, status = run_lint(["--no-install"])
      expect(out).to include("app.rb")
      expect(status).to eq(1)
    end

    it "exits 0 with a clear message when there is nothing to lint" do
      # No src/ and no app.rb in the temp dir -> nothing to lint.
      out, status = run_lint(["--no-install"])
      expect(out).to include("lint: nothing to lint")
      expect(status).to eq(0)
    end
  end

  describe "registration" do
    it "registers `lint` as a command routed to cmd_lint" do
      expect(Tina4::CLI::COMMANDS).to have_key("lint")
      expect(Tina4::CLI::COMMANDS["lint"][:handler]).to eq(:cmd_lint)
    end
  end

  describe "on-demand install (REAL bundle add — no mock)" do
    # The headline feature: with no rubocop resolvable and no --no-install,
    # `tina4ruby lint` adds rubocop as a DEV dependency of the project, then runs
    # it. Spawned as the REAL exe/tina4ruby child under an UNBUNDLED env so
    # `bundle add` mutates the TEMP project's Gemfile (discovered via cwd), never
    # the framework's own Gemfile. Real bundler + real network — slow but real.
    it "installs rubocop dev-only into the project Gemfile, then runs rubocop (not ruby -c)" do
      skip "bundler not on PATH" unless cli.send(:which_executable, "bundle")

      gemfile = File.join(@tmp, "Gemfile")
      File.write(gemfile, %(source "https://rubygems.org"\n))
      FileUtils.mkdir_p(File.join(@tmp, "src"))
      # Valid Ruby (so `ruby -c` PASSES it) but a guaranteed rubocop offense
      # (no frozen_string_literal comment, no space around `=`). A non-zero exit
      # plus the [rubocop] marker therefore PROVES rubocop ran, not the baseline.
      File.write(File.join(@tmp, "src", "smelly.rb"), "x=1\n")

      expect(File.read(gemfile)).not_to include("rubocop")

      # with_unbundled_env restores the pre-Bundler ENV, so the child does not
      # inherit BUNDLE_GEMFILE/RUBYOPT pointing at the framework's bundle.
      # BUNDLE_PATH installs rubocop into a project-LOCAL vendor dir under @tmp
      # (reaped with the temp project), so this test never leaves a rubocop on
      # the shared gem home / PATH — otherwise it would make the sibling baseline
      # examples skip when it happens to run first under a given seed.
      env = { "BUNDLE_PATH" => File.join(@tmp, "vendor", "bundle") }
      output, wait = Bundler.with_unbundled_env do
        Open3.capture2e(env, RUBY_BIN, EXE, "lint", chdir: @tmp)
      end

      after = File.read(gemfile)
      expect(after).to include("rubocop"),
                       "rubocop was not added to the Gemfile.\noutput:\n#{output}\nGemfile:\n#{after}"
      # Added to the DEVELOPMENT group, not the app's runtime dependencies.
      expect(after).to match(/development/),
                       "rubocop was not added to the development group.\nGemfile:\n#{after}"
      expect(output).to include("adding it as a dev dependency"),
                        "the on-demand install path did not run.\noutput:\n#{output}"
      # rubocop ran, NOT the `ruby -c` baseline.
      expect(output).to include("[rubocop"),
                        "rubocop did not run (baseline used instead?).\noutput:\n#{output}"
      expect(output).not_to include("[ruby -c")
      # x=1 is a real rubocop offense but valid syntax, so a non-zero exit proves
      # rubocop (not `ruby -c`, which passes valid syntax) drove the result.
      expect(wait.exitstatus).not_to eq(0),
                                     "rubocop should have flagged x=1.\noutput:\n#{output}"
    end
  end
end
