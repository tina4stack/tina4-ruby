# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Regression: a route path parameter like {id} matched against a real HTTP
# request arrives from Rack's PATH_INFO as an ASCII-8BIT (BINARY) String. If
# the router hands that binary String straight to a SQL bind, the sqlite3 gem
# binds it as a BLOB, and SQLite gives a BLOB no numeric affinity — so
# `WHERE id = ?` never matches an INTEGER column and `GET /api/users/{id}`
# 404s a row that plainly exists. The router must relabel captures as UTF-8 so
# they bind as TEXT (which DOES get numeric affinity), matching the Python
# master where path params are ordinary text strings.
#
# No mocks: exercises the real Tina4::Route matcher AND a real SQLite file.
RSpec.describe "Router path-param encoding (INTEGER PK lookup)" do
  let(:db_path) { File.join(Dir.tmpdir, "tina4_pathparam_#{Process.pid}_#{rand(10_000)}.db") }
  let(:db) do
    d = Tina4::Database.new("sqlite:///#{db_path}")
    d.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
    d.execute("INSERT INTO users (id, name) VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Carol')")
    d
  end

  after do
    db.close if db.respond_to?(:close)
    File.delete(db_path) if File.exist?(db_path)
  end

  def id_param(params)
    params["id"] || params[:id]
  end

  it "relabels an ASCII-8BIT path capture as UTF-8" do
    route = Tina4::Route.new("GET", "/users/{id}", ->(_req, _res) {})
    # Rack delivers PATH_INFO as ASCII-8BIT — reproduce that exactly.
    request_path = (+"/users/2").force_encoding("ASCII-8BIT")

    params = route.match_path(request_path)
    expect(params).to be_a(Hash)
    expect(id_param(params)).to eq("2")
    expect(id_param(params).encoding).to eq(Encoding::UTF_8)
  end

  it "matches an INTEGER primary key from an ASCII-8BIT request path (real SQLite)" do
    route = Tina4::Route.new("GET", "/users/{id}", ->(_req, _res) {})
    request_path = (+"/users/2").force_encoding("ASCII-8BIT")

    captured = id_param(route.match_path(request_path))
    # The router's output, bound through a real SQLite connection, must find Bob.
    result = db.fetch("SELECT name FROM users WHERE id = ?", [captured])
    expect(result.records).to eq([{ name: "Bob" }])
  end

  it "keeps typed {id:int} params working (Integer bind)" do
    route = Tina4::Route.new("GET", "/users/{id:int}", ->(_req, _res) {})
    request_path = (+"/users/3").force_encoding("ASCII-8BIT")

    captured = id_param(route.match_path(request_path))
    expect(captured).to eq(3)
    result = db.fetch("SELECT name FROM users WHERE id = ?", [captured])
    expect(result.records).to eq([{ name: "Carol" }])
  end

  # Characterization: this is WHY the router fix is needed and why the SQLite
  # driver must NOT be the fix layer. A genuinely binary (ASCII-8BIT) value is
  # correctly bound as a BLOB and does not get numeric affinity — that is right
  # for real binary data, so the encoding must be corrected at the source (the
  # router), never by coercing every binary string in the driver.
  it "documents that a raw ASCII-8BIT bind is a BLOB (no INTEGER affinity)" do
    binary_two = (+"2").force_encoding("ASCII-8BIT")
    result = db.fetch("SELECT name FROM users WHERE id = ?", [binary_two])
    expect(result.records).to eq([])
  end
end
