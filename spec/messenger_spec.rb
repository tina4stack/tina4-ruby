# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "socket"
require "securerandom"

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

  # -- IMAP over the REAL GreenMail server ------------------------------------
  #
  # NO MOCKS. These examples drive a live GreenMail instance: deliver a message
  # over plain SMTP (127.0.0.1:3025, no TLS) and read it back over plain IMAP
  # (127.0.0.1:3143, no TLS). Plain (non-TLS) IMAP is selected by passing
  # imap_encryption: "none" — Messenger#initialize maps any value outside
  # %w[tls starttls ssl] to imap_use_tls = false, so Net::IMAP.new is opened
  # with ssl: false. Plain SMTP likewise comes from use_tls: false -> "none".
  #
  # GreenMail has auth disabled (any user/pass is accepted) and creates a
  # mailbox on first access, so each example uses a UNIQUE recipient address to
  # get an isolated, freshly-created mailbox — no cross-example contamination.
  #
  # The fail-loud contract (read methods LOG and RAISE
  # MessengerConnectionError on a connection failure, rather than returning
  # []/nil/0 which is indistinguishable from a genuinely empty mailbox) is
  # exercised with a REAL closed TCP port (a refused connection), not a double.
  describe "IMAP over real GreenMail" do
    GREENMAIL_HOST      = ENV.fetch("TINA4_MAIL_HOST", "127.0.0.1")
    GREENMAIL_SMTP_PORT = ENV.fetch("TINA4_MAIL_PORT", "3025").to_i
    GREENMAIL_IMAP_PORT = ENV.fetch("TINA4_MAIL_IMAP_PORT", "3143").to_i

    # Reachability gate (mirrors session_handlers_spec / spec_helper). A skip
    # reason containing a gate keyword + an unavailable hint is turned into a
    # hard failure under TINA4_REQUIRE_SERVICES, so this real-service spec can
    # never silently no-op when GreenMail is provisioned.
    def self.service_reachable?(host, port)
      s = Socket.tcp(host, port, connect_timeout: 1)
      s.close
      true
    rescue StandardError
      false
    end

    # An unused, never-listening port for the refused-connection (fail-loud)
    # case — a REAL TCP connect that is genuinely refused, no stub.
    def self.find_closed_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    # Build a messenger wired to GreenMail over plain SMTP + plain IMAP for a
    # specific recipient mailbox.
    def build_messenger(address)
      described_class.new(
        host: GREENMAIL_HOST, port: GREENMAIL_SMTP_PORT, use_tls: false,
        imap_host: GREENMAIL_HOST, imap_port: GREENMAIL_IMAP_PORT,
        imap_encryption: "none",
        username: address, password: "secret",
        from_address: "sender@tina4.test", from_name: "Sender"
      )
    end

    # Unique recipient per example -> an isolated, first-access-created mailbox.
    let(:recipient) { "rb-#{SecureRandom.hex(8)}@tina4.test" }
    let(:messenger) { build_messenger(recipient) }

    before do
      unless self.class.service_reachable?(GREENMAIL_HOST, GREENMAIL_IMAP_PORT) &&
             self.class.service_reachable?(GREENMAIL_HOST, GREENMAIL_SMTP_PORT)
        skip "GreenMail mail server not reachable at #{GREENMAIL_HOST} (SMTP " \
             "#{GREENMAIL_SMTP_PORT} / IMAP #{GREENMAIL_IMAP_PORT})"
      end
    end

    # Deliver `subject`/`body` to the recipient over real SMTP, then poll the
    # real IMAP INBOX until it arrives. Returns the envelope hash from #inbox.
    def deliver_and_wait(subject:, body:, html: false)
      result = messenger.send(to: recipient, subject: subject, body: body, html: html)
      expect(result[:success]).to be(true), "SMTP send failed: #{result[:message]}"

      envelope = nil
      40.times do
        envelope = messenger.inbox.find { |m| m[:subject] == subject }
        break if envelope

        sleep 0.25
      end
      expect(envelope).not_to be_nil,
                              "message #{subject.inspect} never arrived in the real IMAP mailbox"
      envelope
    end

    # ── uid TYPE and page ORDER, both measured across all four ──────────────
    #
    # MEASURED 2026-08-06 against this same GreenMail, one mailbox, all four
    # frameworks asked the same question:
    #
    #   uid type   python str   php string   node string   ruby Integer
    #   page order python P3,P2 php P3,P2    node P3,P2    ruby P2,P3
    #
    # Ruby is the outlier on both. The documented contract says uid is a STRING
    # everywhere, so a caller comparing `uid == "3"` gets false in Ruby alone;
    # and `inbox(limit: 1)` returns the NEWEST message in three frameworks and
    # the OLDEST in Ruby, which is the most common inbox call there is.
    #
    # The order bug is subtle: uid_search is reversed to newest-first and the
    # page is sliced correctly, but uid_fetch returns rows in SERVER (ascending)
    # order, discarding the caller's ordering. Selection was right; presentation
    # was not.
    describe "uid type and page order (cross-framework contract)" do
      it "returns uid as a String, the way the other three do" do
        envelope = deliver_and_wait(subject: "uidtype-#{SecureRandom.hex(4)}", body: "x")
        expect(envelope[:uid]).to be_a(String),
          "uid is #{envelope[:uid].class} (#{envelope[:uid].inspect}); the contract " \
          "says String in all four, so `uid == '1'` is false in Ruby alone"
      end

      it "pages newest first, so inbox(limit: 1) is the newest message" do
        first  = "order1-#{SecureRandom.hex(4)}"
        second = "order2-#{SecureRandom.hex(4)}"
        deliver_and_wait(subject: first, body: "older")
        deliver_and_wait(subject: second, body: "newer")

        page = messenger.inbox(limit: 2)
        expect(page.length).to eq(2), "fixture did not build: #{page.map { |m| m[:subject] }}"
        expect(page.first[:subject]).to eq(second),
          "inbox(limit: 2).first is #{page.first[:subject].inspect}; expected the NEWEST " \
          "(#{second.inspect}). Ruby paged oldest-first while the other three page newest-first"

        # The selection half, kept separate from the ordering half: a limit of 1
        # must pick the newest message, not merely order a full page correctly.
        expect(messenger.inbox(limit: 1).map { |m| m[:subject] }).to eq([second])
      end

      it "still reads a message back by the uid it handed out" do
        # The pair. A change that stringified the uid but broke addressing would
        # satisfy the type assertion and be useless.
        subject = "uidread-#{SecureRandom.hex(4)}"
        envelope = deliver_and_wait(subject: subject, body: "read me")
        full = messenger.read(envelope[:uid])
        expect(full).not_to be_nil, "read(#{envelope[:uid].inspect}) found nothing"
        expect(full[:subject]).to eq(subject)
      end
    end


    it "delivers over real SMTP and reads the envelope back over real IMAP" do
      subject = "Inbox RoundTrip #{SecureRandom.hex(4)}"
      env = deliver_and_wait(subject: subject, body: "plain text body")

      expect(env[:subject]).to eq(subject)
      expect(env[:to].map { |a| a[:email] }).to include(recipient)
      expect(env[:from].map { |a| a[:email] }).to include("sender@tina4.test")
      # Was `be_a(Integer)`, which PINNED the divergence: the documented
      # cross-framework contract says uid is a String in all four, and Ruby
      # was the only one returning Integer. The spec asserted the bug.
      expect(env[:uid]).to be_a(String)
    end

    it "reads the full message body back over real IMAP" do
      subject = "Read Body #{SecureRandom.hex(4)}"
      body = "Hello over real IMAP #{SecureRandom.hex(4)}"
      env = deliver_and_wait(subject: subject, body: body)

      full = messenger.read(env[:uid])
      expect(full).not_to be_nil
      expect(full[:subject]).to eq(subject)
      expect(full[:body]).to eq(body)
    end

    it "reads an HTML message body back over real IMAP" do
      subject = "Read HTML #{SecureRandom.hex(4)}"
      html = "<h1>Hi #{SecureRandom.hex(4)}</h1>"
      env = deliver_and_wait(subject: subject, body: html, html: true)

      full = messenger.read(env[:uid])
      expect(full[:html]).to eq(html)
    end

    it "counts unread messages over real IMAP, then zero after reading" do
      subject = "Unread #{SecureRandom.hex(4)}"
      env = deliver_and_wait(subject: subject, body: "count me")

      expect(messenger.unread).to eq(1)
      messenger.read(env[:uid]) # sets the \Seen flag on the real server
      expect(messenger.unread).to eq(0)
    end

    it "searches by subject over real IMAP" do
      subject = "Searchable #{SecureRandom.hex(6)}"
      deliver_and_wait(subject: subject, body: "find me")

      hits = messenger.search(subject: subject)
      expect(hits.map { |m| m[:subject] }).to include(subject)
    end

    it "lists folders (INBOX) over real IMAP" do
      # Touch the mailbox so GreenMail creates it, then list folders for real.
      deliver_and_wait(subject: "Folders #{SecureRandom.hex(4)}", body: "x")
      expect(messenger.folders.map(&:upcase)).to include("INBOX")
    end

    context "when the mailbox is genuinely empty (successful real fetch)" do
      # A brand-new recipient address: GreenMail creates the mailbox on first
      # IMAP access, and it is genuinely empty — a successful fetch, NOT an
      # error. Empty must return []/0/nil, never raise.
      it "inbox returns [] (NOT an error)" do
        expect(messenger.inbox).to eq([])
      end

      it "unread returns 0 (NOT an error)" do
        expect(messenger.unread).to eq(0)
      end

      it "search with no matches returns [] (NOT an error)" do
        expect(messenger.search(subject: "nothing-#{SecureRandom.hex(6)}")).to eq([])
      end

      it "read of a missing UID returns nil (NOT an error)" do
        # Force the mailbox into existence, then fetch a UID that cannot exist.
        messenger.inbox
        expect(messenger.read(999_999)).to be_nil
      end
    end

    context "when the IMAP server is unreachable (real refused connection)" do
      # Point IMAP at a real closed port: Net::IMAP.new gets an actual
      # ECONNREFUSED. The read methods must FAIL LOUD (log + raise), never
      # swallow it into an empty result. No mock — a genuine refused socket.
      let(:dead_port) { self.class.find_closed_port }
      let(:messenger) do
        described_class.new(
          host: GREENMAIL_HOST, port: GREENMAIL_SMTP_PORT, use_tls: false,
          imap_host: "127.0.0.1", imap_port: dead_port, imap_encryption: "none",
          username: recipient, password: "secret"
        )
      end

      it "inbox raises instead of returning []" do
        expect { messenger.inbox }.to raise_error(Tina4::MessengerConnectionError)
      end

      it "read raises instead of returning nil" do
        expect { messenger.read("1") }.to raise_error(Tina4::MessengerConnectionError)
      end

      it "unread raises instead of returning 0" do
        expect { messenger.unread }.to raise_error(Tina4::MessengerConnectionError)
      end

      it "search raises instead of returning []" do
        expect { messenger.search(subject: "hi") }.to raise_error(Tina4::MessengerConnectionError)
      end

      it "folders raises instead of returning []" do
        expect { messenger.folders }.to raise_error(Tina4::MessengerConnectionError)
      end

      it "MessengerConnectionError is a MessengerError" do
        expect { messenger.inbox }.to raise_error(Tina4::MessengerError)
      end
    end
  end
