# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Gallery" do
  let(:gallery_dir) { File.join(File.dirname(__FILE__), "..", "lib", "tina4", "gallery") }
  let(:expected_examples) { %w[auth database error-overlay orm queue rest-api templates] }

  # ── Directory structure ────────────────────────────────────────────

  describe "directory structure" do
    it "gallery directory exists" do
      expect(Dir.exist?(gallery_dir)).to be true
    end

    it "subdirectories are exactly the expected examples (no stray dirs)" do
      subdirs = Dir.children(gallery_dir).select { |d| File.directory?(File.join(gallery_dir, d)) }
      # Every expected example is present AND there are no unexpected stray
      # directories — a stronger contract than a bare count > 0.
      expect(subdirs.sort).to match_array(expected_examples)
    end

    it "contains all expected examples" do
      subdirs = Dir.children(gallery_dir).select { |d| File.directory?(File.join(gallery_dir, d)) }
      expected_examples.each do |name|
        expect(subdirs).to include(name), "Missing gallery example: #{name}"
      end
    end
  end

  # ── Metadata ───────────────────────────────────────────────────────

  describe "metadata" do
    it "every example has a meta.json" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        expect(File.file?(meta_file)).to be(true), "Missing meta.json in gallery/#{name}"
      end
    end

    it "meta.json files contain valid JSON" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        content = File.read(meta_file)
        parsed = JSON.parse(content)
        expect(parsed).to be_a(Hash)
      end
    end

    it "meta.json has a name field" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        parsed = JSON.parse(File.read(meta_file))
        expect(parsed).to have_key("name"), "meta.json in #{name} missing 'name' field"
      end
    end

    it "meta.json has a description field" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        parsed = JSON.parse(File.read(meta_file))
        expect(parsed).to have_key("description"), "meta.json in #{name} missing 'description' field"
      end
    end

    it "name field is a non-empty string" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        parsed = JSON.parse(File.read(meta_file))
        expect(parsed["name"]).to be_a(String)
        expect(parsed["name"].length).to be > 0
      end
    end

    it "description field is a non-empty string" do
      expected_examples.each do |name|
        meta_file = File.join(gallery_dir, name, "meta.json")
        parsed = JSON.parse(File.read(meta_file))
        expect(parsed["description"]).to be_a(String)
        expect(parsed["description"].length).to be > 0
      end
    end
  end

  # ── Example structure ──────────────────────────────────────────────

  describe "example structure" do
    it "each example has a src directory" do
      expected_examples.each do |name|
        src_dir = File.join(gallery_dir, name, "src")
        expect(Dir.exist?(src_dir)).to be(true), "Missing src/ in gallery/#{name}"
      end
    end

    it "each example has Ruby files" do
      expected_examples.each do |name|
        src_dir = File.join(gallery_dir, name, "src")
        rb_files = Dir.glob(File.join(src_dir, "**", "*.rb"))
        expect(rb_files.length).to be > 0, "No .rb files in gallery/#{name}/src"
      end
    end

    it "rest-api has a route file" do
      routes_dir = File.join(gallery_dir, "rest-api", "src", "routes")
      expect(Dir.exist?(routes_dir)).to be true
      rb_files = Dir.glob(File.join(routes_dir, "**", "*.rb"))
      expect(rb_files.length).to be > 0
    end

    it "templates example has a twig file" do
      tpl_dir = File.join(gallery_dir, "templates", "src", "templates")
      expect(Dir.exist?(tpl_dir)).to be true
      twig_files = Dir.glob(File.join(tpl_dir, "**", "*.twig"))
      expect(twig_files.length).to be > 0
    end
  end

  # ── DevAdmin gallery handlers ──────────────────────────────────────

  describe "gallery_list via DevAdmin" do
    it "gallery_list discovers every expected example by id" do
      result = Tina4::DevAdmin.send(:gallery_list)
      expect(result[:count]).to eq(expected_examples.length)
      expect(result[:gallery].map { |i| i["id"] }).to match_array(expected_examples)
    end

    it "gallery_list count is consistent with the gallery contents" do
      result = Tina4::DevAdmin.send(:gallery_list)
      expect(result).to have_key(:gallery)
      expect(result).to have_key(:count)
      # count must actually reflect the gallery it returns, not a stale/independent value.
      expect(result[:gallery]).to be_a(Array)
      expect(result[:count]).to eq(result[:gallery].length)
    end

    it "gallery_list count matches expected examples" do
      result = Tina4::DevAdmin.send(:gallery_list)
      expect(result[:count]).to eq(expected_examples.length)
    end

    it "each gallery item carries real id/name/description matching its meta.json" do
      result = Tina4::DevAdmin.send(:gallery_list)
      result[:gallery].each do |item|
        # id must be one of the real examples (not just present).
        expect(expected_examples).to include(item["id"])

        # name/description must be non-empty strings...
        expect(item["name"]).to be_a(String).and(satisfy { |s| !s.empty? })
        expect(item["description"]).to be_a(String).and(satisfy { |s| !s.empty? })

        # ...and equal the on-disk meta.json for that id (the handler must
        # surface the real metadata, not synthesised placeholders).
        meta = JSON.parse(File.read(File.join(gallery_dir, item["id"], "meta.json")))
        expect(item["name"]).to eq(meta["name"])
        expect(item["description"]).to eq(meta["description"])
      end
    end

    it "each gallery item's listed source files actually exist on disk" do
      result = Tina4::DevAdmin.send(:gallery_list)
      result[:gallery].each do |item|
        expect(item["files"]).to be_a(Array)
        expect(item["files"].length).to be > 0
        # Every listed file is a real readable file under gallery/<id>/src/ —
        # the manifest must match reality, not list phantom paths. (files are
        # stored relative to the src dir, e.g. "routes/api/gallery_hello.rb".)
        item["files"].each do |f|
          path = File.join(gallery_dir, item["id"], "src", f)
          expect(File.file?(path)).to be(true), "Listed file missing on disk: #{path}"
        end
      end
    end
  end

  describe "gallery_deploy via DevAdmin" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_gallery_deploy") }

    before(:each) do
      # Point Tina4 root to a temp directory so deploy writes there
      allow(Tina4).to receive(:root_dir).and_return(tmp_dir)
    end

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    it "returns error for empty name" do
      result = Tina4::DevAdmin.send(:gallery_deploy, "")
      expect(result).to have_key(:error)
    end

    it "returns error for nonexistent gallery item" do
      result = Tina4::DevAdmin.send(:gallery_deploy, "nonexistent_example_xyz")
      expect(result).to have_key(:error)
    end

    it "deploys rest-api example and copies files" do
      result = Tina4::DevAdmin.send(:gallery_deploy, "rest-api")
      expect(result).to have_key(:deployed)
      expect(result[:deployed]).to eq("rest-api")
      expect(result[:files]).to be_a(Array)
      expect(result[:files].length).to be > 0
    end

    it "deploy creates files in the project src directory" do
      Tina4::DevAdmin.send(:gallery_deploy, "rest-api")
      src_dir = File.join(tmp_dir, "src")
      expect(Dir.exist?(src_dir)).to be true
      # At least one file should exist under src/
      deployed_files = Dir.glob(File.join(src_dir, "**", "*")).select { |f| File.file?(f) }
      expect(deployed_files.length).to be > 0
    end
  end
end
