# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "socket"
require "uri"

# A minimal but REAL OpenID Connect provider for the SSO specs: a stdlib
# TCPServer on a real loopback port speaking plain HTTP/1.1, serving every
# endpoint Tina4::Sso talks to. It is not a double - Sso reaches it through
# Net::HTTP exactly as it reaches Keycloak in production, and it enforces the
# parts of the protocol a broken client would get wrong:
#
#   /.well-known/openid-configuration  discovery (issuer must match exactly)
#   /authorize   issues a one-time code bound to the nonce + PKCE challenge and
#                302s back to redirect_uri with code + state
#   /token       exchanges the code ONCE, and only for the matching
#                code_verifier (S256)
#   /introspect  requires the client's Basic credentials
#
# It deliberately does not run on Tina4's own server: the provider is the
# other side of the wire, and must not share code with the framework under
# test. (It used WEBrick until tina4-ruby dropped that gem.)
#
# Used by the issue #134/#135 specs, spec/sso_builtin_mount_query_spec.rb and
# spec/security_headers_every_response_contract_spec.rb.
class LocalOidcProvider
  attr_reader :issuer, :client_id, :client_secret, :subject

  def self.free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def initialize(client_id:, client_secret:, subject: "user-sso")
    @client_id = client_id
    @client_secret = client_secret
    @subject = subject
    @codes = {}
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @issuer = "http://127.0.0.1:#{@server.addr[1]}"
  end

  def start
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def stop
    @server.close
    @thread&.join(5)
  end

  private

  # One request per connection: read the head and a Content-Length body,
  # answer, close.
  def serve(socket)
    request_line = socket.gets("\r\n").to_s
    method, target = request_line.split(" ", 3)
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i).to_s : ""
    uri = URI.parse(target.to_s)
    query = URI.decode_www_form(uri.query.to_s).to_h
    query.merge!(URI.decode_www_form(body).to_h) if method == "POST"
    status, extra_headers, response_body = route(uri.path, query, headers)
    reason = { 200 => "OK", 302 => "Found", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found" }[status]
    head = +"HTTP/1.1 #{status} #{reason}\r\nContent-Length: #{response_body.bytesize}\r\nConnection: close\r\n"
    extra_headers.each { |name, value| head << "#{name}: #{value}\r\n" }
    socket.write(head, "\r\n", response_body)
  rescue StandardError
    nil
  ensure
    socket.close rescue nil
  end

  def route(path, query, headers)
    case path
    when "/.well-known/openid-configuration"
      json("issuer" => @issuer, "authorization_endpoint" => "#{@issuer}/authorize",
           "token_endpoint" => "#{@issuer}/token", "introspection_endpoint" => "#{@issuer}/introspect")
    when "/authorize" then authorize(query)
    when "/token" then token(query)
    when "/introspect" then introspect(headers)
    else [404, {}, ""]
    end
  end

  # base64url without padding, on String#pack (no base64 gem: it left the
  # default gems in Ruby 3.4).
  def b64(value)
    [value].pack("m0").tr("+/", "-_").delete("=")
  end

  def json(body, status = 200)
    [status, { "Content-Type" => "application/json" }, JSON.generate(body)]
  end

  def authorize(query)
    code = SecureRandom.hex(16)
    @lock.synchronize { @codes[code] = { "nonce" => query["nonce"], "challenge" => query["code_challenge"] } }
    [302, { "Location" => "#{query['redirect_uri']}?#{URI.encode_www_form(code: code, state: query['state'])}" }, ""]
  end

  def token(query)
    grant = @lock.synchronize { @codes.delete(query["code"]) }
    verifier = query["code_verifier"].to_s
    return json({ "error" => "invalid_grant" }, 400) if grant.nil? || b64(Digest::SHA256.digest(verifier)) != grant["challenge"]

    header = b64(JSON.generate("alg" => "none"))
    payload = b64(JSON.generate("iss" => @issuer, "sub" => @subject, "nonce" => grant["nonce"]))
    json("access_token" => "at-#{SecureRandom.hex(8)}", "id_token" => "#{header}.#{payload}.sig",
         "refresh_token" => "rt", "expires_in" => 300)
  end

  def introspect(headers)
    user, pass = headers["authorization"].to_s.sub("Basic ", "").unpack1("m").split(":", 2)
    return json({ "error" => "unauthorized" }, 401) unless user == @client_id && pass == @client_secret

    json("active" => true, "iss" => @issuer, "aud" => @client_id, "sub" => @subject, "preferred_username" => "ada")
  end
end
