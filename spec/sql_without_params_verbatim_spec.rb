# frozen_string_literal: true
#
# SQL with NO parameters is sent exactly as written (cross-framework contract;
# PHP already did it). The `?` -> placeholder rewrite only runs when there are
# parameters to bind, so the Postgres jsonb operators ?, ?| and ?& work in a
# parameterless query. With parameters, `?` is a placeholder and those
# operators must be spelled jsonb_exists / jsonb_exists_any / jsonb_exists_all.
#
# Before: PostgresDriver rewrote every `?` even with no params, so
# SELECT '{"a":1}'::jsonb ? 'a' became ... $1 'a' and failed.
#
# REAL PostgreSQL - NO mocks (a provisioned service: its skip fails the
# TINA4_REQUIRE_SERVICES gate).

require "spec_helper"
require_relative "support/live_postgres"
require "socket"
require "uri"

RSpec.describe "SQL with no parameters is sent exactly as written (Postgres jsonb ? operators)" do
  def verbatim_pg_url
    ENV["TINA4_TEST_PG_URL"] || LivePostgres.url
  end

  before(:each) do
    uri = URI.parse(verbatim_pg_url)
    begin
      require "pg"
      TCPSocket.new(uri.host, uri.port || 5432).close
    rescue LoadError, StandardError
      skip "[needs:postgres] PostgreSQL not reachable at #{verbatim_pg_url}"
    end
    @db = Tina4::Database.new(verbatim_pg_url, username: ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4"),
                                               password: ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4"))
  end

  after(:each) { @db&.close rescue nil }

  def truthy(row, key)
    value = row[key] || row[key.to_s]
    [true, "t", "true"].include?(value)
  end

  it "fetch_one: jsonb ? with no params returns true" do
    row = @db.fetch_one(%(SELECT '{"a":1}'::jsonb ? 'a' AS has_a), [], no_cache: true)
    expect(truthy(row, :has_a)).to be(true)
  end

  it "fetch: jsonb ?| and ?& with no params work" do
    row = @db.fetch(%(SELECT '{"a":1,"b":2}'::jsonb ?| array['z','b'] AS any_of, ) +
                    %('{"a":1,"b":2}'::jsonb ?& array['a','b'] AS all_of), [], no_cache: true).records.first
    expect([truthy(row, :any_of), truthy(row, :all_of)]).to eq([true, true])
  end

  it "execute: jsonb ? with no params runs" do
    expect { @db.execute(%(SELECT '{"a":1}'::jsonb ? 'a')) }.not_to raise_error
  end

  it "WITH a param, ? is still a placeholder (and jsonb_exists spells the operator)" do
    row = @db.fetch_one(%(SELECT jsonb_exists('{"a":1}'::jsonb, ?) AS has_a, CAST(? AS INTEGER) AS n), ["a", 5],
                        no_cache: true)
    expect(truthy(row, :has_a)).to be(true)
    expect((row[:n] || row["n"]).to_i).to eq(5)
  end
end
