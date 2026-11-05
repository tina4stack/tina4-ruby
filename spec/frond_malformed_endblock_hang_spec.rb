# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Parity guard for tina4#271 + tina4#286/#290. A child template whose
# {% block %} is never closed -- or whose last {% endblock %} is cut short to
# `{% endblock %` (its closing `}` missing, so the tokenizer never produces the
# tag) -- must FAIL LOUD (tina4#286/#290), and must stay bounded so a
# reintroduced hang trips the timeout rather than locking the render (tina4#271).
# No mocks: real .twig files in a real temp dir through the real engine.

require_relative "spec_helper"
require_relative "../lib/tina4/frond"
require "tmpdir"
require "timeout"

RSpec.describe "Frond malformed {% endblock %} (tina4#271/#286/#290 parity)" do
  it "fails loud on a cut-short endblock in a child template, without hanging" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.twig"), "<html>{% block content %}default{% endblock %}</html>")
      # The final tag is missing its closing brace: `{% endblock %` not `%}`.
      File.write(File.join(dir, "page.twig"), "{% extends \"base.twig\" %}\n{% block content %}\n<p>hi</p>\n{% endblock %")
      engine = Tina4::Frond.new(template_dir: dir)
      expect do
        Timeout.timeout(10) { engine.render("page.twig", {}) }
      end.to raise_error(Tina4::FrondSyntaxError, /content/)
    end
  end

  it "fails loud on an unclosed block in a child template" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "base.twig"), "<html>{% block content %}default{% endblock %}</html>")
      File.write(File.join(dir, "page.twig"), "{% extends \"base.twig\" %}\n{% block content %}\n<p>hi</p>\n")
      engine = Tina4::Frond.new(template_dir: dir)
      expect do
        Timeout.timeout(10) { engine.render("page.twig", {}) }
      end.to raise_error(Tina4::FrondSyntaxError)
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
