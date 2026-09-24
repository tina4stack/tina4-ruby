# frozen_string_literal: true

# ONE worker in the concurrent first-use race driven by
# spec/session_database_engines_spec.rb ("concurrent first use with real processes").
#
# A separate PROCESS on purpose: the property under test is what happens when
# several processes of one app use the database session backend for the first
# time at the same instant. Nothing here is a double - the real handler, the
# real Tina4::Database, the real engine.
#
# It connects BEFORE the barrier (the race is in ensure_table, not in connection
# setup) and then spins to a shared wall-clock instant.
#
# ARGV[0] float   the instant every worker starts at (Time.now.to_f)
# ARGV[1] string  the session id this worker writes
#
# Environment (not TINA4_*, so nothing here is mistaken for a framework setting):
#   T4_RACE_URL / T4_RACE_USERNAME / T4_RACE_PASSWORD
#   T4_RACE_HOLD_NAMED_LOCK   MySQL only - hold a GET_LOCK across the first use
#
# Exit codes: 0 success, 1 the first use failed, 2 could not connect.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "tina4"

start_at = ARGV[0].to_f
session_id = ARGV[1]

begin
  database = Tina4::Database.new(ENV.fetch("T4_RACE_URL"),
                                 username: ENV["T4_RACE_USERNAME"].to_s.empty? ? nil : ENV["T4_RACE_USERNAME"],
                                 password: ENV["T4_RACE_PASSWORD"].to_s.empty? ? nil : ENV["T4_RACE_PASSWORD"])
  handler = Tina4::SessionHandlers::DatabaseHandler.new(db: database)
  # MySQL backs the loser of the metadata-lock deadlock inside CREATE TABLE off
  # silently ONLY when the session holds no other metadata lock. Holding a named
  # lock (the way apps serialise work) takes that away, so the loser gets 1213
  # "Deadlock found" every time instead of by luck.
  unless ENV["T4_RACE_HOLD_NAMED_LOCK"].to_s.empty?
    database.fetch_one("SELECT GET_LOCK(?, 0) AS held", ["tina4-race-#{session_id}"])
  end
rescue StandardError, LoadError => e
  warn "connect: #{e.class}: #{e.message}"
  exit!(2)
end

remaining = start_at - Time.now.to_f
sleep(remaining - 0.01) if remaining > 0.01
nil while Time.now.to_f < start_at

begin
  # write runs ensure_table on its way in - this IS the first use.
  handler.write(session_id, { "worker" => session_id }, 60)
rescue StandardError => e
  warn "#{e.class}: #{e.message}"
  exit!(1)
end

# exit! skips at_exit hooks: a worker has nothing to flush, and the parent
# judges it by its exit code alone.
exit!(0)
