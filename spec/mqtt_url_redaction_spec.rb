# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require_relative "spec_helper"

RSpec.describe "MQTT URL failure redaction" do
  ["http://user:synthetic-secret@localhost", "mqtt://user:synthetic-secret@localhost:bad"].each do |url|
    it "redacts credentials from #{url.split('://').first} URL rejection" do
      expect { Tina4::Mqtt.parse_url(url) }.to raise_error(ArgumentError) { |error|
        expect(error.message).not_to include("synthetic-secret")
        expect(error.message).to include(":***@localhost")
      }
    end
  end
end
