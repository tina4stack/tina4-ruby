# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "net/http"
require "securerandom"
require "socket"

# Tina4's own SMTP and IMAP clients (they replaced net-smtp and net-imap) on the
# wire: STARTTLS, implicit TLS, AUTH PLAIN / LOGIN, certificate verification,
# and the refusals that keep credentials off a clear channel.
#
# NO mocks, doubles or in-test servers. The servers are real and stood up by
# spec/support/mail-infra.sh (CI runs the same script):
#
#   GreenMail  4025 SMTP + AUTH, 4465 SMTPS, 4143 IMAP + LOGIN, 4993 IMAPS
#   Mailpit    4587 SMTP with STARTTLS required + AUTH, 4825 its HTTP API
#   Dovecot    4144 IMAP with STARTTLS
#
# The TLS examples run in a child Ruby process started with SSL_CERT_FILE set to
# the test CA: that is how an app trusts a private CA, and OpenSSL reads the
# variable when it builds its default store, so it cannot be flipped inside this
# process. The NEGATIVE examples start the child WITHOUT it, and must fail: a TLS
# suite passes just as happily with verification switched off, so the refusals
# are what prove it is on.
RSpec.describe "Messenger mail transport (own SMTP + IMAP clients)" do
  # The ports and the account are fixed by spec/support/mail-infra.sh; only the
  # host and the CA travel through the environment (ADR-0038 canonical names).
  # (A method, not a constant: a constant in a describe block lands on Object.)
  def self.mail_ports
    { smtp_auth: 4025, smtps: 4465, imap_auth: 4143, imaps: 4993,
      starttls_smtp: 4587, starttls_api: 4825, starttls_imap: 4144 }
  end

  let(:host) { ENV.fetch("TINA4_TEST_MAIL_TLS_HOST", "127.0.0.1") }
  let(:ca_file) { ENV.fetch("TINA4_TEST_MAIL_TLS_CA_FILE", "") }
  let(:username) { "tina4" }
  let(:password) { "mail-secret" }
  let(:mailbox_address) { "tina4@tina4.test" }

  def port(name)
    self.class.mail_ports.fetch(name)
  end

  def self.reachable?(host, port)
    Socket.tcp(host, port, connect_timeout: 1).close
    true
  rescue StandardError
    false
  end

  before do
    if ca_file.empty? || !File.file?(ca_file)
      skip "TLS mail servers (SMTP/IMAP) not set: run spec/support/mail-infra.sh and export " \
           "TINA4_TEST_MAIL_TLS_HOST / TINA4_TEST_MAIL_TLS_CA_FILE"
    end
    unless self.class.mail_ports.values.all? { |p| self.class.reachable?(host, p) }
      skip "TLS mail servers (SMTP/IMAP) not reachable at #{host} ports #{self.class.mail_ports.values.join(', ')}"
    end
  end

  # Run +script+ in a fresh Ruby with the framework loaded, the messenger
  # options from +options+ as INPUT, and SSL_CERT_FILE set only when +trust_ca+.
  # The script's last value is printed as JSON and returned parsed.
  def child(script, options = {}, trust_ca: true)
    env = { "MAIL_SPEC_INPUT" => JSON.generate(options), "SSL_CERT_FILE" => (trust_ca ? ca_file : nil),
            "TINA4_MAIL_CAPTURE" => nil, "TINA4_MAIL_REDIRECT_TO" => nil }
    program = <<~RUBY
      require "tina4"
      require "json"
      INPUT = JSON.parse(ENV.fetch("MAIL_SPEC_INPUT"), symbolize_names: true)
      def messenger(**overrides)
        Tina4::Messenger.new(**INPUT[:messenger].to_h.merge(overrides))
      end
      result = begin
        #{script}
      rescue StandardError => e
        { "error_class" => e.class.name, "error" => e.message }
      end
      $stdout.write("\\n@@RESULT@@" + JSON.generate(result))
    RUBY
    out, status = Open3.capture2e(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", program)
    out = out.dup.force_encoding(Encoding::UTF_8)
    marker = out.rindex("@@RESULT@@")
    raise "child ruby failed (exit #{status.exitstatus}):\n#{out}" unless marker

    JSON.parse(out[(marker + "@@RESULT@@".length)..])
  end

  def mailpit_subjects(subject)
    uri = URI("http://#{host}:#{port(:starttls_api)}/api/v1/search")
    uri.query = URI.encode_www_form(query: %(subject:"#{subject}"))
    JSON.parse(Net::HTTP.get(uri)).fetch("messages").map { |message| message["Subject"] }
  end

  def unique_subject(label)
    "#{label}-#{SecureRandom.hex(6)}"
  end

  # ── SMTP ──────────────────────────────────────────────────────────────────
  describe "SMTP over STARTTLS (Mailpit, STARTTLS required, AUTH)" do
    let(:options) do
      { messenger: { host: host, port: port(:starttls_smtp), username: username, password: password,
                     from_address: "sender@tina4.test" } }
    end

    %w[starttls tls].each do |encryption|
      it "delivers with encryption #{encryption.inspect}: STARTTLS, AUTH, DATA all over TLS" do
        subject = unique_subject("starttls-#{encryption}")
        result = child(<<~RUBY, options.merge(subject: subject, encryption: encryption))
          messenger(encryption: INPUT[:encryption])
            .send(to: "rcpt@tina4.test", subject: INPUT[:subject], body: "over starttls")
        RUBY
        expect(result["success"]).to be(true), result.inspect
        expect(mailpit_subjects(subject)).to eq([subject])
      end
    end

    it "NEGATIVE: refuses a server whose certificate is not trusted (verification is on)" do
      subject = unique_subject("starttls-untrusted")
      result = child(<<~RUBY, options.merge(subject: subject), trust_ca: false)
        messenger(encryption: "starttls").send(to: "rcpt@tina4.test", subject: INPUT[:subject], body: "x")
      RUBY
      expect(result["success"]).to be(false)
      expect(result["message"]).to match(/certificate verify failed/i)
      expect(mailpit_subjects(subject)).to eq([])
    end

    it "NEGATIVE: encryption 'none' never upgrades, so a STARTTLS-only server refuses the mail" do
      subject = unique_subject("starttls-none")
      result = child(<<~RUBY, options.merge(subject: subject))
        messenger(encryption: "none").send(to: "rcpt@tina4.test", subject: INPUT[:subject], body: "x")
      RUBY
      expect(result["success"]).to be(false), result.inspect
      expect(mailpit_subjects(subject)).to eq([])
    end
  end

  describe "SMTP with implicit TLS (GreenMail SMTPS, encryption 'ssl') read back over IMAPS" do
    let(:options) do
      { messenger: { host: host, port: port(:smtps), username: username, password: password,
                     from_address: "sender@tina4.test", encryption: "ssl",
                     imap_host: host, imap_port: port(:imaps), imap_encryption: "tls" } }
    end

    it "sends over implicit TLS and reads it back over IMAPS with the same shapes" do
      subject = unique_subject("implicit")
      body = "line one\ncaf\u00E9 \u6771\u4EAC\nend"
      result = child(<<~RUBY, options.merge(subject: subject, to: mailbox_address, body: body))
        m = messenger
        sent = m.send(to: INPUT[:to], subject: INPUT[:subject], body: INPUT[:body],
                      attachments: [{ filename: "blob.bin", content: (0..255).map(&:chr).join.b }])
        found = nil
        40.times do
          found = m.inbox(limit: 50).find { |item| item[:subject] == INPUT[:subject] }
          break if found
          sleep 0.25
        end
        full = found && m.read(found[:uid])
        { "sent" => sent[:success], "sent_message" => sent[:message], "found" => found,
          "body_text" => full && full[:body_text],
          "attachment" => full && full[:attachments].map { |a| [a[:filename], a[:size], a[:content].bytes == (0..255).to_a] },
          "folders" => m.folders }
      RUBY
      expect(result["sent"]).to be(true), result.inspect
      expect(result["found"]).to include("subject" => subject, "seen" => false)
      expect(result["found"]["uid"]).to be_a(String)
      expect(result["body_text"]).to eq(body)
      expect(result["attachment"]).to eq([["blob.bin", 256, true]])
      expect(result["folders"]).to include("INBOX")
    end

    it "NEGATIVE: implicit TLS to an untrusted certificate fails the send" do
      result = child(<<~RUBY, options, trust_ca: false)
        messenger.send(to: "x@tina4.test", subject: "never", body: "x")
      RUBY
      expect(result["success"]).to be(false)
      expect(result["message"]).to match(/certificate verify failed/i)
    end

    it "NEGATIVE: IMAPS to an untrusted certificate raises MessengerConnectionError" do
      result = child("messenger.unread", options, trust_ca: false)
      expect(result["error_class"]).to eq("Tina4::MessengerConnectionError")
      expect(result["error"]).to match(/certificate verify failed/i)
    end
  end

  describe "SMTP AUTH mechanisms (GreenMail, credentials really checked)" do
    let(:smtp_port) { port(:smtp_auth) }

    %w[PLAIN LOGIN].each do |mechanism|
      # The raw message also carries lines that start with "." -- SMTP
      # dot-stuffing must double them on the wire and the server undo it, or a
      # lone "." line would end DATA early and truncate the mail.
      it "authenticates with AUTH #{mechanism} and delivers, dot-stuffed lines intact" do
        subject = unique_subject("auth-#{mechanism}")
        body = "first\n.leading dot\n..two dots\n.\nlast"
        Tina4::Messenger::SmtpClient.start(host: host, port: smtp_port, username: username, password: password,
                                auth_mechanism: mechanism) do |smtp|
          smtp.send_message("Subject: #{subject}\n\n#{body}\n", "sender@tina4.test", [mailbox_address])
        end
        messenger = Tina4::Messenger.new(imap_host: host, imap_port: port(:imap_auth), imap_encryption: "none",
                                         imap_username: username, imap_password: password)
        found = nil
        40.times do
          found = messenger.inbox(limit: 50).find { |item| item[:subject] == subject }
          break if found

          sleep 0.25
        end
        expect(found).not_to be_nil
        expect(messenger.read(found[:uid])[:body_text].split(/\r?\n/)).to eq(body.split("\n"))
      end

      it "NEGATIVE: AUTH #{mechanism} with the wrong password is refused with the server's 535" do
        expect do
          Tina4::Messenger::SmtpClient.start(host: host, port: smtp_port, username: username, password: "wrong",
                                  auth_mechanism: mechanism) { |_smtp| nil }
        end.to raise_error(Tina4::Messenger::SmtpClient::Error, /\A535/)
      end
    end

    it "NEGATIVE: Messenger#send reports a refused login as success: false" do
      result = Tina4::Messenger.new(host: host, port: smtp_port, encryption: "none",
                                    username: username, password: "wrong").send(to: "a@tina4.test", subject: "s", body: "b")
      expect(result).to include(success: false, id: nil)
      expect(result[:message]).to start_with("535")
    end

    it "NEGATIVE: STARTTLS asked of a server that does not offer it fails instead of sending in clear" do
      %w[starttls tls].each do |encryption|
        result = Tina4::Messenger.new(host: host, port: smtp_port, encryption: encryption,
                                      username: username, password: password).send(to: "a@tina4.test", subject: "s", body: "b")
        expect(result[:success]).to be(false)
        expect(result[:message]).to eq("STARTTLS was requested but #{host}:#{smtp_port} does not offer it")
      end
    end

    # ADR-0071 section 1: the value is trimmed and compared without case. Before,
    # " SSL " matched nothing, fell through to a plain connection, and this
    # plaintext listener ACCEPTED the login and the message in clear (measured).
    # Now it is "ssl", so the client opens TLS and the plaintext server fails it.
    it "NEGATIVE: ' SSL ' is trimmed to ssl, so a plaintext-only listener fails instead of getting the mail in clear" do
      subject = unique_subject("trimmed-ssl")
      options = { messenger: { host: host, port: smtp_port, username: username, password: password,
                               from_address: "sender@tina4.test", encryption: " SSL " },
                  subject: subject, to: mailbox_address }
      result = child(<<~RUBY, options)
        messenger.send(to: INPUT[:to], subject: INPUT[:subject], body: "b")
      RUBY
      expect(result["success"]).to be(false), result.inspect
      expect(result["message"]).to match(/SSL|TLS|wrong version/i)

      reader = Tina4::Messenger.new(imap_host: host, imap_port: port(:imap_auth), imap_encryption: "none",
                                    imap_username: username, imap_password: password)
      expect(reader.inbox(limit: 50).map { |item| item[:subject] }).not_to include(subject)
    end
  end

  # ── IMAP ──────────────────────────────────────────────────────────────────
  describe "IMAP over STARTTLS (Dovecot)" do
    # Dovecot's image uses a static passdb: any user, password "pass". A fresh
    # user per example is a fresh, empty mailbox.
    let(:options) do
      { messenger: { imap_host: host, imap_port: port(:starttls_imap), imap_encryption: "starttls",
                     imap_username: "rb#{SecureRandom.hex(4)}", imap_password: "pass" } }
    end

    it "upgrades with STARTTLS, logs in and runs SELECT / SEARCH / LIST over TLS" do
      result = child(<<~RUBY, options)
        m = messenger
        { "folders" => m.folders, "unread" => m.unread, "inbox" => m.inbox, "ok" => m.test_imap_connection }
      RUBY
      expect(result).to include("folders" => include("INBOX"), "unread" => 0, "inbox" => [])
      expect(result["ok"]).to include("success" => true)
    end

    it "NEGATIVE: STARTTLS to an untrusted certificate raises MessengerConnectionError" do
      result = child("messenger.folders", options, trust_ca: false)
      expect(result["error_class"]).to eq("Tina4::MessengerConnectionError")
      expect(result["error"]).to match(/certificate verify failed/i)
    end

    it "NEGATIVE: STARTTLS to a server that does not offer it fails before LOGIN" do
      messenger = Tina4::Messenger.new(imap_host: host, imap_port: port(:imap_auth), imap_encryption: "starttls",
                                       imap_username: username, imap_password: password)
      expect { messenger.folders }.to raise_error(Tina4::MessengerConnectionError, /\AIMAP folders failed: /) { |error|
        expect(error.cause).to be_a(Tina4::Messenger::ImapClient::Error)
        expect(%w[NO BAD]).to include(error.cause.status)
      }
    end
  end

  describe "IMAP LOGIN is really checked (GreenMail)" do
    it "NEGATIVE: a wrong password raises MessengerConnectionError, never an empty inbox" do
      messenger = Tina4::Messenger.new(imap_host: host, imap_port: port(:imap_auth), imap_encryption: "none",
                                       imap_username: username, imap_password: "wrong")
      expect { messenger.inbox }.to raise_error(Tina4::MessengerConnectionError, /\AIMAP inbox failed: /) { |error|
        expect(error.cause).to be_a(Tina4::Messenger::ImapClient::Error)
        expect(error.cause.status).to eq("NO")
      }
    end
  end
end
