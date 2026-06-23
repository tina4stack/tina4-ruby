# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::AI do
  let(:tmp_dir) { Dir.mktmpdir("tina4_ai_test") }

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "AI_TOOLS" do
    it "maps each tool name to the exact context file the installer writes, in documented order" do
      # The constant's PURPOSE is to drive which context file gets written for
      # each tool, in a stable documented order. Assert the full ordered
      # name -> context_file mapping (not just that some names are present).
      expect(Tina4::AI::AI_TOOLS.map { |t| [t[:name], t[:context_file]] }).to eq(
        [
          ["claude-code", "CLAUDE.md"],
          ["cursor", ".cursorules"],
          ["copilot", ".github/copilot-instructions.md"],
          ["windsurf", ".windsurfrules"],
          ["aider", "CONVENTIONS.md"],
          ["cline", ".clinerules"],
          ["codex", "AGENTS.md"]
        ]
      )
    end

    it "drives a real context_file (and config_dir when set) for every tool through install_all" do
      # Don't just check the keys exist on the constant -- prove each tool's
      # declared :context_file is actually created on disk, and each non-nil
      # :config_dir is a real directory after a full install.
      Tina4::AI.install_all(tmp_dir)
      Tina4::AI::AI_TOOLS.each do |tool|
        expect(File.exist?(File.join(tmp_dir, tool[:context_file]))).to(
          be(true), "expected #{tool[:name]} context file #{tool[:context_file]} to exist"
        )
        if tool[:config_dir]
          expect(Dir.exist?(File.join(tmp_dir, tool[:config_dir]))).to(
            be(true), "expected #{tool[:name]} config dir #{tool[:config_dir]} to exist"
          )
        end
      end
    end
  end

  describe ".is_installed" do
    it "returns false when context file does not exist" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "cursor" }
      expect(Tina4::AI.is_installed(tmp_dir, tool)).to be false
    end

    it "returns true when context file exists" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "claude-code" }
      FileUtils.touch(File.join(tmp_dir, tool[:context_file]))
      expect(Tina4::AI.is_installed(tmp_dir, tool)).to be true
    end

    it "returns false for copilot when only .github dir exists without the file" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "copilot" }
      FileUtils.mkdir_p(File.join(tmp_dir, ".github"))
      expect(Tina4::AI.is_installed(tmp_dir, tool)).to be false
    end
  end

  describe ".install_selected" do
    it "installs a single tool by number" do
      created = Tina4::AI.install_selected(tmp_dir, "2") # cursor
      expect(created.any? { |f| f.include?(".cursorules") }).to be true
      expect(File.exist?(File.join(tmp_dir, ".cursorules"))).to be true
    end

    it "installs multiple tools by comma-separated numbers" do
      created = Tina4::AI.install_selected(tmp_dir, "1,2")
      expect(created.any? { |f| f.include?("CLAUDE.md") }).to be true
      expect(created.any? { |f| f.include?(".cursorules") }).to be true
    end

    it "installs all tools when selection is 'all'" do
      created = Tina4::AI.install_selected(tmp_dir, "all")
      expect(File.exist?(File.join(tmp_dir, "CLAUDE.md"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".cursorules"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".windsurfrules"))).to be true
      expect(File.exist?(File.join(tmp_dir, "CONVENTIONS.md"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".clinerules"))).to be true
      expect(File.exist?(File.join(tmp_dir, "AGENTS.md"))).to be true
    end

    it "always overwrites existing context files" do
      claude_path = File.join(tmp_dir, "CLAUDE.md")
      File.write(claude_path, "old content")
      Tina4::AI.install_selected(tmp_dir, "1")
      expect(File.read(claude_path)).not_to eq("old content")
    end

    it "creates parent directories for nested context files" do
      created = Tina4::AI.install_selected(tmp_dir, "3") # copilot
      copilot_file = File.join(tmp_dir, ".github", "copilot-instructions.md")
      expect(File.exist?(copilot_file)).to be true
    end

    it "returns the windsurf path and writes its real skill-block content" do
      result = Tina4::AI.install_selected(tmp_dir, "4") # windsurf
      expect(result).to include(".windsurfrules")
      # The written file must actually carry the marker-bracketed skill block
      # (non-.md files use the "# tina4-skills:start" marker form).
      content = File.read(File.join(tmp_dir, ".windsurfrules"))
      expect(content).to include("tina4-skills:start")
    end

    it "installs nothing for an out-of-range selection number" do
      result = Tina4::AI.install_selected(tmp_dir, "99")
      expect(result).to eq([])
      # No context file should have been created for a number outside the menu.
      expect(Dir.children(tmp_dir)).to be_empty
    end

    it "is a true no-op for an empty selection" do
      result = Tina4::AI.install_selected(tmp_dir, "")
      expect(result).to eq([])
      expect(File.exist?(File.join(tmp_dir, "CLAUDE.md"))).to be(false)
      expect(Dir.children(tmp_dir)).to be_empty
    end
  end

  describe ".install_all" do
    it "installs context files for all tools" do
      Tina4::AI.install_all(tmp_dir)
      expect(File.exist?(File.join(tmp_dir, "CLAUDE.md"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".cursorules"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".windsurfrules"))).to be true
      expect(File.exist?(File.join(tmp_dir, "CONVENTIONS.md"))).to be true
      expect(File.exist?(File.join(tmp_dir, ".clinerules"))).to be true
      expect(File.exist?(File.join(tmp_dir, "AGENTS.md"))).to be true
    end

    it "returns an array of installed file paths" do
      result = Tina4::AI.install_all(tmp_dir)
      expect(result).to be_an(Array)
      expect(result.length).to be >= Tina4::AI::AI_TOOLS.size
    end

    it "creates necessary subdirectories" do
      Tina4::AI.install_all(tmp_dir)
      expect(Dir.exist?(File.join(tmp_dir, ".claude"))).to be true
      expect(Dir.exist?(File.join(tmp_dir, ".github"))).to be true
    end
  end

  describe ".generate_context" do
    it "dispatches per-tool so each tool gets distinct, tool-named content" do
      # The case statement in generate_context must produce tool-specific
      # bodies -- prove the dispatch fires by checking each tool's own header
      # text and that two different tools don't render the same document.
      expect(Tina4::AI.generate_context("cursor")).to include("Cursor Rules")
      expect(Tina4::AI.generate_context("copilot")).to include("Copilot Instructions")
      expect(Tina4::AI.generate_context("codex")).to include("Codex Agent Instructions")
      expect(Tina4::AI.generate_context("cursor")).not_to eq(Tina4::AI.generate_context("codex"))
    end

    it "includes Tina4 Ruby references" do
      context = Tina4::AI.generate_context
      expect(context).to include("Tina4")
      expect(context).to include("tina4.com")
    end

    it "includes the skills table" do
      context = Tina4::AI.generate_context
      expect(context).to include("Skill")
    end
  end
end
