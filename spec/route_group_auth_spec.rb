# frozen_string_literal: true

# Feature 79 (route groups) - a group must not weaken the auth gate.
#
# ADR-0019. Python shipped a hole here: attaching middleware to a group set
# auth_required = False, so an ordinary logging middleware made every write
# route inside the group PUBLIC. Ruby has always been correct, because its auth
# decision keys off the HTTP method and the explicit .secure / .no_auth flags
# independent of middleware.
#
# These specs exist so Ruby CANNOT acquire the bug. That is the point: the hole
# survived in Python precisely because nothing asserted the opposite. Case names
# match tina4-python/tests/test_route_groups.py and
# tina4-php/tests/RouteGroupAuthTest.php.
#
# Real requests through Tina4::TestClient, which dispatches through the real
# RackApp and the real auth gate. No doubles.

require "spec_helper"

RSpec.describe "Route group auth" do
  # An ordinary group middleware. It does NOT do auth.
  class CountingGroupMiddleware
    class << self
      attr_accessor :runs
    end
    self.runs = 0

    def self.before_count(request, response)
      self.runs += 1
      [request, response]
    end
  end

  before do
    Tina4::Router.clear!
    CountingGroupMiddleware.runs = 0
  end

  after { Tina4::Router.clear! }

  let(:client) { Tina4::TestClient.new }

  it "ungrouped write route is secured by default" do
    # The control. If this ever goes public the example below proves nothing.
    Tina4::Router.post("/rg/plain") { |_request, response| response.json({ ok: true }) }
    expect(client.post("/rg/plain", json: {}).status).to eq(401)
  end

  it "group middleware does not open a secured write route" do
    Tina4::Router.group("/rg/secured", middleware: [CountingGroupMiddleware]) do
      post("/thing") { |_request, response| response.json({ ok: true }) }
    end

    expect(client.post("/rg/secured/thing", json: {}).status).to eq(401),
      "group middleware silently opened a secured write route"
  end

  it "group middleware does not open a nested write route" do
    Tina4::Router.group("/rg/outer", middleware: [CountingGroupMiddleware]) do
      group("/inner") do
        post("/thing") { |_request, response| response.json({ ok: true }) }
      end
    end

    expect(client.post("/rg/outer/inner/thing", json: {}).status).to eq(401)
  end

  it "group route can still be opened explicitly" do
    # The positive twin: .no_auth is the explicit spelling and must work, or
    # there would be no way to declare a public write route inside a group.
    Tina4::Router.group("/rg/public", middleware: [CountingGroupMiddleware]) do
      post("/thing") { |_request, response| response.json({ ok: true }) }.no_auth
    end

    expect(client.post("/rg/public/thing", json: {}).status).to eq(200)
  end

  it "group middleware runs once per request" do
    # Python merged group middleware twice, so it ran twice and a counter or a
    # rate-limit bucket double-counted every request.
    Tina4::Router.group("/rg/once", middleware: [CountingGroupMiddleware]) do
      get("/thing") { |_request, response| response.json({ ok: true }) }
    end

    CountingGroupMiddleware.runs = 0
    expect(client.get("/rg/once/thing").status).to eq(200)
    expect(CountingGroupMiddleware.runs).to eq(1),
      "group middleware ran #{CountingGroupMiddleware.runs} times, expected 1"
  end

  it "nested group prefix composes" do
    Tina4::Router.group("/rg/api") do
      group("/admin") do
        get("/stats") { |_request, response| response.json({ ok: true }) }
      end
    end

    paths = Tina4::Router.routes.map(&:path)
    expect(paths).to include("/rg/api/admin/stats")
    expect(paths).not_to include("/rg/api/stats")
  end
end
