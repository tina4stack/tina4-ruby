# frozen_string_literal: true

require "spec_helper"

# ── ORM model with snake_case fields for to_h case tests ─────────────────
class ParityArticle < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  string_field :image_url, length: 255
  string_field :created_at
end

# ── ORM subclass with no explicit auto_map setting ───────────────────────
class ParityDefault < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

RSpec.describe "v3.10.99 parity tests" do
  # =========================================================================
  # ORM — to_h case: :snake (default)
  # =========================================================================

  describe "ORM#to_h case: snake (default)" do
    it "returns snake_case keys by default" do
      article = ParityArticle.new(
        title: "Hello",
        image_url: "https://example.com/img.png",
        created_at: "2024-01-15"
      )
      hash = article.to_h
      expect(hash).to have_key(:image_url)
      expect(hash).to have_key(:created_at)
      expect(hash[:image_url]).to eq("https://example.com/img.png")
      expect(hash[:created_at]).to eq("2024-01-15")
    end
  end

  # =========================================================================
  # ORM — to_h case: :camel
  # =========================================================================

  describe "ORM#to_h case: camel" do
    it "returns camelCase keys when case is 'camel'" do
      article = ParityArticle.new(
        title: "Hello",
        image_url: "https://example.com/img.png",
        created_at: "2024-01-15"
      )
      hash = article.to_h(case: "camel")
      expect(hash).to have_key(:imageUrl)
      expect(hash).to have_key(:createdAt)
      expect(hash[:imageUrl]).to eq("https://example.com/img.png")
      expect(hash[:createdAt]).to eq("2024-01-15")
      # snake_case keys should not be present
      expect(hash).not_to have_key(:image_url)
      expect(hash).not_to have_key(:created_at)
    end
  end

  # =========================================================================
  # ORM — auto_map defaults to true
  # =========================================================================

  describe "ORM auto_map default" do
    it "defaults to true when not explicitly set" do
      expect(ParityDefault.auto_map).to be true
    end
  end

  # =========================================================================
  # Frond — replace filter with Hash argument
  # =========================================================================

  describe "Frond replace filter with Hash arg" do
    let(:engine) { Tina4::Frond.new }

    it "applies multiple replacements from a hash" do
      template = '{{ val|replace({"T": " ", "-": "/"}) }}'
      data = { "val" => "2024-01-15T10:30:00" }
      result = engine.render_string(template, data)
      expect(result).to eq("2024/01/15 10:30:00")
    end
  end

  # =========================================================================
  # Frond — replace filter with positional args
  # =========================================================================

  describe "Frond replace filter with positional args" do
    let(:engine) { Tina4::Frond.new }

    it "replaces old with new using two string arguments" do
      template = '{{ val|replace("hello", "world") }}'
      data = { "val" => "say hello" }
      result = engine.render_string(template, data)
      expect(result).to eq("say world")
    end
  end

  # =========================================================================
  # ServiceRunner — background registration
  # =========================================================================

  describe "ServiceRunner background registration" do
    before(:each) do
      Tina4::ServiceRunner.clear!
    end

    after(:each) do
      Tina4::ServiceRunner.clear!
    end

    it "registers a task without starting a server" do
      Tina4::ServiceRunner.register("parity_test", interval: 60) do |ctx|
        # no-op
      end

      services = Tina4::ServiceRunner.list
      expect(services.length).to eq(1)
      expect(services.first[:name]).to eq("parity_test")
      expect(services.first[:running]).to be false
    end
  end
end
