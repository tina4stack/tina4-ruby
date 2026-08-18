# frozen_string_literal: true
#
# Regression: MongoDB Queue#retry(job_id) revives a dead letter, and
# Queue#purge(status) returns a real deleted count for every status.
#
# 3.13.105 (parity port of the MongoDB retry_job/purge fixes on Python master).
#
# The two behaviours pinned here have different root causes across the
# frameworks — because Ruby's Mongo model stores the dead letter as the SAME
# document with its topic flipped to "<topic>.dead_letter", Ruby's retry_job
# lookup by _id already works for the primary fail() path. Purge is a real
# defect in every framework: pre-fix, Ruby's purge(status) delete_many'd on
# {topic: topic, status: status}, so purge("dead"/"failed"/"dead_letter")
# never matched the dead-letter documents (they live under the
# ".dead_letter" topic namespace) and returned 0 silently.
#
# Named positive AND negative cases for both retry_job and purge; each proven
# a real gate. NOT a mock: real live MongoDB. Skipped when unreachable — the
# lab provisions Mongo on 127.0.0.1:27017 and this suite runs there under
# TINA4_REQUIRE_SERVICES=1 (the spec_helper gate then turns a skip into a
# hard failure).
#
# A bare constant declared inside an RSpec.describe block lands on Object
# (GLOBAL); every constant here is prefixed MQRP_ so it cannot clobber
# another spec file's PORT/HOST/TOPIC.

require "spec_helper"
require "securerandom"
require "socket"

MQRP_MONGO_HOST = ENV.fetch("TINA4_TEST_MONGO_HOST", "127.0.0.1")
MQRP_MONGO_PORT = ENV.fetch("TINA4_TEST_MONGO_PORT", "27017").to_i

def mqrp_reachable?(host, port)
  Socket.tcp(host, port, connect_timeout: 2, &:close)
  true
rescue StandardError
  false
end

module MQRPContract
  ENV_KEYS = %w[
    TINA4_QUEUE_BACKEND TINA4_QUEUE_URL
    TINA4_MONGO_URI TINA4_MONGO_HOST TINA4_MONGO_PORT
  ].freeze

  module_function

  def around(example)
    saved = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    ENV["TINA4_QUEUE_BACKEND"] = "mongodb"
    ENV["TINA4_QUEUE_URL"] = "mongodb://#{MQRP_MONGO_HOST}:#{MQRP_MONGO_PORT}"
    begin
      example.run
    ensure
      ENV_KEYS.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  # Push a job, fail it once — max_retries=1 dead-letters immediately.
  # Returns the original job id. Does NOT assert absolute totals so callers
  # may stack multiple dead-letters.
  def dead_letter_one(q)
    prior = q.dead_letters.length
    id = SecureRandom.uuid
    q.push({ "task" => "doomed" })
    job = q.pop
    raise "prime failed: pop returned nil" if job.nil?
    job_id = job.id
    job.fail("boom") # attempts=1 == max_retries=1 -> dead
    raise "prime failed: dead_letters grew by #{q.dead_letters.length - prior}, " \
          "expected +1 (want #{prior + 1}, got #{q.dead_letters.length})" \
      unless q.dead_letters.length == prior + 1
    job_id
  end
end

