# tina4-ruby Copilot Instructions

Tina4 Ruby v3. 140 cataloged features, zero external dependencies.

## Route Pattern

```ruby
Tina4::Router.get "/api/users" do |request, response|
  response.json({ users: [] })
end

Tina4::Router.post("/api/public") { |req, res|
  res.json({ ok: true })
}.no_auth
```

## Critical Rules

- Route params: `{id}` not `:id`
- POST/PUT/DELETE require auth — chain `.no_auth` for public
- GET is public — chain `.secure` to protect
- ORM: `to_h` for hash conversion
- Queue: `job.payload` not `job.data`
- Namespace: `Tina4::` — `Tina4::Router`, `Tina4::ORM`
- snake_case methods: `get_token`, `hash_password`
- Templates: Twig syntax (not ERB)

For the complete API reference, read `CLAUDE.md` in this repo and the docs it links. `llms.txt` is the link index (llmstxt.org format); https://tina4.com/llms-full.txt has the full documentation in one file.
