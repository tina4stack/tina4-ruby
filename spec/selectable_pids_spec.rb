# frozen_string_literal: true

# Lock-in specs for the port-reclaim PID safety rule.
#
# `tina4 serve` reclaims a port from a stale dev server by reading `lsof -ti`
# and signalling what it finds. Before 3.13.84 that output was never validated,
# so a non-numeric field became 0 -- and signalling PID 0 sends the signal to
# EVERY process in the caller's own process group. In a container the server IS
# PID 1, so it killed itself.
#
# selectable_pids is pure, so these specs run over real inputs with no double.

require "spec_helper"
require "tina4/cli"

RSpec.describe "port-reclaim PID safety" do
  # The rule lives on the CLI; instantiate without running a command.
  let(:cli) { Tina4::CLI.allocate }

  def selectable(output, me, my_group = nil)
    cli.send(:selectable_pids, output, me, my_group)
  end

  # ── negative cases: what must NEVER be signalled ────────────────────────

  it "never coerces a non-numeric token into a PID" do
    expect(selectable("php", 999)).to eq([])
    expect(selectable("1 /usr/local/bin/ruby app.rb", 999)).to eq([])
  end

  it "never signals PID 0 (that is our whole process group)" do
    expect(selectable("0", 999)).to eq([])
  end

  it "never signals PID 1 (init, or the server itself in a container)" do
    expect(selectable("1", 999)).to eq([])
  end

  it "never signals its own PID" do
    expect(selectable("4242", 4242)).to eq([])
  end

  it "never signals its own process group" do
    expect(selectable("777", 4242, 777)).to eq([])
  end

  it "yields nothing for empty or whitespace-only output" do
    expect(selectable("", 999)).to eq([])
    expect(selectable("   \n\t ", 999)).to eq([])
  end

  # ── positive cases: a real stale sibling still gets reclaimed ───────────

  it "selects a real foreign PID" do
    expect(selectable("5150", 4242)).to eq([5150])
  end

  it "selects every real foreign PID" do
    expect(selectable("5150\n5151\n5152", 4242)).to eq([5150, 5151, 5152])
  end

  it "drops unsafe PIDs while keeping the safe ones" do
    expect(selectable("ruby 0 1 4242 777 5150 5151", 4242, 777)).to eq([5150, 5151])
  end

  it "reports a duplicate PID once" do
    expect(selectable("5150 5150 5150", 4242)).to eq([5150])
  end
end
