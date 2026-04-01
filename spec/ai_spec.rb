# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::AI do
  let(:tmp_dir) { Dir.mktmpdir("tina4_ai_test") }

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "AI_TOOLS" do
    it "has the expected tools in order" do
      names = Tina4::AI::AI_TOOLS.map { |t| t[:name] }
      expect(names).to include("claude-code", "cursor", "copilot", "windsurf", "aider", "cline", "codex")
    end

    it "each tool has required keys" do
      Tina4::AI::AI_TOOLS.each do |tool|
        expect(tool).to have_key(:name)
        expect(tool).to have_key(:description)
        expect(tool).to have_key(:context_file)
      end
    end
  end

  describe ".installed?" do
    it "returns false when context file does not exist" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "cursor" }
      expect(Tina4::AI.installed?(tmp_dir, tool)).to be false
    end

    it "returns true when context file exists" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "claude-code" }
      FileUtils.touch(File.join(tmp_dir, tool[:context_file]))
      expect(Tina4::AI.installed?(tmp_dir, tool)).to be true
    end

    it "returns false for copilot when only .github dir exists without the file" do
      tool = Tina4::AI::AI_TOOLS.find { |t| t[:name] == "copilot" }
      FileUtils.mkdir_p(File.join(tmp_dir, ".github"))
      expect(Tina4::AI.installed?(tmp_dir, tool)).to be false
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

    it "returns an array of installed file paths" do
      result = Tina4::AI.install_selected(tmp_dir, "4") # windsurf
      expect(result).to be_an(Array)
      expect(result).not_to be_empty
    end

    it "ignores invalid selection numbers" do
      expect { Tina4::AI.install_selected(tmp_dir, "99") }.not_to raise_error
    end

    it "handles empty selection gracefully" do
      result = Tina4::AI.install_selected(tmp_dir, "")
      expect(result).to be_an(Array)
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
    it "returns a non-empty string" do
      context = Tina4::AI.generate_context
      expect(context).to be_a(String)
      expect(context).not_to be_empty
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
