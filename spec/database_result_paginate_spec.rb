# frozen_string_literal: true

require "spec_helper"
require "tina4"

# to_paginate with NO arguments describes the page the query returned.
#
# REGRESSION, measured 2026-08-05 across all four frameworks on a real 250-row
# table read with limit=20 offset=40 (page 3 of 13). Ruby returned ZERO rows:
# it re-sliced by the ABSOLUTE offset (40) against an array that was already
# just that page and only 20 long, so the slice fell off the end. The envelope
# still reported a page number and a total, so it read as a real answer.
RSpec.describe "DatabaseResult#to_paginate describes the fetched page" do
  def result
    rows = (40...60).map { |i| { "id" => i } }   # the rows page 3 holds
    Tina4::DatabaseResult.new(rows, count: 250, limit: 20, offset: 40)
  end

  it "derives the page from the offset" do
    pag = result.to_paginate
    expect(pag[:page]).to eq(3)
    expect(pag[:per_page]).to eq(20)
  end

  it "returns the rows the query returned, never re-sliced" do
    pag = result.to_paginate
    expect(pag[:records].size).to eq(20)
    expect(pag[:records].first["id"]).to eq(40)
  end

  it "refuses to slice a result that is already one page" do
    expect { result.to_paginate(page: 2, per_page: 10) }.to raise_error(ArgumentError)
  end
end
