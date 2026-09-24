# frozen_string_literal: true

require "spec_helper"

# Tina4::Base64 replaces the base64 gem (a bundled gem since Ruby 3.4). The
# oracle here is RFC 4648 section 10 and hand-derived bytes, never the helper
# itself and never the gem, so the spec means the same on every Ruby.
RSpec.describe Tina4::Base64 do
  rfc4648_vectors = {
    "" => "", "f" => "Zg==", "fo" => "Zm8=", "foo" => "Zm9v",
    "foob" => "Zm9vYg==", "fooba" => "Zm9vYmE=", "foobar" => "Zm9vYmFy"
  }

  describe ".strict_encode64 / .strict_decode64" do
    rfc4648_vectors.each do |plain, encoded|
      it "round-trips the RFC 4648 vector #{plain.inspect}" do
        expect(described_class.strict_encode64(plain)).to eq(encoded)
        expect(described_class.strict_decode64(encoded)).to eq(plain.b)
      end
    end

    it "never inserts a line feed, however long the input" do
      expect(described_class.strict_encode64("a" * 200)).not_to include("\n")
    end

    it "encodes raw bytes, not characters" do
      expect(described_class.strict_encode64("\xFF\xFE\x00".b)).to eq("//4A")
    end

    it "returns binary (ASCII-8BIT) bytes from decode" do
      expect(described_class.strict_decode64("w6k=")).to eq("\xC3\xA9".b)
      expect(described_class.strict_decode64("w6k=").encoding).to eq(Encoding::BINARY)
    end

    ["Zm9v\n", "Zm9", "Zm9v!", "Zg=", "Zm9v===="].each do |bad|
      it "raises ArgumentError on non-canonical input #{bad.inspect}" do
        expect { described_class.strict_decode64(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".encode64 / .decode64 (MIME)" do
    it "wraps every 60 encoded characters and ends with a newline" do
      encoded = described_class.encode64("a" * 50)
      lines = encoded.split("\n")
      expect(lines.first.length).to eq(60)
      expect(encoded).to end_with("\n")
      expect(encoded.delete("\n")).to eq(described_class.strict_encode64("a" * 50))
    end

    it "decodes leniently: line feeds and junk are skipped, not raised on" do
      expect(described_class.decode64("Zm9v\nYmFy\n")).to eq("foobar".b)
      expect(described_class.decode64("Zm9v!!YmFy")).to eq("foobar".b)
    end
  end

  describe ".urlsafe_encode64 / .urlsafe_decode64" do
    it "uses - and _ in place of + and /" do
      expect(described_class.urlsafe_encode64("\xFB\xFF".b)).to eq("-_8=")
    end

    it "drops the padding when asked" do
      expect(described_class.urlsafe_encode64("f", padding: false)).to eq("Zg")
      expect(described_class.urlsafe_encode64("fo", padding: false)).to eq("Zm8")
      expect(described_class.urlsafe_encode64("foo", padding: false)).to eq("Zm9v")
    end

    it "decodes padded and unpadded input alike" do
      expect(described_class.urlsafe_decode64("Zg==")).to eq("f".b)
      expect(described_class.urlsafe_decode64("Zg")).to eq("f".b)
      expect(described_class.urlsafe_decode64("-_8")).to eq("\xFB\xFF".b)
    end

    it "does not mutate the caller's string" do
      input = +"-_8"
      described_class.urlsafe_decode64(input)
      expect(input).to eq("-_8")
    end

    it "raises ArgumentError on invalid input" do
      expect { described_class.urlsafe_decode64("Z!8") }.to raise_error(ArgumentError)
      expect { described_class.urlsafe_decode64("Zg=") }.to raise_error(ArgumentError)
    end
  end
end
