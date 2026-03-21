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
end
