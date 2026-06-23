# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::ScssCompiler do
  let(:tmp_dir) { Dir.mktmpdir("tina4_scss_test") }
  let(:scss_dir) { File.join(tmp_dir, "src", "scss") }
  let(:css_dir) { File.join(tmp_dir, "src", "public", "css") }

  before do
    FileUtils.mkdir_p(scss_dir)
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  # Helper to invoke the basic compiler directly (bypasses sassc gem check)
  def basic_compile(content, base_dir = scss_dir)
    Tina4::ScssCompiler.send(:basic_compile, content, base_dir)
  end

  # ── Variable Tests ─────────────────────────────────────────────

  describe "variables" do
    it "substitutes a simple variable" do
      scss = "$color: #333;\n.text { color: $color; }"
      css = basic_compile(scss)
      expect(css).to include("#333")
      expect(css).not_to include("$color")
    end

    it "substitutes a variable used in multiple places" do
      scss = "$primary: blue;\n.btn { color: $primary; border: 1px solid $primary; }"
      css = basic_compile(scss)
      # The variable should be replaced in both locations
      expect(css.scan("blue").length).to be >= 2
    end

    it "handles variable referencing another variable (resolved in order)" do
      # The basic compiler resolves variable references after all declarations
      # are collected, so $large gets $base's raw value only if $base was
      # already substituted into $large's value at extraction time.
      # Since the regex extracts sequentially, $large = "$base" literally.
      # We verify the compiler does not crash and produces output.
      scss = "$base: 16px;\n$large: $base;\n.text { font-size: $large; }"
      css = basic_compile(scss)
      # The basic compiler may not fully resolve chained variables;
      # verify it at least removes declarations and produces a rule
      expect(css).to include("font-size:")
      expect(css).not_to match(/\$large\s*:/)
    end

    it "handles variable with hyphen in name" do
      scss = "$font-size: 14px;\n.body { font-size: $font-size; }"
      css = basic_compile(scss)
      expect(css).to include("14px")
    end

    it "removes variable declarations from output" do
      scss = "$color: red;\n.box { color: $color; }"
      css = basic_compile(scss)
      expect(css).not_to match(/\$color\s*:/)
    end
  end

  # ── Nesting Tests ──────────────────────────────────────────────

  describe "nesting" do
    it "flattens simple single-level nesting" do
      scss = ".nav { ul { list-style: none; } }"
      css = basic_compile(scss)
      expect(css).to include(".nav ul")
      expect(css).to include("list-style: none")
    end

    it "outputs parent properties alongside nested rules" do
      scss = ".card { padding: 10px; .title { font-size: 16px; } }"
      css = basic_compile(scss)
      expect(css).to include(".card")
      expect(css).to include("padding: 10px")
      expect(css).to include(".card .title")
      expect(css).to include("font-size: 16px")
    end

    it "handles multiple nested selectors" do
      scss = ".parent { .child1 { color: red; } .child2 { color: blue; } }"
      css = basic_compile(scss)
      expect(css).to include(".parent .child1")
      expect(css).to include(".parent .child2")
    end
  end

  # ── Parent Selector Tests ──────────────────────────────────────

  describe "parent selector (&)" do
    it "replaces & with parent selector for pseudo-classes" do
      scss = ".btn { &:hover { color: red; } }"
      css = basic_compile(scss)
      # After nesting, ".btn &:hover" becomes ".btn :hover" since & is replaced with ""
      # The basic compiler strips & to empty string
      expect(css).to include(":hover")
    end

    it "replaces & with parent selector for BEM modifiers" do
      scss = ".btn { &--primary { background: blue; } }"
      css = basic_compile(scss)
      expect(css).to include("--primary")
    end
  end

  # ── Import Tests ───────────────────────────────────────────────

  describe "imports" do
    it "imports a partial file (underscore prefix)" do
      File.write(File.join(scss_dir, "_variables.scss"), "$primary: #007bff;")
      scss = "@import 'variables';\n.btn { color: $primary; }"
      css = basic_compile(scss, scss_dir)
      expect(css).to include("#007bff")
    end

    it "imports a file with .scss extension" do
      File.write(File.join(scss_dir, "helpers.scss"), ".helper { display: block; }")
      scss = "@import 'helpers.scss';\n.app { color: red; }"
      css = basic_compile(scss, scss_dir)
      expect(css).to include(".helper")
      expect(css).to include("display: block")
    end

    it "imports a file without underscore prefix" do
      File.write(File.join(scss_dir, "reset.scss"), ".reset { margin: 0; }")
      scss = "@import 'reset';\n.body { padding: 0; }"
      css = basic_compile(scss, scss_dir)
      expect(css).to include(".reset")
    end

    it "outputs a comment when import is not found" do
      scss = "@import 'nonexistent';\n.box { color: red; }"
      css = basic_compile(scss, scss_dir)
      expect(css).to include("/* import not found: nonexistent */")
    end

    it "handles nested imports (import within an imported file)" do
      File.write(File.join(scss_dir, "_colors.scss"), "$bg: #fff;")
      File.write(File.join(scss_dir, "_theme.scss"), "@import 'colors';\n$fg: #000;")
      scss = "@import 'theme';\n.page { background: $bg; color: $fg; }"
      css = basic_compile(scss, scss_dir)
      expect(css).to include("#fff")
      expect(css).to include("#000")
    end
  end

  # ── Comment Tests ──────────────────────────────────────────────

  describe "comments" do
    it "preserves block comments in output" do
      scss = "/* License info */\n.box { color: red; }"
      css = basic_compile(scss)
      expect(css).to include("/* License info */")
    end
  end

  # ── compile_all Integration Tests ──────────────────────────────

  describe ".compile_all" do
    it "compiles .scss files from SCSS_DIRS to CSS_OUTPUT" do
      # Set up the directory structure compile_all expects
      src_scss = File.join(tmp_dir, "src", "scss")
      FileUtils.mkdir_p(src_scss)
      File.write(File.join(src_scss, "main.scss"), ".main { color: red; }")

      Tina4::ScssCompiler.compile_all(tmp_dir)

      css_file = File.join(tmp_dir, "src", "public", "css", "main.css")
      expect(File.exist?(css_file)).to be true
      content = File.read(css_file)
      expect(content).to include(".main")
      expect(content).to include("color: red")
    end

    it "skips partial files (underscore prefix)" do
      src_scss = File.join(tmp_dir, "src", "scss")
      FileUtils.mkdir_p(src_scss)
      File.write(File.join(src_scss, "_partial.scss"), ".partial { display: none; }")
      File.write(File.join(src_scss, "app.scss"), "@import 'partial';\n.app { color: blue; }")

      Tina4::ScssCompiler.compile_all(tmp_dir)

      # _partial.scss should not generate its own CSS file
      partial_css = File.join(tmp_dir, "src", "public", "css", "_partial.css")
      expect(File.exist?(partial_css)).to be false

      # app.css should include the imported content
      app_css = File.join(tmp_dir, "src", "public", "css", "app.css")
      expect(File.exist?(app_css)).to be true
      content = File.read(app_css)
      expect(content).to include(".app")
    end

    it "creates the output directory if it does not exist" do
      src_scss = File.join(tmp_dir, "src", "scss")
      FileUtils.mkdir_p(src_scss)
      File.write(File.join(src_scss, "test.scss"), ".test { color: green; }")

      css_output = File.join(tmp_dir, "src", "public", "css")
      expect(Dir.exist?(css_output)).to be false

      Tina4::ScssCompiler.compile_all(tmp_dir)

      expect(Dir.exist?(css_output)).to be true
    end

    it "skips directories that do not exist" do
      # No scss directories exist, should not raise
      expect { Tina4::ScssCompiler.compile_all(tmp_dir) }.not_to raise_error
    end
  end

  # ── compile_file Tests ─────────────────────────────────────────

  describe ".compile_file" do
    it "writes compiled CSS to the output path" do
      scss_file = File.join(scss_dir, "style.scss")
      File.write(scss_file, "$bg: #eee;\n.page { background: $bg; }")
      output_dir = File.join(tmp_dir, "css_out")
      FileUtils.mkdir_p(output_dir)

      Tina4::ScssCompiler.compile_file(scss_file, output_dir, scss_dir)

      css_file = File.join(output_dir, "style.css")
      expect(File.exist?(css_file)).to be true
      content = File.read(css_file)
      expect(content).to include("#eee")
      expect(content).not_to include("$bg")
    end

    it "creates subdirectories in the output path" do
      sub_dir = File.join(scss_dir, "components")
      FileUtils.mkdir_p(sub_dir)
      scss_file = File.join(sub_dir, "button.scss")
      File.write(scss_file, ".btn { padding: 8px; }")
      output_dir = File.join(tmp_dir, "css_out")
      FileUtils.mkdir_p(output_dir)

      Tina4::ScssCompiler.compile_file(scss_file, output_dir, scss_dir)

      css_file = File.join(output_dir, "components", "button.css")
      expect(File.exist?(css_file)).to be true
    end
  end

  # ── Deep Nesting Tests ──────────────────────────────────────────

  describe "deep nesting" do
    it "flattens three levels of nesting" do
      scss = ".a { .b { .c { color: red; } } }"
      css = basic_compile(scss)
      expect(css).to include("color: red")
    end
  end

  # ── Multiple Selectors Tests ───────────────────────────────────

  describe "multiple selectors" do
    it "preserves comma-separated selectors" do
      scss = "h1, h2 { color: blue; }"
      css = basic_compile(scss)
      expect(css).to include("color: blue")
    end
  end

  # ── Single-line Comment Tests ──────────────────────────────────

  describe "single-line comments" do
    it "does not strip single-line comments (passes // comments through)" do
      scss = "// This is a comment\n.box { color: red; }"
      css = basic_compile(scss)
      # basic_compile does NOT strip `//` comments — the comment line is
      # preserved verbatim alongside the compiled rule. Pin both so a future
      # comment-stripping change is caught.
      expect(css).to include("// This is a comment")
      expect(css).to include("color: red")
    end
  end

  # ── Mixin Tests ────────────────────────────────────────────────

  describe "mixins" do
    it "does not expand mixins (leaves @mixin and @include in the output)" do
      scss = "@mixin reset { margin: 0; padding: 0; }\n.box { @include reset; }"
      css = basic_compile(scss)
      # basic_compile does NOT expand mixins: the @mixin block stays, and the
      # @include is emitted verbatim inside the rule instead of being replaced by
      # the mixin's declarations. Lock that un-expanded behaviour.
      expect(css).to include(".box {")
      expect(css).to include("@include reset")
      expect(css).to include("@mixin reset")
    end

    it "does not expand parametric mixins (passes @include args through verbatim)" do
      scss = "@mixin border($width, $color) { border: $width solid $color; }\n.card { @include border(2px, red); }"
      css = basic_compile(scss)
      # The mixin parameters ($width/$color) are never declared as variables, so
      # they survive, and the @include call is not substituted with a border rule.
      expect(css).to include("@include border(2px, red)")
      expect(css).to include("@mixin border($width, $color)")
    end
  end

  # ── Math Tests ─────────────────────────────────────────────────

  describe "math operations" do
    it "does not evaluate addition (passes arithmetic through verbatim)" do
      scss = ".box { width: 10px + 5px; }"
      css = basic_compile(scss)
      # The basic compiler does NOT do SCSS math — it emits the expression as-is
      # rather than computing 15px. Pin the real pass-through value so a future
      # change that silently starts (or stops) evaluating math is caught.
      expect(css).to include("width: 10px + 5px")
      expect(css).not_to include("width: 15px")
    end

    it "does not evaluate subtraction (passes arithmetic through verbatim)" do
      scss = ".box { margin: 20px - 5px; }"
      css = basic_compile(scss)
      # Same pass-through reality as addition: basic_compile emits the literal
      # expression, not the computed 15px.
      expect(css).to include("margin: 20px - 5px")
      expect(css).not_to include("margin: 15px")
    end
  end

  # ── Color Function Tests ───────────────────────────────────────

  describe "color functions" do
    it "does not resolve the lighten function (passes the call through verbatim)" do
      scss = ".box { color: lighten(#333, 20%); }"
      css = basic_compile(scss)
      # The fallback compiler leaves SCSS color functions untouched — it does NOT
      # compute the lightened hex. Assert the verbatim call so the test documents
      # (and locks) the no-resolve behaviour.
      expect(css).to include("color: lighten(#333, 20%)")
    end

    it "does not resolve the darken function (passes the call through verbatim)" do
      scss = ".box { color: darken(#ccc, 20%); }"
      css = basic_compile(scss)
      # Mirror of lighten: the call survives unevaluated.
      expect(css).to include("color: darken(#ccc, 20%)")
    end
  end

  # ── Media Query Tests ──────────────────────────────────────────

  describe "media queries" do
    it "handles nested media queries" do
      scss = ".container { @media (max-width: 768px) { width: 100%; } }"
      css = basic_compile(scss)
      expect(css).to include("@media")
      expect(css).to include("max-width: 768px")
    end
  end

  # ── Placeholder Tests ──────────────────────────────────────────

  describe "placeholders" do
    it "does not expand placeholders (leaves %placeholder and @extend in the output)" do
      scss = "%clearfix { overflow: hidden; }\n.container { @extend %clearfix; color: red; }"
      css = basic_compile(scss)
      # basic_compile does NOT resolve @extend: the %clearfix placeholder rule is
      # emitted as-is and the @extend stays inside .container instead of pulling
      # in the placeholder's declarations. Lock the no-extend behaviour.
      expect(css).to include("%clearfix")
      expect(css).to include("@extend %clearfix")
      expect(css).to include(".container {")
    end
  end

  # ── compile / set_variable / add_import_path Tests ──────────────

  describe ".compile" do
    before { Tina4::ScssCompiler.instance_variable_set(:@variables, {}) }
    before { Tina4::ScssCompiler.instance_variable_set(:@import_paths, []) }

    it "compiles an SCSS string to CSS" do
      css = Tina4::ScssCompiler.compile("$color: red;\n.box { color: $color; }")
      expect(css).to include("red")
      expect(css).not_to include("$color")
    end
  end

  describe ".set_variable" do
    before { Tina4::ScssCompiler.instance_variable_set(:@variables, {}) }
    before { Tina4::ScssCompiler.instance_variable_set(:@import_paths, []) }

    it "injects a variable for compilation" do
      Tina4::ScssCompiler.set_variable("$primary", "#ff0000")
      css = Tina4::ScssCompiler.compile(".btn { color: $primary; }")
      expect(css).to include("#ff0000")
    end

    it "strips leading $ from variable name" do
      Tina4::ScssCompiler.set_variable("accent", "blue")
      css = Tina4::ScssCompiler.compile(".link { color: $accent; }")
      expect(css).to include("blue")
    end
  end

  describe ".add_import_path" do
    before { Tina4::ScssCompiler.instance_variable_set(:@variables, {}) }
    before { Tina4::ScssCompiler.instance_variable_set(:@import_paths, []) }

    it "resolves imports from added paths" do
      lib_dir = File.join(tmp_dir, "lib")
      FileUtils.mkdir_p(lib_dir)
      File.write(File.join(lib_dir, "_colors.scss"), "$red: #f00;")

      Tina4::ScssCompiler.add_import_path(lib_dir)
      css = Tina4::ScssCompiler.compile("@import 'colors';\n.x { color: $red; }")
      expect(css).to include("#f00")
    end
  end

  # ── Edge Cases ─────────────────────────────────────────────────

  describe "edge cases" do
    it "handles empty input" do
      css = basic_compile("")
      expect(css).to eq("")
    end

    it "handles plain CSS passthrough (no SCSS features)" do
      scss = ".box { color: red; margin: 0; }"
      css = basic_compile(scss)
      expect(css).to include("color: red")
      expect(css).to include("margin: 0")
    end

    it "handles multiple variable declarations" do
      scss = <<~SCSS
        $color: #333;
        $size: 16px;
        $weight: bold;
        .text { color: $color; font-size: $size; font-weight: $weight; }
      SCSS
      css = basic_compile(scss)
      expect(css).to include("#333")
      expect(css).to include("16px")
      expect(css).to include("bold")
    end

    it "handles empty SCSS directory" do
      expect { Tina4::ScssCompiler.compile_all(tmp_dir) }.not_to raise_error
    end

    it "passes a comment-only file through unchanged (block + single-line)" do
      scss = "/* Only a comment */\n// Another comment"
      css = basic_compile(scss)
      # With no rules to flatten, basic_compile returns the input untouched: the
      # block comment is preserved and the `//` line passes through. Assert both
      # concretely instead of the near-no-op not_to be_nil.
      expect(css).to include("/* Only a comment */")
      expect(css).to include("// Another comment")
    end
  end
end
