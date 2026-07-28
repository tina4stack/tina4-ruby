# frozen_string_literal: true

require "spec_helper"

# A database whose connect failed must fail LEGIBLY at the first use.
#
# Tina4::Database#connect deliberately logs-and-degrades rather than crashing boot
# (an unreachable database must not take the service down). But the driver's own
# connection stayed nil, so the next call died as:
#
#   NoMethodError: private method `exec' called for nil:NilClass
#     lib/tina4/drivers/postgres_driver.rb:56:in `execute'
#
# which names neither the database nor the reason. That message sent a maintainer
# looking for an ORM bug when the real cause was an unset TINA4_TEST_PG_DB_2 and a
# database that did not exist.
#
# No mocks and no doubles: the connection failure is REAL — the target is a closed
# port, so the driver genuinely cannot connect.
RSpec.describe "Database connect failure is legible at point of use" do
  # Nothing listens on port 1, so this is a real failure, not a simulated one.
  let(:dead_url) { "postgres://127.0.0.1:1/tina4_does_not_exist" }

  def dead_db
    Tina4::Database.new(dead_url, username: "tina4", password: "sup3rs3cret")
  end

  before do
    skip("needs the pg gem to build a postgres driver") unless defined?(PG) || begin
      require "pg"
      true
    rescue LoadError
      false
    end
  end

  it "raises Tina4::DatabaseConnectionError on the first use, not a nil NoMethodError" do
    db = dead_db

    expect { db.execute("select 1") }.to raise_error(Tina4::DatabaseConnectionError)
  end

  it "does NOT surface the old nil-dereference NoMethodError" do
    db = dead_db

    begin
      db.execute("select 1")
    rescue StandardError => e
      expect(e).not_to be_a(NoMethodError)
      expect(e.message).not_to include("nil:NilClass"),
                               "the nil dereference is back: #{e.class}: #{e.message}"
    end
  end

  it "names the database it could not reach" do
    db = dead_db

    expect { db.execute("select 1") }
      .to raise_error(Tina4::DatabaseConnectionError, /tina4_does_not_exist/)
  end

  it "carries the underlying driver cause" do
    db = dead_db

    begin
      db.execute("select 1")
      raise "expected a connection error"
    rescue Tina4::DatabaseConnectionError => e
      # The original exception class is included, so the reader can tell a refused
      # connection from a bad password from a missing database.
      expect(e.message).to match(/PG::|Error/i)
      expect(e.message.length).to be > "Database not connected".length
    end
  end

  it "NEGATIVE: never leaks the password into the error message" do
    db = dead_db

    begin
      db.execute("select 1")
    rescue Tina4::DatabaseConnectionError => e
      expect(e.message).not_to include("sup3rs3cret"),
                               "SECURITY: the connection string in the error must be redacted"
    end
  end

  it "a reachable database is unaffected (no false positive)" do
    db = Tina4::Database.new("sqlite://#{Dir.tmpdir}/tina4_connect_ok_#{Process.pid}.db")
    expect { db.execute("create table if not exists t (id integer)") }.not_to raise_error
    db.close
  ensure
    File.unlink("#{Dir.tmpdir}/tina4_connect_ok_#{Process.pid}.db") rescue nil
  end
end
