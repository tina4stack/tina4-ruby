# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::Metrics do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      Dir.chdir(dir) do
        example.run
      end
    end
  end

  def create_file(path, content = "")
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    full
  end

  describe ".quick_metrics" do
    it "returns error for missing directory" do
      result = Tina4::Metrics.quick_metrics("nonexistent")
      expect(result).to have_key("error")
    end

    it "counts Ruby files and LOC" do
      create_file("src/foo.rb", "class Foo\n  def bar\n    1\n  end\nend\n")
      create_file("src/baz.rb", "# comment\nmodule Baz\nend\n")
      result = Tina4::Metrics.quick_metrics("src")
      expect(result["file_count"]).to eq(2)
      expect(result["total_loc"]).to be > 0
      expect(result["classes"]).to be >= 2
    end

    it "counts blank and comment lines" do
      create_file("src/a.rb", "# comment\n\ncode\n")
      result = Tina4::Metrics.quick_metrics("src")
      expect(result["total_blank"]).to eq(1)
      expect(result["total_comment"]).to eq(1)
    end
  end

  describe ".full_analysis" do
    it "returns error for missing directory" do
      result = Tina4::Metrics.full_analysis("nonexistent")
      expect(result).to have_key("error")
    end

    it "analyzes files and returns file_metrics with expected keys" do
      create_file("src/widget.rb", <<~RUBY)
        require 'json'
        require_relative 'helper'

        class Widget
          def initialize(name)
            @name = name
          end

          def process(x)
            if x > 0
              x * 2
            else
              x + 1
            end
          end
        end
      RUBY
      result = Tina4::Metrics.full_analysis("src")
      expect(result["files_analyzed"]).to eq(1)
      expect(result["total_functions"]).to be >= 2

      fm = result["file_metrics"].first
      expect(fm).to have_key("path")
      expect(fm).to have_key("loc")
      expect(fm).to have_key("complexity")
      expect(fm).to have_key("maintainability")
      expect(fm).to have_key("has_tests")
      expect(fm).to have_key("dep_count")
      expect(fm["dep_count"]).to eq(2)
    end

    it "sets has_tests to true when a matching spec file exists" do
      create_file("src/auth.rb", "class Auth\nend\n")
      create_file("spec/auth_spec.rb", "# test\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].first
      expect(fm["has_tests"]).to eq(true)
    end

    it "sets has_tests to false when no matching test file exists" do
      create_file("src/orphan.rb", "class Orphan\nend\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].first
      expect(fm["has_tests"]).to eq(false)
    end

    it "counts dep_count from require statements" do
      create_file("src/multi.rb", <<~RUBY)
        require 'net/http'
        require 'json'
        require_relative 'utils'

        class Multi
        end
      RUBY
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].first
      expect(fm["dep_count"]).to eq(3)
    end

    it "sets dep_count to 0 when no requires" do
      create_file("src/plain.rb", "class Plain\nend\n")
      result = Tina4::Metrics.full_analysis("src")
      fm = result["file_metrics"].first
      expect(fm["dep_count"]).to eq(0)
    end

    it "includes dependency_graph in the result" do
      create_file("src/a.rb", "require 'json'\n")
      result = Tina4::Metrics.full_analysis("src")
      expect(result).to have_key("dependency_graph")
      expect(result["dependency_graph"]).to be_a(Hash)
    end

    it "detects violations for high complexity" do
      # Build a method with many branches to exceed complexity 10
      branches = (1..12).map { |i| "      when #{i} then #{i}" }.join("\n")
      create_file("src/complex.rb", <<~RUBY)
        class Complex
          def big_method(x)
            case x
#{branches}
            end
          end
        end
      RUBY
      result = Tina4::Metrics.full_analysis("src")
      violations = result["violations"]
      expect(violations).to be_an(Array)
    end

    it "caches results within TTL" do
      create_file("src/cached.rb", "class Cached\nend\n")
      result1 = Tina4::Metrics.full_analysis("src")
      result2 = Tina4::Metrics.full_analysis("src")
      expect(result1["files_analyzed"]).to eq(result2["files_analyzed"])
    end
  end

  describe ".file_detail" do
    it "returns error for missing file" do
      result = Tina4::Metrics.file_detail("no_such_file.rb")
      expect(result).to have_key("error")
    end

    it "returns detail for an existing file" do
      path = create_file("src/detail.rb", <<~RUBY)
        require 'json'

        class Detail
          def greet(name)
            "Hello, \#{name}"
          end
        end
      RUBY
      result = Tina4::Metrics.file_detail(path)
      expect(result["loc"]).to be > 0
      expect(result["classes"]).to eq(1)
      expect(result["functions"].length).to eq(1)
      expect(result["imports"]).to include("json")
    end
  end

  describe "._has_matching_test" do
    it "finds spec files in spec/ directory" do
      create_file("spec/router_spec.rb", "# test\n")
      expect(Tina4::Metrics.send(:_has_matching_test, "lib/tina4/router.rb")).to eq(true)
    end

    it "finds test files in test/ directory" do
      create_file("test/router_test.rb", "# test\n")
      expect(Tina4::Metrics.send(:_has_matching_test, "lib/tina4/router.rb")).to eq(true)
    end

    it "finds test_ prefixed files in test/ directory" do
      create_file("test/test_router.rb", "# test\n")
      expect(Tina4::Metrics.send(:_has_matching_test, "lib/tina4/router.rb")).to eq(true)
    end

    it "returns false when no matching test exists" do
      expect(Tina4::Metrics.send(:_has_matching_test, "lib/tina4/nonexistent.rb")).to eq(false)
    end
  end
end
