# frozen_string_literal: true

require "spec_helper"

# response.(model) / response.json(model) auto-serialize an ORM model (to_h),
# a list of models, and a DatabaseResult (records) without the caller calling
# .to_h by hand. Plain Hash / String values must behave exactly as before.
RSpec.describe "Response auto-serialization" do
  let(:response) { Tina4::Response.new }

  # A minimal in-memory ORM model (no DB needed for to_h).
  widget_class = Class.new(Tina4::ORM) do
    integer_field :id, primary_key: true
    string_field  :name
    boolean_field :active
  end
  before { stub_const("Widget", widget_class) }

  it "serializes a single ORM model to a JSON object" do
    response.call(Widget.new(id: 1, name: "alpha", active: true))
    expect(response.headers["content-type"]).to start_with("application/json")
    expect(JSON.parse(response.body)).to eq("id" => 1, "name" => "alpha", "active" => true)
  end

  it "serializes a list of models to a JSON array" do
    response.call([Widget.new(id: 1, name: "a", active: true), Widget.new(id: 2, name: "b", active: false)])
    expect(JSON.parse(response.body)).to eq([
      { "id" => 1, "name" => "a", "active" => true },
      { "id" => 2, "name" => "b", "active" => false }
    ])
  end

  it "serializes a DatabaseResult to its records array" do
    result = Tina4::DatabaseResult.new([{ "id" => 1 }, { "id" => 2 }])
    response.call(result)
    expect(JSON.parse(response.body)).to eq([{ "id" => 1 }, { "id" => 2 }])
  end

  it "serializes a model through #json too" do
    response.json(Widget.new(id: 9, name: "z", active: false))
    expect(response.headers["content-type"]).to start_with("application/json")
    expect(JSON.parse(response.body)).to eq("id" => 9, "name" => "z", "active" => false)
  end

  it "leaves a plain Hash unchanged" do
    response.call({ ok: true })
    expect(response.headers["content-type"]).to start_with("application/json")
    expect(JSON.parse(response.body)).to eq("ok" => true)
  end

  it "leaves a plain String unchanged" do
    response.call("<h1>hi</h1>")
    expect(response.headers["content-type"]).to start_with("text/html")
    expect(response.body).to eq("<h1>hi</h1>")
  end
end
