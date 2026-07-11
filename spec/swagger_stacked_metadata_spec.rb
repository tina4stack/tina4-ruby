# frozen_string_literal: true

# #59 — stacked Swagger metadata (summary + description + tags) must ALL survive
# on the registered route and appear together in the generated OpenAPI operation.
#
# python #59 reported that Python's stacked @summary/@description/@tags decorators
# dropped all but the one nearest @get. Python is already correct there (each
# decorator annotates the handler in place). Ruby does NOT use decorators — route
# metadata is a single `swagger_meta:` hash carried on the route, and
# Swagger#add_route_to_spec reads meta[:summary], meta[:description] and
# meta[:tags] INDEPENDENTLY into the operation. So sibling metadata cannot be
# dropped by construction — there is no "nearest decorator wins" mechanism.
#
# These tests LOCK THAT IN (all three survive, order-independent) and are the
# wire contract PHP/Ruby/Node must match. Mirrors
# tests/test_swagger_stacked_decorators.py.
#
# Pure-logic: builds an OpenAPI spec from in-process routes — no DB, no network,
# no doubles.

require "spec_helper"

RSpec.describe "Swagger stacked metadata survival (#59)" do
  before(:each) { Tina4::Router.clear! }

  it "keeps summary, description AND tags all present on one operation" do
    Tina4::Router.get(
      "/widgets",
      swagger_meta: {
        summary: "List widgets",
        description: "Returns every widget in the catalogue.",
        tags: %w[widgets catalogue]
      }
    ) { |_req, res| res }

    op = Tina4::Swagger.generate["paths"]["/widgets"]["get"]
    expect(op["summary"]).to eq("List widgets")
    expect(op["description"]).to eq("Returns every widget in the catalogue.")
    expect(op["tags"]).to eq(%w[widgets catalogue])
  end

  it "is order-independent — declaring the keys in a different order keeps all three" do
    # No metadata key wins by being first/last in the hash; none is dropped.
    Tina4::Router.post(
      "/orders",
      swagger_meta: {
        tags: %w[orders],
        summary: "Create order",
        description: "Creates a new order."
      }
    ) { |_req, res| res }

    op = Tina4::Swagger.generate["paths"]["/orders"]["post"]
    expect(op["summary"]).to eq("Create order")
    expect(op["description"]).to eq("Creates a new order.")
    expect(op["tags"]).to eq(%w[orders])
  end

  it "keeps all three across multiple routes without cross-contamination" do
    Tina4::Router.get(
      "/a",
      swagger_meta: { summary: "A summary", description: "A desc", tags: %w[alpha] }
    ) { |_req, res| res }
    Tina4::Router.get(
      "/b",
      swagger_meta: { summary: "B summary", description: "B desc", tags: %w[beta] }
    ) { |_req, res| res }

    spec = Tina4::Swagger.generate
    a = spec["paths"]["/a"]["get"]
    b = spec["paths"]["/b"]["get"]

    expect([a["summary"], a["description"], a["tags"]]).to eq(["A summary", "A desc", %w[alpha]])
    expect([b["summary"], b["description"], b["tags"]]).to eq(["B summary", "B desc", %w[beta]])
  end
end
