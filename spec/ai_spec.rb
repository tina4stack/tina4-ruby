# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::AI do
  let(:tmp_dir) { Dir.mktmpdir("tina4_ai_test") }

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".detect_ai" do
    it "returns an array of tool hashes for every known tool" do
      result = Tina4::AI.detect_ai(tmp_dir)
      expect(result).to be_an(Array)
      expect(result.length).to eq(Tina4::AI::AI_TOOLS.size)
      result.each do |tool|
        expect(tool).to have_key(:name)
        expect(tool).to have_key(:description)
        expect(tool).to have_key(:config_file)
        expect(tool).to have_key(:status)
      end
    end

    it "returns empty detected list when no AI tools are present" do
      detected = Tina4::AI.detect_ai(tmp_dir).select { |t| t[:status] == "detected" }
      expect(detected).to be_empty
    end

    it "detects Claude Code when CLAUDE.md exists" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      result = Tina4::AI.detect_ai(tmp_dir)
      claude = result.find { |t| t[:name] == "claude-code" }
      expect(claude[:status]).to eq("detected")
    end

    it "detects Claude Code when .claude directory exists" do
      FileUtils.mkdir_p(File.join(tmp_dir, ".claude"))
      result = Tina4::AI.detect_ai(tmp_dir)
      claude = result.find { |t| t[:name] == "claude-code" }
      expect(claude[:status]).to eq("detected")
    end

    it "detects Cursor when .cursorules exists" do
      FileUtils.touch(File.join(tmp_dir, ".cursorules"))
      result = Tina4::AI.detect_ai(tmp_dir)
      cursor = result.find { |t| t[:name] == "cursor" }
      expect(cursor[:status]).to eq("detected")
    end

    it "detects Cursor when .cursor directory exists" do
      FileUtils.mkdir_p(File.join(tmp_dir, ".cursor"))
      result = Tina4::AI.detect_ai(tmp_dir)
      cursor = result.find { |t| t[:name] == "cursor" }
      expect(cursor[:status]).to eq("detected")
    end

    it "detects GitHub Copilot when .github/copilot-instructions.md exists" do
      FileUtils.mkdir_p(File.join(tmp_dir, ".github"))
      FileUtils.touch(File.join(tmp_dir, ".github", "copilot-instructions.md"))
      result = Tina4::AI.detect_ai(tmp_dir)
      copilot = result.find { |t| t[:name] == "copilot" }
      expect(copilot[:status]).to eq("detected")
    end

    it "detects Windsurf when .windsurfrules exists" do
      FileUtils.touch(File.join(tmp_dir, ".windsurfrules"))
      result = Tina4::AI.detect_ai(tmp_dir)
      windsurf = result.find { |t| t[:name] == "windsurf" }
      expect(windsurf[:status]).to eq("detected")
    end

    it "detects Aider when .aider.conf.yml exists" do
      FileUtils.touch(File.join(tmp_dir, ".aider.conf.yml"))
      result = Tina4::AI.detect_ai(tmp_dir)
      aider = result.find { |t| t[:name] == "aider" }
      expect(aider[:status]).to eq("detected")
    end

    it "detects Cline when .clinerules exists" do
      FileUtils.touch(File.join(tmp_dir, ".clinerules"))
      result = Tina4::AI.detect_ai(tmp_dir)
      cline = result.find { |t| t[:name] == "cline" }
      expect(cline[:status]).to eq("detected")
    end

    it "detects Codex when AGENTS.md exists" do
      FileUtils.touch(File.join(tmp_dir, "AGENTS.md"))
      result = Tina4::AI.detect_ai(tmp_dir)
      codex = result.find { |t| t[:name] == "codex" }
      expect(codex[:status]).to eq("detected")
    end
  end

  describe ".detect_ai_names" do
    it "returns just the tool names of detected tools" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      FileUtils.touch(File.join(tmp_dir, ".windsurfrules"))
      names = Tina4::AI.detect_ai_names(tmp_dir)
      expect(names).to include("claude-code")
      expect(names).to include("windsurf")
      expect(names).not_to include("cursor")
    end

    it "returns empty array when nothing detected" do
      names = Tina4::AI.detect_ai_names(tmp_dir)
      expect(names).to be_empty
    end
  end

  describe ".install_ai_context" do
    it "creates context files for detected tools" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      # CLAUDE.md already exists, so it won't be overwritten without force
      # Detect will find claude-code, but file exists => skip
      # Let's use windsurf which doesn't exist yet
      FileUtils.touch(File.join(tmp_dir, ".windsurfrules"))
      # .windsurfrules exists, so it won't be overwritten without force either
      # We need a tool that is detected but whose context file doesn't exist yet
      FileUtils.mkdir_p(File.join(tmp_dir, ".cursor"))
      created = Tina4::AI.install_ai_context(tmp_dir)
      expect(created).to include(".cursorules")
    end

    it "does not overwrite existing files without force" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      File.write(File.join(tmp_dir, "CLAUDE.md"), "original content")
      created = Tina4::AI.install_ai_context(tmp_dir)
      expect(created).not_to include("CLAUDE.md")
      expect(File.read(File.join(tmp_dir, "CLAUDE.md"))).to eq("original content")
    end

    it "overwrites existing files when force: true" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      File.write(File.join(tmp_dir, "CLAUDE.md"), "original content")
      created = Tina4::AI.install_ai_context(tmp_dir, force: true)
      expect(created).to include("CLAUDE.md")
      expect(File.read(File.join(tmp_dir, "CLAUDE.md"))).not_to eq("original content")
    end

    it "only installs for detected tools by default" do
      FileUtils.mkdir_p(File.join(tmp_dir, ".claude"))
      created = Tina4::AI.install_ai_context(tmp_dir)
      # Only claude-code detected, so only CLAUDE.md should be created
      expect(created).to include("CLAUDE.md")
      expect(created).not_to include(".cursorules")
    end

    it "accepts a specific tools list" do
      created = Tina4::AI.install_ai_context(tmp_dir, tools: ["windsurf"])
      expect(created).to include(".windsurfrules")
      expect(created.length).to eq(1)
    end
  end

  describe ".install_all" do
    it "creates context files for ALL tools regardless of detection" do
      created = Tina4::AI.install_all(tmp_dir)
      expect(created.length).to be >= Tina4::AI::AI_TOOLS.size
      expect(created).to include("CLAUDE.md")
      expect(created).to include(".cursorules")
      expect(created).to include(".github/copilot-instructions.md")
      expect(created).to include(".windsurfrules")
      expect(created).to include("CONVENTIONS.md")
      expect(created).to include(".clinerules")
      expect(created).to include("AGENTS.md")
    end

    it "does not overwrite existing files without force" do
      File.write(File.join(tmp_dir, "CLAUDE.md"), "keep me")
      created = Tina4::AI.install_all(tmp_dir)
      expect(created).not_to include("CLAUDE.md")
      expect(File.read(File.join(tmp_dir, "CLAUDE.md"))).to eq("keep me")
    end

    it "overwrites existing files with force: true" do
      File.write(File.join(tmp_dir, "CLAUDE.md"), "replace me")
      created = Tina4::AI.install_all(tmp_dir, force: true)
      expect(created).to include("CLAUDE.md")
      expect(File.read(File.join(tmp_dir, "CLAUDE.md"))).not_to eq("replace me")
    end

    it "creates necessary config directories" do
      Tina4::AI.install_all(tmp_dir)
      expect(Dir.exist?(File.join(tmp_dir, ".claude"))).to be true
      expect(Dir.exist?(File.join(tmp_dir, ".cursor"))).to be true
      expect(Dir.exist?(File.join(tmp_dir, ".github"))).to be true
    end
  end

  describe ".status_report" do
    it "returns a formatted string" do
      report = Tina4::AI.status_report(tmp_dir)
      expect(report).to be_a(String)
      expect(report).to include("Tina4 AI Context Status")
    end

    it "shows 'No AI coding tools detected' when none found" do
      report = Tina4::AI.status_report(tmp_dir)
      expect(report).to include("No AI coding tools detected")
    end

    it "lists detected tools with + prefix" do
      FileUtils.touch(File.join(tmp_dir, "CLAUDE.md"))
      report = Tina4::AI.status_report(tmp_dir)
      expect(report).to include("+ Claude Code (Anthropic CLI) (claude-code)")
    end

    it "lists not-detected tools with - prefix and install hint" do
      report = Tina4::AI.status_report(tmp_dir)
      expect(report).to include("- Cursor IDE (cursor)")
      expect(report).to include("tina4ruby ai --all")
    end
  end
end
