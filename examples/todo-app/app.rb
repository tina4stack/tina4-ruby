require "tina4ruby"

Tina4.database = Tina4::Database.new("sqlite3:todos.db")

Tina4.run(port: 7145)
