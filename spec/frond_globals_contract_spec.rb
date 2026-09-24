# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require_relative "../lib/tina4/frond"

# Frond globals contract — ADR-0085.
#
# A bare zero-argument callable global is invoked and its RETURN VALUE is used
# for both `{{ g }}` output and `{% if g %}` conditions. Explicit `g()` still
# works and never double-calls. A non-callable global is unchanged, a global
# that returns a callable is called once (not twice), and an unregistered
# `nope()` is falsy rather than an error.
#
# Node is the reference implementation; these cases mirror
# tina4-nodejs/test/frondGlobalsContract.test.ts against the shared fixture
# tina4-documentation/plan/v3/fixtures/frond_globals_contract.json.
#
# No mocks: the procs are real and Frond renders real template source.
RSpec.describe Tina4::Frond do
  before(:each) { Tina4::Frond.clear_registry }
  after(:all)   { Tina4::Frond.clear_registry }

  it "zero arg global closure returning false is falsy in if" do
    frond = Tina4::Frond.new
    frond.add_global("admin_only", -> { false })
    expect(frond.render_string("{% if admin_only %}Y{% else %}N{% endif %}")).to eq("N")
  end

  it "zero arg global closure returning true is truthy in if" do
    frond = Tina4::Frond.new
    frond.add_global("admin_only", -> { true })
    expect(frond.render_string("{% if admin_only %}Y{% else %}N{% endif %}")).to eq("Y")
  end

  it "zero arg global closure prints its return value" do
    frond = Tina4::Frond.new
    frond.add_global("greeting", -> { "hello" })
    expect(frond.render_string("{{ greeting }}")).to eq("hello")
  end

  it "explicit call syntax still works" do
    frond = Tina4::Frond.new
    frond.add_global("admin_only", -> { false })
    expect(frond.render_string("{% if admin_only() %}Y{% else %}N{% endif %}")).to eq("N")
  end

  it "non callable global is unchanged" do
    frond = Tina4::Frond.new
    frond.add_global("site_name", "Tina4")
    expect(frond.render_string("{{ site_name }}")).to eq("Tina4")
  end

  it "global returning a callable is not double called" do
    frond = Tina4::Frond.new
    outer_calls = 0
    inner_calls = 0
    frond.add_global("outer", lambda {
      outer_calls += 1
      -> { inner_calls += 1; "inner" }
    })
    # A bare reference calls the global ONCE and yields the inner proc; the
    # inner proc must NOT be invoked (no double-call).
    frond.render_string("{% if outer %}Y{% endif %}")
    expect(outer_calls).to eq(1)
    expect(inner_calls).to eq(0)
  end

  it "unregistered function call is falsy" do
    frond = Tina4::Frond.new
    expect(frond.render_string("{% if nope() %}Y{% else %}N{% endif %}")).to eq("N")
    expect(frond.render_string("{{ nope() }}")).to eq("")
  end
end
