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

  # REMOVED 2026-08-13: "keeps the vendored SCSS source in step with the
  # shipped CSS" asserted lib/tina4/scss/tina4css/_grid.scss, which commit
  # c61250c ("chore(scss): remove the bundled tina4css SCSS source from the
  # framework", 2026-08-10, already an ancestor of this branch) deliberately
  # deleted - the canonical tina4css source now lives in the tina4-css repo
  # and the compiler in the Rust CLI (tina4/src/scss.rs); the framework never
  # compiled or served the vendored copy, so it was a stale duplicate. The
  # premise this test asserted (a vendored SCSS source living in THIS repo)
  # no longer holds, so there is nothing left to keep "in step" - the
  # positive/negative examples above already pin the shipped CSS itself
  # (no unresolved variable, no calc() containing one, the real resolved
  # values), which is the assertion that still applies.
end
