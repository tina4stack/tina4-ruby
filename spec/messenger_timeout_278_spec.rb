# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Regression for tina4-ruby#278: the SMTP send timeout is configurable.
#
# No mocks. A REAL TCP server accepts the connection and then says nothing, so
# send blocks waiting for the SMTP greeting. With the timeout left at its 30 s
# default that is a 30 s hold; with a 1 s timeout the send must fail in about a
# second. The wall-clock is the instrument: a configured 1 s timeout that is
# honoured finishes well under the default, a hardcoded 30 s does not.

require "spec_helper"
require "socket"

RSpec.describe "Messenger SMTP timeout (#278)" do
  # A server that accepts TCP connections and never sends a byte.
  def with_silent_smtp
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    held = []
    stop = false
    thread = Thread.new do
      loop do
        break if stop

        begin
          ready = IO.select([server], nil, nil, 0.25)
          next unless ready

          held << server.accept # keep it open, never reply
        rescue IOError, Errno::EBADF
          break
        end
      end
    end
    yield port
  ensure
    stop = true
    thread&.kill
    thread&.join(2)
    held.each { |c| c.close rescue nil }
    server.close rescue nil
  end

  def time_send(port:, **kwargs)
    messenger = Tina4::Messenger.new(
      host: "127.0.0.1", port: port, encryption: "none",
      from_address: "app@localhost", **kwargs
    )
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = messenger.send(to: "someone@localhost", subject: "test", body: "hello")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    # The host never speaks SMTP, so the send always fails — what matters is HOW
    # LONG it waited, and that the failure is reported AS a timeout.
    expect(result[:success]).to be false
    [elapsed, result]
  end

  it "bounds the send by a constructor timeout and reports a timeout" do
    with_silent_smtp do |port|
      elapsed, result = time_send(port: port, timeout: 1)
      expect(elapsed).to be < 8, "a 1 s timeout should fail fast, not hold ~30 s (took #{elapsed.round(1)} s)"
      expect(result[:message].to_s).to match(/respond within|time/i),
        "a silent server must be reported as a timeout, got #{result[:message].inspect}"
    end
  end

  it "bounds the send by TINA4_MAIL_TIMEOUT" do
    with_silent_smtp do |port|
      ENV["TINA4_MAIL_TIMEOUT"] = "1"
      begin
        elapsed, = time_send(port: port)
        expect(elapsed).to be < 8, "TINA4_MAIL_TIMEOUT=1 should fail fast (took #{elapsed.round(1)} s)"
      ensure
        ENV.delete("TINA4_MAIL_TIMEOUT")
      end
    end
  end

  it "defaults to 30 seconds when nothing is configured" do
    expect(Tina4::Messenger.new(host: "127.0.0.1", encryption: "none").timeout).to eq(30)
  end

  it "warns once and falls back to 30 on a non-numeric TINA4_MAIL_TIMEOUT" do
    ENV["TINA4_MAIL_TIMEOUT"] = "not-a-number"
    begin
      expect(Tina4::Messenger.new(host: "127.0.0.1", encryption: "none").timeout).to eq(30)
    ensure
      ENV.delete("TINA4_MAIL_TIMEOUT")
    end
  end

  it "falls back to 30 on TINA4_MAIL_TIMEOUT=0 (garbage, not an opt-out)" do
    ENV["TINA4_MAIL_TIMEOUT"] = "0"
    begin
      expect(Tina4::Messenger.new(host: "127.0.0.1", encryption: "none").timeout).to eq(30)
    ensure
      ENV.delete("TINA4_MAIL_TIMEOUT")
    end
  end

  it "refuses an explicit sub-second timeout" do
    expect { Tina4::Messenger.new(host: "127.0.0.1", encryption: "none", timeout: 0) }
      .to raise_error(ArgumentError)
  end

  it "no longer honours SMTP_TIMEOUT (dropped for parity with the PHP master)" do
    ENV.delete("TINA4_MAIL_TIMEOUT")
    ENV["SMTP_TIMEOUT"] = "1"
    begin
      expect(Tina4::Messenger.new(host: "127.0.0.1", encryption: "none").timeout).to eq(30)
    ensure
      ENV.delete("SMTP_TIMEOUT")
    end
  end
end
