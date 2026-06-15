# frozen_string_literal: true

require "spec_helper"

# ORM constructor accepts a Hash, keyword args, or a JSON object string (one
# record), and rejects an Array with a clear ArgumentError.
RSpec.describe "ORM construction" do
  ctor_widget = Class.new(Tina4::ORM) do
    integer_field :id, primary_key: true
    string_field  :name
    boolean_field :active
  end
  before { stub_const("CtorWidget", ctor_widget) }

  it "builds from a hash" do
    w = CtorWidget.new({ "id" => 1, "name" => "alpha", "active" => true })
    expect(w.id).to eq(1)
    expect(w.name).to eq("alpha")
    expect(w.active).to be(true)
  end

  it "builds from keyword args" do
    w = CtorWidget.new(id: 2, name: "beta")
    expect(w.id).to eq(2)
    expect(w.name).to eq("beta")
  end

  it "builds from a JSON object string" do
    w = CtorWidget.new('{"id":3,"name":"gamma","active":false}')
    expect(w.id).to eq(3)
    expect(w.name).to eq("gamma")
    expect(w.active).to be(false)
  end

  it "rejects an Array with a clear error" do
    expect { CtorWidget.new(%w[a b]) }.to raise_error(ArgumentError, /one record/)
  end

  it "rejects a JSON array string with a clear error" do
    expect { CtorWidget.new('[{"id":4}]') }.to raise_error(ArgumentError, /one record/)
  end
end
