# frozen_string_literal: true

require "socket"
require "securerandom"
require_relative "mqtt_message"

module Tina4
  # Any MQTT protocol / connection failure.
  class MqttError < StandardError; end

  # The broker did not answer inside the timeout.
  class MqttTimeoutError < MqttError; end

  # Zero-dependency MQTT 3.1.1 client — the protocol every broker and every
  # IoT device already speaks. Built on `socket` and Array#pack/String#unpack
  # only: no gem, so an app that talks to Mosquitto / EMQX / HiveMQ / AWS IoT
  # adds nothing to its dependency tree.
  #
  # Shaped like Tina4::Queue on purpose — publish / subscribe / consume:
  #
  #   mqtt = Tina4::Mqtt.new                          # TINA4_MQTT_URL
  #   mqtt.publish("fleet/meter-42/telemetry", '{"kwh":12.5}', qos: 1)
  #
  #   mqtt.consume("fleet/+/telemetry", qos: 1) do |message|
  #     next if message.duplicate?                    # QoS 1 is at-least-once
  #     store(message.topic, message.payload)
  #   end
  #
  # Environment: TINA4_MQTT_URL (default mqtt://127.0.0.1:1883),
  # TINA4_MQTT_CLIENT_ID, TINA4_MQTT_KEEPALIVE (seconds, default 60).
  #
  # No background thread is started by default. When a connection is otherwise
  # idle the broker will drop it past 1.5x keepalive, so opt in to the
  # cooperative keepalive with `start_keepalive` — it registers a
  # Tina4::Background task exactly like the queue consumers do, rather than
  # spawning a thread of its own.
  #
  # Single reader: like every MQTT client (paho included) the socket has ONE
  # network reader. `receive`/`consume` from one thread; `publish` and the
  # keepalive may be called from others (writes are serialised by a mutex).
  class Mqtt
    # Control packet types. The low nibble of SUBSCRIBE/UNSUBSCRIBE is 0x2
    # because MQTT 3.1.1 mandates QoS 1 on those two packets.
    CONNECT     = 0x10
    CONNACK     = 0x20
    PUBLISH     = 0x30
    PUBACK      = 0x40
    SUBSCRIBE   = 0x82
    SUBACK      = 0x90
    PINGREQ     = 0xC0
    PINGRESP    = 0xD0
    DISCONNECT  = 0xE0

    PROTOCOL_LEVEL = 0x04 # 4 == MQTT 3.1.1
    DEFAULT_PORT = 1883
    DEFAULT_URL = "mqtt://127.0.0.1:1883"
    DEFAULT_KEEPALIVE = 60
    SUBSCRIPTION_REFUSED = 0x80
    MAX_REMAINING_LENGTH = 268_435_455 # 4 varint bytes

    # QoS 2 is refused, never silently downgraded. A caller who asked for
    # exactly-once and quietly got at-least-once would double-process every
    # duplicate forever without ever seeing an error.
    QOS2_REFUSED_MESSAGE =
      "MQTT QoS 2 (exactly-once delivery) is not supported by Tina4 — this " \
      "client speaks QoS 0 and QoS 1 only, and refuses QoS 2 rather than " \
      "silently downgrading it to QoS 1. Use QoS 1 with an idempotent " \
      "consumer keyed on (device_id, device_timestamp): duplicates are then " \
      "harmless, which is what exactly-once was for."

    # Human-readable CONNACK return codes (MQTT 3.1.1 section 3.2.2.3).
    CONNACK_RETURN_CODES = {
      1 => "unacceptable protocol version",
      2 => "client identifier rejected",
      3 => "server unavailable",
      4 => "bad user name or password",
      5 => "not authorised"
    }.freeze

    attr_reader :host, :port, :client_id, :keepalive, :clean_session

    # url:           mqtt://host:port (falls back to TINA4_MQTT_URL, then localhost)
    # client_id:     broker-visible session id (TINA4_MQTT_CLIENT_ID, else generated).
    #                A durable session (clean_session: false) needs a STABLE id —
    #                the generated one changes every process.
    # keepalive:     seconds (TINA4_MQTT_KEEPALIVE, default 60)
    # clean_session: false keeps the subscription + queues QoS 1 messages for us
    #                while we are offline, and replays them on reconnect
    # will_*:        Last Will, published by the broker when we die WITHOUT a
    #                DISCONNECT — dead-device detection that is observed, not
    #                inferred from silence
    # timeout:       seconds to wait for a control-packet answer (CONNACK / PUBACK / SUBACK)
    # read_timeout:  seconds to wait for an application message; nil blocks
    # connect:       false builds the client without opening a socket
    def initialize(url: nil, client_id: nil, keepalive: nil, clean_session: true,
                   will_topic: nil, will_payload: nil, will_qos: 0, will_retain: false,
                   timeout: 5, read_timeout: nil, connect: true)
      @host, @port = self.class.parse_url(url || ENV["TINA4_MQTT_URL"] || DEFAULT_URL)
      @client_id = client_id || ENV["TINA4_MQTT_CLIENT_ID"]
      @client_id = "tina4-#{SecureRandom.hex(8)}" if @client_id.nil? || @client_id.empty?
      @keepalive = (keepalive || ENV["TINA4_MQTT_KEEPALIVE"] || DEFAULT_KEEPALIVE).to_i
      @clean_session = clean_session
      @will_topic = will_topic
      @will_payload = will_payload
      @will_qos = will_qos
      @will_retain = will_retain
      @timeout = timeout
      @read_timeout = read_timeout

      refuse_unsupported_qos(will_qos) if will_topic

      @packet_id = 0
      @inbox = []
      @write_mutex = Mutex.new
      @last_write_at = 0.0
      @socket = nil
      @keepalive_task = nil

      self.connect if connect
    end

    # Split "mqtt://host:port" into [host, port]. A bare "host" or "host:port"
    # works too; an IPv6 literal is bracketed ("mqtt://[::1]:1883").
    def self.parse_url(url)
      raw = url.to_s.strip
      raise ArgumentError, "MQTT url is empty — set TINA4_MQTT_URL (e.g. #{DEFAULT_URL})" if raw.empty?

      scheme = raw[%r{\A([A-Za-z][A-Za-z0-9+.-]*)://}, 1]
      unless scheme.nil? || %w[mqtt tcp].include?(scheme.downcase)
        raise ArgumentError,
              "unsupported MQTT url scheme #{scheme.inspect} in #{raw.inspect} — " \
              "this client speaks plain TCP MQTT only (mqtt:// or tcp://). " \
              "TLS (mqtts://) and WebSocket transports are not implemented."
      end

      rest = scheme ? raw.sub(%r{\A[A-Za-z][A-Za-z0-9+.-]*://}, "") : raw
      if rest.include?("@")
        raise ArgumentError,
              "broker credentials in the MQTT url (#{raw.inspect}) are not supported — " \
              "this client sends no username/password in CONNECT, so the credentials " \
              "would be silently dropped. Point it at an anonymous or " \
              "network-restricted listener instead."
      end

      match = rest.match(%r{\A(?<host>\[[^\]]+\]|[^:/]+)(?::(?<port>\d+))?(?:/.*)?\z})
      raise ArgumentError, "malformed MQTT url #{raw.inspect} — expected mqtt://host:port" unless match

      host = match[:host].delete_prefix("[").delete_suffix("]")
      [host, (match[:port] || DEFAULT_PORT).to_i]
    end

    # Remaining Length: 7 bits per byte, high bit means "another byte follows".
    # A single-byte assumption works for every packet under 128 bytes and then
    # fails, so this is exercised directly at 0 / 127 / 128 / 16383.
    def self.encode_remaining_length(value)
      length = Integer(value)
      if length.negative? || length > MAX_REMAINING_LENGTH
        raise ArgumentError, "remaining length #{length} is outside 0..#{MAX_REMAINING_LENGTH}"
      end

      encoded = String.new(capacity: 4, encoding: Encoding::BINARY)
      loop do
        byte = length & 0x7F
        length >>= 7
        encoded << (length.positive? ? (byte | 0x80) : byte)
        break unless length.positive?
      end
      encoded
    end

    # Open the socket and complete the CONNECT / CONNACK handshake. Also the
    # reconnect path: an existing socket is closed first, and a durable session
    # (clean_session: false) resumes with the same client_id.
    def connect
      close_socket
      @socket = Socket.tcp(@host, @port, connect_timeout: @timeout)
      # Telemetry frames are tiny; Nagle would add latency for no gain.
      @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      @inbox.clear

      body = String.new(capacity: 64, encoding: Encoding::BINARY)
      body << mqtt_string("MQTT")
      body << [PROTOCOL_LEVEL, connect_flags].pack("C2")
      body << [@keepalive].pack("n")
      # Payload order is fixed: client id, will topic, will message,
      # username, password. (No username/password — see parse_url.)
      body << mqtt_string(@client_id)
      if @will_topic
        body << mqtt_string(@will_topic)
        will_bytes = payload_bytes(@will_payload)
        body << [will_bytes.bytesize].pack("n") << will_bytes
      end
      write_packet(CONNECT, body)

      header, payload = read_packet(deadline_in(@timeout))
      unless header == CONNACK && payload.bytesize >= 2
        raise MqttError, format("expected CONNACK, got %#04x", header)
      end

      return_code = payload.getbyte(1)
      unless return_code.zero?
        reason = CONNACK_RETURN_CODES.fetch(return_code, "unknown return code")
        raise MqttError, "broker refused the connection: #{reason} (CONNACK return code #{return_code})"
      end
      true
    rescue SystemCallError, IOError => e
      close_socket
      raise MqttError, "could not connect to MQTT broker at #{@host}:#{@port}: #{e.message}"
    end

    def connected?
      !@socket.nil? && !@socket.closed?
    end

    # Publish an application message. Returns the packet identifier for QoS 1
    # (the broker's PUBACK must carry it back) and nil for QoS 0.
    #
    # retain: true tells the broker to keep this as the topic's last known
    # value and hand it to every FUTURE subscriber — how a dashboard shows
    # current state the moment it connects. Publishing an EMPTY payload with
    # retain: true is how a retained value is cleared.
    def publish(topic, payload, qos: 0, retain: false)
      refuse_unsupported_qos(qos)
      bytes = payload_bytes(payload)
      topic_field = mqtt_string(topic)
      # The packet identifier exists ONLY when QoS > 0. Emitting it at QoS 0 (or
      # omitting it at QoS 1) desynchronises the stream and every later packet
      # mis-parses.
      packet_id = qos.positive? ? next_packet_id : nil

      body = String.new(capacity: topic_field.bytesize + bytes.bytesize + 2,
                        encoding: Encoding::BINARY)
      body << topic_field
      body << [packet_id].pack("n") if packet_id
      body << bytes
      write_packet(PUBLISH | (qos << 1) | (retain ? 0x01 : 0x00), body)

      wait_for_acknowledgement(PUBACK, packet_id, "PUBACK") if qos == 1
      packet_id
    end

    # Subscribe to a topic filter ("fleet/+/telemetry", "fleet/#"). Returns the
    # QoS the broker GRANTED, which can be lower than the one requested.
    #
    # A SUBACK carrying 0x80 is a REFUSAL, not a success — treating any SUBACK
    # as success means sitting on a dead subscription receiving nothing, so it
    # raises here.
    def subscribe(topic_filter, qos: 1)
      refuse_unsupported_qos(qos)
      packet_id = next_packet_id
      filter_field = mqtt_string(topic_filter)

      body = String.new(capacity: filter_field.bytesize + 3, encoding: Encoding::BINARY)
      body << [packet_id].pack("n")
      body << filter_field
      body << qos
      write_packet(SUBSCRIBE, body)

      payload = wait_for_acknowledgement(SUBACK, packet_id, "SUBACK")
      raise MqttError, "malformed SUBACK: no return code for #{topic_filter.inspect}" if payload.bytesize < 3

      granted = payload.getbyte(2)
      if granted == SUBSCRIPTION_REFUSED
        raise MqttError,
              "broker refused the subscription to #{topic_filter.inspect} " \
              "(SUBACK return code 0x80) — check the topic filter and the broker ACLs"
      end
      granted
    end

    # Read the next application message. Returns a Tina4::MqttMessage.
    #
    # ack: true (the default) acknowledges a QoS 1 delivery immediately, which
    # is right for a synchronous read. Pass ack: false when the message must be
    # stored before the broker is allowed to forget it — an unacknowledged QoS 1
    # message is redelivered with DUP set. `consume` does exactly that.
    def receive(timeout: nil, ack: true)
      message = @inbox.shift || read_publish(deadline_in(timeout || @read_timeout))
      message.acknowledge if ack
      message
    end

    # Long-running consumer, mirroring Queue#consume.
    #
    #   mqtt.consume("fleet/+/telemetry", qos: 1) { |message| store(message) }
    #   mqtt.consume.each { |message| store(message) }   # already subscribed
    #
    # The message is acknowledged AFTER the block returns, so a handler that
    # raises leaves the message unacknowledged and the broker redelivers it
    # (with DUP set) — at-least-once, which is the point of QoS 1. The raise
    # propagates: a consumer that swallows storage failures loses data quietly.
    #
    # iterations: > 0 stops after that many messages (bounded runs and tests).
    def consume(topic_filter = nil, qos: 1, iterations: 0, timeout: nil, &block)
      subscribe(topic_filter, qos: qos) if topic_filter
      unless block
        return Enumerator.new do |yielder|
          consume_loop(iterations, timeout) { |message| yielder << message }
        end
      end

      consume_loop(iterations, timeout, &block)
    end

    # PUBACK a QoS 1 delivery. Called by MqttMessage#acknowledge.
    def acknowledge(packet_id)
      write_packet(PUBACK, [packet_id].pack("n"))
      true
    end

    # PINGREQ and wait for the PINGRESP. Use this when nothing else is reading
    # the socket; under a `consume` loop use start_keepalive instead, because
    # the reader there absorbs the PINGRESP.
    def ping(timeout: nil)
      send_keepalive
      deadline = deadline_in(timeout || @timeout)
      loop do
        header, payload = read_packet(deadline)
        return true if header == PINGRESP
        next if stash_publish(header, payload)

        raise MqttError, format("expected PINGRESP, got %#04x", header)
      end
    end

    # Write a PINGREQ without waiting for the answer. The PINGRESP is absorbed
    # by whatever is reading the socket (`receive` skips it), which is what
    # makes the background keepalive safe alongside a consume loop.
    def send_keepalive
      write_packet(PINGREQ, "")
      true
    end

    # Opt in to the cooperative keepalive. Registers a Tina4::Background task —
    # the same mechanism the queue consumers use — that sends a PINGREQ only
    # when the connection has actually gone quiet, so an actively publishing
    # client costs no extra packets. Without a keepalive the broker drops a
    # silent client past 1.5x keepalive (which is exactly what fires the Last
    # Will).
    def start_keepalive(interval: nil)
      return @keepalive_task if @keepalive_task
      raise MqttError, "keepalive is disabled (keepalive: 0) — nothing to schedule" unless @keepalive.positive?

      seconds = interval || [@keepalive / 2.0, 1.0].max
      @keepalive_task = Tina4::Background.register(interval: seconds) do
        send_keepalive if connected? && idle_for?(seconds)
      end
    end

    def stop_keepalive
      return false unless @keepalive_task

      Tina4::Background.stop_task(@keepalive_task)
      @keepalive_task = nil
      true
    end

    # Say goodbye properly: DISCONNECT then close. The broker discards the Last
    # Will on a graceful disconnect, and a clean_session: false session survives
    # for the next connect with the same client_id.
    def disconnect
      stop_keepalive
      begin
        write_packet(DISCONNECT, "") if connected?
      rescue MqttError, SystemCallError, IOError
        # Already gone — closing is still the right outcome.
      ensure
        close_socket
      end
      true
    end

    # Drop the socket WITHOUT a DISCONNECT — what a crashed or unplugged device
    # looks like to the broker, and therefore what fires the Last Will.
    def kill
      stop_keepalive
      close_socket
      true
    end

    private

    # The one delivery loop, shared by the block and Enumerator forms so the
    # acknowledge-after-processing contract cannot drift between them.
    def consume_loop(iterations, timeout)
      consumed = 0
      loop do
        message = receive(timeout: timeout, ack: false)
        yield message
        message.acknowledge
        consumed += 1
        break if iterations.positive? && consumed >= iterations
      end
      consumed
    end

    def connect_flags
      flags = @clean_session ? 0x02 : 0x00
      if @will_topic
        # Will flag 0x04, will QoS at bits 3-4, will retain 0x20.
        flags |= 0x04 | (@will_qos << 3)
        flags |= 0x20 if @will_retain
      end
      flags
    end

    def refuse_unsupported_qos(qos)
      raise ArgumentError, QOS2_REFUSED_MESSAGE if qos == 2
      raise ArgumentError, "qos must be 0 or 1 (got #{qos.inspect})" unless [0, 1].include?(qos)
    end

    # Every MQTT string is a 2-byte big-endian length followed by UTF-8 bytes.
    def mqtt_string(value)
      bytes = binary(value.to_s)
      raise ArgumentError, "MQTT string is longer than 65535 bytes" if bytes.bytesize > 0xFFFF

      [bytes.bytesize].pack("n") << bytes
    end

    def payload_bytes(payload)
      return "".b if payload.nil?

      binary(payload.to_s)
    end

    # The bytes of a String, without copying one that is already binary — a
    # telemetry payload should not be duplicated on its way to the socket.
    def binary(value)
      value.encoding == Encoding::BINARY ? value : value.b
    end

    # Packet identifiers are 1..65535; 0 is invalid.
    def next_packet_id
      @write_mutex.synchronize { @packet_id = (@packet_id % 0xFFFF) + 1 }
    end

    # One buffer per packet. The fixed header (control byte + Remaining Length
    # varint, 5 bytes at most) is written together with the body in a SINGLE
    # write — IO#write with several arguments issues one writev, so the payload
    # is never copied into a second buffer and a small telemetry frame still
    # leaves as one segment.
    def write_packet(header, body)
      raise MqttError, "not connected to an MQTT broker" unless connected?

      fixed_header = String.new(capacity: 5, encoding: Encoding::BINARY)
      fixed_header << header << self.class.encode_remaining_length(body.bytesize)
      @write_mutex.synchronize do
        @socket.write(fixed_header, body)
        @last_write_at = monotonic
      end
      true
    rescue SystemCallError, IOError => e
      raise MqttError, "MQTT write failed: #{e.message}"
    end

    # Returns [control_byte, body]. The fixed header is read in exactly 1 + N
    # bytes (N <= 4 for the varint) so the next packet's header is never
    # consumed by a speculative over-read.
    def read_packet(deadline)
      header = read_exact(1, deadline).getbyte(0)
      multiplier = 1
      length = 0
      loop do
        byte = read_exact(1, deadline).getbyte(0)
        length += (byte & 0x7F) * multiplier
        break if (byte & 0x80).zero?

        multiplier <<= 7
        raise MqttError, "malformed Remaining Length (more than 4 varint bytes)" if multiplier > 0x200000
      end
      [header, length.zero? ? "".b : read_exact(length, deadline)]
    end

    # TCP is a stream: a single read returns SHORT. Loop, or the parse corrupts
    # under load. Reads into one buffer; no per-byte loop.
    def read_exact(count, deadline)
      raise MqttError, "not connected to an MQTT broker" unless connected?

      buffer = String.new(capacity: count, encoding: Encoding::BINARY)
      while buffer.bytesize < count
        wait_readable(deadline)
        begin
          buffer << @socket.readpartial(count - buffer.bytesize)
        rescue EOFError
          raise MqttError, "broker closed the connection"
        rescue SystemCallError, IOError => e
          raise MqttError, "MQTT read failed: #{e.message}"
        end
      end
      buffer
    end

    def wait_readable(deadline)
      remaining = nil
      if deadline
        remaining = deadline - monotonic
        raise MqttTimeoutError, "timed out waiting for the MQTT broker" if remaining <= 0
      end
      return if IO.select([@socket], nil, nil, remaining)

      raise MqttTimeoutError, "timed out waiting for the MQTT broker"
    end

    # Read packets until the next PUBLISH, skipping the PINGRESPs the keepalive
    # generates.
    def read_publish(deadline)
      loop do
        header, payload = read_packet(deadline)
        next if header == PINGRESP

        message = parse_publish(header, payload)
        return message if message

        raise MqttError, format("expected PUBLISH, got %#04x", header)
      end
    end

    # A PUBLISH that arrives while we are waiting for a PUBACK/SUBACK/PINGRESP
    # (normal when the same connection both publishes and subscribes) is parked
    # in the inbox so `receive` still delivers it, in order, instead of it being
    # mistaken for the acknowledgement.
    def stash_publish(header, payload)
      message = parse_publish(header, payload)
      return false unless message

      @inbox << message
      true
    end

    def parse_publish(header, payload)
      return nil unless (header & 0xF0) == PUBLISH

      qos = (header & 0x06) >> 1
      topic_length = payload.unpack1("n")
      offset = 2 + topic_length
      topic = payload.byteslice(2, topic_length).force_encoding(Encoding::UTF_8)
      packet_id = nil
      # The packet identifier is present ONLY when QoS > 0.
      if qos.positive?
        packet_id = payload.byteslice(offset, 2).unpack1("n")
        offset += 2
      end

      MqttMessage.new(
        topic: topic,
        payload: payload.byteslice(offset, payload.bytesize - offset) || "".b,
        qos: qos,
        retained: (header & 0x01) == 0x01,
        duplicate: (header & 0x08) == 0x08,
        packet_id: packet_id,
        client: self
      )
    end

    # Wait for a specific acknowledgement, tolerating interleaved PUBLISH and
    # PINGRESP packets. A mismatched packet identifier is silent data loss if
    # ignored, so it raises.
    def wait_for_acknowledgement(expected_header, packet_id, name)
      deadline = deadline_in(@timeout)
      loop do
        header, payload = read_packet(deadline)
        next if header == PINGRESP
        next if stash_publish(header, payload)

        unless header == expected_header
          raise MqttError, format("expected %s, got %#04x", name, header)
        end

        received_id = payload.unpack1("n")
        unless received_id == packet_id
          raise MqttError,
                "#{name} packet identifier mismatch: broker acknowledged " \
                "#{received_id} but we sent #{packet_id}"
        end
        return payload
      end
    end

    def idle_for?(seconds)
      (monotonic - @last_write_at) >= seconds
    end

    def deadline_in(seconds)
      seconds ? monotonic + seconds : nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def close_socket
      @socket.close if @socket && !@socket.closed?
    rescue IOError, SystemCallError
      nil
    ensure
      @socket = nil
    end
  end
end
