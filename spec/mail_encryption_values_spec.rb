# frozen_string_literal: true

require "spec_helper"

# ADR-0071 section 2: an unknown mail encryption value is refused at construction.
#
# MEASURED on the lab before this change (tina4-ruby#49 code, real GreenMail on
# the plaintext port 4025): encryption "tsl" and "" both DELIVERED the message
# and the AUTH credentials in clear, and " SSL " (not trimmed) did too. A typo
# must never downgrade to cleartext, so the value is trimmed and lower-cased,
# and anything outside ssl / tls / starttls / none raises ArgumentError naming
# the value exactly as it was given.
#
# Pure construction checks: nothing connects, so no service is involved.
RSpec.describe "Mail encryption values (ADR-0071 section 2)" do
  def smtp_message(value)
    "Unknown mail encryption '#{value}'. Valid values: ssl, tls, starttls, none."
  end

  def imap_message(value)
    "Unknown IMAP encryption '#{value}'. Valid values: ssl, tls, starttls, none."
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  around do |example|
    with_env("TINA4_MAIL_ENCRYPTION" => nil, "TINA4_MAIL_IMAP_ENCRYPTION" => nil) { example.run }
  end

  ["tsl", "ssl3", "yes", "", "   ", "starttls1"].each do |value|
    it "SMTP encryption #{value.inspect} raises at construction, naming the value as given" do
      expect { Tina4::Messenger.new(encryption: value) }
        .to raise_error(ArgumentError, smtp_message(value))
    end

    it "IMAP encryption #{value.inspect} raises at construction, naming the value as given" do
      expect { Tina4::Messenger.new(imap_encryption: value) }
        .to raise_error(ArgumentError, imap_message(value))
    end
  end

  it "an unknown TINA4_MAIL_ENCRYPTION / TINA4_MAIL_IMAP_ENCRYPTION raises the same way" do
    with_env("TINA4_MAIL_ENCRYPTION" => "Tsl ") do
      expect { Tina4::Messenger.new }.to raise_error(ArgumentError, smtp_message("Tsl "))
    end
    with_env("TINA4_MAIL_IMAP_ENCRYPTION" => "imaps") do
      expect { Tina4::Messenger.new }.to raise_error(ArgumentError, imap_message("imaps"))
    end
  end

  # Positive: every valid spelling is accepted, trimmed and lower-cased.
  {
    " SSL " => "ssl", "TLS" => "tls", "StartTLS" => "starttls", " none" => "none"
  }.each do |given, normalised|
    it "accepts #{given.inspect} as #{normalised.inspect} for SMTP and IMAP" do
      messenger = Tina4::Messenger.new(encryption: given, imap_encryption: given)
      expect(messenger.encryption).to eq(normalised)
      expect(messenger.imap_encryption).to eq(normalised)
    end
  end

  it "keeps the defaults and the use_tls compatibility switch" do
    expect(Tina4::Messenger.new.encryption).to eq("tls")
    expect(Tina4::Messenger.new.imap_encryption).to eq("tls")
    expect(Tina4::Messenger.new(use_tls: false).encryption).to eq("none")
    expect(Tina4::Messenger.new(use_tls: true).encryption).to eq("tls")
  end
end
