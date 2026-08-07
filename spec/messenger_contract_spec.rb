# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "socket"
require "securerandom"

# Messenger contract, mirroring tina4-nodejs#41 and #42.
#
# Four contract points, each with a POSITIVE example (the right behaviour is
# accepted) and a NEGATIVE one (the wrong behaviour is rejected). The same eight run
# in all four frameworks. Contract and the ADR-0004 ranking:
# tina4-documentation/plan/v3/messenger-contract.md.
#
# Ruby held the BEST piece of this contract and one real gap.
#
# The best piece: native keyword arguments make the #42 class of bug
# UNREPRESENTABLE rather than merely absent. There is no 5th positional to
# mis-order, so `text` can never be mistaken for `cc` here no matter how the two
# signatures drift. That is why the contract adopted keyword discipline.
#
# The gap: create_messenger returned either a Messenger or a DevMessengerProxy, and
# the proxy's #send took NO text: keyword -- so the documented call raised
# ArgumentError on a dev messenger and the plain-text alternative was dropped from
# the captured message. Ruby escaped the #41 CRASH by luck of naming (both arms
# happened to expose #send), not by design. The proxy is gone; capture is a branch
# inside Messenger#send.
#
# The gate is availability, not verbosity (owner decision, superseding the plan's
# original point 3): capture when no SMTP host is configured, send when one is even
# with TINA4_DEBUG on, and TINA4_MAIL_CAPTURE forces capture. Ruby's old gate needed
# debug AND no SMTP host, so a dev box with neither set dialled localhost:587.
#
# NO MOCKS: DevMailbox writes real JSON. Every example points TINA4_MAILBOX_DIR at a
# temp directory and reads the file back off disk.
RSpec.describe "Messenger contract" do
  let(:mailbox_dir) { Dir.mktmpdir("tina4-messenger-contract") }

  around(:each) do |example|
    saved = ENV.to_h.slice(
      "TINA4_MAILBOX_DIR", "TINA4_MAIL_HOST", "TINA4_MAIL_CAPTURE", "TINA4_DEBUG"
    )
    # A dev box with no mail server: capture is the correct behaviour.
    ENV["TINA4_MAILBOX_DIR"] = mailbox_dir
    ENV.delete("TINA4_MAIL_HOST")
    ENV.delete("TINA4_MAIL_CAPTURE")
    ENV["TINA4_DEBUG"] = "true"

    example.run

    %w[TINA4_MAILBOX_DIR TINA4_MAIL_HOST TINA4_MAIL_CAPTURE TINA4_DEBUG].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(mailbox_dir)
  end

  # The captured message, read off disk. Globs recursively rather than assuming a
  # folder name: the four frameworks lay the mailbox out differently and these
  # assertions are about content.
  def captured
    files = Dir.glob(File.join(mailbox_dir, "**", "*.json")).sort
    expect(files).not_to be_empty, "nothing captured under #{mailbox_dir}"
    JSON.parse(File.read(files.first), symbolize_names: true)
  end

  subject(:mail) { Tina4.create_messenger(mailbox_dir: mailbox_dir) }

  # --- 1. the factory returns ONE type, and it can send ---------------------

  it "positive: the factory returns a sender" do
    expect(mail).to respond_to(:send)
  end

  it "negative: the factory never returns a capture-only object" do
    # The #41 failure mode: an object whose only sending verb is capture().
    has_send = mail.respond_to?(:send)
    has_only_capture = mail.respond_to?(:capture) && !has_send
    expect(has_only_capture).to be(false),
                                "the factory returned #{mail.class} offering capture but not send"
  end

  it "negative: the factory never returns a second proxy class" do
    # DevMessengerProxy is gone. One concrete type, always.
    expect(mail).to be_a(Tina4::Messenger)
    expect(defined?(Tina4::DevMessengerProxy)).to be_nil,
                                                  "DevMessengerProxy still exists; the union is not collapsed"
  end

  # --- 2. text is carried, and can never be confused with cc ---------------

  it "positive: a captured message round-trips text" do
    mail.send(to: "a@b.com", subject: "Subj", body: "<p>body</p>", html: true,
              text: "the text part")
    msg = captured
    expect(msg).to have_key(:text),
                   "the captured message has no text field, so it is not what would have been sent"
    expect(msg[:text]).to eq("the text part")
  end

  it "negative: the plain-text body is never stored as a cc recipient" do
    # The #42 failure mode. Ruby cannot represent it -- keywords are named, not
    # positional -- and this pins that property rather than assuming it.
    mail.send(to: "a@b.com", subject: "Subject", body: "<p>hi</p>", html: true,
              text: "plain text alternative")
    cc = Array(captured[:cc])
    expect(cc).not_to include("plain text alternative"),
                      "the plain-text body was filed as a CC recipient: #{cc.inspect}"
  end

  it "negative: send accepts the text: keyword it documents" do
    # The proxy's #send had no text: parameter, so this raised ArgumentError on a
    # dev messenger -- the keyword the class documents did not exist on the object
    # you were handed.
    expect { mail.send(to: "a@b.com", subject: "S", body: "B", text: "t") }.not_to raise_error
  end

  # --- 3. cc/bcc are normalised at the boundary ---------------------------

  it "positive: a proper cc list passes through unchanged" do
    mail.send(to: "a@b.com", subject: "S", body: "<p>b</p>", html: true,
              cc: ["x@y.com", "p@q.com"])
    expect(captured[:cc]).to eq(["x@y.com", "p@q.com"])
  end

  it "negative: a bare-string cc is not stored as a bare string" do
    mail.send(to: "a@b.com", subject: "Subject", body: "<p>hi</p>", html: true,
              cc: "one@cc.com")
    cc = captured[:cc]
    expect(cc).not_to be_a(String), "cc was stored as a bare string where a list is declared"
    expect(cc).to eq(["one@cc.com"])
  end

  # --- 4. interception is a branch, not a separate object -----------------

  it "positive: send is the class's own method" do
    expect(mail.method(:send).owner).to eq(Tina4::Messenger),
                                        "send is not owned by Messenger; interception is installed around it"
  end

  it "negative: capture is reached THROUGH send, not instead of it" do
    result = mail.send(to: "a@b.com", subject: "Through send", body: "Body")
    expect(result[:success]).to be(true)
    expect(mail.dev_mailbox.inbox.length).to eq(1)
  end

  # --- the gate: availability, not verbosity -----------------------------

  it "captures when no SMTP host is configured" do
    expect(mail.dev_mailbox).to be_a(Tina4::DevMailbox),
                                "with no SMTP host there is nowhere to send, so it must capture"
  end

  it "negative: debug alone does not suppress sending" do
    # Debug must NOT swallow mail. A dev box with a real SMTP host can send.
    ENV["TINA4_DEBUG"] = "true"
    ENV["TINA4_MAIL_HOST"] = "smtp.example.com"
    messenger = Tina4.create_messenger(mailbox_dir: mailbox_dir)
    expect(messenger.should_capture?).to be(false),
                                         "TINA4_DEBUG forced capture even though SMTP was configured - " \
                                         "debug must still be able to send real mail"
  end

  it "forces capture when TINA4_MAIL_CAPTURE is set, even with SMTP configured" do
    ENV["TINA4_MAIL_HOST"] = "smtp.example.com"
    ENV["TINA4_MAIL_CAPTURE"] = "true"
    messenger = Tina4.create_messenger(mailbox_dir: mailbox_dir)
    expect(messenger.should_capture?).to be(true)
  end
