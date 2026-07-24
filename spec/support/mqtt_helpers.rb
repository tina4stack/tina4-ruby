# frozen_string_literal: true

# ── MQTT broker helpers (Eclipse Mosquitto + EMQX) ────────────────────────────
#
# Shared by spec/mqtt_spec.rb, spec/mqtt_session_spec.rb and
# spec/mqtt_auth_tls_spec.rb, which drive the REAL brokers (no mocks — a
# hand-rolled binary protocol can only be proven on the wire). The skip reason
# deliberately carries both "mqtt"/"mosquitto" and "not reachable" so
# TINA4_REQUIRE_SERVICES turns a missing broker in CI into a hard failure instead
# of a green skip. Those specs skip per EXAMPLE (in a `before`, not a
# `before(:all)`), the house pattern across this suite; since the gate now walks
# RSpec.world at suite end a before(:context) skip would be caught too, but the
# per-example shape keeps the reason next to the example that needs it.
#
# These live in their own file, required explicitly by the MQTT specs, so the
# shared spec_helper.rb carries only the one thing it must: "mqtt"/"mosquitto" in
# TINA4_GATE_SERVICE_KEYWORDS.
#
# Start every broker with: sh spec/support/mqtt-infra.sh
require "socket"

def mqtt_test_url
  url = ENV["TINA4_TEST_MQTT_URL"].to_s.strip
  url.empty? ? "mqtt://127.0.0.1:1883" : url
end

# The auth-required listener (allow_anonymous false + password_file). Proves the
# CONNECT username/password fields AND the CONNACK-refused path, with a broker
# actually refusing us rather than an assumption about what a broker sends.
def mqtt_auth_test_url
  url = ENV["TINA4_TEST_MQTT_AUTH_URL"].to_s.strip
  url.empty? ? "mqtt://127.0.0.1:1884" : url
end

# The TLS listener (self-signed CA).
def mqtt_tls_test_url
  url = ENV["TINA4_TEST_MQTT_TLS_URL"].to_s.strip
  url.empty? ? "mqtts://127.0.0.1:8883" : url
end

# EMQX. Mosquitto CANNOT produce a SUBACK 0x80 (it enforces ACLs at delivery and
# hands the client a granted QoS), so the subscription-refused path is proven
# against EMQX, whose default authorization already denies "#" and "$SYS/#".
def mqtt_emqx_test_url
  url = ENV["TINA4_TEST_MQTT_EMQX_URL"].to_s.strip
  url.empty? ? "mqtt://127.0.0.1:1885" : url
end

# The CA that signed the TLS listener's certificate. TINA4_MQTT_TEST_CA is the
# name the spike's mqtt-infra.sh prints as a ready-to-paste export, so both
# spellings are read here — nothing in lib/ reads either; the framework's own
# variable is TINA4_MQTT_CA_FILE.
#
# With neither set, fall back to where spec/support/mqtt-infra.sh writes its certs
# by default, so `sh spec/support/mqtt-infra.sh && bundle exec rspec` just works.
def mqtt_test_ca_file
  %w[TINA4_TEST_MQTT_CA_FILE TINA4_MQTT_TEST_CA].each do |name|
    value = ENV[name].to_s.strip
    return value unless value.empty?
  end
  require "tmpdir"
  default = File.join(Dir.tmpdir, "tina4-mqtt-infra", "certs", "ca.crt")
  File.exist?(default) ? default : nil
end

# Does the configured CA actually VERIFY the broker's certificate?
#
# The gate used to accept any CA file that merely EXISTS. A stale
# Dir.tmpdir/tina4-mqtt-infra/certs/ca.crt left behind by an earlier
# mqtt-infra.sh run therefore made the TLS examples RUN and then fail on a
# certificate mismatch -- six red examples in every framework caused purely by
# the environment, with an error that reads like a code regression.
#
# A CA that cannot validate the broker is functionally the same as no CA, so
# prove it with a real handshake and skip when it does not hold. Self-healing:
# regenerate the certs and the examples run again. Memoised for the same reason
# mqtt_broker_reachable? is -- otherwise every example pays the connect timeout.
#
# Uses a FRESH X509::Store rather than context.ca_file=, which writes into the
# shared DEFAULT_CERT_STORE (the same trap the TLS specs themselves document).
def mqtt_ca_verifies?(url = mqtt_tls_test_url, ca_file = mqtt_test_ca_file)
  cache = ($tina4_mqtt_ca_verifies ||= {})
  key = [url, ca_file]
  return cache[key] if cache.key?(key)

  cache[key] = begin
    if ca_file.nil? || !File.exist?(ca_file)
      false
    else
      require "openssl"
      parsed = Tina4::Mqtt.parse_url(url)
      store = OpenSSL::X509::Store.new
      store.add_file(ca_file)
      context = OpenSSL::SSL::SSLContext.new
      context.cert_store = store
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      Socket.tcp(parsed[:host], parsed[:port], connect_timeout: 3) do |socket|
        ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.hostname = parsed[:host]
        begin
          ssl.connect
          true
        ensure
          begin
            ssl.close
          rescue StandardError
            nil
          end
        end
      end
    end
  rescue StandardError
    false
  end
end

def mqtt_test_username
  value = ENV["TINA4_TEST_MQTT_USERNAME"].to_s.strip
  value.empty? ? "tina4" : value
end

def mqtt_test_password
  value = ENV["TINA4_TEST_MQTT_PASSWORD"].to_s.strip
  value.empty? ? "testpass" : value
end

# The auth listener's url with credentials injected into the userinfo, so the
# specs exercise the mqtt://user:pass@host form a developer actually writes.
def mqtt_auth_url_with(username, password)
  parsed = Tina4::Mqtt.parse_url(mqtt_auth_test_url)
  scheme = parsed[:tls] ? "mqtts" : "mqtt"
  credentials = [username, password].compact.map { |part| mqtt_percent_encode(part) }.join(":")
  "#{scheme}://#{credentials}@#{parsed[:host]}:#{parsed[:port]}"
end

def mqtt_percent_encode(value)
  value.to_s.gsub(%r{[^A-Za-z0-9\-_.~]}) { |char| format("%%%02X", char.ord) }
end

# Memoised per process: with a per-example gate this would otherwise re-probe on
# every example (and pay the connect timeout each time when the broker is down).
def mqtt_broker_reachable?(url = mqtt_test_url)
  cache = ($tina4_mqtt_broker_reachable ||= {})
  return cache[url] if cache.key?(url)

  cache[url] = begin
    parsed = Tina4::Mqtt.parse_url(url)
    # A plain TCP connect: this only answers "is a broker listening", so it works
    # for the TLS listener too without doing a handshake.
    Socket.tcp(parsed[:host], parsed[:port], connect_timeout: 2) { true }
  rescue StandardError
    false
  end
end
