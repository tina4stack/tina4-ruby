# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Tina4::QueryBuilder do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "query_builder_test.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:all) do
    @tmpdir_shared = Dir.mktmpdir
    db_path_shared = File.join(@tmpdir_shared, "qb_shared.db")
    @db_shared = Tina4::Database.new("sqlite:///" + db_path_shared)

    @db_shared.execute(<<~SQL)
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL,
        age INTEGER NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
      )
    SQL

    @db_shared.execute(<<~SQL)
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
      )
    SQL

    # Insert 5 user rows
    [
      { name: "Alice",   email: "alice@example.com",   age: 30, active: 1 },
      { name: "Bob",     email: "bob@example.com",     age: 25, active: 1 },
      { name: "Charlie", email: "charlie@example.com", age: 35, active: 0 },
      { name: "Diana",   email: "diana@example.com",   age: 28, active: 1 },
      { name: "Eve",     email: "eve@example.com",     age: 22, active: 1 }
    ].each do |user|
      @db_shared.insert("users", user)
    end

    # Insert some orders
    [
      { user_id: 1, amount: 100.0, status: "completed" },
      { user_id: 1, amount: 50.0,  status: "pending" },
      { user_id: 2, amount: 200.0, status: "completed" },
      { user_id: 3, amount: 75.0,  status: "completed" },
      { user_id: 4, amount: 150.0, status: "pending" }
    ].each do |order|
      @db_shared.insert("orders", order)
    end
  end

  after(:all) do
    @db_shared&.close rescue nil
    FileUtils.rm_rf(@tmpdir_shared) if @tmpdir_shared
  end

  after do
    db.close rescue nil
    FileUtils.rm_rf(tmpdir)
  end

  # ---------------------------------------------------------------------------
  # 1. .from() creates a QueryBuilder
  # ---------------------------------------------------------------------------
  describe ".from_table" do
    it "returns a QueryBuilder instance" do
      qb = Tina4::QueryBuilder.from_table("users", db: @db_shared)
      expect(qb).to be_a(Tina4::QueryBuilder)
    end

    it "accepts a table name" do
      qb = Tina4::QueryBuilder.from_table("users", db: @db_shared)
      expect(qb.to_sql).to include("FROM users")
    end
  end

  # ---------------------------------------------------------------------------
  # 2. .select() sets columns
  # ---------------------------------------------------------------------------
  describe "#select" do
    it "defaults to * when no columns specified" do
      sql = Tina4::QueryBuilder.from_table("users").to_sql
      expect(sql).to eq("SELECT * FROM users")
    end

    it "sets specific columns" do
      sql = Tina4::QueryBuilder.from_table("users").select("id", "name").to_sql
      expect(sql).to eq("SELECT id, name FROM users")
    end

    it "keeps * when called with no arguments" do
      sql = Tina4::QueryBuilder.from_table("users").select.to_sql
      expect(sql).to eq("SELECT * FROM users")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. .where() adds AND conditions
  # ---------------------------------------------------------------------------
  describe "#where" do
    it "adds a single WHERE condition" do
      sql = Tina4::QueryBuilder.from_table("users").where("active = ?", [1]).to_sql
      expect(sql).to eq("SELECT * FROM users WHERE active = ?")
    end

    it "chains multiple WHERE conditions with AND" do
      sql = Tina4::QueryBuilder.from_table("users")
              .where("active = ?", [1])
              .where("age > ?", [18])
              .to_sql
      expect(sql).to eq("SELECT * FROM users WHERE active = ? AND age > ?")
    end
  end

  # ---------------------------------------------------------------------------
  # 4. .or_where() adds OR conditions
  # ---------------------------------------------------------------------------
  describe "#or_where" do
    it "adds an OR condition after a WHERE" do
      sql = Tina4::QueryBuilder.from_table("users")
              .where("active = ?", [1])
              .or_where("age < ?", [25])
              .to_sql
      expect(sql).to eq("SELECT * FROM users WHERE active = ? OR age < ?")
    end

    it "uses OR as the first condition connector (first connector ignored)" do
      sql = Tina4::QueryBuilder.from_table("users")
              .or_where("name = ?", ["Alice"])
              .to_sql
      # First condition drops the connector
      expect(sql).to eq("SELECT * FROM users WHERE name = ?")
    end
  end

  # ---------------------------------------------------------------------------
  # 5. .join() adds INNER JOIN
  # ---------------------------------------------------------------------------
  describe "#join" do
    it "adds an INNER JOIN clause" do
      sql = Tina4::QueryBuilder.from_table("users")
              .join("orders", "orders.user_id = users.id")
              .to_sql
      expect(sql).to include("INNER JOIN orders ON orders.user_id = users.id")
    end
  end

  # ---------------------------------------------------------------------------
  # 6. .left_join() adds LEFT JOIN
  # ---------------------------------------------------------------------------
  describe "#left_join" do
    it "adds a LEFT JOIN clause" do
      sql = Tina4::QueryBuilder.from_table("users")
              .left_join("orders", "orders.user_id = users.id")
              .to_sql
      expect(sql).to include("LEFT JOIN orders ON orders.user_id = users.id")
    end
  end

  # ---------------------------------------------------------------------------
  # 7. .group_by() adds GROUP BY
  # ---------------------------------------------------------------------------
  describe "#group_by" do
    it "adds a GROUP BY clause" do
      sql = Tina4::QueryBuilder.from_table("orders")
              .select("user_id", "COUNT(*) as order_count")
              .group_by("user_id")
              .to_sql
      expect(sql).to include("GROUP BY user_id")
    end

    it "supports multiple group_by calls" do
      sql = Tina4::QueryBuilder.from_table("orders")
              .group_by("user_id")
              .group_by("status")
              .to_sql
      expect(sql).to include("GROUP BY user_id, status")
    end
  end

  # ---------------------------------------------------------------------------
  # 8. .having() adds HAVING
  # ---------------------------------------------------------------------------
  describe "#having" do
    it "adds a HAVING clause" do
      sql = Tina4::QueryBuilder.from_table("orders")
              .select("user_id", "SUM(amount) as total")
              .group_by("user_id")
              .having("SUM(amount) > ?", [100])
              .to_sql
      expect(sql).to include("HAVING SUM(amount) > ?")
    end

    it "chains multiple HAVING clauses with AND" do
      sql = Tina4::QueryBuilder.from_table("orders")
              .select("user_id", "SUM(amount) as total", "COUNT(*) as cnt")
              .group_by("user_id")
              .having("SUM(amount) > ?", [50])
              .having("COUNT(*) > ?", [1])
              .to_sql
      expect(sql).to include("HAVING SUM(amount) > ? AND COUNT(*) > ?")
    end
  end

  # ---------------------------------------------------------------------------
  # 9. .order_by() adds ORDER BY
  # ---------------------------------------------------------------------------
  describe "#order_by" do
    it "adds an ORDER BY clause" do
      sql = Tina4::QueryBuilder.from_table("users").order_by("name ASC").to_sql
      expect(sql).to include("ORDER BY name ASC")
    end

    it "supports multiple order_by calls" do
      sql = Tina4::QueryBuilder.from_table("users")
              .order_by("age DESC")
              .order_by("name ASC")
              .to_sql
      expect(sql).to include("ORDER BY age DESC, name ASC")
    end
  end

  # ---------------------------------------------------------------------------
  # 10. .limit() sets LIMIT and OFFSET
  # ---------------------------------------------------------------------------
  describe "#limit" do
    it "stores the limit value (used by get, not in to_sql)" do
      qb = Tina4::QueryBuilder.from_table("users", db: @db_shared).limit(2)
      result = qb.get
      expect(result.records.length).to be <= 2
    end

    it "stores the offset value" do
      qb = Tina4::QueryBuilder.from_table("users", db: @db_shared)
             .order_by("id ASC")
             .limit(2, 1)
      result = qb.get
      # Offset 1 should skip the first user
      first_record = result.records.first
      first_id = first_record["id"] || first_record[:id]
      expect(first_id.to_i).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # 11. .to_sql() generates correct SQL
  # ---------------------------------------------------------------------------
  describe "#to_sql" do
    it "generates a basic SELECT" do
      sql = Tina4::QueryBuilder.from_table("users").to_sql
      expect(sql).to eq("SELECT * FROM users")
    end

    it "generates SQL with all clauses combined" do
      sql = Tina4::QueryBuilder.from_table("users")
              .select("users.id", "users.name")
              .join("orders", "orders.user_id = users.id")
              .where("users.active = ?", [1])
              .group_by("users.id")
              .having("COUNT(orders.id) > ?", [0])
              .order_by("users.name ASC")
              .to_sql

      expect(sql).to start_with("SELECT users.id, users.name FROM users")
      expect(sql).to include("INNER JOIN orders ON orders.user_id = users.id")
      expect(sql).to include("WHERE users.active = ?")
      expect(sql).to include("GROUP BY users.id")
      expect(sql).to include("HAVING COUNT(orders.id) > ?")
      expect(sql).to include("ORDER BY users.name ASC")
    end

    it "preserves clause ordering (JOIN, WHERE, GROUP BY, HAVING, ORDER BY)" do
      sql = Tina4::QueryBuilder.from_table("users")
              .join("orders", "orders.user_id = users.id")
              .where("active = ?", [1])
              .group_by("users.id")
              .having("COUNT(*) > ?", [1])
              .order_by("users.id")
              .to_sql

      join_pos    = sql.index("INNER JOIN")
      where_pos   = sql.index("WHERE")
      group_pos   = sql.index("GROUP BY")
      having_pos  = sql.index("HAVING")
      order_pos   = sql.index("ORDER BY")

      expect(join_pos).to be < where_pos
      expect(where_pos).to be < group_pos
      expect(group_pos).to be < having_pos
      expect(having_pos).to be < order_pos
    end
  end

  # ---------------------------------------------------------------------------
  # 12. Method chaining returns self
  # ---------------------------------------------------------------------------
  describe "method chaining" do
    it "returns self from select" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.select("id")).to be(qb)
    end

    it "returns self from where" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.where("id = ?", [1])).to be(qb)
    end

    it "returns self from or_where" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.or_where("id = ?", [1])).to be(qb)
    end

    it "returns self from join" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.join("orders", "orders.user_id = users.id")).to be(qb)
    end

    it "returns self from left_join" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.left_join("orders", "orders.user_id = users.id")).to be(qb)
    end

    it "returns self from group_by" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.group_by("id")).to be(qb)
    end

    it "returns self from having" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.having("COUNT(*) > ?", [1])).to be(qb)
    end

    it "returns self from order_by" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.order_by("id")).to be(qb)
    end

    it "returns self from limit" do
      qb = Tina4::QueryBuilder.from_table("users")
      expect(qb.limit(10)).to be(qb)
    end

    it "supports full chained queries" do
      qb = Tina4::QueryBuilder.from_table("users")
             .select("id", "name")
             .where("active = ?", [1])
             .or_where("age > ?", [30])
             .join("orders", "orders.user_id = users.id")
             .group_by("users.id")
             .having("COUNT(*) > ?", [0])
             .order_by("name ASC")
             .limit(10, 5)

      expect(qb).to be_a(Tina4::QueryBuilder)
    end
  end

  # ---------------------------------------------------------------------------
  # 13. .get() returns results
  # ---------------------------------------------------------------------------
  describe "#get" do
    it "returns a DatabaseResult" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared).get
      expect(result).to be_a(Tina4::DatabaseResult)
    end

    it "returns all rows when no conditions" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared).get
      expect(result.records.length).to eq(5)
    end

    it "filters rows with where" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("active = ?", [1])
                 .get
      expect(result.records.length).to eq(4)
    end

    it "respects select columns" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .select("name")
                 .limit(1)
                 .get
      row = result.records.first
      # Row should have name key (string or symbol depending on driver)
      expect(row.key?("name") || row.key?(:name)).to be true
    end

    it "defaults limit to 100 when not set" do
      # With only 5 rows this just verifies no error
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared).get
      expect(result.records.length).to eq(5)
    end
  end

  # ---------------------------------------------------------------------------
  # 14. .first() returns single hash or nil
  # ---------------------------------------------------------------------------
  describe "#first" do
    it "returns a hash for an existing row" do
      row = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("name = ?", ["Alice"])
              .first
      expect(row).to be_a(Hash)
      expect(row["name"] || row[:name]).to eq("Alice")
    end

    it "returns nil when no rows match" do
      row = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("name = ?", ["NonExistent"])
              .first
      expect(row).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # 15. .count() returns integer
  # ---------------------------------------------------------------------------
  describe "#count" do
    it "returns the total count of rows" do
      cnt = Tina4::QueryBuilder.from_table("users", db: @db_shared).count
      expect(cnt).to eq(5)
    end

    it "returns count with where filter" do
      cnt = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("active = ?", [0])
              .count
      expect(cnt).to eq(1)
    end

    it "returns an integer" do
      cnt = Tina4::QueryBuilder.from_table("users", db: @db_shared).count
      expect(cnt).to be_a(Integer)
    end

    it "returns 0 when no rows match" do
      cnt = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("age > ?", [999])
              .count
      expect(cnt).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # 16. .exists?() returns boolean
  # ---------------------------------------------------------------------------
  describe "#exists?" do
    it "returns true when rows match" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("name = ?", ["Alice"])
                 .exists?
      expect(result).to be true
    end

    it "returns false when no rows match" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("name = ?", ["Nobody"])
                 .exists?
      expect(result).to be false
    end

    it "returns a boolean value" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared).exists?
      expect(result).to be(true).or be(false)
    end
  end

  # ---------------------------------------------------------------------------
  # 17. No database raises error
  # ---------------------------------------------------------------------------
  describe "no database connection" do
    it "raises an error on get without db" do
      expect {
        Tina4::QueryBuilder.from_table("users").get
      }.to raise_error(RuntimeError, /No database connection/)
    end

    it "raises an error on first without db" do
      expect {
        Tina4::QueryBuilder.from_table("users").first
      }.to raise_error(RuntimeError, /No database connection/)
    end

    it "raises an error on count without db" do
      expect {
        Tina4::QueryBuilder.from_table("users").count
      }.to raise_error(RuntimeError, /No database connection/)
    end

    it "raises an error on exists? without db" do
      expect {
        Tina4::QueryBuilder.from_table("users").exists?
      }.to raise_error(RuntimeError, /No database connection/)
    end

    it "does not raise on to_sql without db" do
      expect {
        Tina4::QueryBuilder.from_table("users").to_sql
      }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # 18. Complex multi-clause query
  # ---------------------------------------------------------------------------
  describe "complex multi-clause query" do
    it "executes a query with join, where, group_by, having, and order_by" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .select("users.name", "SUM(orders.amount) as total_spent")
                 .join("orders", "orders.user_id = users.id")
                 .where("users.active = ?", [1])
                 .group_by("users.name")
                 .having("SUM(orders.amount) > ?", [50])
                 .order_by("total_spent DESC")
                 .get

      expect(result).to be_a(Tina4::DatabaseResult)
      expect(result.records).not_to be_empty

      # Bob has 200 total, Alice has 150 total — both > 50, both active
      names = result.records.map { |r| r["name"] || r[:name] }
      expect(names).to include("Bob")
      expect(names).to include("Alice")
    end

    it "combines where and or_where correctly" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("age > ?", [30])
                 .or_where("name = ?", ["Eve"])
                 .get

      names = result.records.map { |r| r["name"] || r[:name] }
      expect(names).to include("Charlie") # age 35
      expect(names).to include("Eve")     # name match
      expect(names.length).to eq(2)
    end

    it "builds correct SQL for left join with all clauses" do
      sql = Tina4::QueryBuilder.from_table("users")
              .select("users.id", "users.name", "COUNT(orders.id) as order_count")
              .left_join("orders", "orders.user_id = users.id")
              .where("users.active = ?", [1])
              .group_by("users.id")
              .group_by("users.name")
              .having("COUNT(orders.id) >= ?", [0])
              .order_by("order_count DESC")
              .to_sql

      expect(sql).to eq(
        "SELECT users.id, users.name, COUNT(orders.id) as order_count " \
        "FROM users " \
        "LEFT JOIN orders ON orders.user_id = users.id " \
        "WHERE users.active = ? " \
        "GROUP BY users.id, users.name " \
        "HAVING COUNT(orders.id) >= ? " \
        "ORDER BY order_count DESC"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # 19. Empty results
  # ---------------------------------------------------------------------------
  describe "empty results" do
    it "returns empty records from get when nothing matches" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("age > ?", [999])
                 .get
      expect(result.records).to be_empty
    end

    it "returns nil from first when nothing matches" do
      row = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("age > ?", [999])
              .first
      expect(row).to be_nil
    end

    it "returns 0 from count when nothing matches" do
      cnt = Tina4::QueryBuilder.from_table("users", db: @db_shared)
              .where("age > ?", [999])
              .count
      expect(cnt).to eq(0)
    end

    it "returns false from exists? when nothing matches" do
      result = Tina4::QueryBuilder.from_table("users", db: @db_shared)
                 .where("age > ?", [999])
                 .exists?
      expect(result).to be false
    end

    it "returns empty for a table with no rows" do
      @db_shared.execute("CREATE TABLE IF NOT EXISTS empty_table (id INTEGER PRIMARY KEY)")
      result = Tina4::QueryBuilder.from_table("empty_table", db: @db_shared).get
      expect(result.records).to be_empty
    end
  end
end
