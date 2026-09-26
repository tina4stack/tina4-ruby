# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Mutation-proof for the CLAUDE.md doc-drift gate (scripts/audit_doc_drift.rb).
# The gate reads every ```ruby fence in CLAUDE.md and asserts each Tina4 symbol
# it names EXISTS in the live framework by reflection. This spec proves the gate
# is a GATE, not a ghost: it goes RED when a documented symbol is broken and
# GREEN on the real doc. NO mocks -- it asks the REAL loaded Tina4 runtime.

require "spec_helper"
require "tmpdir"
require_relative "../scripts/audit_doc_drift"

RSpec.describe "CLAUDE.md doc-drift gate" do
  def write_doc(root, body)
    File.write(File.join(root, "CLAUDE.md"), body, encoding: "UTF-8")
  end

  describe "the real repository" do
    it "is clean — every documented Tina4 API resolves against the live code" do
      expect(DocDriftAudit.check(DocDriftAudit::REPO_ROOT)).to eq([])
    end

    it "actually inspects the real CLAUDE.md (mutating a real documented method turns it RED)" do
      real = DocDriftAudit.read_utf8(File.join(DocDriftAudit::REPO_ROOT, "CLAUDE.md"))
      # `Tina4::Auth.get_token` is a real, documented method; rename the call and
      # the gate must catch the now-nonexistent method against the real doc.
      expect(real).to include("Tina4::Auth.get_token")
      mutated = real.sub("Tina4::Auth.get_token", "Tina4::Auth.get_tokenX")

      Dir.mktmpdir do |dir|
        write_doc(dir, mutated)
        problems = DocDriftAudit.check(dir)
        expect(problems).to include(a_string_matching(/Tina4::Auth.*get_tokenX/))
      end
    end
  end

  describe "mutation: it goes RED on injected drift" do
    it "flags a Tina4 constant that does not exist" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\nTina4::NoSuchClass.new\n```\n")
        expect(DocDriftAudit.check(dir))
          .to include(a_string_matching(/Tina4::NoSuchClass.*not a defined Tina4 constant/))
      end
    end

    it "flags a nonexistent method on a real Tina4 class" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\nTina4::Auth.summon_everything(payload)\n```\n")
        expect(DocDriftAudit.check(dir))
          .to include(a_string_matching(/Tina4::Auth.*no method `summon_everything`/))
      end
    end

    it "flags a nonexistent method on a var bound to a real Tina4 class" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\ndb = Tina4::Database.new(\"sqlite:///app.db\")\ndb.summon_everything\n```\n")
        expect(DocDriftAudit.check(dir))
          .to include(a_string_matching(/db\.summon_everything.*Tina4::Database.*no method/))
      end
    end

    it "flags a nonexistent method on the top-level Tina4 module" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\nTina4.summon_everything(\"/x\")\n```\n")
        expect(DocDriftAudit.check(dir))
          .to include(a_string_matching(/Tina4.summon_everything.*no method/))
      end
    end
  end

  describe "it stays GREEN on real API" do
    it "accepts a real singleton method" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\nTina4::Auth.get_token(payload, expires_in: 60)\n```\n")
        expect(DocDriftAudit.check(dir)).to eq([])
      end
    end

    it "accepts a real instance method on a bound var" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\ndb = Tina4::Database.new(\"sqlite:///app.db\")\ndb.fetch(\"SELECT 1\")\n```\n")
        expect(DocDriftAudit.check(dir)).to eq([])
      end
    end

    it "does not read a receiver out of a dotted string literal (no false positive)" do
      Dir.mktmpdir do |dir|
        write_doc(dir, "```ruby\napi = Tina4::API.new(\"https://api.example.com\")\napi.get(\"/x\")\n```\n")
        expect(DocDriftAudit.check(dir)).to eq([])
      end
    end
  end
end
