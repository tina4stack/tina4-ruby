# frozen_string_literal: true

# Session expiry contract - regression gates for the session-backend defect
# batch measured on v3 (2026-08-01).
#
# THE CONTRACT, settled against real mainstream implementations rather than
# internal precedent. PHP's own native files handler, express-session 1.19.0,
# Django 6.0.7 (file and db), Laravel illuminate/session 13.23.0, connect-redis
# 10.0.0 and connect-mongo 6.0.0 were each measured with real runs. ZERO of the
# seven delete a record that carries no expiry: six return it, and Django's db
# backend declines to load it but still keeps it. connect-mongo whitelists the
# case deliberately with `$or: [{expires: {$exists: false}}, {expires: {$gt: now}}]`.
#
#   1. An ABSENT or ZERO expiry stamp means "never expires". It is guarded OUT of
#      the comparison, never fed INTO it, and the record is returned and kept.
#   2. A stamp genuinely PRESENT and in the PAST still expires the record, and the
#      record is still reaped. THE DANGEROUS FIX IS THE OBVIOUS ONE - making the
#      round-trip pass by weakening expiry turns data loss into a
#      sessions-never-expire security bug. Every positive gate below is paired
#      with a negative control.
#   3. The ttl is consumed at WRITE time; nothing at read time needs it.
#   4. write(id, data, ttl) is accepted by EVERY handler. A handler that did not
#      take the third argument raised ArgumentError, safe_write swallowed it and
#      returned false, and the OLD record survived and was served - STALE data,
#      which is worse than losing it because the app sees WRONG data.
#
# NO MOCKS. Real temp directories and a real SQL engine; existence is asserted
# out of band (a directory listing, a separate query) rather than through the
# code under test.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

