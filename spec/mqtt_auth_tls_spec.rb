# frozen_string_literal: true

# MQTT username/password authentication and TLS (mqtts://), against REAL
# Eclipse Mosquitto listeners.
#
# NO mocks, doubles, fakes or in-test brokers. Broker layout (stood up by
# spec/support/mqtt-infra.sh, mirrored in CI):
#
#   1883  anonymous
#   1884  allow_anonymous false + password_file   -> the auth examples
#   8883  TLS, self-signed CA                     -> the mqtts examples
#
# Ported from plan/v3/spikes/mqtt_spike3_auth_tls.py (13/13 against the same
# brokers). Every example names the bug it fails for.
#
# The TLS examples here matter more than they look. A TLS test suite passes just
# as happily with verification switched off, and then "we have TLS" quietly means
# "we trust any certificate" — so the load-bearing assertions are the NEGATIVE
# ones: a self-signed certificate must be REJECTED when its CA is not supplied,
# and supplying a CA for one client must not make a LATER client trust it.

require "spec_helper"
require_relative "support/mqtt_helpers"
require "securerandom"
require "openssl"

RSpec.describe "Tina4::Mqtt authentication and TLS" do
  let(:run_id) { "#{Process.pid}-#{SecureRandom.hex(4)}" }
  let(:prefix) { "tina4rb/authtls/#{run_id}" }
  let(:clients) { [] }

  def track(client)
    clients << client
    client
  end

  after do
    clients.each do |open_client|
      open_client.disconnect
    rescue StandardError
      nil
    end
  end

  # ── Username / password ──────────────────────────────────────────────────
  describe "username and password" do
    before do
      skip "Mosquitto MQTT broker with auth required not reachable at #{mqtt_auth_test_url}" unless
        mqtt_broker_reachable?(mqtt_auth_test_url)
    end

    it "authenticates with credentials taken from the url" do
      connection = track(Tina4::Mqtt.new(url: mqtt_auth_url_with(mqtt_test_username, mqtt_test_password),
                                         client_id: "#{run_id}-good", timeout: 5))
      expect(connection.connected?).to be true
      expect(connection.username).to eq(mqtt_test_username)

      # An authenticated connection is a working connection, not just a CONNACK:
      # the QoS 1 round-trip proves the packet after CONNECT still parses, which
      # is what a mis-sized credential payload would break.
      topic = "#{prefix}/authenticated"
      expect(connection.subscribe(topic, qos: 1)).to eq(1)
      expect(connection.publish(topic, "authenticated", qos: 1)).to be_a(Integer)
      expect(connection.receive(timeout: 3).payload).to eq("authenticated")
    end

    it "accepts credentials passed as keyword arguments" do
      connection = track(Tina4::Mqtt.new(url: mqtt_auth_test_url, client_id: "#{run_id}-kwargs",
                                         username: mqtt_test_username, password: mqtt_test_password,
                                         timeout: 5))
      expect(connection.connected?).to be true
    end

    it "lets explicit keyword credentials win over the url" do
      wrong_in_url = mqtt_auth_url_with(mqtt_test_username, "definitely-wrong")
      connection = track(Tina4::Mqtt.new(url: wrong_in_url, client_id: "#{run_id}-override",
                                         username: mqtt_test_username, password: mqtt_test_password,
                                         timeout: 5))
      expect(connection.connected?).to be true
    end

    it "refuses NO credentials on an auth-required listener (negative)" do
      # The listener refuses anonymous clients. Without per_listener_settings the
      # broker would silently accept this and the whole auth suite would pass for
      # the wrong reason, so this example is the one that keeps the others honest.
      expect { Tina4::Mqtt.new(url: mqtt_auth_test_url, client_id: "#{run_id}-nocreds", timeout: 5) }
        .to raise_error(Tina4::MqttError) { |error|
          expect(error.message).to match(/broker refused the connection/)
          expect(error.message).to match(/CONNACK return code [45]/)
        }
    end

    it "refuses a wrong password and names the CONNACK code (negative)" do
      expect {
        Tina4::Mqtt.new(url: mqtt_auth_url_with(mqtt_test_username, "wrong-password"),
                        client_id: "#{run_id}-badpass", timeout: 5)
      }.to raise_error(Tina4::MqttError, /CONNACK return code [45]/)
    end

    it "refuses an unknown username (negative)" do
      expect {
        Tina4::Mqtt.new(url: mqtt_auth_url_with("nobody", mqtt_test_password),
                        client_id: "#{run_id}-baduser", timeout: 5)
      }.to raise_error(Tina4::MqttError, /CONNACK return code [45]/)
    end

    it "still connects to an ANONYMOUS listener when credentials are supplied" do
      # Credentials the broker does not need must not break the CONNECT payload.
      connection = track(Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-anon-creds",
                                         username: mqtt_test_username, password: mqtt_test_password,
                                         timeout: 5))
      expect(connection.connected?).to be true
      expect(connection.publish("#{prefix}/anon", "fine", qos: 1)).to be_a(Integer)
    end

    it "refuses a password with no username, which MQTT 3.1.1 forbids (negative)" do
      expect {
        Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-passonly",
                        password: "orphan", connect: false)
      }.to raise_error(ArgumentError, /password without a username/)
    end
  end

  # ── url parsing for credentials (pure) ───────────────────────────────────
  describe ".parse_url with credentials" do
    it "splits the userinfo out of the url" do
      parsed = Tina4::Mqtt.parse_url("mqtt://device:s3cret@broker.example:1883")
      expect(parsed[:host]).to eq("broker.example")
      expect(parsed[:port]).to eq(1883)
      expect(parsed[:username]).to eq("device")
      expect(parsed[:password]).to eq("s3cret")
      expect(parsed[:tls]).to be false
    end

    it "accepts a username with no password" do
      parsed = Tina4::Mqtt.parse_url("mqtt://device@broker.example")
      expect(parsed[:username]).to eq("device")
      expect(parsed[:password]).to be_nil
    end

    it "percent-decodes credentials so a password may contain @ : and /" do
      parsed = Tina4::Mqtt.parse_url("mqtt://dev%40site:p%40ss%3Aword%2Fx@broker.example")
      expect(parsed[:username]).to eq("dev@site")
      expect(parsed[:password]).to eq("p@ss:word/x")
    end

    it "marks mqtts:// as TLS and defaults its port to 8883" do
      parsed = Tina4::Mqtt.parse_url("mqtts://broker.example")
      expect(parsed[:tls]).to be true
      expect(parsed[:port]).to eq(8883)
    end

    it "keeps mqtt:// on 1883 and NOT TLS (negative)" do
      parsed = Tina4::Mqtt.parse_url("mqtt://broker.example")
      expect(parsed[:tls]).to be false
      expect(parsed[:port]).to eq(1883)
    end

    it "still refuses a transport it does not speak (negative)" do
      expect { Tina4::Mqtt.parse_url("ws://broker.example:8083/mqtt") }
        .to raise_error(ArgumentError, /mqtt:\/\/, tcp:\/\/ or mqtts:\/\//)
    end
  end

  # ── TLS ──────────────────────────────────────────────────────────────────
  describe "TLS (mqtts://)" do
    before do
      skip "Mosquitto MQTT TLS broker not reachable at #{mqtt_tls_test_url}" unless
        mqtt_broker_reachable?(mqtt_tls_test_url)
      # Guard on "the CA VERIFIES the broker", not merely "a CA file exists" -- a
      # stale ca.crt from an earlier mqtt-infra.sh run otherwise makes these
      # examples run and fail on a cert mismatch (an env problem reported as six
      # code failures). See mqtt_ca_verifies? in spec/support/mqtt_helpers.rb.
      skip "MQTT test CA missing, or it does not verify the broker's certificate " \
           "(stale certs -- re-run mqtt-infra.sh, or export TINA4_TEST_MQTT_CA_FILE)" unless
        mqtt_ca_verifies?(mqtt_tls_test_url, mqtt_test_ca_file)
    end

    it "connects over TLS when the CA is supplied, and negotiates a real cipher" do
      connection = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls",
                                         ca_file: mqtt_test_ca_file, timeout: 5))
      expect(connection.connected?).to be true
      expect(connection.tls?).to be true

      # Not "did it connect" but "is it actually encrypted": a negotiated cipher
      # suite and a TLS protocol version can only come from a completed handshake.
      expect(connection.cipher).to be_a(String)
      expect(connection.cipher).not_to be_empty
      expect(connection.tls_version).to match(/\ATLSv1\.[23]\z/)
    end

    it "publishes and subscribes over TLS with the payload intact" do
      topic = "#{prefix}/over-tls"
      connection = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-rt",
                                         ca_file: mqtt_test_ca_file, timeout: 5))
      expect(connection.subscribe(topic, qos: 1)).to eq(1)
      connection.publish(topic, "over-tls", qos: 1)
      expect(connection.receive(timeout: 5).payload).to eq("over-tls")
    end

    it "reassembles a payload larger than one TLS record over TLS (trap 3, encrypted)" do
      # A TLS record is at most 16 KB, so a 1 MiB payload spans many records AND
      # leaves decrypted bytes buffered inside OpenSSL. A reader that waits on the
      # raw socket while plaintext already sits in the SSL buffer HANGS here.
      topic = "#{prefix}/tls-stream"
      connection = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-big",
                                         ca_file: mqtt_test_ca_file, timeout: 10, read_timeout: 20))
      connection.subscribe(topic, qos: 1)
      payload = SecureRandom.hex(524_288)
      connection.publish(topic, payload, qos: 1)
      received = connection.receive(timeout: 20)
      expect(received.payload.bytesize).to eq(1_048_576)
      expect(received.payload).to eq(payload)
    end

    it "REJECTS a self-signed certificate when the CA is not supplied (negative)" do
      # THE test. Everything else about TLS passes identically with verification
      # disabled; only this fails. If it ever goes green while the positive
      # example also passes, we are not verifying anything.
      expect { Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-noca", timeout: 5) }
        .to raise_error(Tina4::MqttError) { |error|
          expect(error.message).to match(/certificate verif|self-signed|unable to get local issuer/i)
        }
    end

    it "does not leak a client's CA into the process-wide trust store (negative)" do
      # Verified trap, 2026-07-23: OpenSSL::SSL::SSLContext#set_params installs
      # the SHARED DEFAULT_CERT_STORE, so a later `ctx.ca_file = path` writes the
      # CA into that shared store and EVERY subsequent client in the process
      # trusts it. Under a randomised suite that turns the negative above green
      # while proving nothing. Each client therefore builds its OWN X509::Store.
      trusted = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-first",
                                      ca_file: mqtt_test_ca_file, timeout: 5))
      expect(trusted.connected?).to be true

      expect { Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-second", timeout: 5) }
        .to raise_error(Tina4::MqttError, /certificate verif|self-signed|unable to get local issuer/i)
    end

    it "reads the CA from TINA4_MQTT_CA_FILE" do
      original = ENV.key?("TINA4_MQTT_CA_FILE") ? ENV["TINA4_MQTT_CA_FILE"] : :unset
      ENV["TINA4_MQTT_CA_FILE"] = mqtt_test_ca_file
      begin
        connection = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-env", timeout: 5))
        expect(connection.connected?).to be true
      ensure
        original == :unset ? ENV.delete("TINA4_MQTT_CA_FILE") : ENV["TINA4_MQTT_CA_FILE"] = original
      end
    end

    it "connects with verification OFF only when asked explicitly, and says so LOUDLY" do
      # Disabling verification is a foot-gun, so it is never the default and it
      # never happens quietly. Asserted against the REAL log file the real Logger
      # writes (same approach as spec/log_spec.rb) — nothing is stubbed.
      log_root = Dir.mktmpdir
      saved_output = ENV.key?("TINA4_LOG_OUTPUT") ? ENV["TINA4_LOG_OUTPUT"] : :unset
      begin
        ENV["TINA4_LOG_OUTPUT"] = "file"
        Tina4::Log.configure(log_root)

        insecure = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-insecure",
                                         tls_verify: false, timeout: 5))
        expect(insecure.connected?).to be true
        expect(insecure.tls?).to be true
        # Encrypted, yes — but the identity is NOT checked, which is the whole
        # point of the warning.
        expect(insecure.cipher).to be_a(String)

        # Explicit UTF-8: the log line is UTF-8 and Encoding.default_external is
        # US-ASCII under some CI locales, which makes a bare File.read raise.
        logged = File.read(File.join(log_root, "logs", "tina4.log"), encoding: "UTF-8")
        expect(logged).to match(/TLS certificate verification is DISABLED/)
        expect(logged).to include("man in the middle")
        expect(logged).to include("TINA4_MQTT_CA_FILE")
        expect(logged).to include("WARNING")
      ensure
        saved_output == :unset ? ENV.delete("TINA4_LOG_OUTPUT") : ENV["TINA4_LOG_OUTPUT"] = saved_output
        FileUtils.rm_rf(log_root)
      end
    end

    it "treats TINA4_MQTT_TLS_VERIFY=false as the explicit opt-out, and true as verifying (negative)" do
      original = ENV.key?("TINA4_MQTT_TLS_VERIFY") ? ENV["TINA4_MQTT_TLS_VERIFY"] : :unset
      begin
        ENV["TINA4_MQTT_TLS_VERIFY"] = "false"
        insecure = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-envoff", timeout: 5))
        expect(insecure.connected?).to be true

        # The negative half: the env var must not be a one-way door.
        ENV["TINA4_MQTT_TLS_VERIFY"] = "true"
        expect { Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-envon", timeout: 5) }
          .to raise_error(Tina4::MqttError, /certificate verif|self-signed|unable to get local issuer/i)
      ensure
        original == :unset ? ENV.delete("TINA4_MQTT_TLS_VERIFY") : ENV["TINA4_MQTT_TLS_VERIFY"] = original
      end
    end

    it "reports a missing CA file by path instead of failing the handshake obscurely (negative)" do
      expect {
        Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-nofile",
                        ca_file: "/nonexistent/tina4-ca.crt", timeout: 5)
      }.to raise_error(Tina4::MqttError, %r{/nonexistent/tina4-ca\.crt}) { |error|
        expect(error.message).to match(/CA file/i)
      }
    end

    it "authenticates AND encrypts on the same connection when both are configured" do
      # Nothing in the CONNECT payload may shift when TLS wraps the socket.
      skip "Mosquitto MQTT broker with auth required not reachable" unless mqtt_broker_reachable?(mqtt_auth_test_url)

      connection = track(Tina4::Mqtt.new(url: mqtt_tls_test_url, client_id: "#{run_id}-tls-auth",
                                         username: mqtt_test_username, password: mqtt_test_password,
                                         ca_file: mqtt_test_ca_file, timeout: 5))
      expect(connection.connected?).to be true
      expect(connection.tls?).to be true
      expect(connection.publish("#{prefix}/tls-auth", "both", qos: 1)).to be_a(Integer)
    end
  end
end
