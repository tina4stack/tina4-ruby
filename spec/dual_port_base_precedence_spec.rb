# frozen_string_literal: true

# DUALPORT-DEC-02 (DUALPORT-BASE-PRECEDENCE) -- ONE base feeds every derived
# port. Feature 128 (tina4-documentation/plan/v3/features/128-dual-test-port.md).
#
# Three Ruby entry points resolve the SAME `TINA4_PORT`/`PORT` pair independently:
#   - Tina4::CLI#resolve_config(:port, ...)  -- what `tina4ruby serve` binds
#     the MAIN port to, and therefore what the AI port (base + 1000, inside
#     Tina4::WebServer#start) derives from too.
#   - Tina4.resolve_bind_port                -- what Tina4::WebServer.new /
#     Tina4.run! (the `app.rb` entry point) resolve to when no port is passed.
#   - Tina4.mcp_port                          -- the supervisor/agent proxy
#     port (base + 2000), a DIFFERENT construct from the AI port -- not
#     touched by this feature, but it must still SHARE the same base.
#
# Before this fix, resolve_config(:port, nil) read bare PORT only and ignored
# TINA4_PORT, while the other two already preferred TINA4_PORT -- so under
# `tina4ruby serve` with only TINA4_PORT set, the main/AI ports and the
# supervisor port derived from DIFFERENT bases. Python and PHP were already
# consistent (TINA4_PORT > PORT everywhere); only Ruby's CLI disagreed with
# its own webserver and MCP paths.
#
# Pure-function unit test, no dependency and no double: reads ENV, calls three
# real production methods, asserts they agree. Identical shape to (and lives
# beside) spec/bind_port_precedence_spec.rb and spec/port_config_spec.rb's
# TINA4_PORT precedence block -- see the case names for the DUALPORT-DEC-01
# real-socket AI-port proof.
require "spec_helper"
require "tina4/cli"

RSpec.describe "dual-port base precedence (DUALPORT-DEC-02)" do
  let(:cli) { Tina4::CLI.new }

  around do |example|
    saved = %w[TINA4_PORT PORT].to_h { |k| [k, ENV[k]] }
    %w[TINA4_PORT PORT].each { |k| ENV.delete(k) }
    example.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "with only TINA4_PORT set, the CLI base agrees with Tina4.resolve_bind_port and the MCP/supervisor base (+2000) - one base feeds every derived port" do
    ENV["TINA4_PORT"] = "45301"

    cli_base = cli.send(:resolve_config, :port, nil)
    expect(cli_base).to eq(45_301)

    # WebServer / Tina4.run! path -- also feeds the AI port math (base + 1000)
    # inside Tina4::WebServer#start, proven with real sockets in
    # spec/dual_port_contract_spec.rb.
    expect(Tina4.resolve_bind_port(7147)).to eq(cli_base)

    # MCP/supervisor path (base + 2000) -- a DIFFERENT construct from the AI
    # port, not owned by this feature, but it must derive from the SAME base.
    expect(Tina4.mcp_port).to eq(cli_base + 2000)
  end

  it "with only bare PORT set (TINA4_PORT unset), all three still agree" do
    ENV["PORT"] = "45302"

    cli_base = cli.send(:resolve_config, :port, nil)
    expect(cli_base).to eq(45_302)
    expect(Tina4.resolve_bind_port(7147)).to eq(cli_base)
    expect(Tina4.mcp_port).to eq(cli_base + 2000)
  end

  it "with NEITHER set, all three fall back to their own default consistently" do
    cli_base = cli.send(:resolve_config, :port, nil)
    expect(cli_base).to eq(7147)
    expect(Tina4.resolve_bind_port(7147)).to eq(7147)
    expect(Tina4.mcp_port).to eq(9147)
  end
end
