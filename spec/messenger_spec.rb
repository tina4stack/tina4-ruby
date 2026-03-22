# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Tina4::Messenger do
  describe "#initialize" do
    it "creates a messenger with default values" do
      messenger = described_class.new
      expect(messenger.host).to eq("localhost")
      expect(messenger.port).to eq(587)
    end

    it "accepts custom host and port" do
      messenger = described_class.new(host: "smtp.example.com", port: 465)
      expect(messenger.host).to eq("smtp.example.com")
      expect(messenger.port).to eq(465)
    end

    it "stores username" do
      messenger = described_class.new(username: "user@example.com")
      expect(messenger.username).to eq("user@example.com")
    end

    it "stores from_address" do
      messenger = described_class.new(from_address: "noreply@example.com")
      expect(messenger.from_address).to eq("noreply@example.com")
    end

    it "stores from_name" do
      messenger = described_class.new(from_name: "Test Mailer")
      expect(messenger.from_name).to eq("Test Mailer")
    end

    it "defaults use_tls to true" do
      messenger = described_class.new
      expect(messenger.use_tls).to be true
    end

    it "allows disabling TLS" do
      messenger = described_class.new(use_tls: false)
      expect(messenger.use_tls).to be false
    end

    it "stores IMAP host" do
      messenger = described_class.new(imap_host: "imap.example.com")
      expect(messenger.imap_host).to eq("imap.example.com")
    end

    it "stores IMAP port" do
      messenger = described_class.new(imap_port: 143)
      expect(messenger.imap_port).to eq(143)
    end

    it "defaults IMAP port to 993" do
      messenger = described_class.new
      expect(messenger.imap_port).to eq(993)
    end

    it "converts port to integer" do
      messenger = described_class.new(port: "2525")
      expect(messenger.port).to eq(2525)
    end

    it "falls back from_address to username" do
      messenger = described_class.new(username: "user@test.com")
      expect(messenger.from_address).to eq("user@test.com")
    end
  end

  describe "private #normalize_recipients" do
    let(:messenger) { described_class.new }

    it "returns empty array for nil" do
      result = messenger.__send__(:normalize_recipients, nil)
      expect(result).to eq([])
    end

    it "wraps a string in an array" do
      result = messenger.__send__(:normalize_recipients, "test@example.com")
      expect(result).to eq(["test@example.com"])
    end

    it "flattens and compacts arrays" do
      result = messenger.__send__(:normalize_recipients, [["a@test.com", nil], "b@test.com"])
      expect(result).to eq(["a@test.com", "b@test.com"])
    end

    it "converts other types to string" do
      result = messenger.__send__(:normalize_recipients, 42)
      expect(result).to eq(["42"])
    end
  end

  describe "private #auth_method" do
    it "returns :plain when username and password are set" do
      messenger = described_class.new(username: "user", password: "pass")
      expect(messenger.__send__(:auth_method)).to eq(:plain)
    end

    it "returns nil when no credentials" do
      messenger = described_class.new
      expect(messenger.__send__(:auth_method)).to be_nil
    end
  end

  describe "private #format_address" do
    let(:messenger) { described_class.new }

    it "returns just email when no name" do
      result = messenger.__send__(:format_address, "test@example.com")
      expect(result).to eq("test@example.com")
    end

    it "returns formatted address with name" do
      result = messenger.__send__(:format_address, "test@example.com", "John Doe")
      expect(result).to eq("John Doe <test@example.com>")
    end

    it "returns just email when name is empty" do
      result = messenger.__send__(:format_address, "test@example.com", "")
      expect(result).to eq("test@example.com")
    end
  end

  describe "private #encode_header" do
    let(:messenger) { described_class.new }

    it "returns ASCII strings unchanged" do
      result = messenger.__send__(:encode_header, "Hello World")
      expect(result).to eq("Hello World")
    end

    it "encodes non-ASCII strings as base64 UTF-8" do
      result = messenger.__send__(:encode_header, "Bonjour \u00e9")
      expect(result).to start_with("=?UTF-8?B?")
      expect(result).to end_with("?=")
    end
  end

  describe "private #guess_mime_type" do
    let(:messenger) { described_class.new }

    it "returns text/plain for .txt" do
      expect(messenger.__send__(:guess_mime_type, "file.txt")).to eq("text/plain")
    end

    it "returns application/pdf for .pdf" do
      expect(messenger.__send__(:guess_mime_type, "doc.pdf")).to eq("application/pdf")
    end

    it "returns image/png for .png" do
      expect(messenger.__send__(:guess_mime_type, "image.png")).to eq("image/png")
    end

    it "returns image/jpeg for .jpg" do
      expect(messenger.__send__(:guess_mime_type, "photo.jpg")).to eq("image/jpeg")
    end

    it "returns image/jpeg for .jpeg" do
      expect(messenger.__send__(:guess_mime_type, "photo.jpeg")).to eq("image/jpeg")
    end

    it "returns application/json for .json" do
      expect(messenger.__send__(:guess_mime_type, "data.json")).to eq("application/json")
    end

    it "returns application/zip for .zip" do
      expect(messenger.__send__(:guess_mime_type, "archive.zip")).to eq("application/zip")
    end

    it "returns text/html for .html" do
      expect(messenger.__send__(:guess_mime_type, "page.html")).to eq("text/html")
    end

    it "returns text/csv for .csv" do
      expect(messenger.__send__(:guess_mime_type, "data.csv")).to eq("text/csv")
    end

    it "returns application/octet-stream for unknown extensions" do
      expect(messenger.__send__(:guess_mime_type, "file.xyz")).to eq("application/octet-stream")
    end
  end

  describe "private #build_message" do
    let(:messenger) { described_class.new(from_address: "sender@test.com", from_name: "Sender") }

    it "includes From header" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("From: Sender <sender@test.com>")
    end

    it "includes To header" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("To: r@test.com")
    end

    it "includes Subject header" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Hello", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Subject: Hello")
    end

    it "includes Message-ID header" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<abc@localhost>")
      expect(raw).to include("Message-ID: <abc@localhost>")
    end

    it "includes MIME-Version header" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("MIME-Version: 1.0")
    end

    it "sets text/plain content type for non-html" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Content-Type: text/plain")
    end

    it "sets text/html content type for html" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "<h1>Hi</h1>",
                           html: true, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Content-Type: text/html")
    end

    it "includes Cc header when provided" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: ["cc@test.com"], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Cc: cc@test.com")
    end

    it "includes Reply-To header when provided" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: "reply@test.com",
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Reply-To: reply@test.com")
    end

    it "includes custom headers" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: { "X-Custom" => "value" },
                           message_id: "<test@localhost>")
      expect(raw).to include("X-Custom: value")
    end

    it "uses multipart/mixed when attachments present" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hi",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [{ filename: "test.txt", content: "data" }],
                           headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Content-Type: multipart/mixed")
    end

    it "base64 encodes the body" do
      raw = messenger.__send__(:build_message,
                           to: "r@test.com", subject: "Test", body: "Hello",
                           html: false, cc: [], bcc: [], reply_to: nil,
                           attachments: [], headers: {},
                           message_id: "<test@localhost>")
      expect(raw).to include("Content-Transfer-Encoding: base64")
      expect(raw).to include(Base64.encode64("Hello").strip)
    end
  end

  describe "private #build_search_criteria" do
    let(:messenger) { described_class.new }

    it "returns ALL when no criteria given" do
      result = messenger.__send__(:build_search_criteria,
                              subject: nil, sender: nil, since: nil,
                              before: nil, unseen_only: false)
      expect(result).to eq(["ALL"])
    end

    it "includes SUBJECT when subject given" do
      result = messenger.__send__(:build_search_criteria,
                              subject: "hello", sender: nil, since: nil,
                              before: nil, unseen_only: false)
      expect(result).to include("SUBJECT")
      expect(result).to include("hello")
    end

    it "includes FROM when sender given" do
      result = messenger.__send__(:build_search_criteria,
                              subject: nil, sender: "user@test.com", since: nil,
                              before: nil, unseen_only: false)
      expect(result).to include("FROM")
      expect(result).to include("user@test.com")
    end

    it "includes UNSEEN when unseen_only is true" do
      result = messenger.__send__(:build_search_criteria,
                              subject: nil, sender: nil, since: nil,
                              before: nil, unseen_only: true)
      expect(result).to include("UNSEEN")
    end

    it "includes SINCE with formatted date" do
      date = Time.new(2025, 3, 15)
      result = messenger.__send__(:build_search_criteria,
                              subject: nil, sender: nil, since: date,
                              before: nil, unseen_only: false)
      expect(result).to include("SINCE")
      expect(result).to include("15-Mar-2025")
    end

    it "includes BEFORE with formatted date" do
      date = Time.new(2025, 6, 1)
      result = messenger.__send__(:build_search_criteria,
                              subject: nil, sender: nil, since: nil,
                              before: date, unseen_only: false)
      expect(result).to include("BEFORE")
      expect(result).to include("01-Jun-2025")
    end
  end

  describe "private #format_imap_date" do
    let(:messenger) { described_class.new }

    it "formats Time objects" do
      result = messenger.__send__(:format_imap_date, Time.new(2025, 1, 15))
      expect(result).to eq("15-Jan-2025")
    end

    it "formats Date objects" do
      result = messenger.__send__(:format_imap_date, Date.new(2025, 12, 25))
      expect(result).to eq("25-Dec-2025")
    end

    it "passes strings through unchanged" do
      result = messenger.__send__(:format_imap_date, "01-Jan-2025")
      expect(result).to eq("01-Jan-2025")
    end
  end

  describe "private #decode_mime_header" do
    let(:messenger) { described_class.new }

    it "returns plain text unchanged" do
      result = messenger.__send__(:decode_mime_header, "Hello World")
      expect(result).to eq("Hello World")
    end

    it "decodes base64 encoded headers" do
      encoded = "=?UTF-8?B?SGVsbG8=?="
      result = messenger.__send__(:decode_mime_header, encoded)
      expect(result).to eq("Hello")
    end

    it "decodes quoted-printable encoded headers" do
      encoded = "=?UTF-8?Q?Hello_World?="
      result = messenger.__send__(:decode_mime_header, encoded)
      expect(result).to eq("Hello World")
    end

    it "returns empty string for nil" do
      result = messenger.__send__(:decode_mime_header, nil)
      expect(result).to eq("")
    end
  end

  describe "private #extract_body_parts" do
    let(:messenger) { described_class.new }

    it "extracts plain text body from simple message" do
      raw = "Content-Type: text/plain\r\n\r\nHello body"
      text, _html = messenger.__send__(:extract_body_parts, raw)
      expect(text).to eq("Hello body")
    end

    it "extracts HTML body" do
      raw = "Content-Type: text/html\r\n\r\n<h1>Hello</h1>"
      _text, html = messenger.__send__(:extract_body_parts, raw)
      expect(html).to eq("<h1>Hello</h1>")
    end

    it "handles base64 encoded body" do
      encoded = Base64.encode64("Decoded content")
      raw = "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n#{encoded}"
      text, _html = messenger.__send__(:extract_body_parts, raw)
      expect(text).to eq("Decoded content")
    end
  end
