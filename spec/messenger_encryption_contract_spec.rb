# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"

RSpec.describe "Messenger encryption configuration (ADR-0071)" do
  around do |example|
    keys = %w[TINA4_MAIL_ENCRYPTION TINA4_MAIL_IMAP_ENCRYPTION]
    previous = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  { encryption: ["mail", "TINA4_MAIL_ENCRYPTION"],
    imap_encryption: ["IMAP", "TINA4_MAIL_IMAP_ENCRYPTION"] }.each do |option, (label, env_key)|
    ["tsl", "ssl3", "yes", "", "   "].each do |value|
      it "refuses unknown #{option} #{value.inspect} before transport construction" do
        expect { Tina4::Messenger.new(**{ option => value }) }.to raise_error(
          ArgumentError, "Unknown #{label} encryption '#{value}'. Valid values: ssl, tls, starttls, none."
        )
      end
    end

    it "refuses invalid #{env_key} and lets an explicit valid option override it" do
      ENV[env_key] = "typo"
      expect { Tina4::Messenger.new }.to raise_error(ArgumentError, /Unknown #{label} encryption/)
      expect(Tina4::Messenger.new(**{ option => "none" }).public_send(option)).to eq("none")
    end

    it "normalizes valid #{option} case and whitespace" do
      %w[ssl tls starttls none].each do |value|
        expect(Tina4::Messenger.new(**{ option => " #{value.upcase} " }).public_send(option)).to eq(value)
      end
    end
  end

  it "retains safe defaults and the explicit legacy use_tls option" do
    defaults = Tina4::Messenger.new
    expect([defaults.encryption, defaults.imap_encryption]).to eq(%w[tls tls])
    expect(Tina4::Messenger.new(use_tls: false).encryption).to eq("none")
    expect(Tina4::Messenger.new(use_tls: true).encryption).to eq("tls")
  end
end
