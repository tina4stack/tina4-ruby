# frozen_string_literal: true

# Lock-in: the shipped tina4css assets must be fully compiled CSS.
#
# The March 2026 artifacts vendored into all four frameworks contained literal
# SCSS variables inside calc() -- `calc($grid-gutter / 2)` and
# `calc($border-radius-lg - 1px)`. A browser treats those as invalid and DROPS
# the whole declaration, so .container padding, .row negative margins,
# .row > * padding and the card first/last-child corner radii silently did not
# apply. 12 declarations shipped broken in every framework.
#
# These specs read the REAL shipped files off disk -- no mocks, no fixtures.

require "spec_helper"

RSpec.describe "shipped tina4css assets" do
  # A `$name` that is not the CSS `[attr$="x"]` suffix operator.
  UNRESOLVED_VARIABLE = /\$(?!=)[A-Za-z_][A-Za-z0-9_-]*/.freeze
  CALC_WITH_VARIABLE = /calc\([^()]*\$[^()]*\)/.freeze

  let(:css_dir) { File.join(File.dirname(__FILE__), "..", "lib", "tina4", "public", "css") }

  def read(name)
    path = File.join(css_dir, name)
    expect(File.file?(path)).to be(true), "shipped asset missing: #{path}"
    File.read(path)
  end

  %w[tina4.css tina4.min.css].each do |name|
    describe name do
      it "ships no unresolved SCSS variable" do
        # NEGATIVE: nothing unresolved may survive into the artifact.
        expect(read(name).scan(UNRESOLVED_VARIABLE).uniq).to eq([])
      end

      it "ships no calc() containing a SCSS variable" do
        # NEGATIVE: calc() is the exact construct that leaked.
        expect(read(name).scan(CALC_WITH_VARIABLE).uniq).to eq([])
      end

      it "ships the resolved grid gutter" do
        # POSITIVE: an empty file would pass the negative specs on its own.
        # The minifier drops a leading zero (0.75rem -> .75rem); accept both.
        css = read(name)
        expect(css).to match(/padding-right:\s*0?\.75rem/)
        expect(css).to match(/margin-right:\s*-0?\.75rem/)
      end

      it "ships the resolved card corner radius" do
        # POSITIVE: mixed units (rem - px) cannot fold, so a real calc() is right.
        expect(read(name)).to match(/calc\(0?\.5rem - 1px\)/)
      end
    end
  end

  it "keeps the vendored SCSS source in step with the shipped CSS" do
    scss = File.read(File.join(File.dirname(__FILE__), "..", "lib", "tina4",
                              "scss", "tina4css", "_grid.scss"))
    expect(scss).to include("$grid-gutter")
    # The source legitimately uses `calc($grid-gutter / 2)`; the compiler resolves
    # it. What must never happen is that form reaching the shipped CSS.
    expect(scss).to include("calc($grid-gutter / 2)")
    expect(read("tina4.css")).not_to include("calc($grid-gutter / 2)")
  end
end
