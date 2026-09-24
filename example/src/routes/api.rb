# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


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
    response.json({ error: e.message }, Tina4::HTTP_SERVER_ERROR)
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
    response.json({ error: e.message }, Tina4::HTTP_SERVER_ERROR)
  end
end

# POST /api/users — Create a new user
#
# Write routes (POST/PUT/PATCH/DELETE) are SECURE BY DEFAULT in Tina4 v3. Two
# independent gates guard them: `Tina4.post` attaches the default bearer-token
# auth_handler (opt out with `auth: false`), and the router additionally sets
# `auth_required` for write methods (opt out with `.no_auth`). This demo endpoint
# is public, so we clear BOTH — otherwise it returns 403/401 without a token.
Tina4.post("/api/users", auth: false) do |request, response|
  begin
    user = User.create(request.body)
    response.json(user.to_h, Tina4::HTTP_CREATED)
  rescue => e
    Tina4::Log.error("POST /api/users failed: #{e.message}")
    response.json({ error: e.message }, Tina4::HTTP_SERVER_ERROR)
  end
end.no_auth
