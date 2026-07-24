# frozen_string_literal: true

require "spec_helper"

# Lock-in: the startup banner only advertises surfaces that are REACHABLE.
#
# Regression this pins down (issue #99)
# -------------------------------------
# The banner printed
#
#     Swagger:   http://localhost:7147/swagger
#     Dashboard: http://localhost:7147/__dev
#
# unconditionally. In production (or with TINA4_DEBUG off) both of those return
# 404, so the banner (a) told an operator a dev surface was exposed when it was
# not, and (b) sent a developer to a dead link.
#
# banner_surface_lines is a PURE function of (port, two booleans) so this
# contract is testable without booting a server and grepping stdout. No
# dependency, no double -- not a mock test.
#
# Shape note: Ruby returns only the lines that apply (0, 1 or 2 entries, no
# leading newline) because print_banner puts them one per row; Python/PHP/Node
# return a fixed 2-tuple of "\n"-prefixed strings because they interpolate into
# one banner string. The RENDERED banner is identical in all four -- that is the
# parity that matters.
RSpec.describe "Tina4.banner_surface_lines" do
  let(:port) { 7147 }

  it "emits nothing when neither surface is reachable" do
    expect(Tina4.banner_surface_lines(port, swagger_enabled: false, dev_admin_enabled: false)).to eq([])
  end

  it "never leaks a path when both are off" do
    combined = Tina4.banner_surface_lines(port, swagger_enabled: false, dev_admin_enabled: false).join
    expect(combined).not_to include("/swagger")
    expect(combined).not_to include("/__dev")
  end

  it "advertises swagger only when swagger is on and debug is off" do
    lines = Tina4.banner_surface_lines(port, swagger_enabled: true, dev_admin_enabled: false)
    expect(lines).to eq(["  Swagger:   http://localhost:#{port}/swagger"])
  end

  it "advertises the dashboard only when debug is on and swagger is disabled" do
    lines = Tina4.banner_surface_lines(port, swagger_enabled: false, dev_admin_enabled: true)
    expect(lines).to eq(["  Dashboard: http://localhost:#{port}/__dev"])
  end

  it "advertises both in ordinary dev, swagger first" do
    lines = Tina4.banner_surface_lines(port, swagger_enabled: true, dev_admin_enabled: true)
    expect(lines).to eq([
                          "  Swagger:   http://localhost:#{port}/swagger",
                          "  Dashboard: http://localhost:#{port}/__dev"
                        ])
  end

  it "interpolates the port the server actually bound" do
    lines = Tina4.banner_surface_lines(9999, swagger_enabled: true, dev_admin_enabled: true)
    expect(lines).to all(include("9999"))
    expect(lines.join).not_to include(port.to_s)
  end

  it "returns one row per line, with no embedded newline" do
    Tina4.banner_surface_lines(port, swagger_enabled: true, dev_admin_enabled: true).each do |line|
      expect(line).not_to include("\n")
    end
  end
end