RSpec.describe "Session expiry contract" do
  let(:tmpdir) { Dir.mktmpdir("tina4-sess-contract") }
  let(:handler) { Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 3600) }

  after(:each) { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

  # THE ON-DISK NAME, computed out of band.
  #
  # ADR-0021 ("a session id is opaque") made FileHandler name its files
  # sess_<sha256(id)>.json — the old gsub(/[^a-zA-Z0-9_-]/, "") was traversal-safe
  # but LOSSY, collapsing "a/b" and "ab" onto one file so one user's data
  # surfaced under another user's id.
  #
  # This spec was authored on a branch that forked BEFORE that landed and still
  # used the RAW id ("sess_naked.json"). After the merge every seed wrote a file
  # the handler would never look for, and every existence check globbed a name
  # that can never exist — so the negative assertions ("must be reaped") were
  # VACUOUSLY true and the positive ones were simply wrong.
  #
  # Digest::SHA256 here is the spec computing the name independently; it is not
  # the code under test. Deliberately NOT FileHandler#session_path (private, and
  # asking the subject where it put the file proves nothing).
  def session_file(session_id)
    File.join(tmpdir, "sess_#{Digest::SHA256.hexdigest(session_id.to_s)}.json")
  end

  # Seed a record straight onto disk, under the name the handler really uses.
  def seed(session_id, payload)
    File.write(session_file(session_id), JSON.generate(payload))
  end

  # Out-of-band existence check - a real stat of the real path, not the code
  # under test.
  def stored?(session_id)
    File.exist?(session_file(session_id))
  end

  describe "an absent or zero expiry stamp means never expires" do
    it "session_missing_expiry_stamp_survives_read" do
      seed("naked", { "seeded" => true })

      expect(handler.read("naked")).to eq({ "seeded" => true })
      expect(stored?("naked")).to be(true), "an unstamped record must NOT be deleted"
    end

    it "session_zero_expiry_stamp_survives_read" do
      seed("zeroed", { "_data" => { "seeded" => true }, "_expires" => 0 })

      expect(handler.read("zeroed")).to eq({ "seeded" => true })
      expect(stored?("zeroed")).to be(true), "a zero stamp must not delete the record"
    end

    it "session_missing_expiry_stamp_survives_gc" do
      seed("naked", { "seeded" => true })
      seed("zeroed", { "_data" => { "seeded" => true }, "_expires" => 0 })

      handler.gc(0)

      expect(stored?("naked")).to be(true), "gc must never sweep an unstamped record"
      expect(stored?("zeroed")).to be(true), "gc must never sweep a zero-stamped record"
    end
  end

  describe "the negative control: genuine expiry still reaps" do
    it "session_genuinely_expired_record_is_reaped" do
      handler.write("expiring", { "seeded" => true }, 1)
      expect(stored?("expiring")).to be(true), "precondition: the record was written"

      sleep(1.2) # real wall clock, no clock mocking

      expect(handler.read("expiring")).to be_nil
      expect(stored?("expiring")).to be(false), "a genuinely expired record must still be REAPED"
    end

    it "session_past_expiry_stamp_is_reaped" do
      seed("stale", { "_data" => { "seeded" => true }, "_expires" => Time.now.to_f - 99_999 })
      expect(stored?("stale")).to be(true), "precondition: the record really is on disk"

      expect(handler.read("stale")).to be_nil
      expect(stored?("stale")).to be(false), "a past-stamped record must be reaped"
    end

    it "session_past_expiry_stamp_is_swept_by_gc" do
      seed("stale", { "_data" => { "a" => 1 }, "_expires" => Time.now.to_f - 99_999 })
      expect(stored?("stale")).to be(true), "precondition: the record really is on disk"

      handler.gc(0)

      expect(stored?("stale")).to be(false), "gc must reap a genuinely expired record"
    end
  end

  describe "the boundary sweep: every stamp state on one read path" do
    it "session_boundary_sweep" do
      cases = {
        "absent" => [{ "v" => 1 }, true],
        "zero" => [{ "_data" => { "v" => 1 }, "_expires" => 0 }, true],
        "future" => [{ "_data" => { "v" => 1 }, "_expires" => Time.now.to_f + 3600 }, true],
        "past" => [{ "_data" => { "v" => 1 }, "_expires" => Time.now.to_f - 3600 }, false]
      }
      cases.each { |name, (payload, _)| seed(name, payload) }
      cases.each_key { |name| expect(stored?(name)).to be(true), "precondition: #{name} really is on disk" }

      cases.each do |name, (_, should_survive)|
        returned = handler.read(name)
        expect(stored?(name)).to be(should_survive), "#{name}: survival disagreed with the contract"
        expect(returned == { "v" => 1 }).to be(should_survive), "#{name}: payload disagreed with survival"
      end
    end
  end

  describe "gc(max_age) is accepted by every handler that exposes it" do
    # THE SAME DEFECT ONE METHOD OVER, and it shipped. Session#gc calls
    # handler.gc(max_lifetime) with exactly ONE argument (session.rb:254).
    # MemcachedHandler got its #gc from `alias gc cleanup`, and #cleanup takes
    # ZERO, so every session GC against a real memcached raised ArgumentError -
    # which Session#gc's rescue logged as a BACKEND failure, blaming the
    # operator's memcached for an internal arity bug. A healthy, empty memcached
    # therefore logged an ERROR on every sweep.
    #
    # Redis/Valkey/Mongo expose #cleanup and no #gc at all; Session#gc guards
    # with respond_to?(:gc) and skips them, which is why they are exempt here
    # rather than asserted.
    it "session_gc_accepts_the_max_age_argument_on_every_handler" do
      %w[FileHandler DatabaseHandler MongoHandler RedisHandler ValkeyHandler MemcachedHandler].each do |name|
        klass = Tina4::SessionHandlers.const_get(name)
        next unless klass.method_defined?(:gc)

        arity = klass.instance_method(:gc).arity
        expect(arity == 1 || arity <= -1).to be(true),
                                             "#{name}#gc must accept the one argument Session#gc passes " \
                                             "(max_age); arity was #{arity}"
      end
    end
  end

  describe "write(id, data, ttl) is accepted and honoured by every handler" do
    # THE STALE DEFECT. Only MemcachedHandler took a third parameter; the other
    # five raised ArgumentError, safe_write logged it and returned false, and the
    # PREVIOUS record survived and kept being served.
    it "session_write_accepts_ttl_on_every_handler" do
      %w[FileHandler DatabaseHandler MongoHandler RedisHandler ValkeyHandler MemcachedHandler].each do |name|
        arity = Tina4::SessionHandlers.const_get(name).instance_method(:write).arity
        expect(arity).to eq(-3),
                         "#{name}#write must accept (session_id, data, ttl = 0); arity was #{arity}"
      end
    end

    it "session_three_arg_write_is_not_stale" do
      handler.write("sid", { "version" => "OLD" })
      session = Tina4::Session.new({}, handler: "file", handler_options: { dir: tmpdir, ttl: 3600 })

      expect(session.write("sid", { "version" => "NEW" }, 60)).to be(true),
                                                                 "a 3-arg write must succeed, not be swallowed by safe_write"
      expect(handler.read("sid")).to eq({ "version" => "NEW" }),
                                     "the OLD record must not survive a successful write - that is STALE data"
    end

    it "session_write_ttl_argument_is_honoured" do
      handler.write("shortlived", { "seeded" => true }, 1)

      sleep(1.2)

      expect(handler.read("shortlived")).to be_nil,
                                            "a per-call ttl of 1s must expire the record even though the handler ttl is 3600"
      expect(stored?("shortlived")).to be(false)
    end

    it "session_read_verdict_does_not_depend_on_the_readers_ttl" do
      # A read path that knows the ttl can always fabricate an expiry for a record
      # that carries none. Two handlers with wildly different ttls must reach the
      # SAME verdict, because the verdict comes from the record's own deadline.
      Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 100_000).write("shared", { "seeded" => true })
      impatient = Tina4::SessionHandlers::FileHandler.new(dir: tmpdir, ttl: 1)

      sleep(1.2)

      expect(impatient.read("shared")).to eq({ "seeded" => true }),
                                          "a reader with a 1s ttl must not expire a record whose own deadline is far in the future"
      expect(stored?("shared")).to be(true)
    end
  end

  describe "the database backend on a real SQL engine" do
    let(:db_path) { File.join(tmpdir, "sessions.db") }
    let(:db) { Tina4::Database.new("sqlite:///#{db_path}") }
    let(:db_handler) { Tina4::SessionHandlers::DatabaseHandler.new(db: db, ttl: 3600) }

    after(:each) { db.close rescue nil }

    it "session_expires_at_column_is_not_single_precision" do
      # REAL is float4 on PostgreSQL: one ULP at the current epoch is 128 SECONDS,
      # and the loss compounds because the text wire format for float4 does not
      # round-trip into a 64-bit double either. Measured 111.99s worst-case drift
      # over 500 real PostgreSQL 16.14 round-trips. It also violates the Firebird
      # rule (no REAL/FLOAT - use DOUBLE PRECISION).
      source = File.read(
        File.expand_path("../lib/tina4/session_handlers/database_handler.rb", __dir__)
      )

      expect(source).not_to include("expires_at REAL"),
                            "REAL is float4 on PostgreSQL - use DOUBLE PRECISION"
      expect(source).to include("expires_at DOUBLE PRECISION")
    end

    it "session_unstamped_row_survives_but_expired_row_is_reaped" do
      db_handler.write("seed", { "seeded" => true }, 3600) # creates the table

      # POSITIVE: expires_at = 0 means never expires.
      db.execute(
        "INSERT INTO tina4_session (session_id, data, expires_at) VALUES (?, ?, ?)",
        ["unstamped", '{"seeded":true}', 0]
      )
      expect(db_handler.read("unstamped")).to eq({ "seeded" => true })
      expect(db.fetch_one("SELECT count(*) AS c FROM tina4_session WHERE session_id = ?", ["unstamped"])[:c])
        .to eq(1), "an unstamped row must NOT be deleted"

      # NEGATIVE CONTROL: a genuinely past expiry is still reaped.
      db.execute(
        "INSERT INTO tina4_session (session_id, data, expires_at) VALUES (?, ?, ?)",
        ["expired", '{"seeded":true}', 1]
      )
      expect(db_handler.read("expired")).to be_nil
      expect(db.fetch_one("SELECT count(*) AS c FROM tina4_session WHERE session_id = ?", ["expired"])[:c])
        .to eq(0), "a genuinely expired row must still be REAPED"
    end

    it "session_database_write_honours_the_per_call_ttl" do
      db_handler.write("shortlived", { "seeded" => true }, 1)

      row = db.fetch_one("SELECT expires_at FROM tina4_session WHERE session_id = ?", ["shortlived"])
      expect(row[:expires_at].to_f - Time.now.to_f).to be < 5,
                                                        "a per-call ttl of 1s must not become the 3600s handler default"
    end
  end
end