end

RSpec.describe Tina4::DevMailbox do
  let(:test_dir) { Dir.mktmpdir("tina4-messenger-test") }
  let(:mailbox) { described_class.new(mailbox_dir: test_dir) }

  after(:each) { FileUtils.rm_rf(test_dir) }

  describe "#initialize" do
    it "creates a mailbox instance" do
      expect(mailbox).to be_a(Tina4::DevMailbox)
    end

    it "stores the mailbox directory" do
      expect(mailbox.mailbox_dir).to eq(test_dir)
    end

    it "creates messages subdirectory" do
      mailbox # force lazy let to evaluate
      expect(Dir.exist?(File.join(test_dir, "messages"))).to be true
    end

    it "creates attachments subdirectory" do
      mailbox # force lazy let to evaluate
      expect(Dir.exist?(File.join(test_dir, "attachments"))).to be true
    end
  end

  describe "#capture" do
    it "returns success" do
      result = mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      expect(result[:success]).to be true
    end

    it "returns a message string" do
      result = mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      expect(result[:message]).to be_a(String)
    end

    it "returns an id" do
      result = mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      expect(result[:id]).to be_a(String)
      expect(result[:id]).not_to be_empty
    end

    it "writes a file to disk" do
      mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      files = Dir.glob(File.join(test_dir, "messages", "*.json"))
      expect(files.length).to eq(1)
    end

    it "stores to recipients" do
      mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      msg = mailbox.inbox.first
      expect(msg[:to]).to include("alice@test.com")
    end

    it "stores subject" do
      mailbox.capture(to: "alice@test.com", subject: "Test Subject", body: "Hi")
      msg = mailbox.inbox.first
      expect(msg[:subject]).to eq("Test Subject")
    end

    it "stores cc recipients" do
      mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi",
                      cc: ["cc@test.com"])
      msg = mailbox.inbox.first
      expect(msg[:cc]).to include("cc@test.com")
    end

    it "stores bcc recipients" do
      mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi",
                      bcc: ["bcc@test.com"])
      msg = mailbox.inbox.first
      expect(msg[:bcc]).to include("bcc@test.com")
    end
  end

  describe "#inbox" do
    it "returns empty array when no messages" do
      expect(mailbox.inbox).to eq([])
    end

    it "returns captured messages" do
      mailbox.capture(to: "alice@test.com", subject: "First", body: "1")
      mailbox.capture(to: "bob@test.com", subject: "Second", body: "2")
      inbox = mailbox.inbox
      expect(inbox.length).to eq(2)
    end

    it "returns newest first" do
      mailbox.capture(to: "a@t.com", subject: "Old", body: "1")
      sleep 0.01
      mailbox.capture(to: "b@t.com", subject: "New", body: "2")
      inbox = mailbox.inbox
      expect(inbox.first[:subject]).to eq("New")
    end

    it "respects limit" do
      3.times { |i| mailbox.capture(to: "a@t.com", subject: "Msg #{i}", body: "x") }
      inbox = mailbox.inbox(limit: 2)
      expect(inbox.length).to eq(2)
    end

    it "respects offset" do
      3.times { |i| mailbox.capture(to: "a@t.com", subject: "Msg #{i}", body: "x"); sleep 0.01 }
      inbox = mailbox.inbox(limit: 2, offset: 1)
      expect(inbox.length).to eq(2)
    end

    it "filters by folder" do
      mailbox.capture(to: "a@t.com", subject: "Test", body: "x")
      inbox = mailbox.inbox(folder: "outbox")
      expect(inbox.length).to eq(1) # captured messages go to outbox
      inbox = mailbox.inbox(folder: "inbox")
      expect(inbox.length).to eq(0)
    end
  end

  describe "#read" do
    it "returns a message by ID" do
      result = mailbox.capture(to: "a@t.com", subject: "Hello", body: "World")
      msg = mailbox.read(result[:id])
      expect(msg).not_to be_nil
      expect(msg[:subject]).to eq("Hello")
    end

    it "marks message as read" do
      result = mailbox.capture(to: "a@t.com", subject: "Hello", body: "World")
      msg = mailbox.read(result[:id])
      expect(msg[:read]).to be true
    end

    it "returns nil for unknown ID" do
      expect(mailbox.read("nonexistent")).to be_nil
    end
  end

  describe "#unread_count" do
    it "returns 0 when no messages" do
      expect(mailbox.unread_count).to eq(0)
    end

    it "counts unread messages" do
      mailbox.capture(to: "a@t.com", subject: "One", body: "x")
      mailbox.capture(to: "b@t.com", subject: "Two", body: "y")
      expect(mailbox.unread_count).to eq(2)
    end

    it "decreases after reading" do
      result = mailbox.capture(to: "a@t.com", subject: "One", body: "x")
      mailbox.capture(to: "b@t.com", subject: "Two", body: "y")
      mailbox.read(result[:id])
      expect(mailbox.unread_count).to eq(1)
    end
  end

  describe "#delete" do
    it "deletes an existing message" do
      result = mailbox.capture(to: "a@t.com", subject: "Delete me", body: "x")
      expect(mailbox.delete(result[:id])).to be true
    end

    it "returns false for unknown ID" do
      expect(mailbox.delete("nonexistent")).to be false
    end

    it "removes message from inbox after delete" do
      result = mailbox.capture(to: "a@t.com", subject: "Delete me", body: "x")
      mailbox.delete(result[:id])
      expect(mailbox.inbox).to be_empty
    end
  end

  describe "#clear" do
    it "removes all messages" do
      mailbox.capture(to: "a@t.com", subject: "One", body: "x")
      mailbox.capture(to: "b@t.com", subject: "Two", body: "y")
      mailbox.clear
      expect(mailbox.inbox).to be_empty
    end

    it "removes messages by folder" do
      mailbox.capture(to: "a@t.com", subject: "One", body: "x") # goes to outbox
      mailbox.clear(folder: "outbox")
      expect(mailbox.inbox(folder: "outbox")).to be_empty
    end
  end

  describe "#count" do
    it "returns zero counts when empty" do
      counts = mailbox.count
      expect(counts[:total]).to eq(0)
    end

    it "counts messages by folder" do
      mailbox.capture(to: "a@t.com", subject: "One", body: "x")
      mailbox.capture(to: "b@t.com", subject: "Two", body: "y")
      counts = mailbox.count
      expect(counts[:outbox]).to eq(2)
      expect(counts[:total]).to eq(2)
    end

    it "counts for a specific folder" do
      mailbox.capture(to: "a@t.com", subject: "One", body: "x")
      counts = mailbox.count(folder: "outbox")
      expect(counts[:outbox]).to eq(1)
    end
  end

  describe "#seed" do
    it "creates seeded messages" do
      mailbox.seed(count: 3)
      expect(mailbox.inbox.length).to eq(3)
    end

    it "creates messages with subjects" do
      mailbox.seed(count: 2)
      mailbox.inbox.each do |msg|
        expect(msg[:subject]).to be_a(String)
        expect(msg[:subject]).not_to be_empty
      end
    end
  end
