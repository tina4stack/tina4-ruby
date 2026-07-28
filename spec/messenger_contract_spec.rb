# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

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
