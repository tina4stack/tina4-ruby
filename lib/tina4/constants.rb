# Tina4 Constants — HTTP status codes and content types.
#
# Standard constants for use in route handlers across all Tina4 frameworks.
#
#   Tina4.get "/api/users" do |request, response|
#     response.call(users, Tina4::HTTP_OK)
#   end

module Tina4
  # ── HTTP Status Codes ──

  HTTP_OK = 200
  HTTP_CREATED = 201
  HTTP_ACCEPTED = 202
  HTTP_NO_CONTENT = 204

  HTTP_MOVED = 301
  HTTP_REDIRECT = 302
  HTTP_NOT_MODIFIED = 304

  HTTP_BAD_REQUEST = 400
  HTTP_UNAUTHORIZED = 401
  HTTP_FORBIDDEN = 403
  HTTP_NOT_FOUND = 404
  HTTP_METHOD_NOT_ALLOWED = 405
  HTTP_CONFLICT = 409
  HTTP_GONE = 410
  HTTP_UNPROCESSABLE = 422
  HTTP_TOO_MANY = 429

  HTTP_SERVER_ERROR = 500
  HTTP_BAD_GATEWAY = 502
  HTTP_UNAVAILABLE = 503

  # ── Content Types ──

  APPLICATION_JSON = "application/json"
  APPLICATION_XML = "application/xml"
  APPLICATION_FORM = "application/x-www-form-urlencoded"
  APPLICATION_OCTET = "application/octet-stream"

  TEXT_HTML = "text/html; charset=utf-8"
  TEXT_PLAIN = "text/plain; charset=utf-8"
  TEXT_CSV = "text/csv"
  TEXT_XML = "text/xml"

  # ── HTTP Reason Phrases (RFC 7231 / RFC 9110) ──
  #
  # Used to write a correct HTTP/1.1 status line wherever the framework
  # emits one manually. Previously code paths that built the status line
  # by hand wrote "HTTP/1.1 404 OK" regardless of code, which is
  # malformed. ``Tina4.http_reason(status)`` always returns a non-empty
  # phrase that matches the status family.
  HTTP_REASON_PHRASES = {
    100 => "Continue", 101 => "Switching Protocols",
    200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
    206 => "Partial Content",
    301 => "Moved Permanently", 302 => "Found", 303 => "See Other",
    304 => "Not Modified", 307 => "Temporary Redirect", 308 => "Permanent Redirect",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 406 => "Not Acceptable",
    409 => "Conflict", 410 => "Gone", 413 => "Content Too Large",
    415 => "Unsupported Media Type", 422 => "Unprocessable Content",
    429 => "Too Many Requests",
    500 => "Internal Server Error", 501 => "Not Implemented",
    502 => "Bad Gateway", 503 => "Service Unavailable", 504 => "Gateway Timeout"
  }.freeze

  # Return the canonical HTTP reason phrase for ``status``.
  #
  # Falls back to a sensible label when an exotic status is used. Never
  # returns an empty string — the HTTP/1.1 status line requires a phrase.
  # Prefers Rack::Utils::HTTP_STATUS_CODES when Rack is available so the
  # phrase tracks Rack's mapping, otherwise uses the local table above.
  def self.http_reason(status)
    code = status.to_i
    if defined?(Rack::Utils::HTTP_STATUS_CODES)
      phrase = Rack::Utils::HTTP_STATUS_CODES[code]
      return phrase if phrase && !phrase.empty?
    end
    phrase = HTTP_REASON_PHRASES[code]
    return phrase if phrase && !phrase.empty?
    return "OK" if code >= 200 && code < 300
    "Error"
  end
end