end

RSpec.describe Tina4::DevMailbox do
  let(:test_dir) { Dir.mktmpdir("tina4-messenger-test") }
  let(:mailbox) { described_class.new(mailbox_dir: test_dir) }

  after(:each) { FileUtils.rm_rf(test_dir) }

  describe "#initialize" do
    it "creates a usable mailbox instance with its storage dirs" do
      # The constructor's real work is ensure_dirs (creates the messages +
      # attachments subdirs) AND a freshly-built instance must function
      # end-to-end. Prove both: the side-effect dirs exist, and a captured
      # message can be read back through this very instance.
      result = mailbox.capture(to: "alice@test.com", subject: "Ping", body: "Pong")
      expect(Dir.exist?(File.join(test_dir, "messages"))).to be true
      expect(Dir.exist?(File.join(test_dir, "attachments"))).to be true

      stored = mailbox.read(result[:id])
      expect(stored[:subject]).to eq("Ping")
      expect(stored[:body]).to eq("Pong")
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

    it "returns the captured-confirmation message and round-trips the email" do
      result = mailbox.capture(to: "alice@test.com", subject: "Hello", body: "Hi")
      # The contract promises this exact confirmation string, not merely "a String".
      expect(result[:message]).to eq("Email captured to dev mailbox")
      # And the captured email must actually round-trip out of storage.
      msg = mailbox.read(result[:id])
      expect(msg[:subject]).to eq("Hello")
      expect(msg[:body]).to eq("Hi")
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
    # Isolation: these examples assert on the contents of THIS mailbox only.
    # The flake (observed under the full randomized suite, e.g. --seed 24846,
    # green in isolation) was cross-spec contamination of the shared DevAdmin
    # mailbox singleton / a leaked TINA4_MAILBOX_DIR env override leaking a
    # foreign default-dir mailbox into a later read. spec_helper now resets the
    # singleton + scrubs the env after every example; this local hook makes the
    # affected specs self-defending too (resets BEFORE they run regardless of
    # ordering), and the count assertion below stops a contaminated/empty read
    # from passing vacuously.
    before(:each) do
      if defined?(Tina4::DevAdmin) && Tina4::DevAdmin.respond_to?(:reset_singletons!)
        Tina4::DevAdmin.reset_singletons!
      end
      ENV.delete("TINA4_MAILBOX_DIR")
    end

    it "creates seeded messages" do
      mailbox.seed(count: 3)
      expect(mailbox.inbox.length).to eq(3)
    end

    it "creates messages with subjects" do
      mailbox.seed(count: 2)
      messages = mailbox.inbox
      # Guard against a vacuous pass / contaminated read: the count must match
      # exactly what we just seeded into THIS mailbox.
      expect(messages.length).to eq(2)
      messages.each do |msg|
        expect(msg[:subject]).to be_a(String)
        expect(msg[:subject]).not_to be_empty
      end
    end
  end
