# frozen_string_literal: true

# Tina4 Ruby Example Application
# Run: cd tina4-ruby/example && ruby app.rb
# Visit: http://localhost:7147

$LOAD_PATH.unshift(File.join(__dir__, "..", "lib"))
require "tina4"

# Initialize Tina4 (loads .env, sets up logging, auth keys)
Tina4.initialize!(__dir__)

# Database setup — SQLite for this example
DB_PATH = File.join(__dir__, "example.db")
# SQLite DSN convention (parity with Python/PHP/Node): `sqlite:///path` treats
# `path` as RELATIVE to the cwd, while `sqlite:////abs/path` (four slashes) is an
# ABSOLUTE filesystem path. DB_PATH is already absolute, so prefix `sqlite:///`
# to land on `sqlite:////Users/.../example.db` and bind the file in place —
# otherwise the two-slash form yields a three-slash DSN that is resolved
# relative to the cwd (creating a stray nested directory).
db = Tina4::Database.new("sqlite:///#{DB_PATH}")
Tina4.bind_database(db)

# Create users table
db.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    first_name VARCHAR(255) NOT NULL,
    last_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    age INTEGER DEFAULT 0
  )
SQL

# Seed some data if empty
begin
  existing = db.fetch("SELECT COUNT(*) AS cnt FROM users")
  count = existing.to_a.first&.[]("cnt") || existing.to_a.first&.[](:"cnt") || 0

  if count.to_i == 0
    [
      ["Alice", "Johnson", "alice@example.com", 30],
      ["Bob", "Smith", "bob@example.com", 25],
      ["Charlie", "Brown", "charlie@example.com", 35]
    ].each do |first_name, last_name, email, age|
      db.execute(
        "INSERT INTO users (first_name, last_name, email, age) VALUES (?, ?, ?, ?)",
        [first_name, last_name, email, age]
      )
    end
    Tina4::Log.info("Seeded users table with example data")
  end
rescue => e
  Tina4::Log.warning("Could not seed users table: #{e.message}")
end

# Load ORM models and routes from src/
Dir[File.join(__dir__, "src", "orm", "*.rb")].each { |f| require f }
Dir[File.join(__dir__, "src", "routes", "*.rb")].each { |f| require f }

# Start the server
port = (ENV["PORT"] || 7147).to_i
host = ENV["HOST"] || "0.0.0.0"
app = Tina4::RackApp.new(root_dir: __dir__)
server = Tina4::WebServer.new(app, host: host, port: port)
server.start
