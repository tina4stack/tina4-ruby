# frozen_string_literal: true

# MQTT 3.1.1 wire protocol, against a REAL Eclipse Mosquitto broker.
#
# NO mocks, doubles, fakes or in-test brokers anywhere in this file. The bugs in
# a hand-rolled binary protocol live in the wire format, so an in-process stand-in
# would prove nothing: every packet here is written to a real socket and answered
# by a real broker. The only examples with no dependency are the pure functions
# (varint encoding, url parsing, the QoS 2 refusal), which take their inputs and
# return their outputs with no collaborator at all.
#
# Ported from plan/v3/spikes/mqtt_spike.py (the normative reference, 15/15
# against the same broker). Each example names the bug it fails for.
#
# Broker: TINA4_TEST_MQTT_URL, default mqtt://127.0.0.1:1883
#   docker run -d --name tina4-mosquitto -p 1883:1883 \
#     -v $PWD/mosquitto.conf:/mosquitto/config/mosquitto.conf eclipse-mosquitto:2

require "spec_helper"
require_relative "support/mqtt_helpers"
require "securerandom"
require "socket"
require "rbconfig"

# Lazy loading — needs no broker, so it lives outside the gated group below.
RSpec.describe "Tina4::Mqtt lazy loading" do
  it "stays unloaded until the constant is touched, so an app that never uses MQTT pays nothing" do
    # A REAL subprocess with a REAL `require "tina4"`, because the constant is
    # already resolved in this process (autoload leaves no trace to assert on
    # once it has fired). This also pins the provenance: the load path is forced
    # to the working tree, so a stale installed gem cannot answer for it.
    lib_dir = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift #{lib_dir.inspect}
      require "tina4"
      before = $LOADED_FEATURES.grep(%r{tina4/mqtt})
      Tina4::Mqtt # touch it
      after = $LOADED_FEATURES.grep(%r{tina4/mqtt})
      puts "\#{before.length},\#{after.length},\#{Tina4::Mqtt.name}"
    RUBY
    output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)
    expect($?).to be_success, "subprocess failed: #{output}"
    # 0 files before; mqtt.rb + mqtt_message.rb after.
    expect(output.strip).to eq("0,2,Tina4::Mqtt")
  end
end