RSpec.describe "Queue on MongoDB — retry_job + purge (live, no mocks)" do
  before(:all) do
    unless mqrp_reachable?(MQRP_MONGO_HOST, MQRP_MONGO_PORT)
      if ENV["TINA4_REQUIRE_SERVICES"]
        raise "TINA4_REQUIRE_SERVICES is set but MongoDB is not reachable at " \
              "#{MQRP_MONGO_HOST}:#{MQRP_MONGO_PORT}"
      end
      skip "MongoDB not reachable at #{MQRP_MONGO_HOST}:#{MQRP_MONGO_PORT}"
    end
  end

  around(:each) { |example| MQRPContract.around(example) }

  # Fresh, uniquely-named topic per example so re-runs against the same Mongo
  # never contaminate. Cleaned up at the end even on exception.
  around(:each) do |example|
    topic = "mongo_retry_#{SecureRandom.hex(5)}"
    @topic = topic
    @queue = Tina4::Queue.new(topic: topic, max_retries: 1)
    begin
      example.run
    ensure
      begin
        coll = @queue.backend.instance_variable_get(:@db)
                     [@queue.backend.instance_variable_get(:@collection_name)]
        coll.delete_many(topic: topic)
        coll.delete_many(topic: "#{topic}.dead_letter")
      rescue StandardError
        # Best-effort — never mask a spec failure
      end
      @queue.close
    end
  end

  describe "retry_job" do
    it "positive: retry(id) on a genuine dead letter revives it and empties the DL store" do
      q = @queue
      job_id = MQRPContract.dead_letter_one(q)

      ok = q.retry(job_id)

      expect(ok).to be(true),
                    "retry(id) must revive an existing dead letter; before 3.13.105 the search filter " \
                    "was wrong (topic + status + _id all mismatched) and it returned false for every id"
      expect(q.dead_letters.length).to eq(0),
                                       "the dead-letter store must be empty after a successful revival; " \
                                       "leftovers cause double-processing"
      expect(q.size(status: "pending")).to eq(1),
                                           "the revived job must be visible to pop as pending"
      revived = q.pop
      expect(revived).not_to be_nil
      expect(revived.id).to eq(job_id),
                            "revived job's id must match the original (payload continuity)"
    end

    it "negative: retry(id) returns false for an unknown id" do
      q = @queue
      ok = q.retry("does-not-exist-#{SecureRandom.hex(8)}")

      expect(ok).to be(false),
                    "retry(id) must return false when no dead letter matches"
      expect(q.size(status: "pending")).to eq(0)
      expect(q.dead_letters.length).to eq(0)
    end
  end

  describe "purge" do
    it "positive: purge('pending') deletes only pending docs and returns the count" do
      q = @queue
      q.push({ "n" => 1 })
      q.push({ "n" => 2 })
      q.push({ "n" => 3 })
      expect(q.size(status: "pending")).to eq(3)

      removed = q.purge("pending")

      expect(removed).to eq(3),
                         "purge('pending') must return the deleted count, got #{removed.inspect}"
      expect(q.size(status: "pending")).to eq(0)
    end

    it "negative: purge('pending') leaves dead letters alone" do
      # pre-3.13.105 route defect: purge was scoped to {topic:, status:} but
      # if that had ever devolved into a full-topic delete_many it would take
      # the .dead_letter namespace with it. Scope guard.
      q = @queue
      MQRPContract.dead_letter_one(q)                     # 1 dead letter
      q.push({ "n" => "keep-pending" })                   # 1 fresh pending
      expect(q.size(status: "pending")).to eq(1)
      expect(q.dead_letters.length).to eq(1)

      q.purge("pending")

      expect(q.size(status: "pending")).to eq(0),
                                           "purge should have removed the pending"
      expect(q.dead_letters.length).to eq(1),
                                       "purge('pending') removed the dead letter — purge must scope by status, " \
                                       "never nuke the whole topic namespace"
    end

    it "positive: purge('dead') removes dead letters and returns the count" do
      # This is the routing defect in Ruby: purge('dead') used to delete on
      # {topic: topic, status: 'dead'}, but dead docs live under the
      # topic.dead_letter namespace, so it never matched and returned 0.
      q = @queue
      MQRPContract.dead_letter_one(q)
      MQRPContract.dead_letter_one(q)
      expect(q.dead_letters.length).to eq(2)

      removed = q.purge("dead")

      expect(removed).to eq(2),
                         "purge('dead') must return the deleted dead-letter count, got #{removed.inspect}"
      expect(q.dead_letters.length).to eq(0)
    end
  end
end
