# frozen_string_literal: true

require "spec_helper"
require "tina4"
require "fileutils"

# Feature 18 (paginated results) - the five invariants of
# tina4-documentation/plan/v3/fixtures/pagination_contract.json (ADR-0043).
#
# to_paginate() takes NO arguments and derives every field from the query that
# ran; total is the TRUE total for the filter (a COUNT(*) probe run by
# Database#fetch, never the number of rows returned); records are the rows the
# query returned, verbatim; and the envelope is EXACTLY seven snake_case keys.
#
# Real SQLite, a real 250-row table. No mocks, no doubles.
RSpec.describe "Feature 18: paginated results contract (ADR-0043)" do
  # The canonical seven keys, in the order ADR-0043 lists them. A local variable,
  # NOT a constant - a bare constant inside RSpec.describe leaks onto Object.
  seven_keys = %i[records total page per_page total_pages limit offset]

  let(:db_dir) { Dir.mktmpdir("tina4_pagination_contract") }
  let(:db_path) { File.join(db_dir, "pagination.db") }

  let(:db) do
    database = Tina4::Database.new("sqlite:///#{db_path}")
    database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
    (1..250).each do |i|
      database.execute("INSERT INTO items (id, name) VALUES (?, ?)", [i, "item-#{i}"])
    end
    database
  end

  # Page 3 of 13: limit 20, offset 40 - the query the audit measured.
  def page_three
    db.fetch("SELECT * FROM items ORDER BY id", [], limit: 20, offset: 40)
  end

  after do
    db.close
    FileUtils.remove_entry(db_dir, true)
  end

  it "paginate-takes-no-arguments: passing any argument raises ArgumentError" do
    # A FULL result (all 250 rows, records.size == count) so the raise is not
    # masked by the old partial-result guard: on the old two-mode method a full
    # result SLICED silently rather than raising, so this example is genuinely
    # red until to_paginate rejects every argument form.
    full = db.fetch("SELECT * FROM items ORDER BY id", [], limit: 0)
    expect(full.records.size).to eq(250)
    expect(full.count).to eq(250)

    expect { full.to_paginate(page: 2) }.to raise_error(ArgumentError)
    expect { full.to_paginate(page: 2, per_page: 10) }.to raise_error(ArgumentError)
    expect { full.to_paginate(2) }.to raise_error(ArgumentError)

    # ...and the no-argument call still describes the page it holds.
    expect(full.to_paginate[:total]).to eq(250)
  end

  it "paginate-page-is-derived-from-the-offset: limit 20 offset 40 reports page 3" do
    envelope = page_three.to_paginate
    expect(envelope[:page]).to eq(3)        # floor(40 / 20) + 1
    expect(envelope[:per_page]).to eq(20)
    expect(envelope[:limit]).to eq(20)
    expect(envelope[:offset]).to eq(40)
  end

  it "paginate-total-is-the-true-total: a 20-row page of 250 reports total 250" do
    result = page_three
    envelope = result.to_paginate
    # The read-path COUNT probe: .count is the true total for the filter, not the
    # 20 rows this page returned.
    expect(result.count).to eq(250)
    expect(envelope[:total]).to eq(250)
    expect(envelope[:total_pages]).to eq(13) # ceil(250 / 20)
  end

  it "paginate-records-are-the-rows-the-query-returned: all 20 fetched rows, verbatim" do
    envelope = page_three.to_paginate
    expect(envelope[:records].size).to eq(20)
    ids = envelope[:records].map { |row| row[:id] }
    expect(ids).to eq((41..60).to_a)         # page 3's rows, none re-sliced away
  end

  it "paginate-key-set-is-identical-in-all-four: exactly the seven snake_case keys" do
    envelope = page_three.to_paginate
    expect(envelope.keys).to match_array(seven_keys)
    # No duplicate spellings, no camelCase aliases, no removed extras.
    %i[data count totalPages has_next has_prev].each do |removed|
      expect(envelope).not_to have_key(removed)
    end
    expect(envelope).not_to have_key("data")
  end
end
