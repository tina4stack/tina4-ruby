# frozen_string_literal: true

# MQTT session and resilience behaviours the client must SURVIVE, not just
# perform — against a REAL Eclipse Mosquitto broker.
#
# spec/mqtt_spec.rb proves the happy path. This is the awkward half: offline
# replay for an intermittent SIM, the keepalive the Last Will depends on,
# redelivery with the DUP flag, and the acknowledge-after-processing contract
# that makes `consume` crash-safe.
#
# NO mocks, doubles, fakes or in-test brokers. Every drop, every replay and
# every redelivery here is performed by the real broker; the timings are the
# real 1.5x-keepalive window. Ported from plan/v3/spikes/mqtt_spike2_session.py
# (10/10 against the same broker) plus test-plan cases A5, E1 and E2.
#
# Broker: TINA4_TEST_MQTT_URL, default mqtt://127.0.0.1:1883

require "spec_helper"
require_relative "support/mqtt_helpers"
require "securerandom"

RSpec.describe "Tina4::Mqtt sessions and resilience" do
  # Per EXAMPLE, not before(:all) — see spec/mqtt_spec.rb: a before(:context)
  # skip never reaches the after(:each) hook that records a
  # TINA4_REQUIRE_SERVICES violation, so it would slip past the CI gate.
  before do
    skip "Mosquitto MQTT broker not reachable at #{mqtt_test_url}" unless mqtt_broker_reachable?
  end

  # A durable session is keyed on the client id and outlives the process, so
  # every run gets its own ids and topics. Reusing them would let a previous
  # run's queued messages satisfy an assertion this run should have failed.
  let(:run_id) { "#{Process.pid}-#{SecureRandom.hex(4)}" }
  let(:prefix) { "tina4rb/session/#{run_id}" }
  let(:clients) { [] }
  let(:durable_ids) { [] }

  def client(**options)
    created = Tina4::Mqtt.new(**{ url: mqtt_test_url, timeout: 5 }.merge(options))
    clients << created
    created
  end

  # A durable (clean_session: false) client id, remembered so its session is
  # discarded from the broker when the example ends.
  def durable_client(client_id, **options)
    durable_ids << client_id unless durable_ids.include?(client_id)
    client(client_id: client_id, clean_session: false, **options)
  end

  after do
    clients.each do |open_client|
      open_client.disconnect
    rescue StandardError
      nil
    end
    # Connecting once with clean_session: true tells the broker to throw the
    # session (and anything still queued in it) away.
    durable_ids.each do |client_id|
      Tina4::Mqtt.new(url: mqtt_test_url, client_id: client_id, clean_session: true, timeout: 5).disconnect
    rescue StandardError
      nil
    end
  end

  # ── E1: offline replay with clean_session: false ──────────────────────────
  describe "durable session (clean_session: false)" do
    it "replays the QoS 1 messages published while we were OFFLINE, in order" do
      topic = "#{prefix}/telemetry"
      durable_id = "#{run_id}-durable"

      subscriber = durable_client(durable_id)
      expect(subscriber.subscribe(topic, qos: 1)).to eq(1)
      subscriber.disconnect # graceful, so the session persists

      publisher = client(client_id: "#{run_id}-durable-pub")
      3.times { |index| publisher.publish(topic, %({"n":#{index}}), qos: 1) }

      # Same client id, clean_session: false — the broker hands over what it
      # queued for us. This is what makes an intermittent SIM survivable.
      resumed = durable_client(durable_id)
      replayed = 3.times.map { resumed.receive(timeout: 5).payload }
      expect(replayed).to eq(['{"n":0}', '{"n":1}', '{"n":2}'])
    end

    it "keeps replayed PUBLISHes out of the SUBACK it is waiting for" do
      # The awkward ordering, and the reason the ack-wait inbox has to cover
      # SUBSCRIBE and not just PUBLISH: on a clean_session: false resume the
      # broker starts replaying queued QoS 1 messages the moment it sends
      # CONNACK — BEFORE our SUBSCRIBE goes out. So the first packets read while
      # waiting for the SUBACK are PUBLISHes. Mistaking one for the SUBACK loses
      # the message AND desynchronises the stream; dropping them loses the
      # replay the durable session exists to provide.
      topic = "#{prefix}/replay-before-suback"
      durable_id = "#{run_id}-replay-suback"

      subscriber = durable_client(durable_id)
      subscriber.subscribe(topic, qos: 1)
      subscriber.disconnect

      publisher = client(client_id: "#{run_id}-replay-suback-pub")
      3.times { |index| publisher.publish(topic, "queued-#{index}", qos: 1) }

      resumed = durable_client(durable_id)
      # Let the replay land in our socket buffer first, so the SUBACK wait is
      # guaranteed to read a PUBLISH before the SUBACK rather than by luck.
      sleep 0.3

      # The SUBACK must still be found, with its own packet identifier matched.
      expect(resumed.subscribe(topic, qos: 1)).to eq(1)

      # ...and not one replayed message may have been swallowed on the way.
      replayed = 3.times.map { resumed.receive(timeout: 5).payload }
      expect(replayed).to eq(%w[queued-0 queued-1 queued-2])
    end

    it "does NOT replay when clean_session is true (the flag is real, negative)" do
      topic = "#{prefix}/clean"
      clean_id = "#{run_id}-clean"

      subscriber = client(client_id: clean_id, clean_session: true)
      subscriber.subscribe(topic, qos: 1)
      subscriber.disconnect

      publisher = client(client_id: "#{run_id}-clean-pub")
      publisher.publish(topic, "lost", qos: 1)

      # A default of clean_session: true must not look like a durable session,
      # or an app would silently lose the data it thought was queued.
      resumed = client(client_id: clean_id, clean_session: true)
      resumed.subscribe(topic, qos: 1)
      expect { resumed.receive(timeout: 2) }.to raise_error(Tina4::MqttTimeoutError)
    end
  end

  # ── Keepalive ────────────────────────────────────────────────────────────
  #
  # The broker drops a client that goes quiet past 1.5x keepalive. That drop is
  # the mechanism the Last Will depends on — and it is also what silently kills a
  # long-lived consumer that forgets to PINGREQ.
  describe "keepalive" do
    it "is enforced by the broker: a SILENT client is dropped past 1.5x keepalive" do
      silent = client(client_id: "#{run_id}-silent", keepalive: 2)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { silent.receive(timeout: 10) }
        .to raise_error(Tina4::MqttError, /broker closed the connection/)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      # 1.5 x 2s = 3s. Bounded on BOTH sides: an instant failure would mean
      # something other than the keepalive closed the socket.
      expect(elapsed).to be_between(2.0, 8.0)
    end

    it "survives past 2x keepalive when the Background task is doing the pinging" do
      alive = client(client_id: "#{run_id}-alive", keepalive: 2)
      task = alive.start_keepalive
      begin
        sleep 5 # well past the 3s drop point, and past 2x keepalive
        expect(alive.ping).to be true
        expect(alive.connected?).to be true
      ensure
        alive.stop_keepalive
      end
      expect(task[:running]).to be false
    end

    it "registers exactly ONE cooperative Tina4::Background task, and only on request" do
      connection = client(client_id: "#{run_id}-ka-task", keepalive: 2)
      before_count = Tina4::Background.tasks.length

      task = connection.start_keepalive
      begin
        expect(Tina4::Background.tasks.length).to eq(before_count + 1)
        expect(Tina4::Background.tasks).to include(task)
        expect(task[:thread]).to be_a(Thread)
        expect(task[:interval]).to eq(1.0) # keepalive 2 -> ping every 1s
        # Calling it twice must not stack a second thread on one connection.
        expect(connection.start_keepalive).to equal(task)
        expect(Tina4::Background.tasks.length).to eq(before_count + 1)
      ensure
        connection.stop_keepalive
      end

      # stop_keepalive DEREGISTERS the task — the registry is back where it
      # started, not holding a stopped descriptor (see spec/background_spec.rb
      # ".stop_task"). This used to have to assert on the descriptor's own
      # fields because the dead task stayed in `tasks` forever.
      expect(Tina4::Background.tasks).not_to include(task)
      expect(Tina4::Background.tasks.length).to eq(before_count)
      expect(task[:running]).to be false
      expect(task[:thread]).to be_nil
      expect(connection.stop_keepalive).to be false # idempotent
    end
  end

  # ── A5: duplicate delivery ───────────────────────────────────────────────
  #
  # QoS 1 is at-least-once, so a duplicate is guaranteed eventually. A consumer
  # that cannot tell a redelivery from a new sample double-counts energy — the
  # bug that makes billing wrong.
  describe "redelivery and the DUP flag (A5)" do
    it "clears DUP on the first delivery and SETS it on the redelivery" do
      topic = "#{prefix}/dup"
      durable_id = "#{run_id}-dup"

      subscriber = durable_client(durable_id)
      subscriber.subscribe(topic, qos: 1)

      publisher = client(client_id: "#{run_id}-dup-pub")
      publisher.publish(topic, "once", qos: 1)

      # Read it but deliberately do NOT acknowledge, then drop the socket: a
      # consumer that died between receiving and storing.
      first = subscriber.receive(timeout: 5, ack: false)
      expect(first.payload).to eq("once")
      expect(first.duplicate?).to be false
      expect(first.acknowledged?).to be false
      subscriber.kill

      resumed = durable_client(durable_id)
      redelivered = resumed.receive(timeout: 5)
      expect(redelivered.payload).to eq("once")
      expect(redelivered.duplicate?).to be true
    end
  end

  # ── consume: acknowledge AFTER the handler ───────────────────────────────
  describe "#consume" do
    it "acknowledges only after the handler succeeded, so nothing is redelivered" do
      topic = "#{prefix}/consume-ok"
      durable_id = "#{run_id}-consume-ok"

      consumer = durable_client(durable_id)
      consumer.subscribe(topic, qos: 1)
      client(client_id: "#{run_id}-consume-ok-pub").publish(topic, "stored", qos: 1)

      handled = []
      expect(consumer.consume(iterations: 1, timeout: 5) { |message| handled << message.payload }).to eq(1)
      expect(handled).to eq(["stored"])
      consumer.kill # the acknowledgement already went out

      resumed = durable_client(durable_id)
      expect { resumed.receive(timeout: 2) }.to raise_error(Tina4::MqttTimeoutError)
    end

    it "leaves the message unacknowledged when the handler raises, so the broker redelivers it" do
      topic = "#{prefix}/consume-fail"
      durable_id = "#{run_id}-consume-fail"

      consumer = durable_client(durable_id)
      consumer.subscribe(topic, qos: 1)
      client(client_id: "#{run_id}-consume-fail-pub").publish(topic, "retry-me", qos: 1)

      # The raise propagates: a consumer that swallowed a storage failure would
      # acknowledge data it never stored, and the broker would forget it.
      expect { consumer.consume(iterations: 1, timeout: 5) { raise "disk full" } }
        .to raise_error(RuntimeError, "disk full")
      consumer.kill

      resumed = durable_client(durable_id)
      redelivered = resumed.receive(timeout: 5)
      expect(redelivered.payload).to eq("retry-me")
      expect(redelivered.duplicate?).to be true
    end

    it "yields messages as an Enumerator when no block is given" do
      topic = "#{prefix}/consume-enum"
      consumer = client(client_id: "#{run_id}-consume-enum")
      consumer.subscribe(topic, qos: 1)

      publisher = client(client_id: "#{run_id}-consume-enum-pub")
      2.times { |index| publisher.publish(topic, "m#{index}", qos: 1) }

      stream = consumer.consume(iterations: 2, timeout: 5)
      expect(stream).to be_a(Enumerator)
      expect(stream.map(&:payload)).to eq(%w[m0 m1])
    end
  end

  # ── E2: retained state + Last Will after a device dies ───────────────────
  describe "dead-device detection (E2)" do
    it "lets a LATE second subscriber see the retained Last Will of a device that already died" do
      topic = "#{prefix}/meter-77/status"

      watcher = client(client_id: "#{run_id}-e2-watch")
      watcher.subscribe(topic, qos: 1)

      # The device announces itself as retained state, then dies ungracefully.
      device = Tina4::Mqtt.new(url: mqtt_test_url, client_id: "#{run_id}-e2-device",
                               keepalive: 5, will_topic: topic, will_payload: "offline",
                               will_qos: 1, will_retain: true, timeout: 5)
      device.publish(topic, "online", qos: 1, retain: true)
      expect(watcher.receive(timeout: 3).payload).to eq("online")
      device.kill

      # The connected watcher observes the death as an event...
      expect(watcher.receive(timeout: 5).payload).to eq("offline")

      # ...and a dashboard that connects only AFTERWARDS still sees the current
      # state, because the will was retained. Silence would be indistinguishable
      # from a healthy device.
      late = client(client_id: "#{run_id}-e2-late")
      late.subscribe(topic, qos: 1)
      current = late.receive(timeout: 3)
      expect(current.payload).to eq("offline")
      expect(current.retained?).to be true

      client(client_id: "#{run_id}-e2-cleanup").publish(topic, "", qos: 1, retain: true)
    end
  end
end
