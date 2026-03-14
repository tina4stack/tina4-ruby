# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::DatabaseResult do
  let(:records) { [{ "id" => 1, "name" => "Alice" }, { "id" => 2, "name" => "Bob" }] }
  let(:result) { Tina4::DatabaseResult.new(records) }

  describe "#count" do
    it "returns the number of records" do
      expect(result.count).to eq(2)
    end
  end

  describe "#empty?" do
    it "returns false when records exist" do
      expect(result.empty?).to be false
    end

    it "returns true for empty results" do
      empty = Tina4::DatabaseResult.new([])
      expect(empty.empty?).to be true
    end
  end

  describe "#first" do
    it "returns the first record" do
      first = result.first
      expect(first["name"] || first[:name]).to eq("Alice")
    end
  end

  describe "#last" do
    it "returns the last record" do
      last = result.last
      expect(last["name"] || last[:name]).to eq("Bob")
    end
  end

  describe "#to_array" do
    it "returns an array of hashes" do
      arr = result.to_array
      expect(arr).to be_an(Array)
      expect(arr.length).to eq(2)
    end
  end

  describe "#to_json" do
    it "returns valid JSON" do
      json = result.to_json
      parsed = JSON.parse(json)
      expect(parsed).to be_an(Array)
      expect(parsed.length).to eq(2)
    end
  end

  describe "#to_csv" do
    it "returns CSV string" do
      csv = result.to_csv
      expect(csv).to be_a(String)
      expect(csv).to include("Alice")
      expect(csv).to include("Bob")
    end
  end

  describe "#to_paginate" do
    it "returns pagination metadata" do
      page = result.to_paginate
      expect(page).to be_a(Hash)
      expect(page[:data] || page["data"]).to be_an(Array)
    end
  end

  describe "Enumerable" do
    it "supports each" do
      names = []
      result.each { |r| names << (r["name"] || r[:name]) }
      expect(names).to eq(["Alice", "Bob"])
    end
  end

  describe "#[]" do
    it "accesses records by index" do
      record = result[0]
      expect(record).not_to be_nil
    end
  end
end
