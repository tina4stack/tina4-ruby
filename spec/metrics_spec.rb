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
      (result["most_complex_functions"] || []).each_with_object({}) do |f, acc|
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

  # Method LOC used to be a raw line span while file LOC excluded blanks and
  # comments, so `loc` meant two different things in one payload.
  describe "method LOC counts code lines" do
    it "excludes blank lines and comments" do
      create_file("loc.rb", <<~RUBY)
        class A
          # a comment
          def with_comments(x)

            # another comment

            return 1 if x
            2
          end
        end
      RUBY
      result = Tina4::Metrics.full_analysis(@root)
      by_name = (result["most_complex_functions"] || []).to_h { |f| [f["name"], f["loc"]] }
      # Code lines are def + modifier-if + 2 + end.
      expect(by_name["A.with_comments"]).to eq(4)
    end

    it "never reports zero" do
      create_file("loc.rb", "def f\n  1\nend\n")
      result = Tina4::Metrics.full_analysis(@root)
      expect(result["most_complex_functions"].first["loc"]).to be >= 1
    end

    it "uses the same rule as file LOC" do
      # A file that is one single method: the two numbers must agree, which only
      # holds if both count the same thing.
      create_file("loc.rb", "def only(x)\n  # comment\n\n  x\nend\n")
      result = Tina4::Metrics.full_analysis(@root)
      expect(result["most_complex_functions"].first["loc"]).to eq(result["file_metrics"].first["loc"])
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
    it "falls back to a framework scan for a missing directory" do
      # Verified against the Python master AND PHP: _resolve_root deliberately
      # scans the framework package when the target has no source, so the
      # dashboard is never empty. scan_mode reports which one was measured.
      result = Tina4::Metrics.full_analysis("nonexistent")
      expect(result["scan_mode"]).to eq("framework")
      expect(result["files_analyzed"]).to be > 0
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

      # `violations` was the deleted analyzer's key. The engine publishes one
      # ranked `offenders` list instead, and its own --fail-on gate reads that
      # same list, so the dashboard and the build cannot disagree.
      expect(result).not_to have_key("violations")

      found = Tina4::Metrics.offenders("src", 2**31)["offenders"]
      # The detection must actually fire -- not an empty list that a broken
      # detector would also satisfy.
      expect(found).not_to be_empty

      complexity_offender = found.find do |o|
        o["file"].to_s.include?("complex.rb") && o["kind"] == "complexity"
      end
      expect(complexity_offender).not_to be_nil
      expect(complexity_offender["detail"]).to include("Complex.big_method")

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
    it "raises for a missing file and names the path" do
      expect { Tina4::Metrics.file_detail("no_such_file.rb") }
        .to raise_error(Tina4::MetricsEngineError, /no such file: no_such_file\.rb/)
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
      # The engine's per-file shape: `functions` is a COUNT, dependencies are
      # counted rather than listed, and there is no `classes` / `imports` key.
      expect(result["functions"]).to eq(1)
      expect(result["dep_count"]).to be >= 1
      expect(result["engine"]).to eq("tina4-cli")
      expect(result).not_to have_key("classes")
      expect(result).not_to have_key("imports")
    end
  end

  # Lock-in for the cyclomatic-complexity / method-extraction accuracy fix
  # (mirrors the Python AST analyzer's intent: count REAL branches only, never
  # text inside string/regex/comment literals). Before the fix, decision-point
  # keywords inside strings/comments inflated CC and the method-end finder ran
  # past the real `end` (tiny methods reported CC ~496).
  describe "complexity accuracy (strings/comments/regex are neutralised)" do
    # The engine reports per-file `functions` as a COUNT; per-function detail
    # lives in the scan's most_complex_functions. Attach that list under a
    # distinct key so every call site below keeps working unchanged.
    def detail_for(content)
      path = create_file("src/sample.rb", content)
      Tina4::Metrics.file_detail(path).merge(
        "function_list" => Tina4::Metrics.full_analysis(File.dirname(path))["most_complex_functions"]
      )
    end

    def func(detail, name_suffix)
      detail["function_list"].find { |f| f["name"].end_with?(name_suffix) }
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
      names = detail["function_list"].map { |f| f["name"] }
      expect(names).to include("Holder.real_method")
      expect(names).not_to include("Holder.fake_method")
      # A bare `something(...)` call inside a string is never a method either.
      expect(names.none? { |n| n.include?("fake_method") }).to be true
      expect(detail["function_list"].length).to eq(1)
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
      expect(detail["function_list"].map { |f| f["name"] }).to contain_exactly(
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

  # Test detection moved into the engine (ADR-0002). The private
  # _has_matching_test / _defined_constants helpers are gone, so these assert the
  # SAME claims through the engine's public `has_tests` flag: a dedicated test
  # filename counts, an unreferenced module does not, and a SHORT constant
  # (class ORM) that a spec references counts -- that last one was a real bug, a
  # length gate excluded exactly the short framework types that matter most.
  describe "has_tests detection (through the engine)" do
    def has_tests_for(rel_path)
      analysis = Tina4::Metrics.full_analysis(File.join(@root, "lib"))
      entry = analysis["file_metrics"].find { |f| f["path"].end_with?(File.basename(rel_path)) }
      expect(entry).not_to be_nil, "engine reported no metrics for #{rel_path}"
      entry["has_tests"]
    end

    it "counts a dedicated <module>_spec.rb file" do
      create_file("lib/tina4/router.rb", "module Tina4\n  class Router\n  end\nend\n")
      create_file("spec/router_spec.rb", "# test\n")
      expect(has_tests_for("lib/tina4/router.rb")).to eq(true)
    end

    it "counts a dedicated <module>_test.rb file" do
      create_file("lib/tina4/router.rb", "module Tina4\n  class Router\n  end\nend\n")
      create_file("test/router_test.rb", "# test\n")
      expect(has_tests_for("lib/tina4/router.rb")).to eq(true)
    end

    it "counts a test_ prefixed file" do
      create_file("lib/tina4/router.rb", "module Tina4\n  class Router\n  end\nend\n")
      create_file("test/test_router.rb", "# test\n")
      expect(has_tests_for("lib/tina4/router.rb")).to eq(true)
    end

    it "reports UNTESTED when nothing references the module" do
      create_file("lib/tina4/lonely.rb", "module Tina4\n  class Lonely\n  end\nend\n")
      create_file("spec/something_else_spec.rb", "# unrelated\n")
      expect(has_tests_for("lib/tina4/lonely.rb")).to eq(false)
    end

    it "counts a 3-char constant (ORM) a spec references, with no filename match" do
      create_file("lib/tina4/orm.rb", <<~RUBY)
        module Tina4
          class ORM
            def save; end
          end
        end
      RUBY
      # Deliberately NOT orm_spec.rb -- the constant is the only signal.
      create_file("spec/persistence_spec.rb", <<~RUBY)
        require "spec_helper"
        RSpec.describe Tina4::ORM do
          it "saves" do
            expect(Tina4::ORM.new.save).to be_nil
          end
        end
      RUBY
      expect(has_tests_for("lib/tina4/orm.rb")).to eq(true)
    end
  end
end
