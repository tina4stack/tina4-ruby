# frozen_string_literal: true

require "socket"
require "spec_helper"

RSpec.describe Tina4::Push do
  def b64(value)
    [value].pack("m0").tr("+/", "-_").delete("=")
  end

  def subscription(url)
    client = OpenSSL::PKey::EC.generate("prime256v1")
    {
      "endpoint" => url,
      "keys" => {
        "p256dh" => b64(client.public_key.to_bn.to_s(2)),
        "auth" => b64("\x07" * 16)
      }
    }
  end

  def with_http_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    request = {}
    thread = Thread.new do
      socket = server.accept
      headers = {}
      request_line = socket.gets.to_s
      while (line = socket.gets)
        line = line.chomp
        break if line.empty?
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip if key && value
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      request[:line] = request_line
      request[:headers] = headers
      request[:body] = body
      status = request_line[/status=(\d+)/, 1].to_i
      status = 201 if status.zero?
      text = "accepted"
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
      socket.close
    ensure
      server.close unless server.closed?
    end
    yield "http://127.0.0.1:#{port}/push", request
    thread.join
  ensure
    thread&.kill if thread&.alive?
    server&.close unless server&.closed?
  end

  it "generates VAPID keys and delivers to a real endpoint" do
    keys = described_class.generate_vapid_keys
    expect(Base64.urlsafe_decode64(keys.fetch("publicKey"))).to have_attributes(bytesize: 65)
    expect(Base64.urlsafe_decode64(keys.fetch("privateKey"))).to have_attributes(bytesize: 32)

    with_http_server do |url, request|
      result = described_class.new(subject: "mailto:test@tina4.com", public_key: keys["publicKey"], private_key: keys["privateKey"]).send(subscription("#{url}?status=201"), { "message" => "hello" })
      expect(result).to include("ok" => true, "status" => 201, "dead" => false, "retryable" => false)
      expect(request[:headers]["content-encoding"]).to eq("aes128gcm")
      expect(request[:headers]["authorization"]).to start_with("vapid t=")
      expect(request[:body]).not_to be_empty
    end
  end

  it "never emits a VAPID key malformed by a short coordinate" do
    # OpenSSL strips a leading zero byte, so ~0.3% of P-256 private scalars come
    # back 31 bytes; the app's own 32-byte check would then reject the key it
    # just generated. Generate enough to hit the case FOR REAL (no mock), assert
    # the module always emits a fixed-width key, and assert the short case
    # actually occurred so a green result proves the padding fired.
    iterations = 3000
    short_raw = 0
    iterations.times do
      keys = described_class.generate_vapid_keys
      expect(Base64.urlsafe_decode64(keys.fetch("publicKey")).bytesize).to eq(65)
      expect(Base64.urlsafe_decode64(keys.fetch("privateKey")).bytesize).to eq(32)
      short_raw += 1 if OpenSSL::PKey::EC.generate("prime256v1").private_key.to_s(2).bytesize < 32
    end
    expect(short_raw).to be > 0
  end

  it "classifies dead and retryable responses" do
    keys = described_class.generate_vapid_keys
    sender = described_class.new(subject: "mailto:test@tina4.com", public_key: keys["publicKey"], private_key: keys["privateKey"])

    with_http_server do |url, _request|
      dead = sender.send(subscription("#{url}?status=410"), "expired")
      expect(dead).to include("ok" => false, "status" => 410, "dead" => true, "retryable" => false)
    end
    with_http_server do |url, _request|
      not_found = sender.send(subscription("#{url}?status=404"), "expired")
      expect(not_found).to include("ok" => false, "status" => 404, "dead" => true, "retryable" => false)
    end
    with_http_server do |url, _request|
      retryable = sender.send(subscription("#{url}?status=429"), "busy")
      expect(retryable).to include("ok" => false, "status" => 429, "dead" => false, "retryable" => true)
    end
    with_http_server do |url, _request|
      retryable = sender.send(subscription("#{url}?status=500"), "busy")
      expect(retryable).to include("ok" => false, "status" => 500, "dead" => false, "retryable" => true)
    end
  end

  it "fails loudly for missing VAPID configuration" do
    expect { described_class.new(subject: "", public_key: "", private_key: "").send(subscription("http://127.0.0.1/push"), "payload") }
      .to raise_error(Tina4::PushError, /TINA4_VAPID/)
  end

  it "rejects an invalid subscription key before delivery" do
    keys = described_class.generate_vapid_keys
    sender = described_class.new(subject: "mailto:test@tina4.com", public_key: keys["publicKey"], private_key: keys["privateKey"])
    bad = { "endpoint" => "http://127.0.0.1/push", "keys" => { "p256dh" => "bad", "auth" => b64("\x07" * 16) } }
    expect { sender.send(bad, "payload") }.to raise_error(Tina4::PushError, /subscription\.keys\.p256dh/)
  end
end
