# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
