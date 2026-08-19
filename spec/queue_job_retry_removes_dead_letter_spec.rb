# frozen_string_literal: true
#
# Regression: job.retry on a dead-lettered job must remove the dead-letter
# file, not leave a duplicate on disk.
#
# 3.13.105 (parity port of PY-12-05). Before the fix, LiteBackend#retry(job)
# (the path Job#retry calls) re-queued the job to the pending directory but
# never unlinked the file under the dead-letter directory. Because
# dead_letters scans that directory, a manual dead-letter recovery loop
# — retain a Job reference from pop, call job.retry after fail — left the
# dead-letter store carrying every "revived" job, so dead_letters reported
# the same items on the next call and a consumer that acted on both lists
# processed the job twice.
#
# Contrast: Queue#retry(job_id) and no-arg Queue#retry route through
# LiteBackend#retry_job(id) (a different method) which DID unlink correctly.
# Two spellings of the same intent that diverged — the fix aligns them.
#
# NOT a mock: a real file-backed queue on disk.

require "spec_helper"
require "tmpdir"

module QueueJobRetryUnlinkDLContract
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

  # Push two jobs, fail each, return the queue AND the two retained Job refs
  # (still carrying the queue reference from pop) so the caller can invoke
  # job.retry — the exact bug surface.
  def dead_letter_two_jobs(tmp)
    ENV["TINA4_QUEUE_PATH"] = File.join(tmp, "job_retry_clean")
    ENV["TINA4_QUEUE_BACKEND"] = "file"
    q = Tina4::Queue.new(topic: "job_retry_clean", max_retries: 1)
    jobs = []
    2.times { |i| q.push({ "task" => "doomed-#{i}" }) }
    2.times do
      j = q.pop
      raise "prime failed: pop returned nil" if j.nil?
      j.fail("boom")
      jobs << j
    end
    raise "prime: expected two dead letters, got #{q.dead_letters.length}" \
      unless q.dead_letters.length == 2
    [q, jobs]
  end
end

RSpec.describe "job.retry removes the dead-letter file" do
  around(:each) { |example| QueueJobRetryUnlinkDLContract.around(example) }

  around(:each) do |example|
    Dir.mktmpdir("tina4-jobretry-dl") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  it "positive: iterating dead-lettered jobs and calling job.retry empties the DL store" do
    # Same pattern as `for j in q.dead_letters(): j.retry()` in Python — Ruby's
    # dead_letters returns hashes, so we retain the Job references from pop
    # (which carry the queue backref that Job#retry needs) to reach the same
    # code path.
    q, jobs = QueueJobRetryUnlinkDLContract.dead_letter_two_jobs(@tmp)

    jobs.each(&:retry)

    expect(q.dead_letters).to eq([]),
                              "dead-letter store must be empty after job.retry revives every job; a leftover " \
                              "file re-appears on the next dead_letters call and the job is processed twice"
  end

  it "negative: retrieving via job.retry still lands the job in pending" do
    # The unlink must not accidentally drop the requeue path.
    q, jobs = QueueJobRetryUnlinkDLContract.dead_letter_two_jobs(@tmp)

    jobs.each(&:retry)

    expect(q.size(status: "pending")).to eq(2),
                                         "expected two pending jobs after revival, got " \
                                         "#{q.size(status: 'pending')}"
  end
end
