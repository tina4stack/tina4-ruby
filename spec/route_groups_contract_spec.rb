# frozen_string_literal: true

# Feature 32 (route groups) - the prefix+path JOIN grammar (RG-DEC-01).
#
# The audit found the join grammar diverges and is UNGATED: PHP fully
# normalizes (Tina4/Router.php addRoute - the reference: one separator, no
# double slash, a single leading slash); Ruby's GroupContext bare-
# concatenated ("#{@prefix}#{path}"), so group("/api") + get("users")
# silently mis-registered at "/apiusers" (and a doubled prefix separator
# could leave "/api//users"). This converges Ruby onto PHP's grammar
# (Tina4::Router.join_group_path, ported verbatim from Router.php).
#
# Real registration through the real Router, real dispatch through
# Tina4::TestClient -> the real RackApp (the SAME front controller a live
# request hits) - no mocks. Positive AND negative: a mis-registered path
# must 404.
#
# Same case names in all four:
#   tina4-python/tests/test_route_groups_contract.py
#   tina4-php/tests/RouteGroupsContractTest.php
#   tina4-nodejs/test/routeGroupsContract.test.ts
#
# See tina4-documentation/plan/v3/fixtures/route_groups_contract.json.

require "spec_helper"

RSpec.describe "Route groups contract - slash normalization" do
  # An ordinary group middleware. It does NOT do auth.
  class RouteGroupsContractCountingMiddleware
    class << self
      attr_accessor :runs
    end
    self.runs = 0

    def self.before_count(request, response)
      self.runs += 1
      [request, response]
    end
  end

  before { Tina4::Router.clear! }
  after { Tina4::Router.clear! }

  let(:client) { Tina4::TestClient.new }

  it "group_prefix_joins_to_a_single_slash_path" do
    # group("/api") + get("users") - the route's own path has NO leading
    # slash. The old bare concatenation silently produced "/apiusers".
    Tina4::Router.group("/__rg32/c1") do
      get("users") { |_request, response| response.json({ ok: true }) }
    end

    expect(client.get("/__rg32/c1/users").status).to eq(200)
    # Negative: the bare-concat mis-registration must not exist.
    expect(client.get("/__rg32/c1users").status).to eq(404),
      "the bare-concat mis-registration (/__rg32/c1users) must not resolve"
  end

  it "leading_slash_on_the_route_is_normalized" do
    # group("/api") + get("/users") - the route's own path already carries
    # its leading slash. Must land on the SAME canonical path, never a
    # double slash.
    Tina4::Router.group("/__rg32/c2") do
      get("/users") { |_request, response| response.json({ ok: true }) }
    end

    expect(client.get("/__rg32/c2/users").status).to eq(200)

    paths = Tina4::Router.routes.map(&:path)
    expect(paths).to include("/__rg32/c2/users")
    expect(paths).not_to include("/__rg32/c2//users")
  end

  it "trailing_slash_on_the_prefix_is_normalized" do
    # group("/api/") + get("/users") - the GROUP prefix carries a trailing
    # slash. Must ALSO land on the same canonical path.
    Tina4::Router.group("/__rg32/c3/") do
      get("/users") { |_request, response| response.json({ ok: true }) }
    end

    expect(client.get("/__rg32/c3/users").status).to eq(200)

    paths = Tina4::Router.routes.map(&:path)
    expect(paths).to include("/__rg32/c3/users")
    expect(paths).not_to include("/__rg32/c3//users")
  end

  it "nested_groups_concatenate_the_prefix" do
    # group("/api") > group("/v1") + get("users") -> "/api/v1/users".
    Tina4::Router.group("/__rg32/c4") do
      group("/v1") do
        get("users") { |_request, response| response.json({ ok: true }) }
      end
    end

    expect(client.get("/__rg32/c4/v1/users").status).to eq(200)
    # Negative: the missing-separator mis-registration must not exist.
    expect(client.get("/__rg32/c4/v1users").status).to eq(404),
      "the nested bare-concat mis-registration (/__rg32/c4/v1users) must not resolve"
  end

  it "group_middleware_never_opens_the_write_auth_gate" do
    # LOCK: group middleware must never disable the secure-by-default
    # write-auth gate - including under the normalized prefix join.
    RouteGroupsContractCountingMiddleware.runs = 0
    Tina4::Router.group("/__rg32/c5", middleware: [RouteGroupsContractCountingMiddleware]) do
      post("/thing") { |_request, response| response.json({ ok: true }) }
    end

    response = client.post("/__rg32/c5/thing", json: { x: 1 })
    expect(response.status).to eq(401),
      "group middleware silently opened a secured write route under the normalized join"
  end
end
