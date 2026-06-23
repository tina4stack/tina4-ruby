# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tina4::VERSION" do
  it "exposes the exact published version string" do
    # A mere not_to be_nil check would pass on a blank or wrongly-bumped
    # constant. Pin the real value (the source of truth in
    # lib/tina4/version.rb, documented in CLAUDE.md) so a wrong/blank bump
    # is caught, and confirm the gem the gemspec actually publishes carries
    # the SAME string (spec.version = Tina4::VERSION) — no drift between the
    # constant and the publishable artifact.
    expect(Tina4::VERSION).to eq("3.13.44")

    gemspec_path = File.expand_path("../tina4ruby.gemspec", __dir__)
    built_gemspec = Gem::Specification.load(gemspec_path)
    expect(built_gemspec.version.to_s).to eq("3.13.44")
  end

  it "follows semver format" do
    expect(Tina4::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
