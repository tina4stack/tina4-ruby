# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "socket"
require "tmpdir"
require "fileutils"

# MAIL REDIRECT CONTRACT -- TINA4_MAIL_REDIRECT_TO (MAIL-DEC-01).
#
# Pins plan/v3/fixtures/mail_redirect_contract.json. TINA4_MAIL_REDIRECT_TO is a
# SECOND, independent knob on the real-SMTP path: when a redirect list is
# configured and #send is actually talking to SMTP (not capturing), every
# recipient is REPLACED by the redirect list and the original recipients are
# preserved in an X-Tina4-Original-To header. Capture (TINA4_MAIL_CAPTURE / no
# SMTP host) always wins -- redirect never applies on the capture path.
#
# Real GreenMail SMTP :3025 / IMAP :3143 (TINA4_MAIL_HOST / TINA4_MAIL_PORT /
# TINA4_MAIL_IMAP_PORT to relocate -- the SAME coordinates and the SAME live
# server messenger_spec.rb and messenger_contract_spec.rb use). NO MOCKS: every
# example sends real SMTP and proves delivery/non-delivery with a real IMAP
# fetch.
#
# Ruby rule honoured throughout: no bare CONSTANT is declared inside the
# describe block (it would land on Object and clobber other spec files -- see
# spec_helper.rb). GreenMail coordinates are `let`s; helpers are instance
# methods.
RSpec.describe "Mail redirect contract" do
  let(:greenmail_host) { ENV.fetch("TINA4_MAIL_HOST", "127.0.0.1") }
  let(:greenmail_smtp_port) { ENV.fetch("TINA4_MAIL_PORT", "3025").to_i }
  let(:greenmail_imap_port) { ENV.fetch("TINA4_MAIL_IMAP_PORT", "3143").to_i }

  # A real TCP connect that either succeeds or is genuinely refused — never a stub.
  def service_reachable?(host, port)
    socket = Socket.tcp(host, port, connect_timeout: 1)
    socket.close
    true
  rescue StandardError
    false
  end

  # Skip (mirroring spec/messenger_spec.rb) when GreenMail is not up locally.
  # The message carries the gate keywords + "not reachable", so a lab run with
  # TINA4_REQUIRE_SERVICES set fails instead of green-skipping.
  def greenmail!
    return if service_reachable?(greenmail_host, greenmail_imap_port) &&
              service_reachable?(greenmail_host, greenmail_smtp_port)

    skip "GreenMail mail server not reachable at #{greenmail_host} " \
         "(SMTP #{greenmail_smtp_port} / IMAP #{greenmail_imap_port})"
  end

  # A unique address -> an isolated, first-access-created GreenMail mailbox
  # (GreenMail's auth is disabled on the lab, so LOGIN as any never-used
  # address succeeds and SELECT INBOX reports 0 messages -- verified live).
  def unique_address(prefix, domain)
    "mailredirect-#{prefix}-#{SecureRandom.hex(6)}@#{domain}"
  end

  # A messenger wired for a real SMTP send only (no IMAP creds needed).
  def sender_messenger
    Tina4::Messenger.new(
      host: greenmail_host, port: greenmail_smtp_port, use_tls: false,
      from_address: "sender@tina4.test", from_name: "Sender"
    )
  end

  # A messenger wired to poll ONE mailbox's real IMAP. The address IS the
  # mailbox identity (GreenMail auth disabled -- any password is accepted).
  def reader_messenger(address)
    Tina4::Messenger.new(
      imap_host: greenmail_host, imap_port: greenmail_imap_port,
      imap_encryption: "none", username: address, password: "secret"
    )
  end

  # Poll until `subject` is listed in `address`'s real IMAP inbox.
  def wait_present(address, subject, attempts: 40)
    reader = reader_messenger(address)
    envelope = nil
    attempts.times do
      envelope = reader.inbox.find { |m| m[:subject] == subject }
      break if envelope

      sleep 0.25
    end
    expect(envelope).not_to be_nil, "#{subject.inspect} never arrived in #{address}'s real IMAP mailbox"
    envelope
  end

  # Poll for `subject` to confirm it NEVER arrives within a real bounded
  # window. Mutation-proof: if the recipient-rewrite is disabled the message
  # DOES land here and this returns false well before the budget is spent.
  def stays_absent?(address, subject, attempts: 40)
    reader = reader_messenger(address)
    attempts.times do
      return false if reader.inbox.any? { |m| m[:subject] == subject }

      sleep 0.25
    end
    true
  end

  # Run `block` with the given env vars forced to a known state (real process
  # ENV, restored afterwards). A nil value deletes the var.
  def with_mail_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v.to_s) }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  it "redirect_delivers_to_every_address_on_the_list: TINA4_MAIL_REDIRECT_TO delivers to " \
     "every dev address and NOT the real one, carrying X-Tina4-Original-To" do
    greenmail!
    dev1 = unique_address("dev1", "x.test")
    dev2 = unique_address("dev2", "x.test")
    real = unique_address("real", "y.test")
    subject = "mailredirect-#{SecureRandom.hex(4)}"

    # A deliberate space after the comma proves the parse rule really trims.
    with_mail_env("TINA4_MAIL_REDIRECT_TO" => "#{dev1}, #{dev2}") do
      result = sender_messenger.send(to: real, subject: subject, body: "the real message body")
      expect(result[:success]).to be(true), (result[:message] || "send failed")

      # Positive: BOTH dev addresses received it.
      item1 = wait_present(dev1, subject)
      item2 = wait_present(dev2, subject)
      expect(item1[:subject]).to eq(subject)
      expect(item2[:subject]).to eq(subject)

      # Negative: the real recipient never did.
      expect(stays_absent?(real, subject)).to be(true),
                                              "the real recipient #{real} received the redirected mail"

      # The received message carries the original recipient in the header.
      full = reader_messenger(dev1).read(item1[:uid])
      expect(full).not_to be_nil
      expect(full[:headers]["X-Tina4-Original-To"]).to eq(real)
    end
  end

  it "redirect_unset_delivers_normally: with TINA4_MAIL_REDIRECT_TO unset, mail arrives at " \
     "the real recipient (negative/control)" do
    greenmail!
    real = unique_address("realctrl", "y.test")
    subject = "mailredirect-ctrl-#{SecureRandom.hex(4)}"

    with_mail_env("TINA4_MAIL_REDIRECT_TO" => nil) do
      result = sender_messenger.send(to: real, subject: subject, body: "normal delivery")
      expect(result[:success]).to be(true), (result[:message] || "send failed")
      item = wait_present(real, subject)
      expect(item[:subject]).to eq(subject)
    end
  end

  it "capture_takes_precedence_over_redirect: TINA4_MAIL_CAPTURE wins over " \
     "TINA4_MAIL_REDIRECT_TO -- nothing reaches GreenMail, the DevMailbox gets exactly 1 message" do
    greenmail!
    dev1 = unique_address("capdev1", "x.test")
    dev2 = unique_address("capdev2", "x.test")
    real = unique_address("capreal", "y.test")
    subject = "mailredirect-capture-#{SecureRandom.hex(4)}"
    mailbox_dir = Dir.mktmpdir("tina4-mailredirect")

    begin
      with_mail_env(
        "TINA4_MAIL_CAPTURE" => "true",
        "TINA4_MAIL_REDIRECT_TO" => "#{dev1},#{dev2}",
        "TINA4_MAILBOX_DIR" => mailbox_dir
      ) do
        # A REAL SMTP host is configured too, so capture wins on the MERITS of
        # TINA4_MAIL_CAPTURE, not merely because sending was unavailable.
        messenger = Tina4::Messenger.new(
          host: greenmail_host, port: greenmail_smtp_port, use_tls: false,
          from_address: "sender@tina4.test"
        )
        result = messenger.send(to: real, subject: subject, body: "must never leave this box")
        expect(result[:success]).to be(true), (result[:message] || "capture send failed")

        # Nothing reached GreenMail at all -- dev list AND the real recipient
        # stay empty (a shorter budget suffices: capture short-circuits before
        # any socket is opened, so a mutation would surface fast).
        expect(stays_absent?(dev1, subject, attempts: 16)).to be(true),
                                                               "dev1 (#{dev1}) received mail despite TINA4_MAIL_CAPTURE"
        expect(stays_absent?(dev2, subject, attempts: 16)).to be(true),
                                                               "dev2 (#{dev2}) received mail despite TINA4_MAIL_CAPTURE"
        expect(stays_absent?(real, subject, attempts: 16)).to be(true),
                                                               "the real recipient (#{real}) received mail despite TINA4_MAIL_CAPTURE"

        # Exactly one message landed in the local DevMailbox.
        files = Dir.glob(File.join(mailbox_dir, "**", "*.json"))
        expect(files.length).to eq(1), "expected exactly 1 captured message, found #{files.length}"
      end
    ensure
      FileUtils.rm_rf(mailbox_dir)
    end
  end
end
