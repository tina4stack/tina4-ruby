# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "tina4/frond"
require "timeout"

RSpec.describe "Frond tokenizer bounds" do
  let(:frond) { Tina4::Frond.new }

  it "preserves raw text and resumes normal escaping" do
    expect(frond.render_string("{% raw %}{{ value }}{% endraw %}{{ value }}", { "value" => "<b>" })).to eq("{{ value }}&lt;b&gt;")
  end

  it "tokenizes repeated incomplete delimiters in bounded time" do
    ["{{ ", "{% ", "{# ", "{% raw %}"].each do |prefix|
      source = prefix * 30_000
      Timeout.timeout(2) { expect(frond.send(:tokenize, source)).not_to be_empty }
    end
  end

  it "extracts a raw block after an incomplete block opener" do
    expect(frond.send(:tokenize, "{% incomplete {% raw %}{{ value }}{% endraw %}")).to eq([[Tina4::Frond::TEXT, "{% incomplete {{ value }}"]])
  end

  it "still finds other complete tag kinds after an incomplete opener" do
    expect(frond.send(:tokenize, "{{ unfinished {# comment #}")).to eq([
      [Tina4::Frond::TEXT, "{{ unfinished "], [Tina4::Frond::COMMENT, "{# comment #}"]
    ])
  end
end
