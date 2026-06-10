# frozen_string_literal: true

# Tina4 Ruby -- v3.13.9 non-destructive AI installer.
#
# The pre-v3.13.9 installer clobbered the user's CLAUDE.md (and the
# equivalent context files for Cursor / Copilot / Windsurf / etc.) on
# every install. v3.13.9 switches to a marker-bracketed skill block
# that preserves whatever the user had in the file.
#
# Four branches covered:
#
#   1. Fresh install -- file doesn't exist, full framework guide + block.
#   2. Refresh -- file exists with markers, just the block gets replaced.
#   3. Migration -- file starts with a pre-v3.13.9 framework header, the
#      old dump gets replaced.
#   4. Preserve -- file exists with user content, block appended at end.

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "AI installer (v3.13.9)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_ai_installer") }
  let(:claude_md) { File.join(tmp_dir, "CLAUDE.md") }
  let(:framework_guide) { "# Tina4 Ruby\n\nFramework boilerplate here." }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  describe ".markers_for" do
    it "returns HTML comment markers for .md files" do
      start, finish = Tina4::AI.markers_for("CLAUDE.md")
      expect(start).to eq("<!-- tina4-skills:start -->")
      expect(finish).to eq("<!-- tina4-skills:end -->")
    end

    it "returns hash comment markers for rule files" do
      start, finish = Tina4::AI.markers_for(".cursorules")
      expect(start).to eq("# tina4-skills:start")
      expect(finish).to eq("# tina4-skills:end")
    end
  end

  describe ".skill_block" do
    it "mentions all three skills for markdown files" do
      block = Tina4::AI.skill_block("CLAUDE.md")
      expect(block).to include("## Tina4 Skills")
      expect(block).to include("tina4-developer")
      expect(block).to include("tina4-js")
      expect(block).to include("tina4-maintainer")
      expect(block).to include("tina4.com")
    end

    it "uses plain text (no markdown) for rule files" do
      block = Tina4::AI.skill_block(".cursorules")
      expect(block).not_to include("##")
      expect(block).not_to include("**")
      expect(block).to include("tina4-developer")
    end
  end

  describe ".has_markers?" do
    let(:start) { "<!-- tina4-skills:start -->" }
    let(:finish) { "<!-- tina4-skills:end -->" }

    it "returns true when both markers appear in order" do
      text = "user notes\n#{start}\nblock\n#{finish}\nmore"
      expect(Tina4::AI.has_markers?(text, start, finish)).to eq(true)
    end

    it "returns false when only the start marker is present" do
      text = "user notes\n#{start}\nincomplete"
      expect(Tina4::AI.has_markers?(text, start, finish)).to eq(false)
    end

    it "returns false when end appears before start" do
      text = "#{finish}\nstray\n#{start}"
      expect(Tina4::AI.has_markers?(text, start, finish)).to eq(false)
    end
  end

  describe ".looks_like_old_framework_install?" do
    %w[
      Python\ —\ Developer\ Guidelines
      PHP
      Ruby
    ].each do |suffix|
      it "recognises '# Tina4 #{suffix}' as an old install" do
        text = "# Tina4 #{suffix}\n\nOld content..."
        expect(Tina4::AI.looks_like_old_framework_install?(text)).to eq(true)
      end
    end

    it "treats user-authored files as not-old" do
      text = "# My Project Notes\n\nDeploy info..."
      expect(Tina4::AI.looks_like_old_framework_install?(text)).to eq(false)
    end

    it "treats empty files as not-old" do
      expect(Tina4::AI.looks_like_old_framework_install?("")).to eq(false)
    end
  end

  describe ".write_or_merge" do
    it "writes guide + block on fresh install" do
      action = Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      expect(action).to eq("Installed")
      body = File.read(claude_md)
      expect(body).to include("Framework boilerplate")
      expect(body).to include("<!-- tina4-skills:start -->")
      expect(body).to include("<!-- tina4-skills:end -->")
    end

    it "refreshes just the block when markers exist" do
      File.write(claude_md,
        "# My Project Notes\n\n" \
        "Deploy to staging via `make deploy`.\n\n" \
        "<!-- tina4-skills:start -->\nOLD BLOCK CONTENT\n<!-- tina4-skills:end -->\n\n" \
        "Don't forget to bump the version before tagging."
      )

      action = Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      expect(action).to eq("Refreshed skill block in")

      body = File.read(claude_md)
      expect(body).not_to include("OLD BLOCK CONTENT")
      expect(body).to include("tina4-developer")
      expect(body).to include("# My Project Notes")
      expect(body).to include("Deploy to staging via `make deploy`.")
      expect(body).to include("Don't forget to bump the version before tagging.")
      expect(body).not_to include("Framework boilerplate")
    end

    it "is idempotent (second run is a no-op)" do
      File.write(claude_md, "# My Notes\n")
      Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      first = File.read(claude_md)
      Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      second = File.read(claude_md)
      expect(second).to eq(first)
    end

    it "migrates an old framework install" do
      File.write(claude_md, "# Tina4 Ruby\n\nOld framework content (should be replaced)...\n")
      action = Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      expect(action).to eq("Migrated (replaced old framework dump in)")
      body = File.read(claude_md)
      expect(body).not_to include("Old framework content")
      expect(body).to include("Framework boilerplate here.")
      expect(body).to include("<!-- tina4-skills:start -->")
    end

    it "preserves user content and appends the block" do
      original = "# 24rent App\n\n" \
                 "## Conventions\n\n" \
                 "- Branch naming: feature/<jira>-<slug>\n" \
                 "- Deploy: make deploy ENV=staging\n"
      File.write(claude_md, original)

      action = Tina4::AI.write_or_merge(claude_md, "CLAUDE.md", framework_guide)
      expect(action).to eq("Appended skill block to")

      body = File.read(claude_md)
      original.lines.each do |line|
        next if line.strip.empty?
        expect(body).to include(line.chomp), "lost user line: #{line.inspect}"
      end
      expect(body).to include("<!-- tina4-skills:start -->")
    end

    it "uses hash markers for .cursorules" do
      rules = File.join(tmp_dir, ".cursorules")
      File.write(rules, "Rule: keep handlers under 50 lines\n")
      Tina4::AI.write_or_merge(rules, ".cursorules", "# Cursor framework guide")

      body = File.read(rules)
      expect(body).to include("# tina4-skills:start")
      expect(body).to include("# tina4-skills:end")
      expect(body).not_to include("<!--")
      expect(body).to include("Rule: keep handlers under 50 lines")
    end
  end
end
