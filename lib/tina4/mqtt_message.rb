# frozen_string_literal: true

module Tina4
  # One MQTT 3.1.1 application message as delivered by the broker.
  #
  # Shaped like Tina4::Job (the Queue's unit of work): it carries the payload
  # plus the delivery metadata a consumer needs, and it knows how to
  # acknowledge itself back to the client it came from.
  #
  # The two flags matter for correctness, not decoration:
  #
  #   retained?  — the broker replayed the topic's last known value to us
  #                because we subscribed AFTER it was published. It is current
  #                state, not a fresh event.
  #   duplicate? — the DUP flag. The broker is REDELIVERING a QoS 1 message it
  #                never saw acknowledged. QoS 1 is at-least-once, so a
  #                duplicate is guaranteed eventually; a consumer that treats a
  #                DUP delivery as a new sample double-counts energy or mileage
  #                (test case A5). Key the ingest on (device_id,
  #                device_timestamp) and this is harmless.
  class MqttMessage
    attr_reader :topic, :payload, :qos, :packet_id

    def initialize(topic:, payload:, qos: 0, retained: false, duplicate: false,
                   packet_id: nil, client: nil)
      @topic = topic
      @payload = payload
      @qos = qos
      @retained = retained
      @duplicate = duplicate
      @packet_id = packet_id
      @client = client
      @acknowledged = false
    end

    # True when the broker replayed this as the topic's retained (last known) value.
    def retained?
      @retained
    end

    # True when the broker set the DUP flag — this is a REDELIVERY of a QoS 1
    # message we never acknowledged, not a new sample.
    def duplicate?
      @duplicate
    end

    # Acknowledge a QoS 1 delivery (PUBACK) so the broker stops redelivering it.
    # A QoS 0 message needs no acknowledgement, and a second call is a no-op, so
    # this is always safe to call once processing succeeded.
    def acknowledge
      return false if @acknowledged || @qos.zero? || @packet_id.nil? || @client.nil?

      @client.acknowledge(@packet_id)
      @acknowledged = true
    end

    # True once this message has been acknowledged back to the broker.
    def acknowledged?
      @acknowledged
    end

    # The payload as a String — the common case, so `"#{message}"` just works.
    def to_s
      @payload.to_s
    end

    def to_h
      {
        topic: @topic,
        payload: @payload,
        qos: @qos,
        retained: @retained,
        duplicate: @duplicate,
        packet_id: @packet_id
      }
    end
  end
end
