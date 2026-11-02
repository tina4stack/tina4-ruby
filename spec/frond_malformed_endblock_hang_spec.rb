# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Parity guard for tina4#271. A child template whose last {% endblock %} is
# malformed (its closing } missing) must not hang the render.
#
# Python's extract_blocks looped forever on this (its inner `while...else`
# skipped the `else` that advances past a malformed open tag on `break`).
# Ruby's extract_blocks is already safe -- it sets `pos = content_start unless
# matched` after the inner loop, advancing past the open tag so the outer loop
# makes progress -- but the contract must stay locked in all four frameworks,
# so this renders the exact malformed template under a timeout and asserts it
# returns. No mocks: real .twig files in a real temp dir through the real engine.

require_relative "spec_helper"
require_relative "../lib/tina4/frond"
require "tmpdir"
require "timeout"

RSpec.describe "Frond malformed {% endblock %} (tina4#271 parity)" do
  it "does not hang on a malformed endblock in a child template" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.twig"), "<html>{% block content %}default{% endblock %}</html>")
      # The final tag is missing its closing brace: `{% endblock %` not `%}`.
      File.write(File.join(dir, "page.twig"), "{% extends \"base.twig\" %}\n{% block content %}\n<p>hi</p>\n{% endblock %")
      engine = Tina4::Frond.new(template_dir: dir)
      result = Timeout.timeout(10) { engine.render("page.twig", {}) }
      expect(result).to be_a(String)
    end
  end

  it "still substitutes a well-formed child block (no regression)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.twig"), "<html>{% block content %}default{% endblock %}</html>")
      File.write(File.join(dir, "page.twig"), "{% extends \"base.twig\" %}\n{% block content %}<p>hi</p>{% endblock %}")
      result = Tina4::Frond.new(template_dir: dir).render("page.twig", {})
      expect(result).to include("<p>hi</p>")
      expect(result).not_to include("default")
    end
  end
end
