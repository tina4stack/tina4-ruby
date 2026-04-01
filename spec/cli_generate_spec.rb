# frozen_string_literal: true

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"

RSpec.describe "CLI generate commands" do
  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4_cli_gen_test") do |dir|
      @tmp_dir = dir
      Dir.chdir(dir) do
        example.run
      end
    end
  end

  # ── generate model ─────────────────────────────────────────────

  describe "generate model" do
    it "creates a model file in src/orm/" do
      expect {
        cli.run(["generate", "model", "Product"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "orm", "product.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("class Product < Tina4::ORM")
      expect(content).to include('table_name "product"')
      expect(content).to include("integer_field :id, primary_key: true, auto_increment: true")
    end

    it "creates a model with custom fields" do
      expect {
        cli.run(["generate", "model", "Product", "--fields", "name:string,price:float"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "orm", "product.rb")
      content = File.read(path)
      expect(content).to include("string_field :name")
      expect(content).to include("float_field :price")
    end

    it "generates a matching migration" do
      expect {
        cli.run(["generate", "model", "Product", "--fields", "name:string"])
      }.to output(/Created/).to_stdout

      migrations = Dir.glob(File.join(@tmp_dir, "migrations", "*create_product*.sql"))
      expect(migrations.length).to be >= 1
    end

    it "does not overwrite existing model" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "orm"))
      File.write(File.join(@tmp_dir, "src", "orm", "product.rb"), "existing")

      expect {
        cli.run(["generate", "model", "Product"])
      }.to output(/already exists/).to_stdout

      expect(File.read(File.join(@tmp_dir, "src", "orm", "product.rb"))).to eq("existing")
    end

    it "adds created_at field" do
      expect {
        cli.run(["generate", "model", "Widget"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "orm", "widget.rb"))
      expect(content).to include("created_at")
    end

    it "uses snake_case for CamelCase names" do
      expect {
        cli.run(["generate", "model", "BlogPost"])
      }.to output(/Created/).to_stdout

      expect(File.exist?(File.join(@tmp_dir, "src", "orm", "blog_post.rb"))).to be true
    end
  end

  # ── generate route ─────────────────────────────────────────────

  describe "generate route" do
    it "creates a route file in src/routes/" do
      expect {
        cli.run(["generate", "route", "widgets"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "routes", "widgets.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("/api/widgets")
    end

    it "creates a route with model reference" do
      expect {
        cli.run(["generate", "route", "products", "--model", "Product"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "src", "routes", "products.rb"))
      expect(content).to include("Product")
      expect(content).to include("product")
    end

    it "does not overwrite existing route" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "routes"))
      File.write(File.join(@tmp_dir, "src", "routes", "widgets.rb"), "existing")

      expect {
        cli.run(["generate", "route", "widgets"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate migration ─────────────────────────────────────────

  describe "generate migration" do
    it "creates a migration file with timestamp" do
      expect {
        cli.run(["generate", "migration", "add_status_to_orders"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*.sql"))
      expect(files.length).to be >= 1

      filename = File.basename(files.first)
      expect(filename).to match(/^\d{14}_add_status_to_orders/)
    end

    it "creates create table SQL for create_ prefixed migrations" do
      expect {
        cli.run(["generate", "migration", "create_orders", "--fields", "name:string,total:float"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*create_orders.sql"))
      content = File.read(files.first)
      expect(content).to include("CREATE TABLE IF NOT EXISTS")
      expect(content).to include("name VARCHAR(255)")
      expect(content).to include("total REAL")
    end

    it "creates a .down.sql rollback file" do
      expect {
        cli.run(["generate", "migration", "create_items"])
      }.to output(/Created/).to_stdout

      down_files = Dir.glob(File.join(@tmp_dir, "migrations", "*create_items.down.sql"))
      expect(down_files.length).to eq(1)
    end

    it "creates placeholder SQL for non-create migrations" do
      expect {
        cli.run(["generate", "migration", "add_email_to_users"])
      }.to output(/Created/).to_stdout

      files = Dir.glob(File.join(@tmp_dir, "migrations", "*add_email_to_users.sql"))
      content = File.read(files.first)
      expect(content).to include("-- Write your UP migration SQL here")
    end
  end

  # ── generate middleware ─────────────────────────────────────────

  describe "generate middleware" do
    it "creates a middleware file" do
      expect {
        cli.run(["generate", "middleware", "RateLimiter"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "src", "middleware", "rate_limiter.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("class RateLimiter")
      expect(content).to include("def self.before_rate_limiter")
      expect(content).to include("def self.after_rate_limiter")
    end

    it "does not overwrite existing middleware" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "src", "middleware"))
      File.write(File.join(@tmp_dir, "src", "middleware", "rate_limiter.rb"), "existing")

      expect {
        cli.run(["generate", "middleware", "RateLimiter"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate test ──────────────────────────────────────────────

  describe "generate test" do
    it "creates a spec file" do
      expect {
        cli.run(["generate", "test", "widgets"])
      }.to output(/Created/).to_stdout

      path = File.join(@tmp_dir, "spec", "widgets_spec.rb")
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("RSpec.describe")
    end

    it "creates a model-aware spec when --model is given" do
      expect {
        cli.run(["generate", "test", "products", "--model", "Product"])
      }.to output(/Created/).to_stdout

      content = File.read(File.join(@tmp_dir, "spec", "products_spec.rb"))
      expect(content).to include("Product")
      expect(content).to include("creates a product")
      expect(content).to include("deletes a product")
    end

    it "does not overwrite existing spec" do
      FileUtils.mkdir_p(File.join(@tmp_dir, "spec"))
      File.write(File.join(@tmp_dir, "spec", "widgets_spec.rb"), "existing")

      expect {
        cli.run(["generate", "test", "widgets"])
      }.to output(/already exists/).to_stdout
    end
  end

  # ── generate with missing name ─────────────────────────────────

  describe "missing name argument" do
    it "exits with error for generate model without name" do
      expect {
        begin
          cli.run(["generate", "model"])
        rescue SystemExit
          # expected
        end
      }.to output(/Usage/).to_stdout
    end

    it "exits with error for generate without subcommand" do
      expect {
        begin
          cli.run(["generate"])
        rescue SystemExit
          # expected
        end
      }.to output(/Usage/).to_stdout
    end

    it "exits with error for unknown generator" do
      expect {
        begin
          cli.run(["generate", "foobar", "Widget"])
        rescue SystemExit
          # expected
        end
      }.to output(/Unknown generator/).to_stdout
    end
  end

  # ── Helper methods ─────────────────────────────────────────────

  describe "helper methods" do
    it "to_snake_case converts CamelCase" do
      expect(cli.send(:to_snake_case, "BlogPost")).to eq("blog_post")
      expect(cli.send(:to_snake_case, "HTMLParser")).to eq("html_parser")
      expect(cli.send(:to_snake_case, "simple")).to eq("simple")
    end

    it "parse_fields parses comma-separated field definitions" do
      fields = cli.send(:parse_fields, "name:string,price:float,count:integer")
      expect(fields).to eq([["name", "string"], ["price", "float"], ["count", "integer"]])
    end

    it "parse_fields handles fields without type (defaults to string)" do
      fields = cli.send(:parse_fields, "name,email")
      expect(fields).to eq([["name", "string"], ["email", "string"]])
    end

    it "parse_fields handles nil input" do
      expect(cli.send(:parse_fields, nil)).to eq([])
    end

    it "parse_fields handles empty string" do
      expect(cli.send(:parse_fields, "")).to eq([])
    end

    it "to_table_name uses snake_case" do
      expect(cli.send(:to_table_name, "BlogPost")).to eq("blog_post")
    end
  end

  # ── FIELD_TYPE_MAP ─────────────────────────────────────────────

  describe "FIELD_TYPE_MAP" do
    it "maps string types to string_field" do
      expect(Tina4::CLI::FIELD_TYPE_MAP["string"][:orm]).to eq("string_field")
      expect(Tina4::CLI::FIELD_TYPE_MAP["str"][:orm]).to eq("string_field")
    end

    it "maps integer types to integer_field" do
      expect(Tina4::CLI::FIELD_TYPE_MAP["integer"][:orm]).to eq("integer_field")
      expect(Tina4::CLI::FIELD_TYPE_MAP["int"][:orm]).to eq("integer_field")
    end

    it "maps float types to float_field" do
      expect(Tina4::CLI::FIELD_TYPE_MAP["float"][:orm]).to eq("float_field")
      expect(Tina4::CLI::FIELD_TYPE_MAP["decimal"][:orm]).to eq("float_field")
    end

    it "maps boolean types to boolean_field" do
      expect(Tina4::CLI::FIELD_TYPE_MAP["bool"][:orm]).to eq("boolean_field")
      expect(Tina4::CLI::FIELD_TYPE_MAP["boolean"][:orm]).to eq("boolean_field")
    end

    it "includes SQL type mappings" do
      expect(Tina4::CLI::FIELD_TYPE_MAP["string"][:sql]).to eq("VARCHAR(255)")
      expect(Tina4::CLI::FIELD_TYPE_MAP["integer"][:sql]).to eq("INTEGER")
      expect(Tina4::CLI::FIELD_TYPE_MAP["text"][:sql]).to eq("TEXT")
    end
  end
end
