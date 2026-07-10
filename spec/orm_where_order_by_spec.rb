# frozen_string_literal: true
#
# Lock-in tests for Model.where(order_by:, limit:, offset:) — v3.13.66 ORM
# where-ordering parity.
#
# where() was the only filtered finder that could not order its results, and
# (Ruby-specific) the only one without limit:/offset: — find / all /
# QueryBuilder all had ordering, and the other three frameworks' where() had
# pagination. These specs pin the new behaviour:
#   * order_by sorts the filtered result (ASC and DESC)
#   * omitting order_by injects NO ORDER BY (rows come back in natural order)
#   * limit: / offset: slice the filtered result (owner-approved fold-in)
#
# Mirrors tina4-python/tests/test_orm_where_order_by.py (the Python master).
# Real SQLite, no mocks, positive + negative. Rows are inserted OUT OF
# alphabetical order so a missing/extra ORDER BY is observable in the output.

require "spec_helper"

class WhereOrderPerson < Tina4::ORM
  table_name "wpeople"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name
end

RSpec.describe "ORM where(order_by:/limit:/offset:) (v3.13.66)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_where_order") }
  let(:db_path) { File.join(tmp_dir, "where_order.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute("CREATE TABLE wpeople (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
    # Inserted OUT OF alphabetical order:
    # Charlie(1), Alice(2), Bob(3), Dave(4), Eve(5)
    ["Charlie", "Alice", "Bob", "Dave", "Eve"].each { |n| WhereOrderPerson.new(name: n).save }
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  it "orders results with order_by ASC" do
    rows = WhereOrderPerson.where("1=1", order_by: "name ASC")
    expect(rows.map(&:name)).to eq(%w[Alice Bob Charlie Dave Eve])
  end

  it "reverses results with order_by id DESC" do
    # id DESC -> 5,4,3,2,1 -> Eve, Dave, Bob, Alice, Charlie
    rows = WhereOrderPerson.where("1=1", order_by: "id DESC")
    expect(rows.map(&:name)).to eq(%w[Eve Dave Bob Alice Charlie])
  end

  it "injects no ORDER BY without order_by (natural order)" do
    # negative: no order_by -> no ORDER BY -> natural (insertion) order
    rows = WhereOrderPerson.where("1=1")
    expect(rows.map(&:name)).to eq(%w[Charlie Alice Bob Dave Eve])
  end

  it "slices the result with limit: and offset:" do
    # natural order Charlie,Alice,Bob,Dave,Eve; offset 1 limit 2 -> Alice, Bob
    rows = WhereOrderPerson.where("1=1", limit: 2, offset: 1)
    expect(rows.map(&:name)).to eq(%w[Alice Bob])
  end
end
