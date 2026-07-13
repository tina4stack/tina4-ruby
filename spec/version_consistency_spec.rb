# frozen_string_literal: true

# Guard against release-bump drift: the release bumps lib/tina4/version.rb but
# has historically left the version string in CLAUDE.md behind (the AI-facing
# doc assistants read as ground truth), so tools reported an outdated "latest
# version". This pure-logic spec fails if CLAUDE.md's version strings do not
# match VERSION. It only reads two files -- no framework load, no dependency.

require "spec_helper"

RSpec.describe "version consistency" do
  root = File.expand_path("..", __dir__)
  version = File.read(File.join(root, "lib", "tina4", "version.rb"), encoding: "UTF-8")[/VERSION\s*=\s*["'](\d+\.\d+\.\d+)/, 1]
  claude = File.read(File.join(root, "CLAUDE.md"), encoding: "UTF-8")

  it "CLAUDE.md header version matches lib/tina4/version.rb" do
    expect(version).not_to be_nil
    expect(claude).to match(/^Version #{Regexp.escape(version)}\b/)
  end

  it "no CLAUDE.md '- Version:' footer is left stale" do
    footers = claude.scan(/^- Version:\s*(\d+\.\d+\.\d+)/).flatten
    expect(footers).not_to be_empty
    expect(footers.uniq).to eq([version])
  end
end
