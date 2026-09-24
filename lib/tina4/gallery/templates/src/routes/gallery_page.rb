# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Gallery: Templates — render an HTML page with dynamic data via template.

Tina4::Router.get "/gallery/page", template: "gallery_page.twig" do |request, response|
  response.call({
    title: "Gallery Demo Page",
    items: [
      { name: "Tina4 Ruby", description: "Zero-dep web framework", badge: "v3.0.0" },
      { name: "Twig Engine", description: "Built-in template rendering", badge: "included" },
      { name: "Auto-Reload", description: "Templates refresh on save", badge: "dev mode" }
    ]
  }, Tina4::HTTP_OK)
end
