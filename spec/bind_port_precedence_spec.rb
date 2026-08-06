# frozen_string_literal: true

# TINA4_PORT MUST BEAT BARE PORT, ON THE PATH THAT BINDS THE SOCKET.
#
# The CLI documents CLI flag > TINA4_PORT > PORT > default, and calls bare PORT
# "Legacy bare server port (prefer TINA4_PORT)". Ruby had it BOTH ways at once:
# webserver.rb read TINA4_PORT first, tina4.rb read bare PORT first. The same
# variable meant different things depending which entry point you came through.
#
# Both now go through Tina4.resolve_bind_port, so they cannot drift again.
#
# Identical case names in all four frameworks:
#   tina4-python/tests/test_bind_port_precedence.py
#   tina4-php/tests/BindPortPrecedenceTest.php
#   tina4-nodejs/test/bindPortPrecedence.test.ts
require "spec_helper"

RSpec.describe "bind port precedence" do
  around do |example|
    saved = %w[TINA4_PORT PORT TINA4_HOST HOST].to_h { |k| [k, ENV[k]] }
    %w[TINA4_PORT PORT TINA4_HOST HOST].each { |k| ENV.delete(k) }
    Tina4.instance_variable_set(:@warned_bind_vars, {})
    example.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "tina4 port wins over bare port" do
    ENV["TINA4_PORT"] = "45001"
    ENV["PORT"] = "9999"
    expect(Tina4.resolve_bind_port(7147)).to eq(45_001)
  end

  it "bare port is still honoured" do
    ENV["PORT"] = "9999"
    expect(Tina4.resolve_bind_port(7147)).to eq(9999)
  end

  it "the default applies when nothing is set" do
    expect(Tina4.resolve_bind_port(7147)).to eq(7147)
  end

  it "a non numeric value falls through" do
    ENV["TINA4_PORT"] = "not-a-port"
    ENV["PORT"] = "9999"
    expect(Tina4.resolve_bind_port(7147)).to eq(9999)
  end

  it "tina4 host wins over bare host" do
    ENV["TINA4_HOST"] = "127.0.0.1"
    ENV["HOST"] = "0.0.0.0"
    expect(Tina4.resolve_bind_host).to eq("127.0.0.1")
  end

  # The drift that actually happened: two entry points, one variable, two
  # answers. Both must now agree.
  it "the web server and the resolver agree" do
    ENV["TINA4_PORT"] = "45001"
    ENV["PORT"] = "9999"
    server = Tina4::WebServer.new(nil)
    expect(server.instance_variable_get(:@port)).to eq(Tina4.resolve_bind_port(7147))
  end
end
