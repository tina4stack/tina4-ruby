# frozen_string_literal: true

# Feature 8: Health.register! must always register the health routes.
#
# The bug this pins (measured 2026-07-31, tina4-ruby 3.13.94):
#
#   Tina4::Router.any("/{slug}") { ... }   # an ordinary CMS catch-all
#   Tina4::Health.register!
#   -> routes table contains ONLY ["ANY /{slug}"]; health never registered
#   -> GET /__health is answered by the catch-all: {"page":"cms catch-all"}
#
# The cause was an idempotency guard called with its arguments swapped:
#
#   return if Tina4::Router.find_route("/health", "GET")
#
# The real signature is find_route(METHOD, PATH) (lib/tina4/router.rb:441), so
# this asked "is there a route at path /GET for method /health". That normally
# answered nil, which made the guard a silent no-op; but an ANY route matches
# any path, so as soon as an app registered a catch-all the guard fired and
# suppressed health registration entirely. A monitoring probe then received the
# application's catch-all response instead of the health payload, and if that
# catch-all 404s or 500s for an unknown path, liveness fails permanently.
#
# The guard was removed rather than corrected: Router.add already has
# replace-in-place semantics for a repeated (method, path) (router.rb:379-386),
# so re-registering cannot duplicate, which is the only thing the guard was
# there to prevent. Correcting the argument order would NOT have been enough --
# find_route("GET", "/__health") also matches a catch-all ANY route.
#
# No mocks: the real Router, the real Health module, the real handlers.

require "spec_helper"

RSpec.describe "Tina4::Health.register! registration" do
  before { Tina4::Router.clear! }
  after { Tina4::Router.clear! }

  def registered_paths
    Tina4::Router.routes.map { |route| "#{route.method} #{route.path}" }.sort
  end

  # Invoke the handler on the REGISTERED health route entry.
  #
  # Deliberately not routed through find_route: find_route tries the ANY index
  # before the method index (router.rb:449), so a catch-all ANY route shadows a
  # specific GET at DISPATCH. That is a router-precedence question owned by
  # feature 6, not by health, and it is reported separately -- health's job is
  # to make sure the route entry exists and carries the health handler.
  def health_payload_at(path)
    route = Tina4::Router.routes.find { |r| r.method == "GET" && r.path == path }
    raise "no GET route registered at #{path}" if route.nil?

    env = {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new("")
    }
    request = Tina4::Request.new(env)
    response = Tina4::Response.new
    route.handler.call(request, response)
    JSON.parse(response.body)
  end

  it "registers both the configured path and the legacy /health" do
    Tina4::Health.register!
    expect(registered_paths).to include("GET /__health", "GET /health")
  end

  it "still registers health when the app has a catch-all ANY route" do
    Tina4::Router.any("/{slug}") { |_request, response| response.json({ page: "cms catch-all" }) }

    Tina4::Health.register!

    expect(registered_paths).to include("GET /__health", "GET /health")
  end

  it "registers the health handler itself, not the catch-all, when an ANY route exists" do
    Tina4::Router.any("/{slug}") { |_request, response| response.json({ page: "cms catch-all" }) }

    Tina4::Health.register!

    payload = health_payload_at("/__health")
    expect(payload["framework"]).to eq("tina4-ruby")
    expect(payload["status"]).to eq("ok")
    expect(payload).not_to have_key("page")
  end

  it "does not duplicate routes when called more than once" do
    Tina4::Health.register!
    first = registered_paths

    Tina4::Health.register!

    expect(registered_paths).to eq(first)
  end

  it "re-registers after Router.clear! wipes the table" do
    Tina4::Health.register!
    Tina4::Router.clear!
    expect(registered_paths).to be_empty

    Tina4::Health.register!

    expect(registered_paths).to include("GET /__health", "GET /health")
  end
end
