# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "tina4/project_index"

RSpec.describe Tina4::ProjectIndex do
  around(:each) do |ex|
    Dir.mktmpdir("tina4idx") do |tmp|
      Dir.chdir(tmp) { ex.run }
    end
  end

  def write(rel, content)
    path = File.join(Dir.pwd, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe "Ruby extractor" do
    it "captures class/module symbols, require_relative imports, and routes" do
      src = <<~RUBY
        # A users route resource
        require_relative "../app/helpers"
        module MyApp
          class UsersController
          end
        end
        Tina4::Router.get("/api/users") { |req, res| res.call({ ok: true }) }
        Tina4.post "/api/users" do |req, res|
          res.call({})
        end
      RUBY
      out = described_class.extract_ruby(src)
      expect(out["symbols"]).to include("MyApp", "UsersController")
      expect(out["imports"]).to include("../app/helpers")
      methods = out["routes"].map { |r| r["method"] }
      paths   = out["routes"].map { |r| r["path"] }
      expect(methods).to include("GET", "POST")
      expect(paths).to include("/api/users")
      expect(out["docstring"]).to eq("A users route resource")
    end
  end

  describe "SQL extractor" do
    it "captures CREATE TABLE / CREATE INDEX / ALTER TABLE" do
      sql = "CREATE TABLE users (id INT);\nCREATE UNIQUE INDEX idx_email ON users(email);\nALTER TABLE users ADD COLUMN age INT;"
      out = described_class.extract_sql(sql)
      expect(out["creates"]).to include("TABLE users", "INDEX idx_email")
      expect(out["alters"]).to include("TABLE users")
    end
  end

  describe "Twig extractor" do
    it "captures extends, blocks, includes" do
      tpl = %({% extends "base.twig" %}\n{% block content %}Hi{% endblock %}\n{% include "partials/nav.twig" %}\n)
      out = described_class.extract_twig(tpl)
      expect(out["extends"]).to eq(["base.twig"])
      expect(out["blocks"]).to include("content")
      expect(out["includes"]).to include("partials/nav.twig")
    end
  end

  describe "Markdown extractor" do
    it "grabs title and sections" do
      md = "# Title\n\n## First\n\nbody\n\n## Second\n"
      out = described_class.extract_md(md)
      expect(out["title"]).to eq("Title")
      expect(out["sections"]).to eq(["First", "Second"])
    end
  end

  describe ".refresh + .search + .overview" do
    it "indexes a small tree and finds entries by symbol/path" do
      write("src/routes/users.rb", "# Users routes\nTina4::Router.get(\"/api/users\") { |r, s| s.call({}) }\nclass UsersService\nend\n")
      write("src/orm/User.rb", "class User < Tina4::ORM\nend\n")
      write("migrations/001_users.sql", "CREATE TABLE users (id INT);")

      stats = described_class.refresh
      expect(stats["total"]).to be >= 3
      expect(stats["added"]).to be >= 3

      hits = described_class.search("UsersService")
      expect(hits).not_to be_empty
      expect(hits.first["path"]).to eq("src/routes/users.rb")

      overview = described_class.overview
      expect(overview["total_files"]).to be >= 3
      expect(overview["by_language"]["ruby"]).to be >= 2
      expect(overview["routes_declared"]).to be >= 1
      expect(overview["orm_models"]).to be >= 1
    end

    it "file_entry returns a single entry" do
      write("README.md", "# Project\n\n## Intro\n")
      described_class.refresh
      entry = described_class.file_entry("README.md")
      expect(entry["language"]).to eq("markdown")
      expect(entry["title"]).to eq("Project")
    end

    it "drops removed files on re-refresh" do
      write("tmpfile.md", "# gone")
      described_class.refresh
      File.delete("tmpfile.md")
      stats = described_class.refresh
      expect(stats["removed"]).to be >= 1
    end
  end
end
