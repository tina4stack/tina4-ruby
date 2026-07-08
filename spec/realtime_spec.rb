# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Behavioural regression suite for the realtime collaboration module
# (Tina4::Realtime), parity with the Python master's realtime tests and the
# PHP RealtimeTest.
#
# No mocks: the models hit a real SQLite database, LocalStorage hits the real
# filesystem, the ICE-config HMAC is verified against a real hash, and the
# multipart parse runs against a REAL Rack env with a real body (NOT an injected
# rack.request.form_hash - injecting it is exactly what hid the live-upload bug).
# Two framework-level regressions are locked in here:
#   * the RFC 6455 Sec-WebSocket-Accept magic GUID (a wrong GUID let raw clients
#     connect but made every real browser refuse the upgrade), and
#   * live multipart parsing (fields + files arrived empty on a live server
#     because nothing called Rack::Request#POST to populate the form hash).
RSpec.describe Tina4::Realtime do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "rt.db")) }

  before(:each) do
    Tina4.bind_database(db)
    [Tina4::Realtime::Workspace, Tina4::Realtime::Channel, Tina4::Realtime::ChannelMember,
     Tina4::Realtime::Message, Tina4::Realtime::Attachment].each(&:create_table)
  end

  after(:each) do
    db.close rescue nil
    FileUtils.rm_rf(tmp_dir)
    %w[TINA4_RTC_STUN_URLS TINA4_RTC_TURN_URL TINA4_RTC_TURN_SECRET TINA4_RTC_TURN_TTL
       TINA4_STORAGE_BACKEND TINA4_STORAGE_BUCKET].each { |k| ENV.delete(k) }
  end

  # ── ICE config (STUN + ephemeral TURN) ──────────────────────────────
  describe ".ice_servers" do
    it "is STUN-only by default" do
      ENV.delete("TINA4_RTC_TURN_URL")
      ENV.delete("TINA4_RTC_TURN_SECRET")
      servers = Tina4::Realtime.ice_servers
      expect(servers.length).to eq(1)
      expect(servers[0]["urls"]).to eq(["stun:stun.l.google.com:19302"])
      expect(servers[0]).not_to have_key("credential")
    end

    it "adds a TURN entry with a valid HMAC credential when configured" do
      ENV["TINA4_RTC_TURN_URL"] = "turn:turn.example.com:3478"
      ENV["TINA4_RTC_TURN_SECRET"] = "s3cr3t"
      turn = Tina4::Realtime.ice_servers[1]
      expect(turn["urls"]).to eq(["turn:turn.example.com:3478"])
      expect(turn["username"].to_i).to be > Time.now.to_i
      expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA1", "s3cr3t", turn["username"]))
      expect(turn["credential"]).to eq(expected)
    end
  end

  # ── LocalStorage (real filesystem) ──────────────────────────────────
  describe Tina4::Realtime::LocalStorage do
    it "round-trips and deletes bytes" do
      store = Tina4::Realtime::LocalStorage.new(File.join(tmp_dir, "store"))
      key = Tina4::Realtime::Storage.key("report.pdf")
      expect(key).to end_with(".pdf")
      store.put(key, "binary-bytes", "application/pdf")
      expect(store.exists?(key)).to be true
      expect(store.get(key)).to eq("binary-bytes")
      expect(store.url(key)).to be_nil
      store.delete(key)
      expect(store.exists?(key)).to be false
      expect(store.get(key)).to be_nil
    end

    it "rejects path traversal" do
      store = Tina4::Realtime::LocalStorage.new(File.join(tmp_dir, "store"))
      expect(store.get("../../etc/passwd")).to be_nil
      expect(store.exists?("../../etc/passwd")).to be false
    end
  end

  describe Tina4::Realtime::Storage do
    it "selects LocalStorage by default" do
      ENV.delete("TINA4_STORAGE_BACKEND")
      expect(Tina4::Realtime::Storage.select).to be_a(Tina4::Realtime::LocalStorage)
    end

    it "falls back to local when s3 is selected without a bucket" do
      ENV["TINA4_STORAGE_BACKEND"] = "s3"
      ENV.delete("TINA4_STORAGE_BUCKET")
      expect(Tina4::Realtime::Storage.select).to be_a(Tina4::Realtime::LocalStorage)
    end

    it "generates a key with the extension and no path segment" do
      key = Tina4::Realtime::Storage.key("../../evil/name.TXT")
      expect(key).not_to include("/")
      expect(key).to end_with(".TXT")
    end
  end

  # ── Models against real SQLite ──────────────────────────────────────
  describe "models" do
    it "persists an attachment and reads it back scoped to its channel" do
      att = Tina4::Realtime::Attachment.new(
        channel_id: 7, storage_key: "abc123.txt", filename: "note.txt", mime: "text/plain", size: 12
      )
      expect(att.save).not_to eq(false)

      loaded = Tina4::Realtime::Attachment.where("storage_key = ?", ["abc123.txt"]).first
      expect(loaded.channel_id.to_i).to eq(7)
      expect(loaded.filename).to eq("note.txt")

      # Raw row keys are symbols in Ruby (parity: the column is snake_case in the DB).
      row = db.fetch("SELECT channel_id, storage_key FROM tina4_rt_attachments").to_a.first
      expect(row[:channel_id].to_i).to eq(7)
      expect(row[:storage_key]).to eq("abc123.txt")
    end

    it "persists a member's read cursor via load-modify-save" do
      Tina4::Realtime::ChannelMember.new(channel_id: 3, user_id: "1", role: "owner").save
      member = Tina4::Realtime::ChannelMember.where("channel_id = ? AND user_id = ?", [3, "1"]).first
      member.last_read_at = "2026-07-08T10:00:00Z"
      member.save

      row = db.fetch("SELECT channel_id, user_id, last_read_at FROM tina4_rt_channel_members").to_a.first
      expect(row[:channel_id].to_i).to eq(3)
      expect(row[:user_id].to_s).to eq("1")
      expect(row[:last_read_at]).to eq("2026-07-08T10:00:00Z")
    end

    it "returns history newest-first" do
      %w[first second third].each_with_index do |body, i|
        Tina4::Realtime::Message.new(
          channel_id: 1, user_id: "1", body: body, created_at: format("2026-07-08T10:0%d:00Z", i)
        ).save
      end
      hist = Tina4::Realtime.history(1, {})
      expect(hist.map { |m| m["body"] }).to eq(%w[third second first])
    end
  end

  # ── mount() wires the routes + resolved path map ────────────────────
  describe ".mount" do
    it "registers the realtime routes and returns the path map" do
      Tina4::Router.clear!
      paths = Tina4::Realtime.mount(features: %w[calls chat files])
      expect(paths["backend"]).to eq("mesh")
      expect(paths["config"]).to eq("/api/rtc/config")
      expect(paths["signalling"]).to eq("/ws/rtc")
      expect(paths["chat"]).to eq("/ws/chat")
      expect(paths["files"]).to eq("/api/files")
      Tina4::Router.clear!
    end
  end

  # ── framework regressions the browser demo surfaced ─────────────────
  describe "WebSocket handshake (RFC 6455 accept key)" do
    it "computes the RFC test-vector Sec-WebSocket-Accept" do
      Tina4::WebSocket # trigger autoload of the module methods
      accept = Tina4.compute_accept_key("dGhlIHNhbXBsZSBub25jZQ==")
      expect(accept).to eq("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    end
  end

  describe "live multipart parsing (no injected form_hash)" do
    it "parses form fields AND files from a real multipart body" do
      boundary = "----tina4realtimeboundary"
      body = +""
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"channel_id\"\r\n\r\n7\r\n"
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n"
      body << "Content-Type: text/plain\r\n\r\nhello-bytes\r\n"
      body << "--#{boundary}--\r\n"

      env = {
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
        "CONTENT_LENGTH" => body.bytesize.to_s,
        "rack.input" => StringIO.new(body),
        "PATH_INFO" => "/api/files"
      }
      request = Tina4::Request.new(env, {})

      # No rack.request.form_hash was injected: this exercises the live
      # Rack::Request#POST parse path added to Tina4::Request.
      expect(request.body["channel_id"].to_s).to eq("7")
      file = request.files["file"]
      expect(file).not_to be_nil
      expect(file["filename"]).to eq("note.txt")
      expect(file["content"]).to eq("hello-bytes")
    end
  end
end
