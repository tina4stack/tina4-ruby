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

    it "has subdirectories" do
      subdirs = Dir.children(gallery_dir).select { |d| File.directory?(File.join(gallery_dir, d)) }
      expect(subdirs.length).to be > 0
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
    it "DevAdmin responds to gallery_list" do
      expect(Tina4::DevAdmin.respond_to?(:gallery_list, true)).to be true
    end

    it "gallery_list returns gallery and count keys" do
      result = Tina4::DevAdmin.send(:gallery_list)
      expect(result).to have_key(:gallery)
      expect(result).to have_key(:count)
    end

    it "gallery_list count matches expected examples" do
      result = Tina4::DevAdmin.send(:gallery_list)
      expect(result[:count]).to eq(expected_examples.length)
    end

    it "each gallery item has id, name, and description" do
      result = Tina4::DevAdmin.send(:gallery_list)
      result[:gallery].each do |item|
        expect(item).to have_key("id")
        expect(item).to have_key("name")
        expect(item).to have_key("description")
      end
    end

    it "each gallery item lists source files" do
      result = Tina4::DevAdmin.send(:gallery_list)
      result[:gallery].each do |item|
        expect(item).to have_key("files")
        expect(item["files"]).to be_a(Array)
        expect(item["files"].length).to be > 0
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
