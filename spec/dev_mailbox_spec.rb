# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Tina4::DevMailbox do
  let(:tmp_dir) { Dir.mktmpdir("tina4_devmailbox_test") }
  let(:mailbox) { Tina4::DevMailbox.new(mailbox_dir: tmp_dir) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  # ── Directory setup ────────────────────────────────────────────

  describe "initialization" do
    it "creates messages and attachments directories" do
      mailbox_dir = mailbox.mailbox_dir
      expect(Dir.exist?(File.join(mailbox_dir, "messages"))).to be true
      expect(Dir.exist?(File.join(mailbox_dir, "attachments"))).to be true
    end

    it "uses TINA4_MAILBOX_DIR env var when set" do
      env_dir = File.join(tmp_dir, "env_mailbox")
      original = ENV["TINA4_MAILBOX_DIR"]
      begin
        ENV["TINA4_MAILBOX_DIR"] = env_dir
        mb = Tina4::DevMailbox.new
        expect(mb.mailbox_dir).to eq(env_dir)
      ensure
        if original
          ENV["TINA4_MAILBOX_DIR"] = original
        else
          ENV.delete("TINA4_MAILBOX_DIR")
        end
      end
    end

    it "defaults to data/mailbox when no env var set" do
      original = ENV["TINA4_MAILBOX_DIR"]
      begin
        ENV.delete("TINA4_MAILBOX_DIR")
        mb = Tina4::DevMailbox.new(mailbox_dir: nil)
        # When mailbox_dir is nil and env is not set, defaults to data/mailbox
        expect(mb.mailbox_dir).to eq("data/mailbox")
      ensure
        ENV["TINA4_MAILBOX_DIR"] = original if original
      end
    end
  end

  # ── Capture ────────────────────────────────────────────────────

  describe "#capture" do
    it "captures an email and returns success" do
      result = mailbox.capture(
        to: "user@example.com",
        subject: "Test Subject",
        body: "Hello World"
      )
      expect(result[:success]).to be true
      expect(result[:id]).to be_a(String)
      expect(result[:id].length).to eq(36) # UUID format
    end

    it "stores the message as a JSON file" do
      result = mailbox.capture(
        to: "user@example.com",
        subject: "Test",
        body: "Body"
      )
      path = File.join(tmp_dir, "messages", "#{result[:id]}.json")
      expect(File.exist?(path)).to be true

      data = JSON.parse(File.read(path), symbolize_names: true)
      expect(data[:subject]).to eq("Test")
      expect(data[:body]).to eq("Body")
    end

    it "sets folder to outbox" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B")
      msg = mailbox.read(result[:id])
      expect(msg[:folder]).to eq("outbox")
    end

    it "marks message as unread" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B")
      msg = JSON.parse(
        File.read(File.join(tmp_dir, "messages", "#{result[:id]}.json")),
        symbolize_names: true
      )
      expect(msg[:read]).to be false
    end

    it "normalizes string recipient to array" do
      result = mailbox.capture(to: "single@test.com", subject: "S", body: "B")
      msg = mailbox.read(result[:id])
      expect(msg[:to]).to eq(["single@test.com"])
    end

    it "normalizes array recipients" do
      result = mailbox.capture(to: ["a@test.com", "b@test.com"], subject: "S", body: "B")
      msg = mailbox.read(result[:id])
      expect(msg[:to]).to eq(["a@test.com", "b@test.com"])
    end

    it "handles nil cc and bcc" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B", cc: nil, bcc: nil)
      msg = mailbox.read(result[:id])
      expect(msg[:cc]).to eq([])
      expect(msg[:bcc]).to eq([])
    end

    it "stores from_address and from_name" do
      result = mailbox.capture(
        to: "a@b.com", subject: "S", body: "B",
        from_address: "sender@example.com", from_name: "Sender Name"
      )
      msg = mailbox.read(result[:id])
      expect(msg[:from][:email]).to eq("sender@example.com")
      expect(msg[:from][:name]).to eq("Sender Name")
    end

    it "stores html flag" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "<p>Hi</p>", html: true)
      msg = mailbox.read(result[:id])
      expect(msg[:html]).to be true
    end

    it "stores reply_to" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B", reply_to: "reply@test.com")
      msg = mailbox.read(result[:id])
      expect(msg[:reply_to]).to eq("reply@test.com")
    end

    it "stores timestamps in ISO format" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B")
      msg = mailbox.read(result[:id])
      expect(msg[:created_at]).to match(/^\d{4}-\d{2}-\d{2}T/)
      expect(msg[:updated_at]).to match(/^\d{4}-\d{2}-\d{2}T/)
    end
  end

  # ── Attachments ────────────────────────────────────────────────

  describe "attachments" do
    it "stores hash attachments" do
      result = mailbox.capture(
        to: "a@b.com", subject: "S", body: "B",
        attachments: [{ filename: "test.txt", content: "file content", mime_type: "text/plain" }]
      )
      msg = mailbox.read(result[:id])
      expect(msg[:attachments].length).to eq(1)
      expect(msg[:attachments].first[:filename]).to eq("test.txt")
      expect(msg[:attachments].first[:mime_type]).to eq("text/plain")

      att_path = File.join(tmp_dir, "attachments", result[:id], "test.txt")
      expect(File.exist?(att_path)).to be true
      expect(File.read(att_path)).to eq("file content")
    end

    it "handles empty attachments" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B", attachments: [])
      msg = mailbox.read(result[:id])
      expect(msg[:attachments]).to eq([])
    end
  end

  # ── Read ───────────────────────────────────────────────────────

  describe "#read" do
    it "returns a message by ID" do
      result = mailbox.capture(to: "a@b.com", subject: "Read Test", body: "B")
      msg = mailbox.read(result[:id])
      expect(msg[:subject]).to eq("Read Test")
    end

    it "marks the message as read" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B")
      mailbox.read(result[:id])
      msg = mailbox.read(result[:id])
      expect(msg[:read]).to be true
    end

    it "returns nil for nonexistent message" do
      expect(mailbox.read("nonexistent-uuid")).to be_nil
    end
  end

  # ── Inbox ──────────────────────────────────────────────────────

  describe "#inbox" do
    before do
      5.times { |i| mailbox.capture(to: "a@b.com", subject: "Msg #{i}", body: "B") }
    end

    it "returns all messages" do
      messages = mailbox.inbox
      expect(messages.length).to eq(5)
    end

    it "respects limit" do
      messages = mailbox.inbox(limit: 3)
      expect(messages.length).to eq(3)
    end

    it "respects offset" do
      messages = mailbox.inbox(limit: 2, offset: 3)
      expect(messages.length).to eq(2)
    end

    it "filters by folder" do
      messages = mailbox.inbox(folder: "outbox")
      expect(messages.length).to eq(5)

      messages = mailbox.inbox(folder: "inbox")
      expect(messages.length).to eq(0)
    end

    it "returns messages in reverse chronological order" do
      messages = mailbox.inbox
      timestamps = messages.map { |m| m[:created_at] }
      expect(timestamps).to eq(timestamps.sort.reverse)
    end
  end

  # ── Unread count ───────────────────────────────────────────────

  describe "#unread_count" do
    it "counts unread messages" do
      3.times { mailbox.capture(to: "a@b.com", subject: "S", body: "B") }
      expect(mailbox.unread_count).to eq(3)
    end

    it "decreases when messages are read" do
      ids = 3.times.map { mailbox.capture(to: "a@b.com", subject: "S", body: "B")[:id] }
      mailbox.read(ids.first)
      expect(mailbox.unread_count).to eq(2)
    end
  end

  # ── Delete ─────────────────────────────────────────────────────

  describe "#delete" do
    it "removes a message" do
      result = mailbox.capture(to: "a@b.com", subject: "S", body: "B")
      expect(mailbox.delete(result[:id])).to be true
      expect(mailbox.read(result[:id])).to be_nil
    end

    it "returns false for nonexistent message" do
      expect(mailbox.delete("nonexistent-uuid")).to be false
    end

    it "removes attachments directory" do
      result = mailbox.capture(
        to: "a@b.com", subject: "S", body: "B",
        attachments: [{ filename: "file.txt", content: "data" }]
      )
      att_dir = File.join(tmp_dir, "attachments", result[:id])
      expect(Dir.exist?(att_dir)).to be true

      mailbox.delete(result[:id])
      expect(Dir.exist?(att_dir)).to be false
    end
  end

  # ── Clear ──────────────────────────────────────────────────────

  describe "#clear" do
    before do
      3.times { mailbox.capture(to: "a@b.com", subject: "S", body: "B") }
    end

    it "removes all messages" do
      mailbox.clear
      expect(mailbox.inbox.length).to eq(0)
    end

    it "clears by folder" do
      mailbox.clear(folder: "outbox")
      expect(mailbox.inbox.length).to eq(0)
    end

    it "preserves messages in other folders when filtering" do
      # All captured messages are in outbox, clearing inbox should keep them
      mailbox.clear(folder: "inbox")
      expect(mailbox.inbox.length).to eq(3)
    end

    it "recreates directories after clearing" do
      mailbox.clear
      expect(Dir.exist?(File.join(tmp_dir, "messages"))).to be true
      expect(Dir.exist?(File.join(tmp_dir, "attachments"))).to be true
    end
  end

  # ── Count ──────────────────────────────────────────────────────

  describe "#count" do
    before do
      3.times { mailbox.capture(to: "a@b.com", subject: "S", body: "B") }
    end

    it "returns total count" do
      result = mailbox.count
      expect(result[:total]).to eq(3)
    end

    it "returns outbox count" do
      result = mailbox.count
      expect(result[:outbox]).to eq(3)
    end

    it "returns inbox count as zero (all are outbox)" do
      result = mailbox.count
      expect(result[:inbox]).to eq(0)
    end

    it "filters by folder" do
      result = mailbox.count(folder: "outbox")
      expect(result[:outbox]).to eq(3)
      expect(result[:total]).to eq(3)
    end
  end
end
