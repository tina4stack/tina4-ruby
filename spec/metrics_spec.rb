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

  # Each function's raw score covers its whole span, so a branch inside a nested
  # function used to land on that function AND every function around it. The
  # over-count compounded with depth: a wrapper around twenty inner handlers
  # absorbed the whole file and topped the offenders list. Parity with Python
  # master, PHP, Node and the Rust engine.
  describe "nested complexity is measured once" do
    def complexity_by_name(source)
      create_file("nested.rb", source)
      result = Tina4::Metrics.full_analysis(@root)
      (result["all_functions"] || []).each_with_object({}) do |f, acc|
        acc[f["name"]] = f["complexity"]
      end
    end

    it "scores a parent with no branches of its own as one" do
      cc = complexity_by_name(<<~RUBY)
        def outer(a)
          def inner(x)
            return 1 if x
            return 2 if x > 2
            3
          end
          inner(a)
        end
      RUBY
      expect(cc["outer"]).to eq(1)
      expect(cc["inner"]).to eq(3), "the branches moved, not vanished"
    end

    it "lets the parent keep its own branches" do
      cc = complexity_by_name(<<~RUBY)
        def outer(a)
          return 0 if a
          def inner(x)
            return 1 if x
            2
          end
          inner(a)
        end
      RUBY
      expect(cc["outer"]).to eq(2)
      expect(cc["inner"]).to eq(2)
    end

    it "keeps only its own at three levels deep" do
      cc = complexity_by_name(<<~RUBY)
        def a(x)
          return 0 if x
          def b(y)
            return 0 if y
            def c(z)
              return 1 if z
              2
            end
            c(y)
          end
          b(x)
        end
      RUBY
      expect(cc["a"]).to eq(2)
      expect(cc["b"]).to eq(2)
      expect(cc["c"]).to eq(2)
    end

    it "counts a block toward its enclosing method" do
      # Blocks are not reported as methods of their own, so excluding them would
      # LOSE their decisions rather than relocate them.
      cc = complexity_by_name(<<~RUBY)
        class B
          def with_block(items)
            items.map { |i| i.positive? ? 1 : 2 }
          end
        end
      RUBY
      expect(cc["B.with_block"]).to eq(2), "1 + the block's ternary"
    end

    it "never lets sibling methods affect each other" do
      # Guards against an over-eager fix that subtracts from siblings too.
      cc = complexity_by_name(<<~RUBY)
        class A
          def one(x)
            return 1 if x
            2
          end
          def two(y)
            return 1 if y
            2
          end
        end
      RUBY
      expect(cc["A.one"]).to eq(2)
      expect(cc["A.two"]).to eq(2)
    end
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

    it "detects a complexity violation for a method that exceeds the threshold" do
      # Build a method with 12 `when` branches: cyclomatic complexity is
      # 1 (base) + 12 (decision points) = 13, which is above the recommended
      # max of 10 (and below the error threshold of 20), so the analyzer must
      # emit a `moderate_complexity` warning violation for this file.
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

      # The detection must actually fire — not an empty list that a broken
      # detector would also satisfy.
      expect(violations).not_to be_empty

      complexity_violation = violations.find do |v|
        v["file"].to_s.include?("complex.rb") && v["rule"].to_s.include?("complexity")
      end
      expect(complexity_violation).not_to be_nil
      expect(complexity_violation["type"]).to eq("warning")
      expect(complexity_violation["rule"]).to eq("moderate_complexity")
      expect(complexity_violation["message"]).to include("Complex.big_method")

      # And the offending method's COMPUTED complexity must really be above the
      # threshold of 10 (mirrors the `.offenders` complexity assertions in
      # metrics_cli_spec.rb).
      offender = result["most_complex_functions"].find { |f| f["name"] == "Complex.big_method" }
      expect(offender).not_to be_nil
      expect(offender["complexity"]).to be > 10
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

  # Lock-in for the cyclomatic-complexity / method-extraction accuracy fix
  # (mirrors the Python AST analyzer's intent: count REAL branches only, never
  # text inside string/regex/comment literals). Before the fix, decision-point
  # keywords inside strings/comments inflated CC and the method-end finder ran
  # past the real `end` (tiny methods reported CC ~496).
  describe "complexity accuracy (strings/comments/regex are neutralised)" do
    def detail_for(content)
      path = create_file("src/sample.rb", content)
      Tina4::Metrics.file_detail(path)
    end

    def func(detail, name_suffix)
      detail["functions"].find { |f| f["name"].end_with?(name_suffix) }
    end

    it "ignores && / || / if that live inside a STRING literal" do
      detail = detail_for(<<~RUBY)
        class Calc
          def describe_rules
            msg = "use if a && b || c and if d || e while running"
            msg
          end
        end
      RUBY
      f = func(detail, "describe_rules")
      # 1 real branch path only (no decision points) -> CC 1, not inflated.
      expect(f["complexity"]).to eq(1)
      expect(f["loc"]).to eq(4)
    end

    it "ignores decision keywords inside a COMMENT" do
      detail = detail_for(<<~RUBY)
        class Calc
          def plain
            # if this && that || other, while looping unless stopped
            42
          end
        end
      RUBY
      f = func(detail, "plain")
      expect(f["complexity"]).to eq(1)
    end

    it "ignores keywords inside a REGEX literal and a heredoc" do
      detail = detail_for(<<~'RUBY')
        class Calc
          def scan
            re = /if|while|unless|&&|\|\|/
            doc = <<~TXT
              if a && b
              while c || d
            TXT
            [re, doc]
          end
        end
      RUBY
      f = func(detail, "scan")
      expect(f["complexity"]).to eq(1)
    end

    it "does NOT extract a method-shaped substring inside a string" do
      detail = detail_for(<<~RUBY)
        class Holder
          def real_method
            snippet = "def fake_method(x); something(x); end"
            snippet
          end
        end
      RUBY
      names = detail["functions"].map { |f| f["name"] }
      expect(names).to include("Holder.real_method")
      expect(names).not_to include("Holder.fake_method")
      # A bare `something(...)` call inside a string is never a method either.
      expect(names.none? { |n| n.include?("fake_method") }).to be true
      expect(detail["functions"].length).to eq(1)
    end

    it "does NOT over-run the method end on `self.class` (regression: CC ~496)" do
      detail = detail_for(<<~RUBY)
        class Registry
          def add_thing(name, &blk)
            self.class.add_thing(name, &blk)
            @things[name.to_s] = blk
            self
          end

          def add_other(name, value)
            self.class.add_other(name, value)
            @others[name.to_s] = value
            self
          end
        end
      RUBY
      add_thing = func(detail, "add_thing")
      expect(add_thing["complexity"]).to eq(1)
      expect(add_thing["loc"]).to eq(5)
      # Both methods are still detected as separate functions.
      expect(detail["functions"].map { |f| f["name"] }).to contain_exactly(
        "Registry.add_thing", "Registry.add_other"
      )
    end

    it "still reports HIGH complexity for a genuinely branchy method (no real loss)" do
      detail = detail_for(<<~RUBY)
        class Decider
          def classify(a, b, c, d)
            if a && b
              return 1
            elsif c || d
              return 2
            end
            case a
            when 1 then 10
            when 2 then 20
            else
              30
            end
            x = a > 0 ? b : c
            d.times { |i| puts i if i.even? }
            x
          end
        end
      RUBY
      f = func(detail, "classify")
      # if(1) + && (1) + elsif (1) + || (1) + when*2 (2) + ternary (1)
      # + the `if` modifier inside the block (1) = well above 5.
      expect(f["complexity"]).to be >= 8
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

    # Regression (mirrors the Python master fix): a file whose only distinctive
    # top-level constant is <= 3 chars (e.g. `class ORM`) used to be mislabelled
    # UNTESTED because the defined-constant gate excluded names of length <= 3.
    # A spec referencing `Tina4::ORM` must mark orm.rb tested via the constant
    # signal — even with NO dedicated <module>_spec.rb filename match.
    it "detects a 3-char constant (ORM) referenced by a spec" do
      # Source file: only distinctive constant is the 3-char ORM.
      create_file("lib/tina4/orm.rb", <<~RUBY)
        module Tina4
          class ORM
            def save; end
          end
        end
      RUBY
      # Spec references the constant but does NOT match the filename pattern
      # (no orm_spec.rb / orm_test.rb / test_orm.rb) and does NOT require it.
      create_file("spec/persistence_spec.rb", <<~RUBY)
        it "saves" do
          record = Tina4::ORM.new
          record.save
        end
      RUBY

      expect(Tina4::Metrics.send(:_defined_constants, "lib/tina4/orm.rb")).to include("ORM")
      expect(Tina4::Metrics.send(:_has_matching_test, "lib/tina4/orm.rb")).to eq(true)
    end
  end
end
