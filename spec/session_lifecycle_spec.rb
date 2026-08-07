# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# Session lifecycle parity specs (file backend, real filesystem, no mocks).
#
# Aligns tina4-ruby to the Python master
# (tina4_python/tina4_python/session/__init__.py):
#
#   1. #destroy ENDS the session — a later set()+save() with NO new start() must
#      write NO record. The master nulls _session_id in destroy(); Ruby kept @id
#      and #save persisted under it, re-creating the just-destroyed record.
#   2. #flash(key, nil) is the GET sentinel — it reads-and-clears and never
#      STORES nil (Ruby already correct — locked in here).
#
# NO MOCKS: a real Tina4::Session over the real FileHandler on a real tmp dir.
RSpec.describe "Tina4::Session lifecycle parity" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sess_lifecycle") }
  let(:env) { { "HTTP_COOKIE" => "" } }
  let(:options) { { handler: :file, handler_options: { dir: tmp_dir } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def new_session
    Tina4::Session.new(env, options)
  end

  # The session records on disk (FileHandler names them "sess_<sha256>.json").
  def session_files
    Dir.glob(File.join(tmp_dir, "sess_*.json"))
  end

  describe "#destroy does not let a later set()+save() resurrect the session" do
    it "set()+save() after destroy() creates no record" do
      session = new_session
      old_id = session.start
      session.set("user_id", 42)
      session.save
      expect(session_files.length).to eq(1)

      # End the session: the record is removed and the id is cleared.
      session.destroy
      expect(session_files).to be_empty
      expect(session.get_session_id).to be_nil

      # A set()+save() with NO new start() must write NO record.
      session.set("user_id", 99)
      session.save
      expect(session_files).to be_empty

      # A FRESH session reading the OLD id from the SAME backend finds NO data.
      fresh = new_session
      expect(fresh.read(old_id)).to be_empty
    end

    it "a fresh start() after destroy() mints a new id and persists (negative control)" do
      session = new_session
      old_id = session.start
      session.set("k", "v")
      session.save
      session.destroy

      new_id = session.start
      expect(new_id).not_to eq(old_id)
      expect(new_id).not_to be_nil

      session.set("k", "v2")
      session.save
      expect(session_files.length).to eq(1)

      fresh = new_session
      expect(fresh.read(new_id)["k"]).to eq("v2")
    end
  end

  describe "#flash(key, nil) reads-and-clears and does not store nil" do
    it "returns the pending value, clears the key, and never stores nil" do
      session = new_session
      session.start

      session.flash("message", "Saved!") # set (value is not nil)
      expect(session.has?("_flash_message")).to be(true)

      # nil is the GET sentinel: read the pending value AND clear it.
      first = session.flash("message", nil)
      expect(first).to eq("Saved!")
      expect(session.has?("_flash_message")).to be(false)

      # A second read is empty — the value was consumed, not re-stored as nil.
      second = session.flash("message", nil)
      expect(second).to be_nil
    end
  end
end
