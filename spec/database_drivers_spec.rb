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

    it "maps pgsql to PostgresDriver" do
      # pgsql:// is the PDO / Laravel / Doctrine scheme name (issue #58)
      expect(Tina4::Database::DRIVERS["pgsql"]).to eq("Tina4::Drivers::PostgresDriver")
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
    # These exercise the REAL detection / driver behaviour. SQLite is the only
    # engine provisioned for unit tests, so it gets a full connect+execute path
    # against a real on-disk DB; the other engines have their server-free pure
    # methods (placeholder/placeholders/apply_limit + private SQL translators)
    # invoked for their real computed output.

    it "detects sqlite from .db extension and the driver actually functions" do
      tmp = Dir.mktmpdir
      begin
        db = Tina4::Database.new("sqlite:///" + File.join(tmp, "x.db"))
        # Real detection: the connection string was routed to the sqlite driver.
        expect(db.driver_name).to eq("sqlite")
        # ...and that driver actually works against a real SQLite file.
        db.execute("CREATE TABLE t(id INTEGER)")
        expect(db.table_exists?("t")).to be true
        db.close
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "postgres driver produces $N placeholders and LIMIT/OFFSET SQL" do
      driver = Tina4::Drivers::PostgresDriver.new
      # Pure, server-free methods — assert real computed output, not existence.
      expect(driver.placeholder).to eq("?")
      expect(driver.placeholders(2)).to eq("$1, $2")
      expect(driver.apply_limit("SELECT * FROM t", 10, 5)).to eq("SELECT * FROM t LIMIT 10 OFFSET 5")
      expect(driver.send(:convert_placeholders, "a = ? AND b = ?")).to eq("a = $1 AND b = $2")
    end

    it "mysql driver produces ? placeholders and LIMIT/OFFSET SQL" do
      driver = Tina4::Drivers::MysqlDriver.new
      expect(driver.placeholder).to eq("?")
      expect(driver.placeholders(3)).to eq("?, ?, ?")
      expect(driver.apply_limit("SELECT * FROM t", 10, 5)).to eq("SELECT * FROM t LIMIT 10 OFFSET 5")
      # #262: last_insert_id now returns the id CAPTURED AT WRITE TIME on the last
      # INSERT (mirroring Python's mysql.py cursor.lastrowid) rather than re-reading
      # @connection.last_id — which a follow-up autocommit COMMIT had clobbered to 0,
      # making db.get_last_id return 0 after an insert. With no insert yet the cache
      # is nil (same contract as the Firebird driver below), not a probe error.
      expect(driver.last_insert_id).to be_nil
    end

    it "mssql driver translates LIMIT to OFFSET/FETCH and escapes params" do
      driver = Tina4::Drivers::MssqlDriver.new
      expect(driver.apply_limit("SELECT * FROM users", 10, 5))
        .to eq("SELECT * FROM users ORDER BY (SELECT NULL) OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY")
      # Real param interpolation: single quotes are doubled (SQL-escaped).
      expect(driver.send(:interpolate_params, "WHERE name = ?", ["O'Brien"]))
        .to eq("WHERE name = 'O''Brien'")
    end

    it "firebird driver translates LIMIT to FIRST/SKIP and has nil last id" do
      driver = Tina4::Drivers::FirebirdDriver.new
      expect(driver.apply_limit("SELECT * FROM users", 10, 5))
        .to eq("SELECT FIRST 10 SKIP 5 * FROM (SELECT * FROM users)")
      expect(driver.placeholders(3)).to eq("?, ?, ?")
      # Firebird has no last-insert-id concept; the driver returns nil literally.
      expect(driver.last_insert_id).to be_nil
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
      expect(result).to eq("SELECT * FROM users ORDER BY (SELECT NULL) OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY")
    end

    it "applies OFFSET 0 when no offset given" do
      result = driver.apply_limit("SELECT * FROM users", 10, 0)
      expect(result).to eq("SELECT * FROM users ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
    end

    it "preserves an existing ORDER BY instead of adding the (SELECT NULL) default" do
      # OFFSET/FETCH needs an ORDER BY; when the query already has one the
      # driver must NOT append a second (which would be a syntax error) — the
      # default is only for unordered queries (a fetch_one aggregate).
      result = driver.apply_limit("SELECT * FROM users ORDER BY id", 10, 5)
      expect(result).to eq("SELECT * FROM users ORDER BY id OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY")
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

    # ── SQLite URL path resolution (parity with tina4-python, tina4-php, tina4-nodejs)
    #
    # Convention:
    #   sqlite:///X    → relative to cwd (three slashes)
    #   sqlite:////X   → absolute (four slashes)
    #   sqlite:///C:/  → Windows absolute (drive letter)
    #   sqlite::memory: and sqlite:///:memory: → in-memory
    describe ".resolve_path" do
      it ":memory: short form passes through" do
        expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite::memory:")).to eq(":memory:")
      end

      it ":memory: URL form passes through" do
        expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///:memory:")).to eq(":memory:")
      end

      it "three-slash URL resolves relative to cwd" do
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) do
            # macOS symlinks /var/folders -> /private/var/folders, so compare
            # against the resolved cwd rather than the tmp path.
            resolved_cwd = Dir.pwd
            expected = File.join(resolved_cwd, "data", "app.db")
            expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///data/app.db")).to eq(expected)
            expect(File.directory?(File.join(resolved_cwd, "data"))).to be true
          end
        end
      end

      it "four-slash URL is absolute" do
        expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:////var/data/app.db")).to eq("/var/data/app.db")
      end

      it "Windows drive-letter URL is absolute" do
        expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///C:/Users/app.db")).to eq("C:/Users/app.db")
      end

      it "does not mkdir outside cwd for absolute paths (bruce regression)" do
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) do
            # Regression for the bruceproject crash that hit
            # `Errno::EROFS: Read-only file system @ dir_s_mkdir - /data` on macOS.
            # Absolute paths must NOT try to create parent dirs outside cwd.
            Tina4::Drivers::SqliteDriver.resolve_path("sqlite:////does/not/exist/app.db")
            expect(File.exist?("/does")).to be false
          end
        end
      end
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
    # The contract isn't "the method exists" — respond_to? proves nothing about
    # behaviour. We assert the real engine-specific output of the pure members
    # (placeholder / placeholders / apply_limit) per driver, and for the
    # SqliteDriver — the one engine provisioned for unit tests — we exercise the
    # connection-requiring members (connect/execute/begin_transaction/commit/
    # rollback/tables/columns/close) for real against a tmp SQLite database.

    # Expected engine-specific output for the pure (server-free) members.
    {
      "SqliteDriver"   => { placeholders: "?, ?, ?",   limit: "SELECT * FROM t LIMIT 10 OFFSET 5" },
      "PostgresDriver" => { placeholders: "$1, $2, $3", limit: "SELECT * FROM t LIMIT 10 OFFSET 5" },
      "MysqlDriver"    => { placeholders: "?, ?, ?",   limit: "SELECT * FROM t LIMIT 10 OFFSET 5" },
      "MssqlDriver"    => { placeholders: "?, ?, ?",   limit: "SELECT * FROM t ORDER BY (SELECT NULL) OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY" },
      "FirebirdDriver" => { placeholders: "?, ?, ?",   limit: "SELECT FIRST 10 SKIP 5 * FROM (SELECT * FROM t)" }
    }.each do |driver_class_name, expected|
      describe driver_class_name do
        let(:driver) { Tina4::Drivers.const_get(driver_class_name).new }

        it "produces ? as its bind placeholder" do
          expect(driver.placeholder).to eq("?")
        end

        it "expands placeholders to the engine's style" do
          expect(driver.placeholders(3)).to eq(expected[:placeholders])
        end

        it "applies LIMIT/OFFSET in the engine's dialect" do
          expect(driver.apply_limit("SELECT * FROM t", 10, 5)).to eq(expected[:limit])
        end
      end
    end

    # SqliteDriver — the connection-requiring members exercised for real.
    describe "SqliteDriver live connection members" do
      let(:tmp_dir) { Dir.mktmpdir("tina4_adapter_contract") }
      let(:db_path) { File.join(tmp_dir, "contract.db") }
      let(:driver)  { Tina4::Drivers::SqliteDriver.new }

      before(:each) { driver.connect("sqlite:///" + db_path) }

      after(:each) do
        driver.close
        FileUtils.rm_rf(tmp_dir)
      end

      it "connect + execute create a real table that tables/columns report" do
        driver.execute("CREATE TABLE t(id INTEGER, name TEXT)")
        expect(driver.tables).to include("t")
        col_names = driver.columns("t").map { |c| c[:name] || c["name"] }
        expect(col_names).to include("id", "name")
      end

      it "execute_query returns the rows that execute inserted" do
        driver.execute("CREATE TABLE t(id INTEGER)")
        driver.execute("INSERT INTO t VALUES (1)")
        driver.execute("INSERT INTO t VALUES (2)")
        rows = driver.execute_query("SELECT id FROM t ORDER BY id")
        expect(rows).to eq([{ id: 1 }, { id: 2 }])
      end

      it "execute has a real side effect (a row is persisted)" do
        driver.execute("CREATE TABLE t(id INTEGER)")
        driver.execute("INSERT INTO t VALUES (1)")
        count = driver.execute_query("SELECT count(*) AS n FROM t").first[:n]
        expect(count).to eq(1)
      end

      it "begin_transaction + rollback discards the write" do
        driver.execute("CREATE TABLE t(id INTEGER)")
        driver.begin_transaction
        driver.execute("INSERT INTO t VALUES (1)")
        driver.rollback
        count = driver.execute_query("SELECT count(*) AS n FROM t").first[:n]
        expect(count).to eq(0)
      end

      it "begin_transaction + commit persists the write across a reconnect" do
        driver.execute("CREATE TABLE t(id INTEGER)")
        driver.begin_transaction
        driver.execute("INSERT INTO t VALUES (42)")
        driver.commit
        driver.close
        # Reopen the same file to prove the commit hit disk, not just a cache.
        reopened = Tina4::Drivers::SqliteDriver.new
        reopened.connect("sqlite:///" + db_path)
        row = reopened.execute_query("SELECT id FROM t").first
        expect(row[:id]).to eq(42)
        reopened.close
      end

      it "close releases the connection (a later query raises)" do
        driver.execute("CREATE TABLE t(id INTEGER)")
        expect { driver.close }.not_to raise_error
        expect { driver.execute_query("SELECT 1") }.to raise_error(StandardError)
      end

      it "tables lists a freshly created table" do
        driver.execute("CREATE TABLE foo(id INTEGER)")
        expect(driver.tables).to include("foo")
      end

      it "columns reports the real column names of a table" do
        driver.execute("CREATE TABLE foo(id INTEGER, name TEXT)")
        col_names = driver.columns("foo").map { |c| c[:name] || c["name"] }
        expect(col_names).to include("id", "name")
      end
    end
  end

  # ── SQLite CRUD Tests (always available) ─────────────────────────

  describe "SQLite CRUD" do
    let(:tmp_dir) { Dir.mktmpdir("tina4_db_test") }
    let(:db_path) { File.join(tmp_dir, "crud_test.db") }
    let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

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
