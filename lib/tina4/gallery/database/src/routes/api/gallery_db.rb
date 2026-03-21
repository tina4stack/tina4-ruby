# Gallery: Database — raw SQL query demo.

Tina4::Router.get("/api/gallery/db/tables") do |request, response|
  begin
    db = Tina4::Database.new("sqlite://data/gallery.db")
    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS gallery_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        body TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    tables = db.tables
    response.json({ tables: tables, engine: "sqlite" })
  rescue => e
    response.json({ error: e.message }, 500)
  end
end

Tina4::Router.post("/api/gallery/db/notes") do |request, response|
  begin
    db = Tina4::Database.new("sqlite://data/gallery.db")
    body = request.body || {}
    db.insert("gallery_notes", {
      title: body["title"] || "Untitled",
      body: body["body"] || ""
    })
    response.json({ created: true }, 201)
  rescue => e
    response.json({ error: e.message }, 500)
  end
end

Tina4::Router.get("/api/gallery/db/notes") do |request, response|
  begin
    db = Tina4::Database.new("sqlite://data/gallery.db")
    result = db.fetch("SELECT * FROM gallery_notes ORDER BY id DESC", [], limit: 50)
    response.json(result.to_a)
  rescue => e
    response.json({ error: e.message }, 500)
  end
end