end

RSpec.describe Tina4::DevMessengerProxy do
  let(:test_dir) { Dir.mktmpdir("tina4-proxy-test") }
  let(:mailbox) { Tina4::DevMailbox.new(mailbox_dir: test_dir) }
  let(:proxy) { described_class.new(mailbox, from_address: "dev@localhost", from_name: "Dev") }

  after(:each) { FileUtils.rm_rf(test_dir) }

  describe "#send" do
    it "delegates to mailbox capture" do
      result = proxy.send(to: "test@test.com", subject: "Hello", body: "World")
      expect(result[:success]).to be true
    end
  end

  describe "#test_connection" do
    it "returns success in dev mode" do
      result = proxy.test_connection
      expect(result[:success]).to be true
      expect(result[:message]).to include("DevMailbox")
    end
  end

  describe "#inbox" do
    it "delegates to mailbox" do
      proxy.send(to: "test@test.com", subject: "Hello", body: "World")
      inbox = proxy.inbox
      expect(inbox.length).to eq(1)
    end
  end

  describe "#folders" do
    it "returns inbox and outbox" do
      expect(proxy.folders).to eq(["inbox", "outbox"])
    end
  end

  describe "#mailbox" do
    it "exposes the underlying mailbox" do
      expect(proxy.mailbox).to eq(mailbox)
    end
  end
end
