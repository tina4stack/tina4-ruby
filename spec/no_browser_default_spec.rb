# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "open3"
require "rbconfig"

# Guard: the test runner must start with TINA4_NO_BROWSER=true.
#
# spec/spec_helper.rb sets it before any spec runs, so every server a spec
# spawns inherits it and no browser tab opens on the machine running the
# suite. If that default is removed (or the runner is started with it switched
# off), this fails.
RSpec.describe "TINA4_NO_BROWSER test-run default" do
  it "is set to true for the whole run" do
    expect(ENV["TINA4_NO_BROWSER"]).to eq("true")
  end

  it "is inherited by a spawned child" do
    output, status = Open3.capture2(RbConfig.ruby, "-e", 'print ENV["TINA4_NO_BROWSER"]')
    expect(status.success?).to be(true)
    expect(output).to eq("true")
  end
end
