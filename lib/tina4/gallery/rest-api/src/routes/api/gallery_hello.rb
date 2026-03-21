# Gallery: REST API — simple JSON endpoints.

Tina4::Router.get("/api/gallery/hello") do |request, response|
  response.json({ message: "Hello from Tina4!", method: "GET" })
end

Tina4::Router.get("/api/gallery/hello/{name}") do |request, response|
  response.json({ message: "Hello #{request.params["name"]}!", method: "GET" })
end

Tina4::Router.post("/api/gallery/hello") do |request, response|
  data = request.body || {}
  response.json({ echo: data, method: "POST" }, 201)
end
