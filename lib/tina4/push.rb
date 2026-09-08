# frozen_string_literal: true

require "openssl"
require "base64"
require "json"
require "net/http"
require "uri"

module Tina4
  class PushError < StandardError; end

  # Provider-neutral Web Push sender using Ruby's stdlib OpenSSL and Net::HTTP.
  # Web Push remains optional at use time; a Ruby build without OpenSSL fails
  # loudly when the feature is selected rather than silently sending plaintext.
  class Push
    RECORD_SIZE = 4096
    MAX_PAYLOAD = RECORD_SIZE - 17

    def self.generate_vapid_keys
      require_openssl
      key = OpenSSL::PKey::EC.generate("prime256v1")
      {
        # The public point keeps its width -- the 0x04 lead byte is non-zero, so
        # to_s(2) never drops it. The private SCALAR has no such guard: OpenSSL
        # strips a leading zero byte, so ~0.3% of keys come back 31 bytes and the
        # app's own 32-byte validation would then reject the key it just made.
        "publicKey" => b64(key.public_key.to_bn.to_s(2)),
        "privateKey" => b64(pad32(key.private_key.to_s(2)))
      }
    end

    # Left-pad big-endian EC material to the fixed 32-byte P-256 field width.
    def self.pad32(bytes)
      bytes.b.rjust(32, "\x00".b)
    end

    def initialize(subject: nil, public_key: nil, private_key: nil, ttl: 60, urgency: nil)
      @subject = (subject || ENV.fetch("TINA4_VAPID_SUBJECT", "")).strip
      @public_key = (public_key || ENV.fetch("TINA4_VAPID_PUBLIC", "")).strip
      @private_key = (private_key || ENV.fetch("TINA4_VAPID_PRIVATE", "")).strip
      @ttl = ttl
      @urgency = urgency
      if %w[0 false off no].include?(ENV.fetch("TINA4_WEB_PUSH", "").strip.downcase)
        raise PushError, "Web Push is disabled by TINA4_WEB_PUSH"
      end
      configuration if [@subject, @public_key, @private_key].any? { |value| !value.empty? }
    end

    def send(subscription, payload)
      endpoint, uri = endpoint_for(subscription)
      subject, public_key, private_key = configuration
      public, private = vapid_keys(public_key, private_key)
      deliver(endpoint, uri, subject, public_key, private, public, encrypt(payload_bytes(payload), subscription))
    rescue URI::InvalidURIError => e
      raise PushError, "Push subscription endpoint must be a valid URL: #{e.message}"
    rescue Net::HTTPError, SocketError, SystemCallError => e
      raise PushError, "Web Push request failed: #{e.message}"
    end

    private

    def endpoint_for(subscription)
      endpoint = subscription.is_a?(Hash) ? (subscription["endpoint"] || subscription[:endpoint]) : nil
      raise PushError, "A Web Push subscription with an endpoint is required" unless endpoint.is_a?(String) && !endpoint.empty?
      uri = URI.parse(endpoint)
      raise PushError, "Push subscription endpoint must use HTTP or HTTPS" unless %w[http https].include?(uri.scheme) && uri.host
      [endpoint, uri]
    end

    def vapid_keys(public_key, private_key)
      public = decode(public_key, "TINA4_VAPID_PUBLIC")
      private = decode(private_key, "TINA4_VAPID_PRIVATE")
      raise PushError, "TINA4_VAPID_PUBLIC must be a 65-byte P-256 public key" unless public.bytesize == 65 && public.getbyte(0) == 4
      raise PushError, "TINA4_VAPID_PRIVATE must be a 32-byte P-256 private key" unless private.bytesize == 32
      begin
        derived = private_key_from_raw(private, public).public_key.to_bn.to_s(2)
      rescue OpenSSL::PKey::PKeyError => e
        raise PushError, "TINA4_VAPID_PRIVATE is not a valid P-256 private key: #{e.message}"
      end
      raise PushError, "TINA4_VAPID_PUBLIC does not match TINA4_VAPID_PRIVATE" unless derived == public
      [public, private]
    end

    def deliver(endpoint, uri, subject, public_key, private, public, body)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "vapid t=#{vapid_token(uri, subject, private, public)}, k=#{public_key}"
      request["Content-Encoding"] = "aes128gcm"
      request["Content-Type"] = "application/octet-stream"
      request["TTL"] = @ttl.to_i.to_s
      request["Urgency"] = @urgency if @urgency && !@urgency.empty?
      request.body = body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      response = http.start { |client| client.request(request) }
      status = response.code.to_i
      { "ok" => status < 400, "status" => status, "dead" => [404, 410].include?(status), "retryable" => [408, 429].include?(status) || status >= 500, "endpoint" => endpoint, "response" => response.body.to_s }
    end

    def configuration
      missing = []
      missing << "TINA4_VAPID_SUBJECT" if @subject.empty?
      missing << "TINA4_VAPID_PUBLIC" if @public_key.empty?
      missing << "TINA4_VAPID_PRIVATE" if @private_key.empty?
      raise PushError, "Web Push is configured but missing: #{missing.join(', ')}" unless missing.empty?
      self.class.send(:require_openssl)
      [@subject, @public_key, @private_key]
    end

    def self.require_openssl
      return if defined?(OpenSSL::PKey::EC)

      raise PushError, "Web Push requires Ruby's OpenSSL stdlib capability; rebuild Ruby with OpenSSL support"
    end

    def self.b64(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def decode(value, name)
      raise PushError, "#{name} must be a non-empty base64url string" unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+\z/)

      Base64.urlsafe_decode64(value)
    rescue ArgumentError => e
      raise PushError, "#{name} must be base64url encoded: #{e.message}"
    end

    def payload_bytes(payload)
      return payload.b if payload.is_a?(String)
      JSON.generate(payload)
    rescue JSON::GeneratorError => e
      raise PushError, "Push payload is not JSON serializable: #{e.message}"
    end

    def private_key_from_raw(private, public)
      body = OpenSSL::ASN1::Sequence.new([
        OpenSSL::ASN1::Integer.new(1),
        OpenSSL::ASN1::OctetString.new(private),
        OpenSSL::ASN1::ASN1Data.new([OpenSSL::ASN1::ObjectId.new("prime256v1")], 0, :CONTEXT_SPECIFIC),
        OpenSSL::ASN1::ASN1Data.new([OpenSSL::ASN1::BitString.new(public)], 1, :CONTEXT_SPECIFIC)
      ])
      OpenSSL::PKey.read(body.to_der)
    end

    def public_key_from_raw(public)
      algorithm = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::ObjectId.new("id-ecPublicKey"), OpenSSL::ASN1::ObjectId.new("prime256v1")])
      OpenSSL::PKey.read(OpenSSL::ASN1::Sequence.new([algorithm, OpenSSL::ASN1::BitString.new(public)]).to_der)
    end

    def encrypt(payload, subscription)
      raise PushError, "Push payload is too large; maximum is #{MAX_PAYLOAD} bytes" if payload.bytesize > MAX_PAYLOAD
      keys = subscription.is_a?(Hash) ? (subscription["keys"] || subscription[:keys] || {}) : {}
      p256dh = keys["p256dh"] || keys[:p256dh]
      auth = keys["auth"] || keys[:auth]
      client = decode(p256dh.to_s, "subscription.keys.p256dh")
      auth_secret = decode(auth.to_s, "subscription.keys.auth")
      raise PushError, "subscription.keys.p256dh must be a 65-byte P-256 public key" unless client.bytesize == 65 && client.getbyte(0) == 4
      raise PushError, "subscription.keys.auth must be a 16-byte authentication secret" unless auth_secret.bytesize == 16

      ephemeral = OpenSSL::PKey::EC.generate("prime256v1")
      server = ephemeral.public_key.to_bn.to_s(2)
      shared = ephemeral.derive(public_key_from_raw(client))
      ikm = hkdf(hmac(auth_secret, shared), "WebPush: info\0" + client + server, 32)
      salt = OpenSSL::Random.random_bytes(16)
      prk = hmac(salt, ikm)
      cek = hkdf(prk, "Content-Encoding: aes128gcm\0", 16)
      nonce = hkdf(prk, "Content-Encoding: nonce\0", 12)
      cipher = OpenSSL::Cipher.new("aes-128-gcm")
      cipher.encrypt
      cipher.key = cek
      cipher.iv = nonce
      ciphertext = cipher.update(payload + "\x02") + cipher.final
      tag = cipher.auth_tag
      salt + [RECORD_SIZE].pack("N") + [server.bytesize].pack("C") + server + ciphertext + tag
    end

    def hmac(key, value)
      OpenSSL::HMAC.digest(OpenSSL::Digest::SHA256.new, key, value)
    end

    def hkdf(prk, info, length)
      output = +""
      previous = +""
      counter = 1
      while output.bytesize < length
        previous = hmac(prk, previous + info + [counter].pack("C"))
        output << previous
        counter += 1
        raise PushError, "HKDF output is too large" if counter > 255
      end
      output.byteslice(0, length)
    end

    def vapid_token(uri, subject, private, public)
      aud = "#{uri.scheme}://#{uri.host}#{uri.port && ![80, 443].include?(uri.port) ? ":#{uri.port}" : ""}"
      header = self.class.send(:b64, JSON.generate({ typ: "JWT", alg: "ES256" }))
      claims = self.class.send(:b64, JSON.generate({ aud: aud, exp: Time.now.to_i + 43_200, sub: subject }))
      input = "#{header}.#{claims}"
      signature = private_key_from_raw(private, public).sign(OpenSSL::Digest::SHA256.new, input)
      asn = OpenSSL::ASN1.decode(signature)
      raw = [asn.value[0].value.to_s(2), asn.value[1].value.to_s(2)].map { |value| value.rjust(32, "\0") }.join
      "#{input}.#{self.class.send(:b64, raw)}"
    end
  end
end
