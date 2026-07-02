# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tina4::VERSION" do
  it "is valid semver and matches the gemspec version" do
    # No hardcoded literal to forget on a bump: lib/tina4/version.rb is the
    # single source of truth. Assert the constant is valid semver (catches a
    # blank or malformed bump) and that the gemspec the artifact actually
    # publishes carries the SAME string (the gemspec sets spec.version =
    # Tina4::VERSION), so the constant and the publishable gem can never drift.
    #
    # A pinned literal used to live here; it was not updated at 3.13.48/49, so
    # this spec failed and Ruby CI went red for several releases (the publish
    # workflow is separate, so the gem still shipped). Reading the constant
    # removes that manual-update footgun.
    expect(Tina4::VERSION).to match(/\A\d+\.\d+\.\d+\z/)

    gemspec_path = File.expand_path("../tina4ruby.gemspec", __dir__)
    built_gemspec = Gem::Specification.load(gemspec_path)
    expect(built_gemspec.version.to_s).to eq(Tina4::VERSION)
  end
end
