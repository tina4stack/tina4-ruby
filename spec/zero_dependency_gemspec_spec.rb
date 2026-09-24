# frozen_string_literal: true

require "spec_helper"

# Zero-dependency guard (parity with Node's core-barrel guard, Python's import
# guard and PHP's composer-require guard). The pinned baseline is what is still
# declared while the zero-dependency work lands; a feature that adds a NEW
# third-party gem -- an AI SDK, or the jwt gem that was deliberately removed --
# would install for every app, so it must use the stdlib or lazy-load instead.
RSpec.describe "zero-dependency gemspec" do
  # A `let`, not a bare constant: a constant declared inside an RSpec.describe
  # lands on Object and leaks across spec files.
  let(:baseline) do
    %w[rack rackup puma net-smtp net-imap rexml webrick]
  end

  # Gems Ruby itself provides, or that Tina4 replaced with its own code. None
  # may come back as a runtime dependency:
  #   json            default gem on every supported Ruby
  #   base64          replaced by Tina4::Base64 (core Array#pack)
  #   logger          never required: Tina4::Log writes its own files
  #   sqlite3         an APP dependency (ADR-0067): the scaffold Gemfile declares it
  let(:replaced) { %w[json base64 logger sqlite3] }

  it "declares no runtime gem outside the pinned baseline" do
    gemspec = Gem::Specification.load(File.expand_path("../tina4ruby.gemspec", __dir__))
    names = gemspec.runtime_dependencies.map(&:name)
    extra = names - baseline
    expect(extra).to eq([]),
                      "tina4ruby.gemspec declares runtime gems outside the baseline: " \
                      "#{extra.join(', ')} -- an optional feature must use the stdlib or " \
                      "lazy-load, never add a hard runtime gem"
  end

  it "declares none of the gems Ruby ships or Tina4 replaced" do
    gemspec = Gem::Specification.load(File.expand_path("../tina4ruby.gemspec", __dir__))
    back = gemspec.runtime_dependencies.map(&:name) & replaced
    expect(back).to eq([]),
                    "tina4ruby.gemspec declares #{back.join(', ')} again -- " \
                    "these are stdlib or replaced by Tina4 code (see the spec comment)"
  end
end
