# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::FakeData do
  # ── Basic generators ──────────────────────────────────────────────

  describe "name generators" do
    it "returns a full name with first and last" do
      fake = described_class.new
      name = fake.name
      expect(name).to be_a(String)
      expect(name).to include(" ")
    end

    it "returns a first name" do
      fake = described_class.new
      first = fake.first_name
      expect(first).to be_a(String)
      expect(first.length).to be > 0
    end

    it "returns a last name" do
      fake = described_class.new
      last = fake.last_name
      expect(last).to be_a(String)
      expect(last.length).to be > 0
    end

    it "first_name comes from the FIRST_NAMES list" do
      fake = described_class.new(seed: 42)
      expect(described_class::FIRST_NAMES).to include(fake.first_name)
    end

    it "last_name comes from the LAST_NAMES list" do
      fake = described_class.new(seed: 42)
      expect(described_class::LAST_NAMES).to include(fake.last_name)
    end
  end

  # ── Email ─────────────────────────────────────────────────────────

  describe "#email" do
    it "contains an @ sign" do
      fake = described_class.new
      expect(fake.email).to include("@")
    end

    it "has a domain with a dot" do
      fake = described_class.new
      domain = fake.email.split("@").last
      expect(domain).to include(".")
    end

    it "accepts from_name override" do
      fake = described_class.new(seed: 42)
      email = fake.email(from_name: "Jane Doe")
      expect(email).to start_with("jane.doe")
    end
  end

  # ── Phone ─────────────────────────────────────────────────────────

  describe "#phone" do
    it "contains at least 10 digits" do
      fake = described_class.new
      digits = fake.phone.gsub(/\D/, "")
      expect(digits.length).to be >= 10
    end

    it "starts with +1" do
      fake = described_class.new
      expect(fake.phone).to start_with("+1")
    end
  end

  # ── Sentence / text generators ────────────────────────────────────

  describe "#sentence" do
    it "ends with a period" do
      fake = described_class.new
      expect(fake.sentence).to end_with(".")
    end

    it "respects the word count parameter" do
      fake = described_class.new(seed: 42)
      s = fake.sentence(words: 5)
      word_count = s.chomp(".").split.length
      expect(word_count).to eq(5)
    end

    it "starts with an uppercase letter" do
      fake = described_class.new(seed: 42)
      expect(fake.sentence[0]).to match(/[A-Z]/)
    end
  end

  describe "#paragraph" do
    it "contains multiple sentences" do
      fake = described_class.new
      p = fake.paragraph(sentences: 3)
      expect(p.scan(/\./).length).to be >= 3
    end
  end

  describe "#word" do
    it "returns a non-empty string" do
      fake = described_class.new
      w = fake.word
      expect(w).to be_a(String)
      expect(w.length).to be > 0
    end

    it "comes from the WORDS list" do
      fake = described_class.new(seed: 42)
      expect(described_class::WORDS).to include(fake.word)
    end
  end

  # ── Number generators ─────────────────────────────────────────────

  describe "#integer" do
    it "returns value within default range" do
      fake = described_class.new
      val = fake.integer
      expect(val).to be_between(0, 10_000)
    end

    it "respects min and max parameters" do
      fake = described_class.new(seed: 42)
      20.times do
        val = fake.integer(min: 10, max: 50)
        expect(val).to be_between(10, 50)
      end
    end
  end

  describe "#numeric" do
    it "returns value within range" do
      fake = described_class.new(seed: 42)
      20.times do
        val = fake.numeric(min: 1.0, max: 10.0)
        expect(val).to be_between(1.0, 10.0)
      end
    end

    it "respects decimal precision" do
      fake = described_class.new(seed: 42)
      val = fake.numeric(min: 0.0, max: 100.0, decimals: 3)
      # Check no more than 3 decimal places
      parts = val.to_s.split(".")
      expect(parts.last.length).to be <= 3 if parts.length == 2
    end
  end

  describe "#boolean" do
    it "returns 0 or 1" do
      fake = described_class.new
      val = fake.boolean
      expect([0, 1]).to include(val)
    end
  end

  # ── Date / time generators ────────────────────────────────────────

  describe "#date" do
    it "returns YYYY-MM-DD format" do
      fake = described_class.new(seed: 42)
      expect(fake.date).to match(/\A\d{4}-\d{2}-\d{2}\z/)
    end

    it "respects year range" do
      fake = described_class.new(seed: 42)
      d = fake.date(start_year: 2023, end_year: 2024)
      year = d.split("-").first.to_i
      expect(year).to be_between(2023, 2024)
    end
  end

  describe "#timestamp" do
    it "returns date-time format" do
      fake = described_class.new(seed: 42)
      expect(fake.timestamp).to match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/)
    end
  end

  describe "#datetime" do
    it "returns a Time object" do
      fake = described_class.new(seed: 42)
      expect(fake.datetime).to be_a(Time)
    end
  end

  # ── UUID ──────────────────────────────────────────────────────────

  describe "#uuid" do
    it "matches UUID format" do
      fake = described_class.new(seed: 42)
      expect(fake.uuid).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end
  end

  # ── URL ───────────────────────────────────────────────────────────

  describe "#url" do
    it "starts with https://" do
      fake = described_class.new
      expect(fake.url).to start_with("https://")
    end

    it "contains a domain" do
      fake = described_class.new
      expect(fake.url).to include(".")
    end
  end

  # ── Address / location ────────────────────────────────────────────

  describe "#address" do
    it "returns a non-empty string" do
      fake = described_class.new(seed: 42)
      expect(fake.address).to be_a(String)
      expect(fake.address.length).to be > 0
    end

    it "contains a street type" do
      fake = described_class.new(seed: 42)
      types = described_class::STREET_TYPES
      addr = fake.address
      expect(types.any? { |t| addr.include?(t) }).to be true
    end
  end

  describe "#city" do
    it "comes from the CITIES list" do
      fake = described_class.new(seed: 42)
      expect(described_class::CITIES).to include(fake.city)
    end
  end

  describe "#country" do
    it "comes from the COUNTRIES list" do
      fake = described_class.new(seed: 42)
      expect(described_class::COUNTRIES).to include(fake.country)
    end
  end

  # ── Other generators ──────────────────────────────────────────────

  describe "#slug" do
    it "returns hyphenated words" do
      fake = described_class.new(seed: 42)
      slug = fake.slug(words: 3)
      expect(slug.split("-").length).to eq(3)
    end
  end

  describe "#company" do
    it "returns a non-empty string" do
      fake = described_class.new(seed: 42)
      expect(fake.company.length).to be > 0
    end
  end

  describe "#color_hex" do
    it "matches hex color format" do
      fake = described_class.new(seed: 42)
      expect(fake.color_hex).to match(/\A#[0-9a-f]{6}\z/)
    end
  end

  describe "#password" do
    it "returns correct length" do
      fake = described_class.new(seed: 42)
      expect(fake.password(length: 20).length).to eq(20)
    end

    it "contains only alphanumeric characters" do
      fake = described_class.new(seed: 42)
      expect(fake.password).to match(/\A[a-zA-Z0-9]+\z/)
    end
  end

  describe "#choice" do
    it "returns an element from the given list" do
      fake = described_class.new(seed: 42)
      items = %w[a b c]
      expect(items).to include(fake.choice(items))
    end
  end

  describe "#zip_code" do
    it "returns a 5-digit string" do
      fake = described_class.new(seed: 42)
      expect(fake.zip_code).to match(/\A\d{5}\z/)
    end
  end

  describe "#blob" do
    it "returns binary data of specified size" do
      fake = described_class.new
      data = fake.blob(size: 32)
      expect(data.bytesize).to eq(32)
    end
  end

  describe "#json_data" do
    it "returns a hash" do
      fake = described_class.new(seed: 42)
      expect(fake.json_data).to be_a(Hash)
    end

    it "uses provided keys" do
      fake = described_class.new(seed: 42)
      result = fake.json_data(keys: %w[foo bar])
      expect(result.keys).to eq(%w[foo bar])
    end
  end

  describe "#text" do
    it "respects max_length" do
      fake = described_class.new(seed: 42)
      t = fake.text(max_length: 50)
      expect(t.length).to be <= 50
    end
  end

  # ── Deterministic seeding ─────────────────────────────────────────

  describe "deterministic seeding" do
    it "same seed produces same output" do
      a = described_class.new(seed: 123)
      b = described_class.new(seed: 123)
      expect(a.name).to eq(b.name)
      expect(a.email).to eq(b.email)
      expect(a.integer).to eq(b.integer)
    end

    it "different seeds produce different output" do
      a = described_class.new(seed: 1)
      b = described_class.new(seed: 2)
      # Very unlikely to match with different seeds
      names_differ = a.name != b.name
      a2 = described_class.new(seed: 1)
      b2 = described_class.new(seed: 2)
      emails_differ = a2.email != b2.email
      expect(names_differ || emails_differ).to be true
    end

    it "seed factory method works" do
      fake = described_class.seed(42)
      expect(fake).to be_a(described_class)
      expect(fake.name).to be_a(String)
    end
  end

  # ── for_field smart generation ────────────────────────────────────

  describe "#for_field" do
    it "generates integer for integer type" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :integer })
      expect(val).to be_a(Integer)
    end

    it "generates string for string type" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :string, length: 50 })
      expect(val).to be_a(String)
      expect(val.length).to be <= 50
    end

    it "generates email for email column" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :string, length: 100 }, "email")
      expect(val).to include("@")
    end

    it "generates phone for phone column" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :string, length: 30 }, "phone")
      expect(val.gsub(/\D/, "").length).to be >= 10
    end

    it "returns nil for auto-increment primary keys" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :integer, primary_key: true, auto_increment: true })
      expect(val).to be_nil
    end

    it "generates date for date type" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :date })
      expect(val).to match(/\A\d{4}-\d{2}-\d{2}\z/)
    end

    it "generates boolean for boolean type" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :boolean })
      expect([0, 1]).to include(val)
    end

    it "generates float for float type" do
      fake = described_class.new(seed: 42)
      val = fake.for_field({ type: :float })
      expect(val).to be_a(Float)
    end
  end
end
