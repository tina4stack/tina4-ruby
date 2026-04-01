# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::DevReload do
  # ── Watch Extensions ──────────────────────────────────────────

  describe "WATCH_EXTENSIONS" do
    it "includes .rb" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".rb")
    end

    it "includes .twig" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".twig")
    end

    it "includes .html" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".html")
    end

    it "includes .css" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".css")
    end

    it "includes .scss" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".scss")
    end

    it "includes .js" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".js")
    end

    it "includes .erb" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to include(".erb")
    end

    it "does not include .txt" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).not_to include(".txt")
    end

    it "does not include .md" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).not_to include(".md")
    end

    it "does not include .json" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).not_to include(".json")
    end

    it "is frozen" do
      expect(Tina4::DevReload::WATCH_EXTENSIONS).to be_frozen
    end
  end

  # ── Watch Directories ─────────────────────────────────────────

  describe "WATCH_DIRS" do
    it "includes src" do
      expect(Tina4::DevReload::WATCH_DIRS).to include("src")
    end

    it "includes routes" do
      expect(Tina4::DevReload::WATCH_DIRS).to include("routes")
    end

    it "includes lib" do
      expect(Tina4::DevReload::WATCH_DIRS).to include("lib")
    end

    it "includes templates" do
      expect(Tina4::DevReload::WATCH_DIRS).to include("templates")
    end

    it "includes public" do
      expect(Tina4::DevReload::WATCH_DIRS).to include("public")
    end

    it "is frozen" do
      expect(Tina4::DevReload::WATCH_DIRS).to be_frozen
    end
  end

  # ── Ignore Directories ────────────────────────────────────────

  describe "IGNORE_DIRS" do
    it "includes .git" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include(".git")
    end

    it "includes node_modules" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include("node_modules")
    end

    it "includes vendor" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include("vendor")
    end

    it "includes logs" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include("logs")
    end

    it "includes sessions" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include("sessions")
    end

    it "includes .queue" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include(".queue")
    end

    it "includes .keys" do
      expect(Tina4::DevReload::IGNORE_DIRS).to include(".keys")
    end

    it "is frozen" do
      expect(Tina4::DevReload::IGNORE_DIRS).to be_frozen
    end
  end

  # ── Ignore Regex ──────────────────────────────────────────────

  describe ".build_ignore_regex" do
    let(:regex) { Tina4::DevReload.send(:build_ignore_regex) }

    it "returns a Regexp" do
      expect(regex).to be_a(Regexp)
    end

    it "matches .git path" do
      expect(".git/objects/abc").to match(regex)
    end

    it "matches node_modules path" do
      expect("frontend/node_modules/pkg/index.js").to match(regex)
    end

    it "matches vendor path" do
      expect("vendor/bundle/gems").to match(regex)
    end

    it "does not match normal src path" do
      expect("src/routes/users.rb").not_to match(regex)
    end

    it "does not match normal lib path" do
      expect("lib/tina4/router.rb").not_to match(regex)
    end
  end

  # ── Module Interface ──────────────────────────────────────────

  describe "module interface" do
    it "responds to .start" do
      expect(Tina4::DevReload).to respond_to(:start)
    end

    it "responds to .stop" do
      expect(Tina4::DevReload).to respond_to(:stop)
    end
  end

  # ── Extension Filtering ───────────────────────────────────────

  describe "extension filtering" do
    it "builds a regex matching all watch extensions" do
      # The Listen :only option is built from WATCH_EXTENSIONS
      pattern_parts = Tina4::DevReload::WATCH_EXTENSIONS.map { |e| e.delete(".") }
      regex = /\.(#{pattern_parts.join("|")})$/

      expect("app.rb").to match(regex)
      expect("style.css").to match(regex)
      expect("page.twig").to match(regex)
      expect("index.html").to match(regex)
      expect("main.js").to match(regex)
      expect("layout.erb").to match(regex)

      expect("readme.txt").not_to match(regex)
      expect("data.json").not_to match(regex)
      expect("notes.md").not_to match(regex)
    end
  end

  # ── Watch Directory Resolution ────────────────────────────────

  describe "watch directory resolution" do
    it "resolves existing directories from WATCH_DIRS" do
      Dir.mktmpdir("tina4-reload-test") do |root|
        # Create only some of the dirs
        FileUtils.mkdir_p(File.join(root, "src"))
        FileUtils.mkdir_p(File.join(root, "routes"))

        dirs = Tina4::DevReload::WATCH_DIRS
          .map { |d| File.join(root, d) }
          .select { |d| Dir.exist?(d) }

        expect(dirs.size).to eq(2)
        expect(dirs).to include(File.join(root, "src"))
        expect(dirs).to include(File.join(root, "routes"))
      end
    end

    it "skips non-existent directories" do
      Dir.mktmpdir("tina4-reload-test") do |root|
        dirs = Tina4::DevReload::WATCH_DIRS
          .map { |d| File.join(root, d) }
          .select { |d| Dir.exist?(d) }

        expect(dirs).to be_empty
      end
    end
  end

  # ── Stop Without Start ────────────────────────────────────────

  describe ".stop" do
    it "does not raise when called without start" do
      expect { Tina4::DevReload.stop }.not_to raise_error
    end
  end
end
