# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"

# /__dev/api/system must carry `memory_mb`, the process's CURRENT resident set
# size in MB, because that is the field the dashboard's "Memory" figure reads
# (it showed "?" on Ruby, which never sent it). Parity with tina4-python#316 and
# tina4-nodejs#197.
#
# Real dispatch, no doubles: every request goes through Tina4::RackApp#call, the
# same Rack entry point Puma / the built-in server call, so the real router and
# the real /__dev gate (TINA4_DEBUG on + loopback peer) sit in front of the
# handler. The witness is the kernel's own figure for this process, read
# independently from /proc/self/status (Linux) or `ps` (macOS), while a real
# 150 MB string is held and then freed.
RSpec.describe "GET /__dev/api/system memory_mb (current process RSS)" do
  around(:each) do |example|
    saved = ENV["TINA4_DEBUG"]
    Dir.mktmpdir("tina4_devadmin_mem") do |tmp|
      ENV["TINA4_DEBUG"] = "true"
      Dir.chdir(tmp) do
        Tina4::Router.clear!
        example.run
      end
    end
  ensure
    saved.nil? ? ENV.delete("TINA4_DEBUG") : ENV["TINA4_DEBUG"] = saved
    Tina4::Router.clear!
  end

  let(:app) { Tina4::RackApp.new }

  def get_system(remote_addr: "127.0.0.1")
    env = {
      "REQUEST_METHOD" => "GET", "PATH_INFO" => "/__dev/api/system", "SCRIPT_NAME" => "",
      "QUERY_STRING" => "", "SERVER_NAME" => "localhost", "SERVER_PORT" => "7147",
      "SERVER_PROTOCOL" => "HTTP/1.1", "REMOTE_ADDR" => remote_addr, "HTTP_HOST" => "localhost",
      "rack.url_scheme" => "http", "rack.input" => StringIO.new(""), "rack.errors" => StringIO.new
    }
    status, _headers, body = app.call(env)
    text = +""
    body.each { |chunk| text << chunk.to_s }
    [status, (JSON.parse(text) rescue text)]
  end

  # The kernel's figure for THIS process in MB, read independently of the
  # framework: VmRSS / VmHWM on Linux, `ps -o rss=` (current only) on macOS.
  # nil where the OS exposes neither.
  def kernel_mb(key)
    if RUBY_PLATFORM.include?("linux")
      kb = File.read("/proc/self/status")[/#{key}:\s+(\d+)/, 1]
      kb && kb.to_i / 1024.0
    elsif RUBY_PLATFORM.include?("darwin") && key == "VmRSS"
      `ps -o rss= -p #{Process.pid}`.strip.to_i / 1024.0
    end
  end

  def near?(value, real)
    (value - real).abs <= 25 + 0.1 * real
  end

  it "answers 200 through the real app and carries a memory_mb field" do
    status, data = get_system
    expect(status).to eq(200)
    expect(data).to have_key("memory_mb")
  end

  it "is refused to a non-loopback peer, so the figure is not exposed off-box" do
    status, data = get_system(remote_addr: "203.0.113.9")
    expect(status).to eq(403)
    expect(data.is_a?(Hash) && data.key?("memory_mb")).to be(false)
  end

  it "reports memory_mb as the kernel's current RSS for this process, or nil where there is none" do
    _status, data = get_system
    real = kernel_mb("VmRSS")
    if real
      expect(data["memory_mb"]).to be_a(Numeric)
      expect(near?(data["memory_mb"], real)).to be(true),
        "memory_mb=#{data['memory_mb']} MB, kernel current RSS #{real.round(1)} MB"
      # memory.current_mb is the same figure.
      expect(data["memory"]["current_mb"]).to eq(data["memory_mb"])
    else
      # No RSS source on this OS (e.g. Windows): an honest nil, never a fake 0.
      expect(data["memory_mb"]).to be_nil
    end
  end

  it "tracks a real 150 MB allocation up and back down (current RSS, not the peak)" do
    before_rss = kernel_mb("VmRSS")
    if before_rss.nil?
      # No RSS source on this OS: the field stays nil even under load.
      blob = "x" * (150 * 1024 * 1024)
      _s, data = get_system
      expect(blob.bytesize).to eq(150 * 1024 * 1024)
      expect(data["memory_mb"]).to be_nil
      next
    end

    blob = "x" * (150 * 1024 * 1024) # every byte written, so every page is resident
    _s, held = get_system
    held_rss = kernel_mb("VmRSS")
    expect(blob.bytesize).to eq(150 * 1024 * 1024)
    expect(held_rss - before_rss).to be > 100, "precondition: holding the string grew RSS (#{before_rss.round(1)} -> #{held_rss.round(1)} MB)"
    expect(near?(held["memory_mb"], held_rss)).to be(true),
      "held: memory_mb=#{held['memory_mb']} MB, kernel current RSS #{held_rss.round(1)} MB"

    blob = nil
    GC.start(full_mark: true, immediate_sweep: true)
    GC.start(full_mark: true, immediate_sweep: true)
    _s, freed = get_system
    now_rss = kernel_mb("VmRSS")
    expect(held_rss - now_rss).to be > 100, "precondition: freeing the string lowered RSS (#{held_rss.round(1)} -> #{now_rss.round(1)} MB)"
    expect(near?(freed["memory_mb"], now_rss)).to be(true),
      "freed: memory_mb=#{freed['memory_mb']} MB, kernel current RSS #{now_rss.round(1)} MB"
    expect(held["memory_mb"] - freed["memory_mb"]).to be > 100,
      "memory_mb fell with the free: held #{held['memory_mb']} MB, freed #{freed['memory_mb']} MB"

    peak = kernel_mb("VmHWM")
    if peak
      # Linux: the peak is still the held size, so a figure that tracked the
      # peak (VmHWM / ru_maxrss) would sit 100+ MB above memory_mb now.
      expect(peak - freed["memory_mb"]).to be > 100,
        "memory_mb=#{freed['memory_mb']} MB is not the peak #{peak.round(1)} MB"
    end
  end
end
