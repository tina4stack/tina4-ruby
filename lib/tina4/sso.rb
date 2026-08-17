# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Tina4
  class SsoError < StandardError; end

  # Provider-neutral, configuration-first OpenID Connect SSO.
  class Sso
    PENDING_KEY = "_tina4_sso_pending"
    SESSION_KEY = "_tina4_sso"
    attr_reader :issuer, :client_id, :client_secret, :redirect_uri, :scopes,
                :verify, :post_logout_redirect_uri, :claim_map
    @mounted = false

    def initialize(options = {})
      @issuer = (options[:issuer] || ENV["TINA4_SSO_ISSUER"] || "").sub(%r{/$}, "")
      @client_id = options[:client_id] || ENV["TINA4_SSO_CLIENT_ID"] || ""
      @client_secret = options.key?(:client_secret) ? options[:client_secret] : ENV["TINA4_SSO_CLIENT_SECRET"]
      @redirect_uri = options[:redirect_uri] || ENV["TINA4_SSO_REDIRECT_URI"] || ""
      @scopes = options[:scopes] || json_env("TINA4_SSO_SCOPES", %w[openid profile email])
      @verify = (options[:verify] || ENV["TINA4_SSO_VERIFY"] || "introspection").downcase
      @post_logout_redirect_uri = options[:post_logout_redirect_uri] || ENV["TINA4_SSO_POST_LOGOUT_REDIRECT_URI"]
      @claim_map = options[:claim_map] || json_env("TINA4_SSO_CLAIM_MAP", {})
      @metadata = {}
      validate_config!
    end

    def self.from_issuer(options = {})
      new(options).tap(&:discover)
    end

    def self.configured?
      %w[TINA4_SSO_ISSUER TINA4_SSO_CLIENT_ID TINA4_SSO_REDIRECT_URI].all? { |key| !ENV[key].to_s.empty? }
    end

    def json_env(name, fallback)
      raw = ENV[name]
      raw.nil? || raw.empty? ? fallback : JSON.parse(raw)
    rescue JSON::ParserError => e
      raise SsoError, "#{name} must be valid JSON", cause: e
    end

    def self.secure_url!(value, name)
      uri = URI.parse(value)
      raise SsoError, "#{name} must be an absolute URL" unless uri.absolute? && uri.host

      loopback = %w[localhost 127.0.0.1 ::1].include?(uri.host)
      raise SsoError, "#{name} must use HTTPS except on loopback" unless uri.scheme == "https" || (uri.scheme == "http" && loopback)
    rescue URI::InvalidURIError => e
      raise SsoError, "#{name} must be an absolute URL", cause: e
    end

    def validate_config!
      if @issuer.empty? || @client_id.empty? || @redirect_uri.empty?
        raise SsoError, "TINA4_SSO_ISSUER, TINA4_SSO_CLIENT_ID and TINA4_SSO_REDIRECT_URI are required"
      end
      self.class.secure_url!(@issuer, "issuer")
      self.class.secure_url!(@redirect_uri, "redirect URI")
      raise SsoError, "TINA4_SSO_VERIFY must be introspection or jwks" unless %w[introspection jwks].include?(@verify)
      raise SsoError, "jwks verification requires an installed cryptography capability" if @verify == "jwks"
      raise SsoError, "introspection verification requires TINA4_SSO_CLIENT_SECRET" if @verify == "introspection" && @client_secret.to_s.empty?
      raise SsoError, "TINA4_SSO_SCOPES must be a list containing openid" unless @scopes.is_a?(Array) && @scopes.include?("openid")
    end

    def request_json(url, form: nil, bearer: nil, basic: false)
      uri = URI.parse(url)
      request = form ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request.set_form_data(form.transform_values(&:to_s)) if form
      request["Authorization"] = "Bearer #{bearer}" if bearer
      request.basic_auth(@client_id, @client_secret) if basic
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = 10
      http.read_timeout = 10
      response = http.request(request)
      raise SsoError, "OIDC provider request failed" unless response.is_a?(Net::HTTPSuccess)
      result = JSON.parse(response.body)
      raise SsoError, "OIDC provider returned a non-object response" unless result.is_a?(Hash)
      result
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error => e
      raise SsoError, "OIDC provider request failed", cause: e
    end

    def discover(force = false)
      return @metadata.dup unless @metadata.empty? || force
      result = request_json("#{@issuer}/.well-known/openid-configuration")
      raise SsoError, "OIDC discovery issuer does not exactly match configuration" unless result["issuer"] == @issuer
      required = %w[authorization_endpoint token_endpoint]
      required << "introspection_endpoint" if @verify == "introspection"
      required.each do |key|
        raise SsoError, "OIDC discovery is missing #{key}" if result[key].to_s.empty?
        self.class.secure_url!(result[key], key)
      end
      @metadata = result
      result.dup
    end

    def self.safe_return(value)
      return "/" if value.to_s.empty? || !value.start_with?("/") || value.start_with?("//") || value.include?("\\")
      value.each_byte.any? { |byte| byte < 32 } ? "/" : value
    end

    def session(value)
      value.is_a?(Tina4::Session) ? value : value&.session
    end

    def login(request_or_session, return_to = "/")
      current = session(request_or_session)
      raise SsoError, "SSO login requires a Tina4 Session" unless current
      state = SecureRandom.urlsafe_base64(32)
      nonce = SecureRandom.urlsafe_base64(32)
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      current.set(PENDING_KEY, {
                    "state" => state, "nonce" => nonce, "verifier" => verifier,
                    "return_to" => self.class.safe_return(return_to), "created_at" => Time.now.to_i
                  })
      query = URI.encode_www_form(
        client_id: @client_id, redirect_uri: @redirect_uri, response_type: "code",
        scope: @scopes.join(" "), state: state, nonce: nonce,
        code_challenge: challenge, code_challenge_method: "S256"
      )
      "#{discover['authorization_endpoint']}?#{query}"
    end

    def self.secure_equal(left, right)
      a = left.to_s
      b = right.to_s
      a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
    end

    def self.jwt_payload(token)
      part = token.split(".")[1].to_s
      JSON.parse(Base64.urlsafe_decode64(part.ljust((part.length + 3) / 4 * 4, "=")))
    rescue JSON::ParserError, ArgumentError
      raise SsoError, "provider returned an invalid ID token"
    end

    def introspect(access_token)
      result = request_json(discover["introspection_endpoint"],
                            form: { token: access_token, token_type_hint: "access_token" }, basic: true)
      unless result["active"] == true && result["iss"] == @issuer
        raise SsoError, "OIDC access token is inactive or has the wrong issuer"
      end
      audience = result["aud"] || result["client_id"]
      valid = audience.is_a?(Array) ? audience.include?(@client_id) : audience == @client_id
      valid ||= result["client_id"] == @client_id
      raise SsoError, "OIDC token audience mismatch" unless valid
      result
    end

    def claim(claims, configured, fallback)
      (configured || fallback).split(".").reduce(claims) { |value, key| value.is_a?(Hash) ? value[key] : nil }
    end

    def normalize(claims)
      subject = claim(claims, @claim_map["subject"], "sub")
      identity_issuer = claim(claims, @claim_map["issuer"], "iss") || @issuer
      raise SsoError, "OIDC identity is missing a valid issuer or subject" if subject.to_s.empty? || identity_issuer != @issuer
      roles = Array(claim(claims, @claim_map["roles"], "realm_access.roles"))
      roles += Array(claims.dig("resource_access", @client_id, "roles"))
      groups = Array(claim(claims, @claim_map["groups"], "groups"))
      {
        "issuer" => identity_issuer, "subject" => subject,
        "username" => claim(claims, @claim_map["username"], "preferred_username"),
        "email" => claim(claims, @claim_map["email"], "email"),
        "name" => claim(claims, @claim_map["name"], "name"),
        "roles" => roles.map(&:to_s).uniq.sort, "groups" => groups.map(&:to_s).uniq.sort
      }
    end

    def callback(request_or_session, query = nil)
      current = session(request_or_session)
      values = query || request_or_session.params
      pending = current&.get(PENDING_KEY)
      current&.delete(PENDING_KEY)
      unless pending.is_a?(Hash) && !values["code"].to_s.empty? && self.class.secure_equal(values["state"], pending["state"])
        raise SsoError, "OIDC callback state is invalid or already consumed"
      end
      raise SsoError, "OIDC callback state has expired" if Time.now.to_i - pending.fetch("created_at", 0).to_i > 600
      metadata = discover
      tokens = request_json(metadata["token_endpoint"], form: {
                              grant_type: "authorization_code", code: values["code"], redirect_uri: @redirect_uri,
                              client_id: @client_id, code_verifier: pending["verifier"]
                            }, basic: !@client_secret.to_s.empty?)
      raise SsoError, "OIDC token response is incomplete" if tokens["access_token"].to_s.empty? || tokens["id_token"].to_s.empty?
      raise SsoError, "JWKS verification requires an installed cryptography capability" if @verify == "jwks"
      claims = introspect(tokens["access_token"])
      unless self.class.secure_equal(self.class.jwt_payload(tokens["id_token"])["nonce"], pending["nonce"])
        raise SsoError, "OIDC ID token nonce mismatch"
      end
      claims.merge!(request_json(metadata["userinfo_endpoint"], bearer: tokens["access_token"])) if metadata["userinfo_endpoint"]
      identity = normalize(claims)
      current.regenerate
      current.set(SESSION_KEY, {
                    "version" => 1, "identity" => identity, "access_token" => tokens["access_token"],
                    "refresh_token" => tokens["refresh_token"], "id_token" => tokens["id_token"],
                    "expires_at" => Time.now.to_i + tokens.fetch("expires_in", 0).to_i
                  })
      { "identity" => identity, "return_to" => self.class.safe_return(pending["return_to"]) }
    end

    def identity(request_or_session)
      stored = session(request_or_session)&.get(SESSION_KEY)
      value = stored.is_a?(Hash) ? stored["identity"] : nil
      request_or_session.user = value if value && !request_or_session.is_a?(Tina4::Session)
      value
    end

    def refresh(request_or_session)
      current = session(request_or_session)
      stored = current&.get(SESSION_KEY)
      unless stored.is_a?(Hash) && !stored["refresh_token"].to_s.empty?
        current&.delete(SESSION_KEY)
        raise SsoError, "OIDC session cannot be refreshed"
      end
      metadata = discover
      tokens = request_json(metadata["token_endpoint"], form: {
                              grant_type: "refresh_token", refresh_token: stored["refresh_token"], client_id: @client_id
                            }, basic: !@client_secret.to_s.empty?)
      claims = introspect(tokens["access_token"])
      claims.merge!(request_json(metadata["userinfo_endpoint"], bearer: tokens["access_token"])) if metadata["userinfo_endpoint"]
      value = normalize(claims)
      current.set(SESSION_KEY, stored.merge(
        "identity" => value, "access_token" => tokens["access_token"],
        "refresh_token" => tokens["refresh_token"] || stored["refresh_token"],
        "id_token" => tokens["id_token"] || stored["id_token"],
        "expires_at" => Time.now.to_i + tokens.fetch("expires_in", 0).to_i
      ))
      value
    rescue StandardError
      current&.delete(SESSION_KEY)
      raise
    end

    def logout(request_or_session, return_to = "/")
      current = session(request_or_session)
      stored = current&.get(SESSION_KEY)
      current&.destroy
      endpoint = discover["end_session_endpoint"]
      target = @post_logout_redirect_uri || self.class.safe_return(return_to)
      return target unless endpoint
      params = { post_logout_redirect_uri: target, client_id: @client_id }
      params[:id_token_hint] = stored["id_token"] if stored.is_a?(Hash) && stored["id_token"]
      "#{endpoint}?#{URI.encode_www_form(params)}"
    end

    def self.mount_configured
      return false if @mounted || !configured?
      owned = [["GET", "/auth/login"], ["GET", "/auth/callback"], ["POST", "/auth/logout"]]
      collisions = Tina4::Router.routes.select { |route| owned.include?([route.method, route.path]) }
      unless collisions.empty?
        raise SsoError, "SSO route collision: #{collisions.map { |route| "#{route.method} #{route.path}" }.join(', ')}"
      end
      sso = from_issuer
      Tina4::Router.get("/auth/login") do |request, response|
        response.redirect(sso.login(request, request.params["return_to"] || "/"))
      end
      Tina4::Router.get("/auth/callback") do |request, response|
        begin
          response.redirect(sso.callback(request)["return_to"])
        rescue SsoError => e
          response.json({ error: "SSO_CALLBACK_FAILED", message: e.message }, 400)
        end
      end
      Tina4::Router.post("/auth/logout") do |request, response|
        response.redirect(sso.logout(request, request.params["return_to"] || "/"))
      end
      @mounted = true
      true
    end
  end

  SSO = Sso
end
