# frozen_string_literal: true

# GET /api/hello — Simple JSON greeting
Tina4.get "/api/hello" do |_request, response|
  response.json({ message: "Hello from Tina4 Ruby!", version: Tina4::VERSION }, Tina4::HTTP_OK)
end

# GET /api/users — List all users
Tina4.get "/api/users" do |_request, response|
  begin
    users = User.all(limit: 100, order_by: "id ASC")
    response.json(users.map(&:to_h), Tina4::HTTP_OK)
  rescue => e
    Tina4::Log.error("GET /api/users failed: #{e.message}")
    response.json({ error: e.message }, Tina4::HTTP_INTERNAL_SERVER_ERROR)
  end
end

# GET /api/users/{id} — Get a single user by ID
Tina4.get "/api/users/{id}" do |request, response|
  begin
    user = User.find(request.params[:id])
    if user
      response.json(user.to_h, Tina4::HTTP_OK)
    else
      response.json({ error: "User not found" }, Tina4::HTTP_NOT_FOUND)
    end
  rescue => e
    Tina4::Log.error("GET /api/users/{id} failed: #{e.message}")
    response.json({ error: e.message }, Tina4::HTTP_INTERNAL_SERVER_ERROR)
  end
end

# POST /api/users — Create a new user
Tina4.post "/api/users" do |request, response|
  begin
    user = User.create(request.body)
    response.json(user.to_h, Tina4::HTTP_CREATED)
  rescue => e
    Tina4::Log.error("POST /api/users failed: #{e.message}")
    response.json({ error: e.message }, Tina4::HTTP_INTERNAL_SERVER_ERROR)
  end
end
