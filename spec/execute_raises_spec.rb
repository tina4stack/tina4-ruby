# frozen_string_literal: true

# Database#execute must FAIL LOUD — raise on a SQL error, never silently
# return false.
#
# Pre-3.13.x Database#execute caught the driver exception and returned false
# (storing the cause on @last_error). Almost no caller checks a boolean after
# every write, so a failed INSERT/UPDATE/DELETE looked like success while the
# row never landed — a silent partial-write footgun. It now raises (mirroring
# fetch/fetch_one), while still capturing the cause on @last_error / #get_error.
#
# Engine-agnostic — runs on SQLite, so it executes locally and in CI with no
# database server. Mirrors tina4-python/tests/test_execute_raises.py.

require "spec_helper"
require "tmpdir"

RSpec.describe "Tina4::Database#execute raises on error" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmpdir, "raise.db")) }

  before do
    db.execute("CREATE TABLE widget (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    db.commit rescue nil
  end

  after do
    db.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  it "raises on a statement against a missing table — it does NOT return false" do
    expect { db.execute("INSERT INTO no_such_table (x) VALUES (1)") }.to raise_error(StandardError)
    # The cause is still readable through the public API after the raise.
    expect(db.get_error).not_to be_nil
  end

  it "raises on a NOT NULL violation and the row is NOT written" do
    expect { db.execute("INSERT INTO widget (id, name) VALUES (1, NULL)") }.to raise_error(StandardError)
    expect(db.fetch("SELECT * FROM widget").count).to eq(0)
  end

  it "returns truthy (never false) and clears the error on a successful write" do
    result = db.execute("INSERT INTO widget (id, name) VALUES (1, 'ok')")
    db.commit rescue nil
    expect(result).not_to be false
    expect(result).not_to be_nil
    expect(db.get_error).to be_nil
    expect(db.fetch("SELECT * FROM widget").count).to eq(1)
  end
end
