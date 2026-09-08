# frozen_string_literal: true

require "spec_helper"

# Zero-dependency guard (parity with Node's core-barrel guard, Python's import
# guard and PHP's composer-require guard). Ruby is the one framework that cannot
# be truly zero-gem: it has no built-in HTTP server and no built-in SQLite, so it
# must declare the Rack web stack, the sqlite3 driver, and the stdlib gems that
# Ruby 3.4+ makes you name explicitly (net-smtp, net-imap, json, rexml, webrick,
# logger, base64). Those are the pinned baseline. A feature that adds a NEW
# third-party gem -- an AI SDK, or the jwt gem that was deliberately removed --
# would install for every app, so it must use the stdlib or lazy-load instead.
RSpec.describe "zero-dependency gemspec" do
  # A `let`, not a bare constant: a constant declared inside an RSpec.describe
  # lands on Object and leaks across spec files.
  let(:baseline) do
    %w[rack rackup puma net-smtp net-imap json rexml webrick logger base64 sqlite3]
  end

  it "declares no runtime gem outside the pinned baseline" do
    gemspec = Gem::Specification.load(File.expand_path("../tina4ruby.gemspec", __dir__))
    names = gemspec.runtime_dependencies.map(&:name)
    extra = names - baseline
    expect(extra).to eq([]),
                      "tina4ruby.gemspec declares runtime gems outside the baseline: " \
                      "#{extra.join(', ')} -- an optional feature must use the stdlib or " \
                      "lazy-load, never add a hard runtime gem"
  end
end