end

# ── The 14 shared MESSENGER CONTRACT invariants ──────────────────────────────
#
# Source of truth: tina4-documentation/plan/v3/fixtures/messenger_contract.json
# (14 invariants, measured 2026-08-06). One example per invariant, each NAMED so
# its normalised description contains the invariant id verbatim (the shared
# cross-framework auditor lowercases, strips non-alphanumerics, and strips a
# leading "test") — so the same invariant matches in all four frameworks. This
# is what moves each invariant from "owed" to "proven" in Ruby.
#
# NO MOCKS. GreenMail is a real SMTP+IMAP server (delivered over 127.0.0.1:3025,
# read back over 127.0.0.1:3143, plain/no-TLS); the fail-loud case is a REAL
# refused socket on a genuinely closed port; the capture / gate / precedence
# cases construct a real Messenger over the real process ENV and write real JSON
# to a real temp dir. IMAP-dependent examples skip-guard exactly like
# spec/messenger_spec.rb, so under TINA4_REQUIRE_SERVICES the spec_helper gate
# turns a GreenMail-down skip into a hard failure (it can never green-skip on the
# lab). The constructor/gate/reflection examples need no service and run anywhere.
#
# Ruby rule honoured throughout: NO bare CONSTANT is declared inside the describe
# (it would land on Object and clobber other spec files — see spec_helper.rb).
# GreenMail coordinates are `let`s; the reachability / build / deliver helpers
# are instance methods.
RSpec.describe "Messenger contract invariants" do
  let(:greenmail_host) { ENV.fetch("TINA4_MAIL_HOST", "127.0.0.1") }
  let(:greenmail_smtp_port) { ENV.fetch("TINA4_MAIL_PORT", "3025").to_i }
  let(:greenmail_imap_port) { ENV.fetch("TINA4_MAIL_IMAP_PORT", "3143").to_i }

  # Unique recipient per example -> a fresh, isolated mailbox (GreenMail creates
  # it on first access, auth is disabled), so examples never contaminate each other.
  let(:recipient) { "rbc-#{SecureRandom.hex(8)}@tina4.test" }
  let(:messenger) { build_messenger(recipient) }

  # A real TCP connect that either succeeds or is genuinely refused — never a stub.
  def service_reachable?(host, port)
    socket = Socket.tcp(host, port, connect_timeout: 1)
    socket.close
    true
  rescue StandardError
    false
  end

  # A real, never-listening port for the refused-connection (fail-loud) case.
  def find_closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # A Messenger wired to GreenMail over plain SMTP + plain IMAP for `address`'s
  # mailbox (imap_encryption/use_tls "none" -> ssl: false). Overrides win.
  def build_messenger(address, **overrides)
    Tina4::Messenger.new(
      **{
        host: greenmail_host, port: greenmail_smtp_port, use_tls: false,
        imap_host: greenmail_host, imap_port: greenmail_imap_port,
        imap_encryption: "none",
        username: address, password: "secret",
        from_address: "sender@tina4.test", from_name: "Sender"
      }.merge(overrides)
    )
  end

  # Skip (mirroring spec/messenger_spec.rb) when GreenMail is not up locally. The
  # message carries the gate keywords + "not reachable", so a lab run with
  # TINA4_REQUIRE_SERVICES set fails instead of green-skipping.
  def greenmail!
    return if service_reachable?(greenmail_host, greenmail_imap_port) &&
              service_reachable?(greenmail_host, greenmail_smtp_port)

    skip "GreenMail mail server not reachable at #{greenmail_host} " \
         "(SMTP #{greenmail_smtp_port} / IMAP #{greenmail_imap_port})"
  end

  # Deliver over real SMTP, then poll the real IMAP INBOX until it arrives.
  # Returns the envelope hash from #inbox.
  def deliver_and_wait(msgr, subject:, body:, html: false)
    result = msgr.send(to: msgr.username, subject: subject, body: body, html: html)
    expect(result[:success]).to be(true), "SMTP send failed: #{result[:message]}"

    envelope = nil
    40.times do
      envelope = msgr.inbox.find { |m| m[:subject] == subject }
      break if envelope

      sleep 0.25
    end
    expect(envelope).not_to be_nil, "#{subject.inspect} never arrived over real IMAP"
    envelope
  end

  # Run `block` with the mail-mode env vars forced to a known state (real process
  # ENV, restored afterwards), so an ambient TINA4_MAIL_HOST / _CAPTURE / _DEBUG on
  # the host cannot flip the capture gate under the example.
  def with_mail_env(host: :delete, capture: :delete, debug: :delete)
    wanted = { "TINA4_MAIL_HOST" => host, "TINA4_MAIL_CAPTURE" => capture, "TINA4_DEBUG" => debug }
    saved = wanted.keys.to_h { |k| [k, ENV[k]] }
    wanted.each { |k, v| v == :delete ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  # ── 1. msg-uid-is-a-real-uid — the ONLY proof is a real expunge ─────────────
  it "msg-uid-is-a-real-uid: the uid is the IMAP UID and survives an expunge (not a sequence number)" do
    greenmail!
    tag = SecureRandom.hex(4)
    first  = deliver_and_wait(messenger, subject: "uid1-#{tag}", body: "one")
    second = deliver_and_wait(messenger, subject: "uid2-#{tag}", body: "two")
    third  = deliver_and_wait(messenger, subject: "uid3-#{tag}", body: "three")

    # Expunge the FIRST message. Under sequence numbering the survivors RENUMBER
    # (an id stored today addresses a different message tomorrow); under UID
    # addressing their ids are stable. Read each survivor back by the SAME id it
    # was handed — a sequence-number implementation reads back the wrong message
    # (or nothing) here, so this example fails on the two frameworks the fixture
    # measured returning sequence numbers.
    expect(messenger.delete(first[:uid])).to be(true)
    expect(messenger.read(second[:uid])[:subject]).to eq("uid2-#{tag}")
    expect(messenger.read(third[:uid])[:subject]).to eq("uid3-#{tag}")
  end

  # ── 2. msg-uid-is-a-string ──────────────────────────────────────────────────
  it "msg-uid-is-a-string: uid is a String on every method that returns one" do
    greenmail!
    env = deliver_and_wait(messenger, subject: "uidstr-#{SecureRandom.hex(4)}", body: "x")
    expect(env[:uid]).to be_a(String)
    expect(messenger.read(env[:uid])[:uid]).to be_a(String)
  end

  # ── 3. msg-inbox-is-newest-first ────────────────────────────────────────────
  it "msg-inbox-is-newest-first: inbox(limit:1) is the NEWEST message and the page is newest-first" do
    greenmail!
    tag = SecureRandom.hex(4)
    older = "nf-old-#{tag}"
    newer = "nf-new-#{tag}"
    deliver_and_wait(messenger, subject: older, body: "older")
    deliver_and_wait(messenger, subject: newer, body: "newer")

    expect(messenger.inbox(limit: 1).map { |m| m[:subject] }).to eq([newer])
    expect(messenger.inbox(limit: 2).map { |m| m[:subject] }).to eq([newer, older])
  end

  # ── 4. msg-folder-is-first-and-positional ───────────────────────────────────
  it "msg-folder-is-first-and-positional: inbox(folder,limit,offset) and read(uid,folder) are callable POSITIONALLY (keyword never substituted)" do
    greenmail!
    subject = "pos-#{SecureRandom.hex(4)}"
    env = deliver_and_wait(messenger, subject: subject, body: "positional")

    # Positional, folder first — this raised ArgumentError before 3.13.96.
    expect(messenger.inbox("INBOX", 10, 0).map { |m| m[:subject] }).to include(subject)
    expect(messenger.read(env[:uid], "INBOX")[:subject]).to eq(subject)

    # The keyword form is ADDED, never substituted — it must still work.
    expect(messenger.inbox(folder: "INBOX", limit: 10).map { |m| m[:subject] }).to include(subject)
    expect(messenger.read(env[:uid], folder: "INBOX", mark_read: false)[:subject]).to eq(subject)
  end

  # ── 5. msg-missing-uid-is-null-not-empty ────────────────────────────────────
  it "msg-missing-uid-is-null-not-empty: read() of a non-existent uid returns nil and never raises" do
    greenmail!
    messenger.inbox # force the mailbox into existence (a successful fetch)
    result = :unset
    expect { result = messenger.read(999_999) }.not_to raise_error
    expect(result).to be_nil
  end

  # ── 6. msg-read-methods-fail-loud — real refused port, no service needed ─────
  it "msg-read-methods-fail-loud: read methods RAISE MessengerConnectionError on a closed port; send() never raises" do
    dead = find_closed_port
    m = Tina4::Messenger.new(
      host: "127.0.0.1", port: dead, use_tls: false,
      imap_host: "127.0.0.1", imap_port: dead, imap_encryption: "none",
      username: "x@tina4.test", password: "secret"
    )

    expect { m.inbox }.to raise_error(Tina4::MessengerConnectionError)
    expect { m.read("1") }.to raise_error(Tina4::MessengerConnectionError)
    expect { m.unread }.to raise_error(Tina4::MessengerConnectionError)
    expect { m.search(subject: "x") }.to raise_error(Tina4::MessengerConnectionError)
    expect { m.folders }.to raise_error(Tina4::MessengerConnectionError)

    # send() returns a result on a real refused SMTP connection — it NEVER raises.
    with_mail_env(host: :delete, capture: :delete, debug: :delete) do
      result = :unset
      expect { result = m.send(to: "a@b.com", subject: "s", body: "b") }.not_to raise_error
      expect(result[:success]).to be(false)
    end
  end

  # ── 7. msg-inbox-item-shape ─────────────────────────────────────────────────
  it "msg-inbox-item-shape: an inbox() item is EXACTLY {uid,subject,from,to,date,snippet,seen} with string from/to, ISO-8601 date, Boolean seen" do
    greenmail!
    subject = "shape-#{SecureRandom.hex(4)}"
    env = deliver_and_wait(messenger, subject: subject, body: "shape body")

    expect(env.keys.sort).to eq(%i[date from seen snippet subject to uid])
    expect(env[:from]).to be_a(String).and include("sender@tina4.test")
    expect(env[:to]).to be_a(String).and include(recipient)
    expect(env[:date]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    expect([true, false]).to include(env[:seen])
  end

  # ── 8. msg-read-item-shape ──────────────────────────────────────────────────
  it "msg-read-item-shape: read() returns body_text/body_html + attachments + headers, and never the old body/html keys" do
    greenmail!
    subject = "read-#{SecureRandom.hex(4)}"
    env = deliver_and_wait(messenger, subject: subject, body: "the body text")
    full = messenger.read(env[:uid])

    expect(full.keys).to include(:uid, :subject, :from, :to, :cc, :date,
                                 :body_text, :body_html, :attachments, :headers)
    expect(full[:body_text]).to eq("the body text")
    expect(full[:attachments]).to eq([]) # a plain message has none, but the field exists
    expect(full[:headers]).to be_a(Hash)
    expect(full[:headers]["Message-ID"]).to be_a(String)
    expect(full).not_to have_key(:body)
    expect(full).not_to have_key(:html)
  end

  # ── 9. msg-snippet-is-decoded-text ──────────────────────────────────────────
  it "msg-snippet-is-decoded-text: snippet is decoded, tag-stripped plain text (never raw base64, never unconditionally empty)" do
    greenmail!
    tag = SecureRandom.hex(4)
    plain = deliver_and_wait(messenger, subject: "snip-#{tag}", body: "the quick brown fox")
    expect(plain[:snippet]).to eq("the quick brown fox")

    htmlmsg = deliver_and_wait(messenger, subject: "sniph-#{tag}",
                               body: "<p>Hello <b>world</b></p>", html: true)
    expect(htmlmsg[:snippet]).to eq("Hello world")
  end

  # ── 10. msg-send-result-shape — capture + delivery paths, both real ─────────
  it "msg-send-result-shape: send() returns exactly {success,message,id} on both paths; id present on success, null on failure; no extra keys" do
    keys = %i[id message success]

    # Capture path (no SMTP host): a real message written to a real temp dir.
    Dir.mktmpdir("tina4-msg-sendshape") do |dir|
      with_mail_env(host: :delete, capture: :delete, debug: :delete) do
        captured = Tina4.create_messenger(mailbox_dir: dir).send(to: "a@b.com", subject: "cap", body: "b")
        expect(captured.keys.sort).to eq(keys)
        expect(captured[:success]).to be(true)
        expect(captured[:id]).to be_a(String).and(be_truthy)
      end
    end

    # Delivery FAILURE path: a real refused SMTP port. Same keys; id present and nil.
    with_mail_env(host: :delete, capture: :delete, debug: :delete) do
      dead = find_closed_port
      fail_result = Tina4::Messenger.new(host: "127.0.0.1", port: dead, use_tls: false,
                                         username: "x@y.com", password: "p")
                                    .send(to: "a@b.com", subject: "fail", body: "b")
      expect(fail_result.keys.sort).to eq(keys)
      expect(fail_result[:success]).to be(false)
      expect(fail_result[:id]).to be_nil
    end

    # Delivery SUCCESS path over real GreenMail: id is a real Message-ID.
    if service_reachable?(greenmail_host, greenmail_smtp_port)
      with_mail_env(host: :delete, capture: :delete, debug: :delete) do
        ok = build_messenger(recipient).send(to: recipient,
                                             subject: "ok-#{SecureRandom.hex(4)}", body: "b")
        expect(ok.keys.sort).to eq(keys)
        expect(ok[:success]).to be(true)
        expect(ok[:id]).to match(/\A<.+@.+>\z/)
      end
    end
  end

  # ── 11. msg-every-method-exists-everywhere — pure reflection, no service ─────
  it "msg-every-method-exists-everywhere: inbox/read/unread/search/folders/send/send_template/mark_read/mark_unread/delete all exist under ONE name" do
    own = Tina4::Messenger.instance_methods(false)
    %i[inbox read unread search folders send send_template mark_read mark_unread delete].each do |name|
      expect(own).to include(name), "Tina4::Messenger does not define ##{name}"
    end
    # delete is the ONE spelling — no deleteMessage/delete_message twin.
    expect(own).not_to include(:delete_message, :deleteMessage)
  end

  # ── 12. msg-env-vars-are-honoured-everywhere ────────────────────────────────
  it "msg-env-vars-are-honoured-everywhere: TINA4_MAIL_IMAP_USERNAME/_PASSWORD are read and acted on (falling back to TINA4_MAIL_USERNAME/_PASSWORD)" do
    saved = ENV.to_h.slice("TINA4_MAIL_IMAP_USERNAME", "TINA4_MAIL_IMAP_PASSWORD",
                           "TINA4_MAIL_USERNAME", "TINA4_MAIL_PASSWORD")
    ENV["TINA4_MAIL_USERNAME"] = "smtp-user@tina4.test"
    ENV["TINA4_MAIL_PASSWORD"] = "smtp-pass"
    ENV.delete("TINA4_MAIL_IMAP_USERNAME")
    ENV.delete("TINA4_MAIL_IMAP_PASSWORD")

    # Fallback: with no dedicated IMAP creds the SMTP creds are used for IMAP.
    fallback = Tina4::Messenger.new
    expect(fallback.imap_username).to eq("smtp-user@tina4.test")
    expect(fallback.imap_password).to eq("smtp-pass")

    # Dedicated IMAP creds are read and WIN over the SMTP ones.
    ENV["TINA4_MAIL_IMAP_USERNAME"] = "imap-user@tina4.test"
    ENV["TINA4_MAIL_IMAP_PASSWORD"] = "imap-pass"
    dedicated = Tina4::Messenger.new
    expect(dedicated.imap_username).to eq("imap-user@tina4.test")
    expect(dedicated.imap_password).to eq("imap-pass")

    # ACTED ON, end to end over real GreenMail: a reader whose IMAP username names
    # a DIFFERENT fresh mailbox reads THAT (empty) mailbox, not the SMTP account's
    # — the exact failure the fixture measured (three frameworks read the SMTP
    # account). GreenMail-gated; the constructor reads above prove the READ locally.
    if service_reachable?(greenmail_host, greenmail_imap_port) &&
       service_reachable?(greenmail_host, greenmail_smtp_port)
      # Clear the IMAP env set above so the WRITER reads the mailbox it delivers
      # to (no imap_username arg -> falls back to its SMTP username = recipient).
      # Leaving the env set would (correctly!) point the writer's reads elsewhere.
      ENV.delete("TINA4_MAIL_IMAP_USERNAME")
      ENV.delete("TINA4_MAIL_IMAP_PASSWORD")
      writer = build_messenger(recipient)
      deliver_and_wait(writer, subject: "envread-#{SecureRandom.hex(4)}", body: "x")

      env_user = "rbc-env-#{SecureRandom.hex(8)}@tina4.test"
      ENV["TINA4_MAIL_IMAP_USERNAME"] = env_user
      ENV["TINA4_MAIL_IMAP_PASSWORD"] = "secret"
      reader = Tina4::Messenger.new(
        host: greenmail_host, port: greenmail_smtp_port, use_tls: false,
        imap_host: greenmail_host, imap_port: greenmail_imap_port, imap_encryption: "none",
        username: recipient, password: "secret"
      )
      expect(reader.imap_username).to eq(env_user)
      expect(reader.inbox).to eq([]) # env_user's brand-new mailbox is empty, not recipient's
    end
  ensure
    %w[TINA4_MAIL_IMAP_USERNAME TINA4_MAIL_IMAP_PASSWORD TINA4_MAIL_USERNAME TINA4_MAIL_PASSWORD].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # ── 13. msg-explicit-beats-env — constructor wins, no service needed ────────
  it "msg-explicit-beats-env: a constructor argument overrides the matching env var (imap_encryption included)" do
    saved = ENV.to_h.slice("TINA4_MAIL_HOST", "TINA4_MAIL_PORT", "TINA4_MAIL_USERNAME",
                           "TINA4_MAIL_ENCRYPTION", "TINA4_MAIL_IMAP_ENCRYPTION")
    ENV["TINA4_MAIL_HOST"] = "env-host"
    ENV["TINA4_MAIL_PORT"] = "2500"
    ENV["TINA4_MAIL_USERNAME"] = "env-user@tina4.test"
    ENV["TINA4_MAIL_ENCRYPTION"] = "tls"
    ENV["TINA4_MAIL_IMAP_ENCRYPTION"] = "tls"

    m = Tina4::Messenger.new(host: "arg-host", port: 2600, username: "arg-user@tina4.test",
                             encryption: "none", imap_encryption: "none")
    expect(m.host).to eq("arg-host")            # not "env-host"
    expect(m.port).to eq(2600)                  # not 2500
    expect(m.username).to eq("arg-user@tina4.test")
    expect(m.encryption).to eq("none")          # not "tls"
    # imap_encryption is env-only in Python/PHP; in Ruby it is settable AND wins.
    expect(m.imap_encryption).to eq("none")
    expect(m.imap_use_tls).to be(false)
  ensure
    %w[TINA4_MAIL_HOST TINA4_MAIL_PORT TINA4_MAIL_USERNAME TINA4_MAIL_ENCRYPTION TINA4_MAIL_IMAP_ENCRYPTION].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # ── 14. msg-capture-gate — availability decides; ONE type, a branch ─────────
  it "msg-capture-gate: capture iff no SMTP host (TINA4_MAIL_CAPTURE forces, TINA4_DEBUG never suppresses); one concrete type, interception a branch" do
    with_mail_env(host: :delete, capture: :delete, debug: :delete) do
      # No host -> capture; a host -> send.
      expect(Tina4::Messenger.new.should_capture?).to be(true)
      expect(Tina4::Messenger.new(host: "smtp.example.com").should_capture?).to be(false)

      # TINA4_DEBUG must NOT suppress a real send.
      ENV["TINA4_DEBUG"] = "true"
      expect(Tina4::Messenger.new(host: "smtp.example.com").should_capture?).to be(false)
      ENV.delete("TINA4_DEBUG")

      # TINA4_MAIL_CAPTURE forces capture even with a host configured.
      ENV["TINA4_MAIL_CAPTURE"] = "true"
      expect(Tina4::Messenger.new(host: "smtp.example.com").should_capture?).to be(true)
    end

    # ONE concrete type; capture is a BRANCH inside #send, not a swapped object —
    # and it writes a real message to a real temp dir.
    Dir.mktmpdir("tina4-msg-gate") do |dir|
      with_mail_env(host: :delete, capture: :delete, debug: :delete) do
        m = Tina4.create_messenger(mailbox_dir: dir)
        expect(m).to be_a(Tina4::Messenger)
        expect(m.method(:send).owner).to eq(Tina4::Messenger)
        expect(defined?(Tina4::DevMessengerProxy)).to be_nil
        result = m.send(to: "a@b.com", subject: "gate", body: "b")
        expect(result[:success]).to be(true)
        expect(m.dev_mailbox.inbox.length).to eq(1)
      end
    end
  end
end
