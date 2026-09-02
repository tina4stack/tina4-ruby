# frozen_string_literal: true
#
# `generate model` on a reserved-word class name (issue #123).
#
# The scaffolder no longer renames silently: it auto-pluralises a reserved-word
# table (`Order` -> `orders`, the SAFE choice, because Tina4 interpolates table
# names UNQUOTED) but says so out loud, and `--table-name` lets the developer
# force their own name (owning the quoting in raw SQL if it is itself reserved).
# No ORM quoting change -- identifier quoting is a global storage invariant, not
# a local fix, so that footgun stays shut.
#
# Mirrors tina4-python/tests/test_gen_model_reserved_table.py. NO mocks: the
# resolver is a pure method; the end-to-end cases generate a REAL model file
# (in-process AND via the real exe/tina4ruby subprocess) and read it back.

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "stringio"
require "fileutils"
require "open3"

RSpec.describe "generate model — reserved-word table resolver (#123)" do
  let(:cli) { Tina4::CLI.new }

  # Swap $stdout for a StringIO, run the block, return everything it printed.
  # resolve_table / generate_model use `puts`, so this captures the note/warning.
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  # ── Pure resolver ────────────────────────────────────────────────────
  describe "#resolve_table" do
    it "keeps a non-reserved class singular and prints nothing" do
      result = nil
      out = capture_stdout { result = cli.send(:resolve_table, "Product", {}, announce: true) }
      expect(result).to eq("product")
      expect(out).to eq("")
    end

    it "pluralises a reserved class with a loud note WHEN announcing" do
      result = nil
      out = capture_stdout { result = cli.send(:resolve_table, "Order", {}, announce: true) }
      expect(result).to eq("orders")
      expect(out).to include("order")
      expect(out).to include("reserved")
      expect(out).to include("--table-name")
    end

    it "pluralises a reserved class SILENTLY when NOT announcing" do
      # Composite / existing-table generators resolve the same name without
      # repeating the note.
      result = nil
      out = capture_stdout { result = cli.send(:resolve_table, "Order", {}) }
      expect(result).to eq("orders")
      expect(out).to eq("")
    end

    it "uses --table-name verbatim with no warning for a non-reserved override" do
      result = nil
      out = capture_stdout do
        result = cli.send(:resolve_table, "Order", { "table-name" => "customer_orders" }, announce: true)
      end
      expect(result).to eq("customer_orders")
      expect(out).to eq("") # a non-reserved override needs no warning
    end

    it "warns but OBEYS when a reserved word is forced via --table-name" do
      result = nil
      out = capture_stdout do
        result = cli.send(:resolve_table, "Order", { "table-name" => "select" }, announce: true)
      end
      expect(result).to eq("select")
      expect(out).to include("select")
      expect(out).to include("reserved")
      expect(out).to include("UNQUOTED")
    end

    it "ignores a bare --table-name flag (parsed to true)" do
      # `--table-name` with no value parses to true; it must not become the table.
      result = nil
      capture_stdout { result = cli.send(:resolve_table, "Order", { "table-name" => true }, announce: true) }
      expect(result).to eq("orders")
    end

    it "ignores an empty --table-name '' (Ruby truthiness guard)" do
      # "" is truthy in Ruby (unlike Python), so the guard must reject it
      # explicitly, else it would silently become the table name.
      result = nil
      capture_stdout { result = cli.send(:resolve_table, "Order", { "table-name" => "" }, announce: true) }
      expect(result).to eq("orders")
    end
  end

  # ── End-to-end: real generator method, real file on disk ─────────────
  describe "generate model (in-process, real file)" do
    around(:each) do |example|
      Dir.mktmpdir("tina4_gen_model_reserved") do |dir|
        @tmp_dir = dir
        Dir.chdir(dir) { example.run }
      end
    end

    it "gives a reserved class a plural table_name AND prints a note" do
      out = capture_stdout do
        cli.send(:generate_model, "Order", { "no-migration" => true }, emit_test: false)
      end
      content = File.read(File.join(@tmp_dir, "src", "orm", "order.rb"))
      expect(content).to include('table_name "orders"')
      expect(out).to include("reserved")
    end

    it "uses --table-name verbatim in the generated model" do
      capture_stdout do
        cli.send(:generate_model, "Order",
                 { "no-migration" => true, "table-name" => "my_orders" }, emit_test: false)
      end
      content = File.read(File.join(@tmp_dir, "src", "orm", "order.rb"))
      expect(content).to include('table_name "my_orders"')
    end
  end

  # ── End-to-end: the real CLI process (does-it-run through the full path) ──
  # Proves the note reaches STDOUT exactly ONCE through the resolution-aware
  # wrapper (the sandbox edit-hint pre-run captures its own stdout, so it must
  # not leak a second copy).
  describe "tina4ruby generate model (real subprocess)" do
    around(:each) do |example|
      Dir.mktmpdir("tina4_gen_model_reserved_exe") do |dir|
        @project_root = dir
        example.run
      end
    end

    it "prints the reserved-word note exactly once and writes table_name \"orders\"" do
      stdout, stderr, status = Open3.capture3(
        RUBY_BIN, EXE, "generate", "model", "Order", chdir: @project_root
      )
      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      # The child emits UTF-8 (the note's `·`); Open3 tags the capture US-ASCII,
      # so re-tag before scanning a string that carries a multibyte glyph.
      stdout = stdout.force_encoding("UTF-8")
      expect(stdout.scan("is a SQL reserved word").length).to eq(1)

      model_path = File.join(@project_root, "src", "orm", "order.rb")
      expect(File.exist?(model_path)).to be true
      expect(File.read(model_path)).to include('table_name "orders"')
    end

    it "honours --table-name my_orders end-to-end" do
      stdout, stderr, status = Open3.capture3(
        RUBY_BIN, EXE, "generate", "model", "Order", "--table-name", "my_orders",
        chdir: @project_root
      )
      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      stdout = stdout.force_encoding("UTF-8")
      # A non-reserved override is silent — no note.
      expect(stdout).not_to include("is a SQL reserved word")

      model_path = File.join(@project_root, "src", "orm", "order.rb")
      expect(File.read(model_path)).to include('table_name "my_orders"')
    end
  end
end
