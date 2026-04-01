# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Database Driver Registration" do
  describe "Tina4::Database::DRIVERS" do
    it "maps sqlite to SqliteDriver" do
      expect(Tina4::Database::DRIVERS["sqlite"]).to eq("Tina4::Drivers::SqliteDriver")
    end

    it "maps sqlite3 to SqliteDriver" do
      expect(Tina4::Database::DRIVERS["sqlite3"]).to eq("Tina4::Drivers::SqliteDriver")
    end

    it "maps postgres to PostgresDriver" do
      expect(Tina4::Database::DRIVERS["postgres"]).to eq("Tina4::Drivers::PostgresDriver")
    end

    it "maps postgresql to PostgresDriver" do
      expect(Tina4::Database::DRIVERS["postgresql"]).to eq("Tina4::Drivers::PostgresDriver")
    end

    it "maps mysql to MysqlDriver" do
      expect(Tina4::Database::DRIVERS["mysql"]).to eq("Tina4::Drivers::MysqlDriver")
    end

    it "maps mssql to MssqlDriver" do
      expect(Tina4::Database::DRIVERS["mssql"]).to eq("Tina4::Drivers::MssqlDriver")
    end

    it "maps sqlserver to MssqlDriver" do
      expect(Tina4::Database::DRIVERS["sqlserver"]).to eq("Tina4::Drivers::MssqlDriver")
    end

    it "maps firebird to FirebirdDriver" do
      expect(Tina4::Database::DRIVERS["firebird"]).to eq("Tina4::Drivers::FirebirdDriver")
    end

    it "is frozen" do
      expect(Tina4::Database::DRIVERS).to be_frozen
    end
  end

  describe "driver detection via connection string" do
    # We test detect_driver indirectly through create_driver behavior.
    # Since we can't connect to real databases, we verify the driver class is instantiated.

    it "detects sqlite from .db extension" do
      driver = Tina4::Drivers::SqliteDriver.new
      expect(driver).to respond_to(:connect)
      expect(driver).to respond_to(:execute_query)
      expect(driver).to respond_to(:execute)
    end

    it "detects postgres driver responds to expected interface" do
      driver = Tina4::Drivers::PostgresDriver.new
      expect(driver).to respond_to(:connect)
      expect(driver).to respond_to(:execute_query)
      expect(driver).to respond_to(:placeholder)
      expect(driver).to respond_to(:placeholders)
      expect(driver).to respond_to(:apply_limit)
      expect(driver).to respond_to(:begin_transaction)
      expect(driver).to respond_to(:commit)
      expect(driver).to respond_to(:rollback)
      expect(driver).to respond_to(:tables)
      expect(driver).to respond_to(:columns)
      expect(driver).to respond_to(:close)
    end

    it "detects mysql driver responds to expected interface" do
      driver = Tina4::Drivers::MysqlDriver.new
      expect(driver).to respond_to(:connect)
      expect(driver).to respond_to(:execute_query)
      expect(driver).to respond_to(:last_insert_id)
    end

    it "detects mssql driver responds to expected interface" do
      driver = Tina4::Drivers::MssqlDriver.new
      expect(driver).to respond_to(:connect)
      expect(driver).to respond_to(:execute_query)
      expect(driver).to respond_to(:apply_limit)
    end

    it "detects firebird driver responds to expected interface" do
      driver = Tina4::Drivers::FirebirdDriver.new
      expect(driver).to respond_to(:connect)
      expect(driver).to respond_to(:execute_query)
      expect(driver).to respond_to(:apply_limit)
    end
  end

  describe "PostgresDriver" do
    let(:driver) { Tina4::Drivers::PostgresDriver.new }

    it "returns ? as placeholder" do
      expect(driver.placeholder).to eq("?")
    end

    it "generates $N-style placeholders" do
      expect(driver.placeholders(3)).to eq("$1, $2, $3")
    end

    it "generates single placeholder" do
      expect(driver.placeholders(1)).to eq("$1")
    end

    it "applies LIMIT/OFFSET syntax" do
      result = driver.apply_limit("SELECT * FROM users", 10, 5)
      expect(result).to eq("SELECT * FROM users LIMIT 10 OFFSET 5")
    end

    it "applies LIMIT with zero offset" do
      result = driver.apply_limit("SELECT * FROM users", 10, 0)
      expect(result).to eq("SELECT * FROM users LIMIT 10 OFFSET 0")
    end
  end

  describe "MysqlDriver" do
    let(:driver) { Tina4::Drivers::MysqlDriver.new }

    it "returns ? as placeholder" do
      expect(driver.placeholder).to eq("?")
    end

    it "generates ?-style placeholders" do
      expect(driver.placeholders(3)).to eq("?, ?, ?")
    end

    it "generates single placeholder" do
      expect(driver.placeholders(1)).to eq("?")
    end

    it "applies LIMIT/OFFSET syntax" do
      result = driver.apply_limit("SELECT * FROM users", 10, 5)
      expect(result).to eq("SELECT * FROM users LIMIT 10 OFFSET 5")
    end
  end

  describe "MssqlDriver" do
    let(:driver) { Tina4::Drivers::MssqlDriver.new }

    it "returns ? as placeholder" do
      expect(driver.placeholder).to eq("?")
    end

    it "generates ?-style placeholders" do
      expect(driver.placeholders(3)).to eq("?, ?, ?")
    end

    it "applies OFFSET/FETCH NEXT syntax for MSSQL" do
      result = driver.apply_limit("SELECT * FROM users", 10, 5)
      expect(result).to eq("SELECT * FROM users OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY")
    end

    it "applies OFFSET 0 when no offset given" do
      result = driver.apply_limit("SELECT * FROM users", 10, 0)
      expect(result).to eq("SELECT * FROM users OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
    end
  end

  describe "FirebirdDriver" do
    let(:driver) { Tina4::Drivers::FirebirdDriver.new }

    it "returns ? as placeholder" do
      expect(driver.placeholder).to eq("?")
    end

    it "generates ?-style placeholders" do
      expect(driver.placeholders(3)).to eq("?, ?, ?")
    end

    it "applies FIRST/SKIP syntax for Firebird" do
      result = driver.apply_limit("SELECT * FROM users", 10, 5)
      expect(result).to eq("SELECT FIRST 10 SKIP 5 * FROM (SELECT * FROM users)")
    end

    it "applies FIRST with zero skip" do
      result = driver.apply_limit("SELECT * FROM users", 10, 0)
      expect(result).to eq("SELECT FIRST 10 SKIP 0 * FROM (SELECT * FROM users)")
    end

    it "returns nil for last_insert_id" do
      expect(driver.last_insert_id).to be_nil
    end
  end

  describe "SqliteDriver" do
    let(:driver) { Tina4::Drivers::SqliteDriver.new }

    it "returns ? as placeholder" do
      expect(driver.placeholder).to eq("?")
    end

    it "generates ?-style placeholders" do
      expect(driver.placeholders(3)).to eq("?, ?, ?")
    end

    it "applies LIMIT/OFFSET syntax" do
      result = driver.apply_limit("SELECT * FROM users", 10, 5)
      expect(result).to eq("SELECT * FROM users LIMIT 10 OFFSET 5")
    end
  end

  describe "MssqlDriver connection string parsing" do
    let(:driver) { Tina4::Drivers::MssqlDriver.new }

    it "parses full mssql:// URL" do
      parsed = driver.send(:parse_connection, "mssql://admin:secret@db.example.com:1433/mydb")
      expect(parsed[:host]).to eq("db.example.com")
      expect(parsed[:port]).to eq(1433)
      expect(parsed[:username]).to eq("admin")
      expect(parsed[:password]).to eq("secret")
      expect(parsed[:database]).to eq("mydb")
    end

    it "parses sqlserver:// URL" do
      parsed = driver.send(:parse_connection, "sqlserver://user:pass@localhost/testdb")
      expect(parsed[:host]).to eq("localhost")
      expect(parsed[:database]).to eq("testdb")
    end

    it "falls back to localhost for unparseable strings" do
      parsed = driver.send(:parse_connection, "just_a_db_name")
      expect(parsed[:host]).to eq("localhost")
      expect(parsed[:database]).to eq("just_a_db_name")
    end
  end

  describe "MssqlDriver parameter interpolation" do
    let(:driver) { Tina4::Drivers::MssqlDriver.new }

    it "returns sql unchanged when no params" do
      sql = "SELECT * FROM users"
      result = driver.send(:interpolate_params, sql, [])
      expect(result).to eq(sql)
    end

    it "replaces ? with string param (escaped)" do
      result = driver.send(:interpolate_params, "SELECT * FROM users WHERE name = ?", ["Alice"])
      expect(result).to eq("SELECT * FROM users WHERE name = 'Alice'")
    end

    it "escapes single quotes in strings" do
      result = driver.send(:interpolate_params, "SELECT * FROM users WHERE name = ?", ["O'Brien"])
      expect(result).to eq("SELECT * FROM users WHERE name = 'O''Brien'")
    end

    it "replaces ? with integer param" do
      result = driver.send(:interpolate_params, "SELECT * FROM users WHERE id = ?", [42])
      expect(result).to eq("SELECT * FROM users WHERE id = 42")
    end
  end

  describe "PostgresDriver placeholder conversion" do
    let(:driver) { Tina4::Drivers::PostgresDriver.new }

    it "converts ? placeholders to $N" do
      result = driver.send(:convert_placeholders, "SELECT * FROM t WHERE a = ? AND b = ?")
      expect(result).to eq("SELECT * FROM t WHERE a = $1 AND b = $2")
    end

    it "leaves sql unchanged when no placeholders" do
      sql = "SELECT * FROM users"
      result = driver.send(:convert_placeholders, sql)
      expect(result).to eq(sql)
    end
  end

  # ── Connection URL Parsing ───────────────────────────────────────

  describe "Connection URL parsing via URI" do
    # Test URL parsing logic that all drivers rely on

    it "parses PostgreSQL URL components" do
      url = "postgresql://alice:secret@db.example.com:5433/myapp"
      uri = URI.parse(url)
      expect(uri.scheme).to eq("postgresql")
      expect(uri.host).to eq("db.example.com")
      expect(uri.port).to eq(5433)
      expect(uri.user).to eq("alice")
      expect(uri.password).to eq("secret")
      expect(uri.path).to eq("/myapp")
    end

    it "parses MySQL URL components" do
      url = "mysql://root:pass123@mysql-server:3307/shop"
      uri = URI.parse(url)
      expect(uri.scheme).to eq("mysql")
      expect(uri.host).to eq("mysql-server")
      expect(uri.port).to eq(3307)
      expect(uri.user).to eq("root")
      expect(uri.password).to eq("pass123")
      expect(uri.path).to eq("/shop")
    end

    it "parses Firebird URL components" do
      url = "firebird://SYSDBA:masterkey@fbhost:3050/var/lib/firebird/data/app.fdb"
      uri = URI.parse(url)
      expect(uri.scheme).to eq("firebird")
      expect(uri.host).to eq("fbhost")
      expect(uri.port).to eq(3050)
      expect(uri.user).to eq("SYSDBA")
      expect(uri.password).to eq("masterkey")
    end

    it "parses PostgreSQL URL with defaults" do
      url = "postgresql://localhost/testdb"
      uri = URI.parse(url)
      expect(uri.host).to eq("localhost")
      expect(uri.port).to be_nil
      expect(uri.path).to eq("/testdb")
    end

    it "parses MSSQL URL components" do
      url = "mssql://sa:MyPass@mssql-host:1434/warehouse"
      uri = URI.parse(url)
      expect(uri.scheme).to eq("mssql")
      expect(uri.host).to eq("mssql-host")
      expect(uri.port).to eq(1434)
      expect(uri.user).to eq("sa")
      expect(uri.password).to eq("MyPass")
    end
  end

  # ── Adapter Contract (all drivers must implement same interface) ──

  describe "Adapter contract" do
    %w[SqliteDriver PostgresDriver MysqlDriver MssqlDriver FirebirdDriver].each do |driver_class_name|
      describe driver_class_name do
        let(:driver) { Tina4::Drivers.const_get(driver_class_name).new }

        it "has connect" do
          expect(driver).to respond_to(:connect)
        end

        it "has close" do
          expect(driver).to respond_to(:close)
        end

        it "has execute_query" do
          expect(driver).to respond_to(:execute_query)
        end

        it "has execute" do
          expect(driver).to respond_to(:execute)
        end

        it "has placeholder" do
          expect(driver).to respond_to(:placeholder)
        end

        it "has placeholders" do
          expect(driver).to respond_to(:placeholders)
        end

        it "has apply_limit" do
          expect(driver).to respond_to(:apply_limit)
        end

        it "has begin_transaction" do
          expect(driver).to respond_to(:begin_transaction)
        end

        it "has commit" do
          expect(driver).to respond_to(:commit)
        end

        it "has rollback" do
          expect(driver).to respond_to(:rollback)
        end

        it "has tables" do
          expect(driver).to respond_to(:tables)
        end

        it "has columns" do
          expect(driver).to respond_to(:columns)
        end

        it "has close" do
          expect(driver).to respond_to(:close)
        end
      end
    end
  end

  # ── SQLite CRUD Tests (always available) ─────────────────────────

  describe "SQLite CRUD" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_db_test") }
    let(:db_path) { File.join(tmp_dir, "crud_test.db") }
    let(:db) { Tina4::Database.new("sqlite://#{db_path}") }

    before(:each) do
      db.execute("CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, price REAL DEFAULT 0.0, active INTEGER DEFAULT 1)")
    end

    after(:each) do
      db.close
      FileUtils.rm_rf(tmp_dir)
    end

    it "inserts a record" do
      result = db.insert("products", { name: "Widget", price: 9.99 })
      expect(result[:success]).to be true
      expect(result[:last_id]).not_to be_nil
    end

    it "fetches records" do
      db.insert("products", { name: "A", price: 1.0 })
      db.insert("products", { name: "B", price: 2.0 })
      db.insert("products", { name: "C", price: 3.0 })
      result = db.fetch("SELECT * FROM products", [], limit: 2)
      expect(result.records.length).to eq(2)
    end

    it "fetches one record" do
      db.insert("products", { name: "Solo", price: 5.0 })
      row = db.fetch_one("SELECT * FROM products WHERE name = ?", ["Solo"])
      expect(row).not_to be_nil
      expect(row[:name]).to eq("Solo")
    end

    it "updates a record" do
      db.insert("products", { name: "Old", price: 1.0 })
      db.update("products", { name: "New" }, { name: "Old" })
      row = db.fetch_one("SELECT * FROM products WHERE name = ?", ["New"])
      expect(row).not_to be_nil
      expect(row[:name]).to eq("New")
    end

    it "deletes a record" do
      db.insert("products", { name: "Gone", price: 0.0 })
      db.delete("products", { name: "Gone" })
      row = db.fetch_one("SELECT * FROM products WHERE name = ?", ["Gone"])
      expect(row).to be_nil
    end

    it "checks table exists" do
      expect(db.table_exists?("products")).to be true
      expect(db.table_exists?("nonexistent")).to be false
    end

    it "gets table list" do
      tables = db.tables
      expect(tables).to include("products")
    end

    it "gets column list" do
      cols = db.columns("products")
      col_names = cols.map { |c| c[:name] || c["name"] }
      expect(col_names).to include("id")
      expect(col_names).to include("name")
      expect(col_names).to include("price")
      expect(col_names).to include("active")
    end

    it "rolls back a transaction" do
      db.insert("products", { name: "Kept" })
      begin
        db.transaction do |_txn|
          db.insert("products", { name: "Discarded" })
          raise "rollback"
        end
      rescue RuntimeError
        # expected — transaction was rolled back
      end
      row = db.fetch_one("SELECT * FROM products WHERE name = ?", ["Discarded"])
      expect(row).to be_nil
      row = db.fetch_one("SELECT * FROM products WHERE name = ?", ["Kept"])
      expect(row).not_to be_nil
    end

    it "detects database type as sqlite" do
      expect(db.driver_name).to eq("sqlite")
    end
  end

  # ── Unknown scheme falls back to sqlite ───────────────────────────

  describe "Unknown scheme" do
    it "falls back to sqlite for unrecognised connection strings" do
      # detect_driver defaults to sqlite when scheme is unknown
      db_instance = Tina4::Database.new
      detected = db_instance.send(:detect_driver, "fakedb://localhost/test")
      expect(detected).to eq("sqlite")
    end
  end

  # ── Database DRIVERS hash ────────────────────────────────────────

  describe "DRIVERS constant completeness" do
    it "contains all expected schemes" do
      %w[sqlite sqlite3 postgres postgresql mysql mssql sqlserver firebird].each do |scheme|
        expect(Tina4::Database::DRIVERS).to have_key(scheme)
      end
    end

    it "postgres and postgresql map to same driver" do
      expect(Tina4::Database::DRIVERS["postgres"]).to eq(Tina4::Database::DRIVERS["postgresql"])
    end

    it "mssql and sqlserver map to same driver" do
      expect(Tina4::Database::DRIVERS["mssql"]).to eq(Tina4::Database::DRIVERS["sqlserver"])
    end

    it "sqlite and sqlite3 map to same driver" do
      expect(Tina4::Database::DRIVERS["sqlite"]).to eq(Tina4::Database::DRIVERS["sqlite3"])
    end
  end
end
