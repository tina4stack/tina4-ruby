# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "securerandom"

# MongoDB SQL provider - a bound parameter is a value, never part of the statement.
#
# The provider parses the SQL text itself, so it used to paste each bound value
# into that text before parsing it. A value holding a quote, a keyword or a comma
# was then read as SQL, and matched, wrote or returned something other than what
# the statement says. Bound values now stand in the text as opaque tokens and are
# resolved only where a literal is read.
#
# NO MOCKS. A real MongoDB; the framework performs the writes, an independent
# raw Mongo::Client witnesses the documents. Each case fails against the
# pre-fix driver.
RSpec.describe "MongoDB SQL bound values" do
  BOUNDSQL_URI = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017")
  BOUNDSQL_DB = "tina4_mongosql_rb"

  def self.mongo_reachable?
    return @mongo_reachable unless @mongo_reachable.nil?

    @mongo_reachable = begin
      require "mongo"
      Mongo::Logger.logger.level = Logger::FATAL
      client = Mongo::Client.new(BOUNDSQL_URI, server_selection_timeout: 3)
      client.database.command(ping: 1)
      client.close
      true
    rescue StandardError, LoadError
      false
    end
  end

  def uri_with_db
    scheme, rest = BOUNDSQL_URI.split("://", 2)
    query = rest.include?("?") ? "?#{rest.split('?', 2)[1]}" : ""
    host = rest.split("?", 2)[0].split("/", 2)[0]
    "#{scheme}://#{host}/#{BOUNDSQL_DB}#{query}"
  end

  before do
    skip "no reachable MongoDB at #{BOUNDSQL_URI} (set TINA4_TEST_MONGO_URI)" unless self.class.mongo_reachable?

    @db = Tina4::Database.new(uri_with_db)
    @collection = "bound_#{SecureRandom.hex(6)}"
    # Independent witness: a raw driver client, not the code under test.
    @witness = Mongo::Client.new(BOUNDSQL_URI, server_selection_timeout: 3).use(BOUNDSQL_DB)
    [[1, "a"], [2, "b"], [3, "c"]].each do |id, name|
      @witness[@collection].insert_one({ "id" => id, "name" => name, "role" => "user" })
    end
  end

  after do
    if @db
      begin
        @db.execute("DROP TABLE #{@collection}")
      rescue StandardError
        # best effort
      end
      @db.close
    end
    @witness&.close
  end

  def docs
    @witness[@collection].find.sort(id: 1).map { |d| d.to_h.except("_id") }
  end

  it "a quoted bound value in a DELETE matches only itself" do
    @db.execute("DELETE FROM #{@collection} WHERE name = ?", ["z' OR name IS NOT NULL OR name = 'y"])

    expect(docs.map { |d| d["id"] }).to eq([1, 2, 3])
  end

  it "a quoted bound value in an UPDATE SET is stored whole and writes no other field" do
    @db.execute("UPDATE #{@collection} SET name = ? WHERE id = ?", ["n', role = 'x", 2])

    expect(docs).to eq([
                         { "id" => 1, "name" => "a", "role" => "user" },
                         { "id" => 2, "name" => "n', role = 'x", "role" => "user" },
                         { "id" => 3, "name" => "c", "role" => "user" }
                       ])
  end

  it "a bound value holding a keyword does not change the UPDATE's WHERE" do
    @db.execute("UPDATE #{@collection} SET name = ? WHERE id = ?", ["n' WHERE id > 0 OR id = 'y", 2])

    expect(docs.map { |d| d["name"] }).to eq(["a", "n' WHERE id > 0 OR id = 'y", "c"])
  end

  it "a quoted bound value in a SELECT matches only itself" do
    rows = @db.fetch("SELECT * FROM #{@collection} WHERE name = ?", ["z' OR name IS NOT NULL OR name = 'y"]).to_a

    expect(rows).to eq([])
  end

  it "a bound value holding LIMIT does not limit the SELECT" do
    rows = @db.fetch("SELECT * FROM #{@collection} WHERE name != ?", ["z LIMIT 1"]).to_a

    expect(rows.length).to eq(3)
  end

  it "a value with a quote round-trips through INSERT and SELECT exactly" do
    @db.execute("INSERT INTO #{@collection} (id, name) VALUES (?, ?)", [4, "it's"])

    expect(@witness[@collection].find("id" => 4).first["name"]).to eq("it's")
    rows = @db.fetch("SELECT * FROM #{@collection} WHERE name = ?", ["it's"]).to_a
    expect(rows.map { |r| r[:id] || r["id"] }).to eq([4])
  end

  it "a bound LIKE pattern with a quote matches as a pattern" do
    @db.execute("INSERT INTO #{@collection} (id, name) VALUES (?, ?)", [4, "it's"])

    rows = @db.fetch("SELECT * FROM #{@collection} WHERE name LIKE ?", ["it'%"]).to_a
    expect(rows.map { |r| r[:id] || r["id"] }).to eq([4])
  end
end
