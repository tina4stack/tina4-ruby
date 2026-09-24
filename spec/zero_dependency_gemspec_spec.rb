# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"

# Zero-dependency guard (parity with Node's core-barrel guard, Python's import
# guard and PHP's composer-require guard). tina4ruby declares NO runtime gem:
# it serves HTTP itself (lib/tina4/http_server.rb) and speaks SMTP, IMAP and XML
# itself, and the gems an application may want - puma, sqlite3, a database
# driver - are the application's to declare (ADR-0067). A feature that adds a
# third-party gem would install for every app, so it must use the stdlib or
# lazy-load instead.
RSpec.describe "zero-dependency gemspec" do
  # Gems Ruby itself provides, or that Tina4 replaced with its own code, or that
  # belong to the application. None may come back as a runtime dependency:
  #   rack, rackup, webrick  replaced by Tina4::HttpServer + Tina4::FormParser
  #   puma            opt-in: an app that wants it lists it in its own Gemfile
  #   json            default gem on every supported Ruby
  #   base64          replaced by Tina4::Base64 (core Array#pack)
  #   logger          never required: Tina4::Log writes its own files
  #   sqlite3         an APP dependency (ADR-0067): the scaffold Gemfile declares it
  #   net-smtp        replaced by Tina4::Messenger::SmtpClient (socket + openssl)
  #   net-imap        replaced by Tina4::Messenger::ImapClient (socket + openssl)
  #   rexml           replaced by Tina4::WSDL::XmlParser (UTF-8 only, no DTDs)
  #   net-protocol, timeout, date   only ever arrived through net-smtp / net-imap
  let(:replaced) do
    %w[rack rackup webrick puma json base64 logger sqlite3 net-smtp net-imap rexml net-protocol timeout date]
  end

  let(:runtime_names) do
    Gem::Specification.load(File.expand_path("../tina4ruby.gemspec", __dir__)).runtime_dependencies.map(&:name)
  end

  it "declares no runtime gem at all" do
    expect(runtime_names).to eq([]),
                             "tina4ruby.gemspec declares runtime gems: #{runtime_names.join(', ')} -- " \
                             "an optional feature must use the stdlib or lazy-load, never add a hard runtime gem"
  end

  it "declares none of the gems Ruby ships, Tina4 replaced, or the app owns" do
    back = runtime_names & replaced
    expect(back).to eq([]),
                    "tina4ruby.gemspec declares #{back.join(', ')} again -- " \
                    "these are stdlib, replaced by Tina4 code, or the application's (see the spec comment)"
  end
end
