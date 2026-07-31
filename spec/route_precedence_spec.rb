# frozen_string_literal: true

require "spec_helper"

# Route precedence: an ANY route must not shadow a specific-method route
# registered before it (feature 6).
#
# find_route used to build its candidate list as `ANY + method`, so an ANY
# route was ALWAYS tried first regardless of when either was registered. An
# app with an ordinary CMS catch-all (`any("/{slug}")`) therefore swallowed
# every specific route in the app, including the framework's own /__health -
# the route was registered correctly, the router simply never reached it.
#
# Measured across all four frameworks before this was changed: Python, PHP and
# Node all resolve by forward REGISTRATION order; only Ruby preferred ANY. So
# this is a parity fix onto the 3-of-4 behaviour, not a new contract.
#
# The deeper question - whether a specific route should beat a catch-all
# regardless of registration order - is deliberately NOT decided here. These
# specs pin registration order only.
RSpec.describe "Route precedence" do
  before(:each) { Tina4::Router.clear! }
  after(:each)  { Tina4::Router.clear! }

  it "lets a specific route registered before an ANY route win" do
    Tina4::Router.get("/probe") { |_q, s| s }
    Tina4::Router.any("/{slug}") { |_q, s| s }

    route, = Tina4::Router.find_route("GET", "/probe")

    expect(route).not_to be_nil
    expect(route.method).to eq("GET")
    expect(route.path).to eq("/probe")
  end

  it "lets an ANY route registered first win, because order decides" do
    Tina4::Router.any("/{slug}") { |_q, s| s }
    Tina4::Router.get("/probe") { |_q, s| s }

    route, = Tina4::Router.find_route("GET", "/probe")

    expect(route.method).to eq("ANY")
    expect(route.path).to eq("/{slug}")
  end

  it "keeps matching ANY routes for methods that have no specific route" do
    Tina4::Router.any("/{slug}") { |_q, s| s }

    route, = Tina4::Router.find_route("DELETE", "/anything")

    expect(route).not_to be_nil
    expect(route.method).to eq("ANY")
  end

  it "still resolves a specific route when no ANY route exists at all" do
    # Pins the fast path: with no ANY routes registered, find_route uses the
    # per-method index directly and must behave exactly as before.
    Tina4::Router.get("/only") { |_q, s| s }

    route, = Tina4::Router.find_route("GET", "/only")

    expect(route.path).to eq("/only")
  end

  it "does not let an app catch-all shadow the built-in health route" do
    # The real-world failure: a container health check probing /__health gets
    # the app's catch-all instead. Built-ins register before route discovery,
    # so a catch-all declared by the app cannot reach in front of them.
    Tina4.register_builtin_routes!
    Tina4::Router.any("/{slug}") { |_q, s| s }

    route, = Tina4::Router.find_route("GET", "/__health")

    expect(route).not_to be_nil
    expect(route.method).to eq("GET"), "the app catch-all shadowed /__health"
    expect(route.path).to eq("/__health")
  end
end
