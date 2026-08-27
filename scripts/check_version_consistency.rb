#!/usr/bin/env ruby
# frozen_string_literal: true

# check_version_consistency.rb -- pre-tag guard against a partial version bump.
#
# A release stamps the version into several files by hand. It is easy to bump
# some and miss others, and the drift is only discovered on CI AFTER the tag has
# already been pushed. Run this BEFORE `git tag` so a file left behind fails
# loudly here -- naming the file and its stale value -- instead of on CI:
#
#     ruby scripts/check_version_consistency.rb 3.13.121
#
# Exit 0 when every version-bearing file agrees with the given version;
# exit 1 (naming each drifted file + its wrong value) when any disagrees;
# exit 2 on a usage error.
#
# Pure Ruby stdlib -- no gems -- so it runs in any release environment.

# Files that carry the CURRENT release version and can drift from a partial bump.
# Each entry is [repo-relative path, capture regex, human label]. A file may
# appear more than once when it stamps the version in more than one place.
#
# Deliberately NOT listed:
#   * tina4.gemspec / tina4ruby.gemspec -- both `require_relative "lib/tina4/version"`
#     and set `spec.version = Tina4::VERSION`, so they read version.rb and cannot
#     drift. (Verified 2026-08-27.)
#   * CHANGELOG.md and spec comments -- carry HISTORICAL versions on purpose.
VERSION_CHECKS = [
  ["lib/tina4/version.rb", /^\s*VERSION\s*=\s*["']([^"']+)["']/, "VERSION constant"],
  ["CLAUDE.md",            /^Version\s+(\d+\.\d+\.\d+)\b/,        "header 'Version X'"],
  ["CLAUDE.md",            /^-\s*Version:\s*(\d+\.\d+\.\d+)\b/,   "'- Version:' line"],
  ["Gemfile.lock",         /^\s+tina4ruby \((\d+\.\d+\.\d+)\)/,   "tina4ruby lock pin"]
].freeze

# Parse `<version> [--root DIR]`. Default root is the repo (scripts/'s parent),
# resolved from the script's own location so cwd never matters. --root DIR
# points the checks at a copy of the tree (used by the spec against a fixture).
def parse_arguments(argv)
  root = File.expand_path("..", __dir__)
  positionals = []
  index = 0
  while index < argv.length
    argument = argv[index]
    if argument == "--root"
      root = argv[index + 1]
      abort("error: --root needs a directory") if root.nil?
      index += 2
    elsif argument.start_with?("--root=")
      root = argument.split("=", 2)[1]
      index += 1
    else
      positionals << argument
      index += 1
    end
  end
  [positionals[0], root]
end

expected_version, root_directory = parse_arguments(ARGV)

if expected_version.nil? || !expected_version.match?(/\A\d+\.\d+\.\d+\z/)
  warn "usage: ruby scripts/check_version_consistency.rb <version> [--root DIR]"
  warn "       <version> is the intended release, e.g. 3.13.121 (X.Y.Z)"
  exit 2
end

puts "Version consistency check against #{expected_version}  (root: #{root_directory})"
puts

failures = []

VERSION_CHECKS.each do |relative_path, pattern, label|
  absolute_path = File.join(root_directory, relative_path)

  unless File.file?(absolute_path)
    puts format("FAIL  %-22<path>s %-9<found>s (%<label>s)  file not found",
                path: relative_path, found: "-", label: label)
    failures << "#{relative_path} (#{label}): file not found"
    next
  end

  # Read as UTF-8 (and scrub any stray bytes) so a version stamp sitting in a
  # file with non-ASCII content -- CLAUDE.md carries emoji and em dashes -- never
  # crashes the check on a host whose locale defaults to US-ASCII.
  found = File.read(absolute_path, encoding: "UTF-8").scrub.scan(pattern).flatten.uniq

  if found.empty?
    puts format("FAIL  %-22<path>s %-9<found>s (%<label>s)  no version stamp found",
                path: relative_path, found: "-", label: label)
    failures << "#{relative_path} (#{label}): no version stamp matching the expected pattern"
  elsif found == [expected_version]
    puts format("PASS  %-22<path>s %-9<found>s (%<label>s)",
                path: relative_path, found: expected_version, label: label)
  else
    shown = found.join(", ")
    puts format("FAIL  %-22<path>s %-9<found>s (%<label>s)  expected %<want>s",
                path: relative_path, found: shown, label: label, want: expected_version)
    failures << "#{relative_path} (#{label}): found #{shown}, expected #{expected_version}"
  end
end

puts
if failures.empty?
  puts "RESULT: PASS -- all #{VERSION_CHECKS.length} version stamps agree on #{expected_version}"
  exit 0
else
  puts "RESULT: FAIL -- #{failures.length} of #{VERSION_CHECKS.length} disagree with #{expected_version}:"
  failures.each { |line| puts "  - #{line}" }
  exit 1
end
