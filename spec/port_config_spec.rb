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

      # DUALPORT-DEC-02 (DUALPORT-BASE-PRECEDENCE): resolve_config used to read
      # bare PORT only, ignoring TINA4_PORT -- the name the CLI documents and
      # prefers -- while Tina4.resolve_bind_port (WebServer / Tina4.run!) and
      # Tina4.mcp_port (the supervisor/+2000 port) both already read
      # TINA4_PORT first. Under `tina4ruby serve` with only TINA4_PORT set, the
      # main/AI/supervisor ports derived from DIFFERENT bases. Single-sourced
      # now: see spec/dual_port_base_precedence_spec.rb for the cross-path proof.
      describe "TINA4_PORT precedence (DUALPORT-DEC-02)" do
        after do
          ENV.delete("TINA4_PORT")
          ENV.delete("PORT")
        end

        it "TINA4_PORT wins over bare PORT" do
          ENV["TINA4_PORT"] = "45201"
          ENV["PORT"] = "9999"
          expect(resolve(:port, nil)).to eq(45_201)
        end

        it "bare PORT is still honoured when TINA4_PORT is unset" do
          ENV.delete("TINA4_PORT")
          ENV["PORT"] = "45202"
          expect(resolve(:port, nil)).to eq(45_202)
        end

        it "a non-numeric TINA4_PORT falls through to PORT" do
          ENV["TINA4_PORT"] = "not-a-port"
          ENV["PORT"] = "45203"
          expect(resolve(:port, nil)).to eq(45_203)
        end

        it "a CLI flag still overrides TINA4_PORT" do
          ENV["TINA4_PORT"] = "45204"
          expect(resolve(:port, 8080)).to eq(8080)
        end
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
    after { ENV.delete("PORT") }

    it "is the port resolution actually falls back to (no CLI flag, no ENV)" do
      ENV.delete("PORT")
      resolved = cli.send(:resolve_config, :port, nil)
      expect(resolved).to eq(Tina4::CLI.const_get(:DEFAULT_PORT))
      # and it is the documented value (CLAUDE.md / scaffolding contract)
      expect(resolved).to eq(7147)
    end
  end

  describe "DEFAULT_HOST" do
    after { ENV.delete("HOST") }

    it "is the host resolution actually falls back to (no CLI flag, no ENV)" do
      ENV.delete("HOST")
      resolved = cli.send(:resolve_config, :host, nil)
      expect(resolved).to eq(Tina4::CLI.const_get(:DEFAULT_HOST))
      # and it is the documented value (bind-all default)
      expect(resolved).to eq("0.0.0.0")
    end
  end
end
