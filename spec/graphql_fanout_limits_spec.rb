# frozen_string_literal: true

# Medium security finding F2 — GraphQL fan-out limits.
#
# The depth guard bounds NESTING but not WIDTH. This pins the two controls that
# close the gap, at parity with tina4-python/tests/test_graphql_fanout_limits.py,
# tina4-nodejs/test/graphqlFanoutLimits.test.ts and
# tina4-php/tests/GraphQLFanoutLimitsTest.php:
#   * a total expanded-node (complexity) budget that rejects a fragment bomb and
#     an alias explosion before any resolver runs; and
#   * a parser recursion bound, so a deeply nested query fails with a clean
#     GraphQL error instead of a SystemStackError escaping as a 500 (Ruby's
#     SystemStackError is not a StandardError, so `rescue => e` misses it).
require "spec_helper"

RSpec.describe "GraphQL fan-out limits (F2)" do
  around do |example|
    saved = { n: ENV["TINA4_GRAPHQL_MAX_NODES"], d: ENV["TINA4_GRAPHQL_MAX_DEPTH"] }
    example.run
    %w[TINA4_GRAPHQL_MAX_NODES TINA4_GRAPHQL_MAX_DEPTH].each { |k| ENV.delete(k) }
    ENV["TINA4_GRAPHQL_MAX_NODES"] = saved[:n] if saved[:n]
    ENV["TINA4_GRAPHQL_MAX_DEPTH"] = saved[:d] if saved[:d]
  end

  # Build the schema AFTER the env is set, since the limits are read at construction.
  def make_gql
    gql = Tina4::GraphQL.new
    gql.schema.add_query("ping", {}, "String") { |_r, _a, _c| "pong" }
    gql
  end

  def err_text(result)
    (result["errors"] || []).map { |e| e["message"] }.join(" ")
  end

  it "rejects a fragment bomb" do
    ENV["TINA4_GRAPHQL_MAX_NODES"] = "100"
    gql = make_gql
    frags = "fragment f0 on Query { ping }\n"
    prev = "f0"
    (1...8).each do |i|
      frags += "fragment f#{i} on Query { ...#{prev} ...#{prev} }\n"
      prev = "f#{i}"
    end
    result = gql.execute(frags + "{ ...f7 }")
    expect(err_text(result).downcase).to include("complexity"), "fragment bomb not bounded: #{result}"
  end

  it "rejects an alias explosion" do
    ENV["TINA4_GRAPHQL_MAX_NODES"] = "100"
    gql = make_gql
    aliases = (0...200).map { |i| "a#{i}: ping" }.join(" ")
    result = gql.execute("{ #{aliases} }")
    expect(err_text(result).downcase).to include("complexity"), "alias explosion not bounded: #{result}"
  end

  it "bounds a deeply nested query at the parser (no SystemStackError-500)" do
    ENV["TINA4_GRAPHQL_MAX_NODES"] = "0" # disable the node budget so this isolates the parser bound
    ENV["TINA4_GRAPHQL_MAX_DEPTH"] = "20"
    gql = make_gql
    inner = "x"
    3000.times { inner = "ping { #{inner} }" }
    # Without the parser bound this raises SystemStackError (a 500); the fix makes
    # it a clean GraphQL error. Guard so the red-first run reports a failure, not
    # an un-rescued crash.
    result = begin
      gql.execute("{ #{inner} }")
    rescue Exception => e # rubocop:disable Lint/RescueException
      { "errors" => [{ "message" => "uncaught #{e.class}" }] }
    end
    expect(err_text(result).downcase).to include("maximum depth"),
                                          "deep nesting not bounded by the parser: #{result}"
  end

  it "still runs an ordinary query" do
    ENV["TINA4_GRAPHQL_MAX_NODES"] = "100"
    gql = make_gql
    result = gql.execute("{ ping }")
    expect(result.dig("data", "ping")).to eq("pong"), result.to_s
  end
end
