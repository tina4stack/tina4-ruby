# frozen_string_literal: true
#
# Regression / lock-in spec for tina4-python#57 on the Ruby side.
#
# The reporter bound a Ruby boolean to an INTEGER column, never checked the
# execute() return, called commit(), and got an empty table. The root cause was
# a pre-3.13.38 Database.execute() that SWALLOWED the driver exception and
# returned False; the write silently vanished. At HEAD execute() FAILS LOUD:
# it captures the cause on get_error and re-raises, so the lost-write footgun
# cannot recur. This spec proves that contract against a REAL PostgreSQL:
#
#   * a valid integer insert lands a row (positive), and
#   * a bool -> INTEGER insert RAISES, sets get_error, and leaves the table
#     EMPTY — no silent False, no phantom "success" (negative).
#
# SQLite cannot catch this (it is dynamically typed and stores the bool
# happily), so the assertion must run on real PostgreSQL. It uses the same
# gate as the other PG specs: skip only when the pg gem is missing or the
# server is unreachable — never a mock.

require "spec_helper"
require "socket"

PG57_HOST = ENV.fetch("TINA4_TEST_PG_HOST", "localhost")
PG57_PORT = ENV.fetch("TINA4_TEST_PG_PORT", "5432").to_i
PG57_USER = ENV.fetch("TINA4_TEST_PG_USER", "tina4")
PG57_PASS = ENV.fetch("TINA4_TEST_PG_PASS", "tina4")
PG57_DB   = ENV.fetch("TINA4_TEST_PG_DB", "tina4_rb")

def pg57_reachable?
  TCPSocket.new(PG57_HOST, PG57_PORT).tap(&:close)
  true
rescue StandardError
  false
end

def pg57_gem_available?
  require "pg"
  true
rescue LoadError
  false
end

RSpec.describe "PostgreSQL execute() fails loud on bool->INTEGER (#57)" do
  before(:all) do
    @skip_reason = if !pg57_gem_available?
                     "pg gem not installed (skip)"
                   elsif !pg57_reachable?
                     "PostgreSQL not reachable at #{PG57_HOST}:#{PG57_PORT} (skip)"
                   end
  end

  before(:each) do
    skip(@skip_reason) if @skip_reason
    @db = Tina4::Database.new(
      "postgres://#{PG57_HOST}:#{PG57_PORT}/#{PG57_DB}",
      username: PG57_USER, password: PG57_PASS
    )
    @db.execute("DROP TABLE IF EXISTS pg57_qty")
    @db.execute("CREATE TABLE pg57_qty (id SERIAL PRIMARY KEY, qty INTEGER NOT NULL)")
  end

  after(:each) do
    next unless @db

    begin
      @db.execute("DROP TABLE IF EXISTS pg57_qty")
    ensure
      @db.close rescue nil
    end
  end

  it "lands a row for a valid integer insert (positive)" do
    @db.execute("INSERT INTO pg57_qty (qty) VALUES (?)", [7])
    rows = @db.fetch("SELECT qty FROM pg57_qty")
    expect(rows.count).to eq(1)
    expect(rows[0][:qty]).to eq(7)
  end

  it "RAISES on a bool bound to an INTEGER column and leaves the table empty (negative)" do
    expect do
      @db.execute("INSERT INTO pg57_qty (qty) VALUES (?)", [true])
    end.to raise_error(StandardError)

    # The cause is captured (readable after the raise), not swallowed.
    expect(@db.get_error).to be_a(String)
    expect(@db.get_error).not_to be_empty

    # The failed write left NO row behind — the #57 lost-write footgun cannot
    # recur (the pre-3.13.38 bug returned False here and the row vanished
    # silently, which the reporter mistook for a successful, then-committed
    # write).
    count = @db.fetch("SELECT count(*) AS c FROM pg57_qty")[0][:c]
    expect(count.to_i).to eq(0)
  end

  it "never returns a falsey value from execute (raises instead)" do
    # Lock in the "fail loud, never a silent False" contract directly: a caller
    # that (wrongly) tests the return value must not be handed a False — it must
    # get an exception it cannot ignore.
    returned = :sentinel
    expect do
      returned = @db.execute("INSERT INTO pg57_qty (qty) VALUES (?)", [true])
    end.to raise_error(StandardError)
    expect(returned).to eq(:sentinel) # assignment never happened
  end
end
