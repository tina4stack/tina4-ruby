# frozen_string_literal: true

require "spec_helper"
require "tina4/cli"

RSpec.describe "Port/Host configuration" do
  let(:cli) { Tina4::CLI.new }

  describe "resolve_config" do
    # Access the private method for testing
    def resolve(key, cli_value)
      cli.send(:resolve_config, key, cli_value)
    end

    describe "port" do
      after { ENV.delete("PORT") }

      it "defaults to 7147 when no CLI flag and no ENV var" do
        ENV.delete("PORT")
        expect(resolve(:port, nil)).to eq(7147)
      end

      it "picks up PORT env var as fallback" do
        ENV["PORT"] = "9000"
        expect(resolve(:port, nil)).to eq(9000)
      end

      it "CLI flag overrides PORT env var" do
        ENV["PORT"] = "9000"
        expect(resolve(:port, 8080)).to eq(8080)
      end

      it "ignores empty PORT env var" do
        ENV["PORT"] = ""
        expect(resolve(:port, nil)).to eq(7147)
      end
    end

    describe "host" do
      after { ENV.delete("HOST") }

      it "defaults to 0.0.0.0 when no CLI flag and no ENV var" do
        ENV.delete("HOST")
        expect(resolve(:host, nil)).to eq("0.0.0.0")
      end

      it "picks up HOST env var as fallback" do
        ENV["HOST"] = "127.0.0.1"
        expect(resolve(:host, nil)).to eq("127.0.0.1")
      end

      it "CLI flag overrides HOST env var" do
        ENV["HOST"] = "127.0.0.1"
        expect(resolve(:host, "192.168.1.1")).to eq("192.168.1.1")
      end

      it "ignores empty HOST env var" do
        ENV["HOST"] = ""
        expect(resolve(:host, nil)).to eq("0.0.0.0")
      end
    end
  end

  describe "DEFAULT_PORT" do
    it "is 7147" do
      expect(Tina4::CLI.const_get(:DEFAULT_PORT)).to eq(7147)
    end
  end

  describe "DEFAULT_HOST" do
    it "is 0.0.0.0" do
      expect(Tina4::CLI.const_get(:DEFAULT_HOST)).to eq("0.0.0.0")
    end
  end
end
