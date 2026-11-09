# frozen_string_literal: true

# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "spec_helper"
require "tmpdir"

# Regressions for two TestClient DX footguns (#296, #300).
#
# No mocks/doubles: a real .env file on disk, the real Tina4::Env loader the
# server uses, and a real TestResponse built from a real Rack response tuple.
#
# Mirrors: tina4-python tests/test_test_client_env_and_headers.py,
#          tina4-php tests/TestClientEnvAndHeadersTest.php,
#          tina4-nodejs test/testClientEnvAndHeaders.test.ts
RSpec.describe "TestClient env + case-insensitive headers" do
  around do |example|
    original = ENV.fetch("TINA4_SECRET", :unset)
    example.run
  ensure
    if original == :unset
      ENV.delete("TINA4_SECRET")
    else
      ENV["TINA4_SECRET"] = original
    end
  end

  # ───────────────────────── #296 — TestClient loads .env ─────────────────────

  it "loads .env from the project root without booting the app (#296)" do
    secret = "a" * 64
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "TINA4_SECRET=#{secret}\n")
      ENV.delete("TINA4_SECRET")

      expect(ENV["TINA4_SECRET"]).to be_nil # precondition

      Tina4::TestClient.new(root_dir: dir) # construction loads .env

      expect(ENV["TINA4_SECRET"]).to eq(secret)
    end
  end

  it "does not clobber a real env var set before the client (#296 first-wins)" do
    real = "r" * 64
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env"), "TINA4_SECRET=#{'d' * 64}\n") # a DIFFERENT value
      ENV["TINA4_SECRET"] = real

      Tina4::TestClient.new(root_dir: dir)

      expect(ENV["TINA4_SECRET"]).to eq(real)
    end
  end

  # ─────────────────── #300 — case-insensitive response headers ───────────────

  it "looks a header up case-insensitively (#300)" do
    r = Tina4::TestResponse.new([303, { "Location" => "/complaints" }, [""]])

    expect(r.headers["Location"]).to eq("/complaints")       # canonical case
    expect(r.headers["location"]).to eq("/complaints")       # lower case
    expect(r.headers.key?("Location")).to be(true)
    expect(r.headers.fetch("Location")).to eq("/complaints")
    expect(r.get_all("Location")).to eq(["/complaints"])
  end

  it "treats a header never sent as a miss, not a false hit (#300)" do
    r = Tina4::TestResponse.new([200, { "Content-Type" => "text/html" }, [""]])

    expect(r.headers["X-Absent"]).to be_nil
    expect(r.headers.key?("X-Absent")).to be(false)
    expect(r.get_all("X-Absent")).to eq([])
    expect(r.headers).to be_a(Hash) # still a Hash — readers are unaffected
  end
end
