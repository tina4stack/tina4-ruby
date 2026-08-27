# frozen_string_literal: true
#
# Real-subprocess lock-in for scripts/check_version_consistency.rb -- the pre-tag
# guard that catches a partial version bump BEFORE a tag is cut (rather than on
# CI after the tag already ran ahead of some version-bearing files).
#
# No mocks, no doubles, no stubs. Every case runs the REAL script in a fresh
# child ruby process via Open3.capture3 and asserts on its real exit status and
# real output:
#   * positive -- it PASSES (exit 0) against this working tree at HEAD, so the
#     spec doubles as a guard that HEAD is itself version-consistent;
#   * negative -- given a fixture tree with exactly ONE file left behind, it
#     FAILS (non-zero) and NAMES the drifted file and its wrong value. Two
#     different files are corrupted across two cases to prove the check is not
#     version.rb-only.

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "scripts/check_version_consistency.rb" do
  repo_root  = File.expand_path("..", __dir__)
  script     = File.join(repo_root, "scripts", "check_version_consistency.rb")
  version_rb = File.join(repo_root, "lib", "tina4", "version.rb")

  # The canonical current version, straight from the source of truth.
  current = File.read(version_rb)[/VERSION\s*=\s*["']([^"']+)["']/, 1]

  # Copy every checked file into a fresh tree mirroring the repo layout, so the
  # only failure a corruption can produce is the intended one.
  def stage_fixture(dir, repo_root)
    FileUtils.mkdir_p(File.join(dir, "lib", "tina4"))
    FileUtils.cp(File.join(repo_root, "lib", "tina4", "version.rb"),
                 File.join(dir, "lib", "tina4", "version.rb"))
    FileUtils.cp(File.join(repo_root, "CLAUDE.md"),   File.join(dir, "CLAUDE.md"))
    FileUtils.cp(File.join(repo_root, "Gemfile.lock"), File.join(dir, "Gemfile.lock"))
  end

  it "the script and the canonical version file are present" do
    expect(File).to exist(script)
    expect(current).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "PASSES (exit 0) against the real repo at HEAD for the current version" do
    stdout, stderr, status = Open3.capture3("ruby", script, current)
    expect(status.exitstatus).to eq(0), "expected pass, got:\n#{stdout}\n#{stderr}"
    expect(stdout).to include("RESULT: PASS")
    expect(stdout).not_to include("FAIL")
  end

  it "FAILS (non-zero) and NAMES version.rb when it is the file left behind" do
    Dir.mktmpdir do |dir|
      stage_fixture(dir, repo_root)

      drifted = File.join(dir, "lib", "tina4", "version.rb")
      File.write(drifted,
                 File.read(drifted).sub(/VERSION\s*=\s*["'][^"']+["']/, 'VERSION = "9.9.9"'))

      stdout, stderr, status = Open3.capture3("ruby", script, current, "--root", dir)
      output = stdout + stderr

      expect(status.exitstatus).not_to eq(0), "expected non-zero, got 0:\n#{output}"
      expect(output).to include("version.rb")  # names the drifted file
      expect(output).to include("9.9.9")        # shows the stale value
      expect(output).to include(current)        # shows what was expected
    end
  end

  it "FAILS and NAMES CLAUDE.md when its footer is the file left behind" do
    Dir.mktmpdir do |dir|
      stage_fixture(dir, repo_root)

      claude = File.join(dir, "CLAUDE.md")
      # UTF-8: CLAUDE.md carries non-ASCII bytes, and the locale default here is
      # US-ASCII -- a plain File.read would make #sub raise on the high bytes.
      File.write(claude,
                 File.read(claude, encoding: "UTF-8").sub(/^-\s*Version:\s*\d+\.\d+\.\d+/, "- Version: 8.8.8"))

      stdout, stderr, status = Open3.capture3("ruby", script, current, "--root", dir)
      output = stdout + stderr

      expect(status.exitstatus).not_to eq(0), "expected non-zero, got 0:\n#{output}"
      expect(output).to include("CLAUDE.md")
      expect(output).to include("8.8.8")
    end
  end

  it "exits 2 on a usage error (no version argument)" do
    _stdout, stderr, status = Open3.capture3("ruby", script)
    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("usage:")
  end
end
