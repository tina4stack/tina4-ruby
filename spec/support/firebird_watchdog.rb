# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "uri"
require "tmpdir"

# ── Firebird watchdog: a leaked transaction FAILS a spec instead of hanging it ─
#
# SPECS ONLY - the framework's own transaction settings are untouched.
#
# Why not a lock timeout: the `fb` gem's default transaction is already
# NO WAIT (isc_tpb_nowait), and its transaction-option parser has no LOCK
# TIMEOUT keyword. The hang that stalled the lab was not a row-lock wait at
# all: a connection whose failed fetch left a statement and a transaction
# open could not even be closed, and the NEXT connection's DROP TABLE then
# waited on that attachment's metadata lock with no bound (measured: 199.7s
# until killed; SET STATEMENT TIMEOUT does not interrupt it either). The gem
# also never releases the GVL, so an in-process Timeout cannot fire.
#
# So the guard lives in a separate PROCESS: before the example runs, a forked
# child waits up to +seconds+. When the example finishes in time the pipe
# closes and the child exits. When it does not, the child attaches to the SAME
# database and deletes every MON$ATTACHMENTS row owned by the spec process -
# Firebird's own way to cancel an attachment - so the blocked call returns
# and the example FAILS, loudly, instead of holding the lab. Cancelling the
# leaked attachment can also let the blocked call SUCCEED, so the child leaves
# a marker and the parent raises after the example whenever the watchdog fired.
module FirebirdWatchdog
  DEFAULT_SECONDS = 20

  def self.with_watchdog(url, seconds: DEFAULT_SECONDS)
    return yield if url.to_s.empty?

    owner = Process.pid
    marker = File.join(Dir.tmpdir, "tina4-fb-watchdog-#{owner}-#{rand(1 << 32)}")
    reader, writer = IO.pipe
    child = fork do
      writer.close
      if IO.select([reader], nil, nil, seconds).nil?
        File.write(marker, "fired")
        cancel_attachments(url, owner, seconds)
      end
      exit!(0) # skip the parent's at_exit hooks (RSpec, SpecTmpdir)
    end
    reader.close
    result = yield
    writer.close
    Process.wait(child)
    child = nil
    if File.exist?(marker)
      raise "FirebirdWatchdog: a Firebird call was still blocked after #{seconds}s (a leaked " \
            "transaction or statement); its attachments were cancelled"
    end
    result
  ensure
    writer.close if writer && !writer.closed?
    Process.wait(child) if child
    File.delete(marker) if marker && File.exist?(marker)
  end

  # Runs in the watchdog child only.
  def self.cancel_attachments(url, owner, seconds)
    require "fb"
    uri = URI.parse(url)
    database = "#{uri.host}/#{uri.port || 3050}:#{uri.path.sub(%r{\A/(?=/)}, '')}"
    connection = Fb::Database.new(database: database,
                                  username: ENV.fetch("TINA4_TEST_FIREBIRD_USERNAME", "SYSDBA"),
                                  password: ENV.fetch("TINA4_TEST_FIREBIRD_PASSWORD", "masterkey")).connect
    connection.execute("DELETE FROM MON$ATTACHMENTS WHERE MON$REMOTE_PID = ? " \
                       "AND MON$ATTACHMENT_ID <> CURRENT_CONNECTION", owner)
    connection.close
    warn "FirebirdWatchdog: example still blocked after #{seconds}s - cancelled pid #{owner}'s attachments"
  rescue StandardError => e
    warn "FirebirdWatchdog: could not cancel pid #{owner}'s attachments: #{e.message}"
  end
end

# Tag an example group `firebird_watchdog: true` to guard every example in it.
RSpec.configure do |config|
  config.around(:each, :firebird_watchdog) do |example|
    FirebirdWatchdog.with_watchdog(ENV["TINA4_TEST_FIREBIRD_URL"]) { example.run }
  end
end
