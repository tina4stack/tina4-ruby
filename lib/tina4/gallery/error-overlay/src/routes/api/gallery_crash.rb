# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Gallery: Error Overlay — deliberately crash to demo the debug overlay.
#
# This route deliberately raises an error to showcase the error overlay.
#
# In debug mode (TINA4_DEBUG=true), you will see:
# - Exception type and message
# - Stack trace with syntax-highlighted source code
# - The exact line that caused the error (highlighted)
# - Request details (method, path, headers)
# - Environment info (framework version, Ruby version)

Tina4::Router.get("/api/gallery/crash") do |request, response|
  # Simulate a realistic error — accessing a missing key
  user = { name: "Alice", email: "alice@example.com" }
  role = user.fetch(:role) # KeyError: key not found: :role — this line will be highlighted in the overlay
  response.json({ role: role })
end
