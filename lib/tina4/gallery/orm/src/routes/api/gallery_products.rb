# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Gallery: ORM — Product CRUD endpoints.

Tina4::Router.get("/api/gallery/products") do |request, response|
  response.json({
    products: [
      { id: 1, name: "Widget", price: 9.99 },
      { id: 2, name: "Gadget", price: 24.99 }
    ],
    note: "Connect a database and deploy the ORM model for live data"
  })
end

Tina4::Router.post("/api/gallery/products") do |request, response|
  data = request.body || {}
  response.json({ created: data, id: 3 }, 201)
end
