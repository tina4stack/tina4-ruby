require "tina4ruby"

Tina4.bind_database(Tina4::Database.new("sqlite3:todos.db"))

Tina4.run(port: 7147)