end

# DevMessengerProxy is GONE (3.13.94). It was a second return type from
# create_messenger whose #send took no text: keyword, so the documented call raised
# ArgumentError on a dev messenger and the plain-text alternative was dropped.
# Capture is now a branch inside Messenger#send, so these are the same behaviours
# asserted against the one type that actually exists.
RSpec.describe "Tina4::Messenger capture path (replaces DevMessengerProxy)" do
  let(:test_dir) { Dir.mktmpdir("tina4-capture-test") }

  around(:each) do |example|
    saved = ENV.to_h.slice("TINA4_MAIL_HOST", "TINA4_MAIL_CAPTURE", "TINA4_MAILBOX_DIR")
    ENV.delete("TINA4_MAIL_HOST")
    ENV.delete("TINA4_MAIL_CAPTURE")
    ENV["TINA4_MAILBOX_DIR"] = test_dir
    example.run
    ENV.delete("TINA4_MAILBOX_DIR")
    saved.each { |k, v| ENV[k] = v }
  end

  after(:each) { FileUtils.rm_rf(test_dir) }

  subject(:messenger) do
    Tina4.create_messenger(
      mailbox_dir: test_dir, from_address: "dev@localhost", from_name: "Dev"
    )
  end

  describe "#send" do
    it "captures to the mailbox when no SMTP host is configured" do
      result = messenger.send(to: "test@test.com", subject: "Hello", body: "World")
      expect(result[:success]).to be true
    end

    it "carries the plain-text alternative, which the proxy dropped" do
      messenger.send(
        to: "test@test.com", subject: "Hello", body: "<p>World</p>",
        html: true, text: "the text part"
      )
      captured = messenger.dev_mailbox.inbox.first
      expect(captured[:text]).to eq("the text part")
    end
  end

  describe "#dev_mailbox" do
    it "exposes the underlying mailbox" do
      expect(messenger.dev_mailbox).to be_a(Tina4::DevMailbox)
    end

    it "receives what send captured" do
      messenger.send(to: "test@test.com", subject: "Hello", body: "World")
      expect(messenger.dev_mailbox.inbox.length).to eq(1)
    end
  end

  describe "one concrete type" do
    it "always returns a Messenger, never a second proxy class" do
      expect(messenger).to be_a(Tina4::Messenger)
      expect(messenger).to respond_to(:send)
    end
  end
end
