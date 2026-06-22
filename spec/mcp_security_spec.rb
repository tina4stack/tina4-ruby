# frozen_string_literal: true

require "spec_helper"

# MCP endpoint security guard (3.13.40 P0 — Ruby mirror of the Python master
# tests/test_mcp_security.py and the PHP McpSecurityTest).
#
# Locks in the capability / per-request authorisation split that replaced the
# old config-host mcp_enabled? gate, plus the read-only guard on database_query
# and the identifier guard on database_columns. Regression cover for the audit
# finding that a 0.0.0.0-bound TINA4_DEBUG box exposed the MCP tool registry to
# remote unauthenticated callers. The trust decision uses the RAW socket peer,
# never X-Forwarded-For.
RSpec.describe "Tina4 MCP security guard" do
  around(:each) do |example|
    keys = %w[TINA4_MCP TINA4_DEBUG TINA4_MCP_REMOTE TINA4_MCP_TOKEN TINA4_API_KEY TINA4_HOST_NAME]
    saved = keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
    keys.each { |k| ENV.delete(k) }
    example.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  describe "Tina4.is_loopback?" do
    it "is true for loopback addresses (and empty / in-process)" do
      ["127.0.0.1", "127.0.0.5", "::1", "::ffff:127.0.0.1", "localhost", "", nil].each do |ip|
        expect(Tina4.is_loopback?(ip)).to be(true), ip.inspect
      end
    end

    it "is false for non-loopback addresses (0.0.0.0 is a bind addr, not a peer)" do
      ["0.0.0.0", "1.2.3.4", "10.0.0.5", "192.168.1.10",
       "::ffff:1.2.3.4", "2001:db8::1", "203.0.113.9"].each do |ip|
        expect(Tina4.is_loopback?(ip)).to be(false), ip
      end
    end
  end

  describe "Tina4.request_allowed?" do
    it "denies even loopback when the capability is off" do
      expect(Tina4.request_allowed?("127.0.0.1")).to be false
    end

    it "allows loopback (and in-process) when enabled" do
      ENV["TINA4_DEBUG"] = "true"
      expect(Tina4.request_allowed?("127.0.0.1")).to be true
      expect(Tina4.request_allowed?("")).to be true
    end

    it "denies a remote caller without the remote opt-in" do
      ENV["TINA4_DEBUG"] = "true"
      expect(Tina4.request_allowed?("1.2.3.4")).to be false
    end

    it "denies a remote caller with the opt-in but no token" do
      ENV["TINA4_DEBUG"] = "true"
      ENV["TINA4_MCP_REMOTE"] = "true"
      expect(Tina4.request_allowed?("1.2.3.4", has_valid_token: false)).to be false
    end

    it "allows a remote caller with the opt-in AND a valid token" do
      ENV["TINA4_DEBUG"] = "true"
      ENV["TINA4_MCP_REMOTE"] = "true"
      expect(Tina4.request_allowed?("1.2.3.4", has_valid_token: true)).to be true
    end

    it "a 0.0.0.0 bind host does NOT admit a remote caller (regression)" do
      ENV["TINA4_DEBUG"] = "true"
      ENV["TINA4_HOST_NAME"] = "0.0.0.0:7145"
      expect(Tina4.request_allowed?("203.0.113.9")).to be false
    end
  end

  describe "database_query read-only guard" do
    let(:server) { Tina4._default_mcp_server }

    around(:each) do |example|
      saved = ENV["TINA4_DATABASE_URL"]
      ENV["TINA4_DATABASE_URL"] = "sqlite://:memory:"
      Tina4.bind_database(Tina4::Database.new("sqlite://:memory:"))
      example.run
      saved.nil? ? ENV.delete("TINA4_DATABASE_URL") : (ENV["TINA4_DATABASE_URL"] = saved)
    end

    def query(sql, params = "[]")
      raw = server.handle_message(JSON.generate({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "database_query", "arguments" => { "sql" => sql, "params" => params } }
      }))
      payload = JSON.parse(raw)
      JSON.parse(payload.dig("result", "content", 0, "text"))
    end

    it "allows a SELECT" do
      out = query("SELECT 1 AS n")
      expect(out).to have_key("records")
      expect(out).not_to have_key("error")
    end

    it "rejects an UPDATE" do
      out = query("UPDATE users SET is_admin = 1")
      expect(out["error"].to_s.downcase).to include("read-only")
    end

    it "rejects DELETE and DROP" do
      expect(query("DELETE FROM users")).to have_key("error")
      expect(query("DROP TABLE users")).to have_key("error")
    end

    it "rejects stacked statements" do
      out = query("SELECT 1; DROP TABLE users")
      expect(out["error"].to_s.downcase).to include("multiple statements")
    end

    it "binds parameters (regression: params were dropped before)" do
      out = query("SELECT ? AS n", "[42]")
      expect(out).not_to have_key("error")
      expect(out["records"].first.values.first.to_i).to eq(42)
    end
  end

  describe "database_columns identifier guard" do
    let(:server) { Tina4._default_mcp_server }

    around(:each) do |example|
      saved = ENV["TINA4_DATABASE_URL"]
      ENV["TINA4_DATABASE_URL"] = "sqlite://:memory:"
      Tina4.bind_database(Tina4::Database.new("sqlite://:memory:"))
      example.run
      saved.nil? ? ENV.delete("TINA4_DATABASE_URL") : (ENV["TINA4_DATABASE_URL"] = saved)
    end

    it "rejects an injection-shaped table name" do
      raw = server.handle_message(JSON.generate({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "database_columns", "arguments" => { "table" => "users; DROP TABLE users" } }
      }))
      out = JSON.parse(JSON.parse(raw).dig("result", "content", 0, "text"))
      expect(out["error"].to_s.downcase).to include("invalid table")
    end
  end
end