RSpec.describe Tina4::Mqtt do
  # Per EXAMPLE, not before(:all): RSpec skips the after(:each) hook for an
  # example skipped by a before(:context) hook, and that hook is what records a
  # TINA4_REQUIRE_SERVICES violation — a before(:all) skip would slip past the
  # CI gate as a green skip. The reachability probe is memoised per process.
  before do
    skip "Mosquitto MQTT broker not reachable at #{mqtt_test_url}" unless mqtt_broker_reachable?
  end

  # Retained messages and durable sessions outlive a single example, so every
  # run gets its own topic tree and its own client ids. Without this, a retained
  # value from an earlier run would satisfy an assertion that the CURRENT run
  # should have failed.
  let(:run_id) { "#{Process.pid}-#{SecureRandom.hex(4)}" }
  let(:prefix) { "tina4rb/#{run_id}" }
  let(:clients) { [] }

  # Every client this example opened, closed no matter how the example ended.
  def client(**options)
    created = Tina4::Mqtt.new(**{ url: mqtt_test_url, timeout: 5 }.merge(options))
    clients << created
    created
  end

  after do
    clients.each do |open_client|
      open_client.disconnect
    rescue StandardError
      nil
    end
  end

  # ── Remaining Length varint (trap 2) ─────────────────────────────────────
  #
  # 7 bits per byte, high bit = "another byte follows". A single-byte assumption
  # works for every packet under 128 bytes and then fails, so 128 is asserted
  # explicitly — both as bytes and over the real wire further down.
  describe ".encode_remaining_length" do
    it "encodes 0 as a single zero byte" do
      expect(described_class.encode_remaining_length(0).unpack("C*")).to eq([0x00])
    end

    it "encodes 127 as a single byte (the last single-byte length)" do
      expect(described_class.encode_remaining_length(127).unpack("C*")).to eq([0x7F])
    end

    it "encodes 128 as TWO bytes 0x80 0x01 (the multi-byte boundary)" do
      expect(described_class.encode_remaining_length(128).unpack("C*")).to eq([0x80, 0x01])
    end

    it "encodes 16383 as 0xFF 0x7F" do
      expect(described_class.encode_remaining_length(16_383).unpack("C*")).to eq([0xFF, 0x7F])
    end

    it "encodes the 4-byte maximum 268435455" do
      expect(described_class.encode_remaining_length(268_435_455).unpack("C*"))
        .to eq([0xFF, 0xFF, 0xFF, 0x7F])
    end

    it "refuses a length that cannot be encoded in 4 bytes (negative)" do
      expect { described_class.encode_remaining_length(268_435_456) }
        .to raise_error(ArgumentError, /outside 0\.\.268435455/)
      expect { described_class.encode_remaining_length(-1) }
        .to raise_error(ArgumentError, /outside 0\.\.268435455/)
    end
  end

  # ── URL parsing ──────────────────────────────────────────────────────────
  describe ".parse_url" do
    it "parses mqtt://host:port" do
      expect(described_class.parse_url("mqtt://broker.example:18883"))
        .to include(host: "broker.example", port: 18_883, tls: false)
    end

    it "defaults the port to 1883" do
      expect(described_class.parse_url("mqtt://broker.example")).to include(host: "broker.example", port: 1883)
      expect(described_class.parse_url("broker.example")).to include(host: "broker.example", port: 1883)
    end

    it "accepts tcp:// and a bracketed IPv6 literal" do
      expect(described_class.parse_url("tcp://127.0.0.1:1883")).to include(host: "127.0.0.1", port: 1883)
      expect(described_class.parse_url("mqtt://[::1]:1883")).to include(host: "::1", port: 1883)
    end

    it "carries no credentials when the url has none" do
      expect(described_class.parse_url("mqtt://broker.example"))
        .to include(username: nil, password: nil)
    end

    it "refuses a transport it does not speak instead of guessing (negative)" do
      # mqtts:// IS spoken (see spec/mqtt_auth_tls_spec.rb); WebSocket is not.
      expect { described_class.parse_url("ws://broker.example:8083/mqtt") }
        .to raise_error(ArgumentError, %r{mqtt://, tcp:// or mqtts://})
      expect { described_class.parse_url("http://broker.example") }
        .to raise_error(ArgumentError, %r{mqtt://, tcp:// or mqtts://})
    end

    it "refuses an empty url and names the env var (negative)" do
      expect { described_class.parse_url("  ") }
        .to raise_error(ArgumentError, /TINA4_MQTT_URL/)
    end
  end

  # ── QoS 2: refuse loudly (owner decision, 2026-07-23) ────────────────────
  #
  # A caller who asked for exactly-once and quietly got at-least-once would
  # double-process every duplicate forever without ever seeing an error, so
  # QoS 2 raises rather than being downgraded to QoS 1.
  describe "QoS 2" do
    it "refuses publish at QoS 2 with a message naming BOTH the limit and the alternative" do
      connection = client(client_id: "#{run_id}-qos2")
      expect { connection.publish("#{prefix}/qos2", "exactly-once", qos: 2) }
        .to raise_error(ArgumentError) { |error|
          # the limit
          expect(error.message).to include("QoS 2")
          expect(error.message).to match(/not supported/i)
          expect(error.message).to include("QoS 0 and QoS 1")
          # the alternative
          expect(error.message).to include("QoS 1")
          expect(error.message).to include("idempotent")
          expect(error.message).to include("(device_id, device_timestamp)")
        }
    end

    it "refuses subscribe at QoS 2 the same way" do
      connection = client(client_id: "#{run_id}-qos2-sub")
      expect { connection.subscribe("#{prefix}/qos2", qos: 2) }
        .to raise_error(ArgumentError, /QoS 2 .* not supported/m)
    end

    it "refuses a QoS 2 Last Will at construction" do
      expect {
        Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-qos2-will",
                        will_topic: "#{prefix}/will", will_payload: "gone", will_qos: 2)
      }.to raise_error(ArgumentError, /QoS 2 .* not supported/m)
    end

    it "does NOT silently downgrade to QoS 1 — nothing reaches the broker (negative)" do
      topic = "#{prefix}/qos2-not-downgraded"
      watcher = client(client_id: "#{run_id}-qos2-watch")
      expect(watcher.subscribe(topic, qos: 1)).to eq(1)

      publisher = client(client_id: "#{run_id}-qos2-pub")
      expect { publisher.publish(topic, "exactly-once", qos: 2) }.to raise_error(ArgumentError)

      # A downgrade would have delivered this at QoS 1.
      expect { watcher.receive(timeout: 2) }.to raise_error(Tina4::MqttTimeoutError)
    end

    it "refuses a QoS that is not 0, 1 or 2 with its own message" do
      connection = client(client_id: "#{run_id}-qos7")
      expect { connection.publish("#{prefix}/qos7", "x", qos: 7) }
        .to raise_error(ArgumentError, /qos must be 0 or 1 \(got 7\)/)
    end
  end

  # ── CONNECT / CONNACK ────────────────────────────────────────────────────
  describe "connect" do
    it "completes the handshake with CONNACK return code 0" do
      connection = client(client_id: "#{run_id}-connect")
      expect(connection.connected?).to be true
    end

    it "generates a client id when none is configured" do
      original = ENV.key?("TINA4_MQTT_CLIENT_ID") ? ENV["TINA4_MQTT_CLIENT_ID"] : :unset
      ENV.delete("TINA4_MQTT_CLIENT_ID")
      begin
        connection = client
        expect(connection.client_id).to start_with("tina4-")
        expect(connection.connected?).to be true
      ensure
        original == :unset ? ENV.delete("TINA4_MQTT_CLIENT_ID") : ENV["TINA4_MQTT_CLIENT_ID"] = original
      end
    end

    it "reads the broker from TINA4_MQTT_URL when no url is passed" do
      original = ENV.key?("TINA4_MQTT_URL") ? ENV["TINA4_MQTT_URL"] : :unset
      ENV["TINA4_MQTT_URL"] = mqtt_test_url
      begin
        connection = Tina4::Mqtt.new(client_id: "#{run_id}-envurl", timeout: 5)
        clients << connection
        parsed = described_class.parse_url(mqtt_test_url)
        expect([connection.host, connection.port]).to eq([parsed[:host], parsed[:port]])
        expect(connection.connected?).to be true
      ensure
        original == :unset ? ENV.delete("TINA4_MQTT_URL") : ENV["TINA4_MQTT_URL"] = original
      end
    end

    it "does not expose the broker password through inspect (negative)" do
      # A client can end up in a log line, an exception report or the debug
      # overlay, and Ruby's default inspect prints every instance variable.
      connection = Tina4::Mqtt.new(url: "mqtt://device:sup3rs3cret@broker.example:1883",
                                   client_id: "#{run_id}-inspect", connect: false)
      expect(connection.inspect).to include("broker.example", "device")
      expect(connection.inspect).not_to include("sup3rs3cret")
    end

    it "raises a named error when no broker is listening (negative)" do
      # A real closed port — nothing is standing in for the broker.
      dead_port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
      expect { Tina4::Mqtt.new(url: "mqtt://127.0.0.1:#{dead_port}", client_id: "#{run_id}-dead", timeout: 2) }
        .to raise_error(Tina4::MqttError, /could not connect to MQTT broker at 127\.0\.0\.1:#{dead_port}/)
    end
  end

  # ── PUBLISH ──────────────────────────────────────────────────────────────
  describe "publish" do
    it "emits NO packet identifier at QoS 0 and expects no acknowledgement (trap 1)" do
      topic = "#{prefix}/qos0"
      subscriber = client(client_id: "#{run_id}-pub0-sub")
      subscriber.subscribe(topic, qos: 0)

      connection = client(client_id: "#{run_id}-pub0")
      expect(connection.publish(topic, "hello", qos: 0)).to be_nil

      # A packet identifier written at QoS 0 would shift the payload by two
      # bytes on the wire, so exact payload equality is what proves it absent.
      message = subscriber.receive(timeout: 3)
      expect(message.payload).to eq("hello")
      expect(message.qos).to eq(0)
      expect(message.packet_id).to be_nil

      # The stream is still in sync afterwards: a spurious packet id would have
      # desynchronised it and this round-trip would fail.
      expect(connection.ping).to be true
    end

    it "round-trips a matching PUBACK at QoS 1 and increments the packet id" do
      connection = client(client_id: "#{run_id}-pub1")
      expect(connection.publish("#{prefix}/qos1", '{"kwh":12.5}', qos: 1)).to eq(1)
      expect(connection.publish("#{prefix}/qos1", '{"kwh":13.5}', qos: 1)).to eq(2)
    end

    it "keeps a QoS 1 publish and an inbound PUBLISH apart on one connection" do
      # A connection that both publishes and subscribes will see an inbound
      # PUBLISH arrive while it is waiting for its own PUBACK. Mistaking that
      # PUBLISH for the acknowledgement desynchronises the stream (and loses the
      # message), so the inbound packet is parked and delivered by receive().
      topic = "#{prefix}/self-subscribed"
      connection = client(client_id: "#{run_id}-loopback")
      expect(connection.subscribe(topic, qos: 1)).to eq(1)

      expect(connection.publish(topic, "echo-1", qos: 1)).to eq(2)
      expect(connection.publish(topic, "echo-2", qos: 1)).to eq(3)

      expect(connection.receive(timeout: 3).payload).to eq("echo-1")
      expect(connection.receive(timeout: 3).payload).to eq("echo-2")
    end
  end

  # ── SUBSCRIBE / SUBACK ───────────────────────────────────────────────────
  describe "subscribe" do
    it "returns the QoS the broker GRANTED for a wildcard filter" do
      subscriber = client(client_id: "#{run_id}-sub")
      expect(subscriber.subscribe("#{prefix}/fleet/+/telemetry", qos: 1)).to eq(1)
    end

    it "returns 0 when QoS 0 was requested (the granted QoS is read, not assumed)" do
      subscriber = client(client_id: "#{run_id}-sub0")
      expect(subscriber.subscribe("#{prefix}/fleet/#", qos: 0)).to eq(0)
    end

    it "fails loudly when the broker rejects the subscription (negative)" do
      # "a/#/b" is an illegal filter (# must be the last level). A real
      # Mosquitto treats it as a protocol violation and closes the connection —
      # which must surface as an error, never as a silently dead subscription.
      subscriber = client(client_id: "#{run_id}-badfilter")
      expect { subscriber.subscribe("#{prefix}/a/#/b", qos: 1) }
        .to raise_error(Tina4::MqttError)
    end

    # SUBACK 0x80 — trap 5, against a broker that actually sends it.
    #
    # Mosquitto CANNOT produce 0x80: it enforces its ACLs at DELIVERY time and
    # answers the SUBSCRIBE with a granted QoS, then silently delivers nothing
    # (verified 2026-07-23 against a Mosquitto 2.1.2 with `topic readwrite
    # allowed/#`: subscribing to a denied topic returned granted QoS 1). EMQX
    # refuses at subscribe time instead, and its DEFAULT authorization already
    # denies "#" and "$SYS/#", so no custom ACL is needed. This is the real
    # broker that turns the refusal branch from written into proven.
    describe "a broker that REFUSES the subscription (EMQX)" do
      before do
        skip "EMQX MQTT broker not reachable at #{mqtt_emqx_test_url}" unless
          mqtt_broker_reachable?(mqtt_emqx_test_url)
      end

      let(:emqx) do
        client(url: mqtt_emqx_test_url, client_id: "#{run_id}-emqx")
      end

      it "raises on SUBACK 0x80 for '#', naming the filter and the code (negative)" do
        # Treating any SUBACK as success here means sitting on a dead
        # subscription receiving nothing, forever, with no error anywhere.
        expect { emqx.subscribe("#", qos: 1) }
          .to raise_error(Tina4::MqttError) { |error|
            expect(error.message).to include("refused the subscription")
            expect(error.message).to include('"#"')
            expect(error.message).to include("0x80")
          }
      end

      it "raises on SUBACK 0x80 for '$SYS/#' (negative)" do
        expect { emqx.subscribe("$SYS/#", qos: 1) }
          .to raise_error(Tina4::MqttError, /refused the subscription/)
      end

      it "still GRANTS a permitted filter on the same broker" do
        # The positive half: the refusal check must not reject every subscription.
        expect(emqx.subscribe("allowed/topic", qos: 1)).to eq(1)
      end

      it "keeps the connection usable after a refusal, and delivers on a granted filter" do
        # A refusal is a per-subscription answer, not a broken stream: the packet
        # identifier bookkeeping must survive it.
        expect { emqx.subscribe("#", qos: 1) }.to raise_error(Tina4::MqttError)
        topic = "#{prefix}/emqx/after-refusal"
        expect(emqx.subscribe(topic, qos: 1)).to eq(1)
        emqx.publish(topic, "still-working", qos: 1)
        expect(emqx.receive(timeout: 5).payload).to eq("still-working")
      end
    end
  end

  # ── End to end ───────────────────────────────────────────────────────────
  describe "delivery" do
    it "delivers the right topic and an intact payload through a wildcard filter" do
      subscriber = client(client_id: "#{run_id}-e2e-sub")
      expect(subscriber.subscribe("#{prefix}/fleet/+/telemetry", qos: 1)).to eq(1)

      publisher = client(client_id: "#{run_id}-e2e-pub")
      publisher.publish("#{prefix}/fleet/meter-42/telemetry", '{"kwh":99}', qos: 1)

      message = subscriber.receive(timeout: 3)
      expect(message.topic).to eq("#{prefix}/fleet/meter-42/telemetry")
      expect(message.payload).to eq('{"kwh":99}')
      expect(message.qos).to eq(1)
      expect(message.duplicate?).to be false
      expect(message.retained?).to be false
      expect(message.acknowledged?).to be true

      # The message reads like Tina4::Job: the payload is its string form, and
      # to_h carries the delivery metadata a consumer logs or stores.
      expect(message.to_s).to eq('{"kwh":99}')
      expect(message.to_h).to include(
        topic: "#{prefix}/fleet/meter-42/telemetry",
        payload: '{"kwh":99}',
        qos: 1,
        retained: false,
        duplicate: false
      )
      expect(message.to_h[:packet_id]).to be_a(Integer)
    end

    it "carries arbitrary binary bytes without corruption" do
      topic = "#{prefix}/binary"
      subscriber = client(client_id: "#{run_id}-bin-sub")
      subscriber.subscribe(topic, qos: 1)

      # Every byte value, including the 0x00 and 0x80 that break naive
      # string handling.
      payload = (0..255).to_a.pack("C*")
      client(client_id: "#{run_id}-bin-pub").publish(topic, payload, qos: 1)

      received = subscriber.receive(timeout: 3)
      expect(received.payload.bytesize).to eq(256)
      expect(received.payload.b).to eq(payload)
    end

    it "survives the Remaining Length boundaries 127, 128 and 16383 over the real wire" do
      topic = "#{prefix}/varint"
      subscriber = client(client_id: "#{run_id}-varint-sub")
      subscriber.subscribe(topic, qos: 0)
      publisher = client(client_id: "#{run_id}-varint-pub")

      # At QoS 0 the PUBLISH body is 2 (topic length) + topic + payload, so this
      # sizes each payload to land the Remaining Length exactly ON the boundary.
      overhead = 2 + topic.bytesize
      [127, 128, 16_383, 16_384].each do |remaining_length|
        payload = "P" * (remaining_length - overhead)
        publisher.publish(topic, payload, qos: 0)
        received = subscriber.receive(timeout: 3)
        expect(received.payload.bytesize).to eq(payload.bytesize)
        expect(received.payload).to eq(payload)
      end
    end

    it "reassembles a payload that does not fit in one TCP read (trap 3)" do
      # TCP is a stream: a single read returns SHORT. This is the classic
      # hand-rolled-protocol bug and it only shows once a packet outgrows the
      # socket buffer — 1 MB does, on loopback, so a single-read parse truncates
      # here (verified: it returned ~400 KB of the 1 MB) while the real loop
      # reassembles it. Also a 3-byte Remaining Length varint.
      topic = "#{prefix}/streamed"
      subscriber = client(client_id: "#{run_id}-stream-sub")
      subscriber.subscribe(topic, qos: 1)

      payload = SecureRandom.hex(524_288) # 1 MiB of non-repeating bytes
      client(client_id: "#{run_id}-stream-pub").publish(topic, payload, qos: 1)

      received = subscriber.receive(timeout: 10)
      expect(received.payload.bytesize).to eq(1_048_576)
      expect(received.payload).to eq(payload)
    end
  end

  # ── Keepalive ────────────────────────────────────────────────────────────
  describe "ping" do
    it "answers PINGREQ with PINGRESP" do
      connection = client(client_id: "#{run_id}-ping")
      expect(connection.ping).to be true
    end

    it "starts NO background thread of its own by default" do
      before_count = Tina4::Background.tasks.length
      client(client_id: "#{run_id}-nothread")
      expect(Tina4::Background.tasks.length).to eq(before_count)
    end
  end

  # ── Retained messages ────────────────────────────────────────────────────
  describe "retained messages" do
    it "hands the last known value to a LATE subscriber" do
      topic = "#{prefix}/meter-42/status"
      publisher = client(client_id: "#{run_id}-retain-pub")
      publisher.publish(topic, "online", qos: 1, retain: true)

      # Connects and subscribes AFTER the publish — a dashboard opening later.
      late = client(client_id: "#{run_id}-retain-late")
      late.subscribe(topic, qos: 1)
      message = late.receive(timeout: 3)
      expect(message.payload).to eq("online")
      expect(message.retained?).to be true
    end

    it "clears the retained value with an empty payload (negative)" do
      topic = "#{prefix}/meter-43/status"
      publisher = client(client_id: "#{run_id}-clear-pub")
      publisher.publish(topic, "online", qos: 1, retain: true)
      publisher.publish(topic, "", qos: 1, retain: true)

      late = client(client_id: "#{run_id}-clear-late")
      late.subscribe(topic, qos: 1)
      expect { late.receive(timeout: 2) }.to raise_error(Tina4::MqttTimeoutError)
    end
  end

  # ── Last Will ────────────────────────────────────────────────────────────
  describe "Last Will" do
    it "is published by the broker when the client dies WITHOUT a DISCONNECT" do
      topic = "#{prefix}/meter-99/status"
      watcher = client(client_id: "#{run_id}-will-watch")
      watcher.subscribe(topic, qos: 1)

      doomed = Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-doomed",
                               keepalive: 5, will_topic: topic,
                               will_payload: "offline", will_qos: 1)
      doomed.kill # socket dropped, no DISCONNECT — an unplugged device

      message = watcher.receive(timeout: 5)
      expect(message.topic).to eq(topic)
      expect(message.payload).to eq("offline")
    end

    it "is DISCARDED on a graceful disconnect (negative)" do
      topic = "#{prefix}/meter-98/status"
      watcher = client(client_id: "#{run_id}-will-watch2")
      watcher.subscribe(topic, qos: 1)

      polite = Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-polite",
                               keepalive: 5, will_topic: topic,
                               will_payload: "offline", will_qos: 1)
      polite.disconnect # said goodbye properly

      # A will that fired here would make every planned restart look like a
      # dead device.
      expect { watcher.receive(timeout: 2) }.to raise_error(Tina4::MqttTimeoutError)
    end
  end
end
