# frozen_string_literal: true

require "spec_helper"
require "uri"
require "socket"

class GisFixtureSite < Tina4::ORM
  table_name "gis_fixture_site"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
  point_field :location
end

RSpec.describe "Feature 137 real PostGIS fixture" do
  contract = JSON.parse(File.read(File.expand_path("fixtures/gis_contract.json", __dir__)))

  before do
    uri = URI(ENV.fetch("TINA4_TEST_POSTGIS_URL", "postgres://tina4:tina4@127.0.0.1:55433/tina4_gis"))
    begin
      socket = TCPSocket.new(uri.host, uri.port)
      socket.close
    rescue StandardError
      skip "PostGIS not reachable at #{uri.host}:#{uri.port}"
    end
    @db = Tina4::Database.new("postgres://#{uri.host}:#{uri.port}#{uri.path}", username: URI.decode_www_form_component(uri.user), password: URI.decode_www_form_component(uri.password))
    GisFixtureSite.db = @db
    @db.execute("CREATE EXTENSION IF NOT EXISTS postgis")
    @db.execute("DROP TABLE IF EXISTS gis_fixture_site")
    @db.commit
  end

  after do
    next unless @db
    @db.execute("DROP TABLE IF EXISTS gis_fixture_site")
    @db.commit
    @db.close
  end

  it "runs DDL, GiST, persistence and spatial queries against PostGIS" do
    expect(GisFixtureSite.create_table).to be(true)
    expect(GisFixtureSite.create_table).to be(true)
    column = @db.fetch_one("SELECT type, srid FROM geography_columns WHERE f_table_name = ? AND f_geography_column = ?", ["gis_fixture_site", "location"])
    expect([column[:type], column[:srid].to_i]).to eq(["Point", 4326])
    index = @db.fetch_one("SELECT indexdef FROM pg_indexes WHERE tablename = ? AND indexname = ?", ["gis_fixture_site", "gis_fixture_site_location_gist"])
    expect(index[:indexdef].downcase).to include("using gist")

    { "cape_town" => "Cape Town", "johannesburg" => "Johannesburg", "anti_east" => "Anti East", "anti_west" => "Anti West" }.each do |key, name|
      expect(GisFixtureSite.new(name: name, location: contract["points"][key]).save).not_to be(false)
    end
    near = GisFixtureSite.query.within_distance(:location, contract["points"]["cape_town"], 1000)
                         .order_by_distance(:location, contract["points"]["cape_town"]).get
    expect(near.to_a.map { |row| row[:name] }).to eq(["Cape Town"])
    distance = GisFixtureSite.query.select(:name).select_distance(:location, contract["points"]["cape_town"], alias_name: :metres)
                             .where("name = ?", ["Johannesburg"]).first
    expected = contract["distance_cases"].first
    expect(distance[:metres].to_f).to be_between(expected["minimum_metres"], expected["maximum_metres"])
    box = contract["bbox_cases"].first
    boxed = GisFixtureSite.query.bbox(:location, *box["bounds"]).get
    expect(boxed.to_a.map { |row| row[:name] }).to eq(["Cape Town"])
    loaded = GisFixtureSite.find(1)
    expect(loaded.location).to be_a(Tina4::Point)
  end
end

RSpec.describe "Feature 137 GIS contract" do
  contract_path = File.expand_path("fixtures/gis_contract.json", __dir__)
  contract = JSON.parse(File.read(contract_path))
  let(:cape_town) { [18.4241, -33.9249] }

  it "loads and applies the byte-identical shared fixture" do
    expect(contract["adr"]).to eq("ADR-0057")
    contract["accepted_point_forms"].each do |fixture_case|
      expect(Tina4::Point.parse(fixture_case["value"]).geojson.transform_keys(&:to_s)).to eq(fixture_case["expected"])
    end
  end

  it "normalises longitude-first point forms without dependencies" do
    forms = [
      cape_town,
      "POINT(18.4241 -33.9249)",
      "SRID=4326;POINT(18.4241 -33.9249)",
      { type: "Point", coordinates: cape_town },
      { type: "Feature", geometry: { type: "Point", coordinates: cape_town }, properties: {} }
    ]
    expect(forms.map { |value| Tina4::Point.parse(value).geojson }).to all(eq(type: "Point", coordinates: cape_town))
  end

  it "parses the EWKB returned by PostGIS" do
    point = Tina4::Point.parse("0101000020E6100000CD3B4ED1916C324003098A1F63F640C0")
    expect([point.lon.round(4), point.lat.round(4), point.srid]).to eq([18.4241, -33.9249, 4326])
  end

  it "rejects invalid and mismatched-SRID values before SQL" do
    [[18, 91], [181, -33], [true, -33], [18]].each do |value|
      expect { GisFixtureSite.new(location: value) }.to raise_error(ArgumentError)
    end
    expect { GisFixtureSite.new(location: "SRID=3857;POINT(1 2)") }.to raise_error(ArgumentError, /expects SRID 4326/)
  end

  it "emits bound PostGIS SQL and rejects unsafe identifiers" do
    expect(Tina4::SQLTranslator.within_distance("postgres", "location"))
      .to eq("ST_DWithin(location, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)")
    expect { Tina4::SQLTranslator.distance("postgres", "location; DROP TABLE sites") }.to raise_error(ArgumentError)
  end

  it "renders Feature and ordered FeatureCollection output" do
    first = GisFixtureSite.new(id: 1, name: "Cape Town", location: cape_town)
    second = GisFixtureSite.new(id: 2, name: "Johannesburg", location: [28.0473, -26.2041])
    expect(first.to_feature).to eq(
      type: "Feature", geometry: { type: "Point", coordinates: cape_town }, properties: { id: 1, name: "Cape Town" }
    )
    expect(GisFixtureSite.feature_collection([second, first])[:features].map { |feature| feature[:properties][:id] }).to eq([2, 1])
  end

  it "fails loudly when SQLite is asked for spatial behavior" do
    expect { Tina4::SQLTranslator.point_column_type("sqlite") }.to raise_error(Tina4::SpatialNotSupportedError, /PostGIS-first/)
  end
end
