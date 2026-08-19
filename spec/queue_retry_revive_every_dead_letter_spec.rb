# frozen_string_literal: true
#
# Regression: Queue#retry with no args must revive EVERY dead letter.
#
# 3.13.105 (parity lock-in of PY-12-04). Python's bug was that the no-arg branch
# used any(retry_job(j.id) for j in dead), so the short-circuiting any() stopped
# iterating on the FIRST truthy result and silently left the rest in the store.
#
# In Ruby the no-arg branch delegates to LiteBackend#retry_job(topic, job_id:
# nil), which iterates every dead-letter file with `.each` and counts (no
# short-circuit). So Ruby is already safe; this file LOCKS IN that safety so a
# future refactor that switches to `dead.any? { |j| backend.retry_job(j.id) }`
# would fail here before it ships.
#
# NOT a mock: a real file-backed queue on disk with real dead-letters written
# through pop/fail lifecycle.

require "spec_helper"
require "tmpdir"

module QueueRetryReviveAllContract
  ENV_KEYS = %w[TINA4_QUEUE_BACKEND TINA4_QUEUE_PATH].freeze

  module_function

  def around(example)
    saved = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    begin
      example.run
    ensure
      ENV_KEYS.each { |k| saved[k].nil? ? ENV.delete(k) : ENV[k] = saved[k] }
    end
  end

  def dead_letter_three_jobs(tmp)
    ENV["TINA4_QUEUE_PATH"] = File.join(tmp, "revive_all")
    ENV["TINA4_QUEUE_BACKEND"] = "file"
    q = Tina4::Queue.new(topic: "revive_all", max_retries: 1)
    3.times { |i| q.push({ "task" => "doomed-#{i}" }) }
    # Fail each once — attempts=1 == max_retries=1 -> dead.
    3.times do
      job = q.pop
      raise "prime failed: could not pop the job" if job.nil?
      job.fail("err")
    end
    raise "prime failed: three dead letters expected, got #{q.dead_letters.length}" \
      unless q.dead_letters.length == 3
    raise "prime failed: pending should be 0" unless q.size(status: "pending") == 0
    q
  end
end

RSpec.describe "Queue#retry (no arg) revives every dead letter" do
  around(:each) { |example| QueueRetryReviveAllContract.around(example) }

  around(:each) do |example|
    Dir.mktmpdir("tina4-retry-revive-all") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "positive: retry with no arg revives all three dead letters" do
    q = QueueRetryReviveAllContract.dead_letter_three_jobs(@tmp)

    ok = q.retry

    expect(ok).to be(true), "at least one dead letter should have been revived"
    expect(q.size(status: "pending")).to eq(3),
                                         "expected all three dead letters revived, got size(pending)=" \
                                         "#{q.size(status: 'pending')}; an any-short-circuit only re-queues the first"
  end

  it "negative: retry with no arg leaves the dead-letter store empty" do
    # A successful retry() must fully consume the dead-letter store — a
    # leftover would lead to double-processing on a later retry().
    q = QueueRetryReviveAllContract.dead_letter_three_jobs(@tmp)

    q.retry

    expect(q.dead_letters).to eq([]),
                              "no dead letter must remain after retry() revives all three; " \
                              "stale entries lead to double-processing on a later retry()"
  end
end
