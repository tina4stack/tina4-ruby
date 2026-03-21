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
