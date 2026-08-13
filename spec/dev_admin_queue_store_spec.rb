# frozen_string_literal: true

# Regression specs for TWO defects that share one root cause: nothing in the
# Ruby tree agreed on WHERE the queue files live.
#
#   1. The dev-admin queue panel LISTED a different store from the one it
#      COUNTED. /__dev/api/queue/topics scanned a hardcoded Dir.pwd/data/queue
#      while the lite backend wrote to Dir.pwd/.queue, so the topic list could
#      never name a real topic; /__dev/api/queue never listed pending or
#      reserved jobs at all, and listed a dead letter only when its attempt
#      count happened to clear the dev admin's OWN max_retries.
#   2. The lite backend ignored TINA4_QUEUE_PATH entirely and stored jobs at
#      Dir.pwd/.queue/<topic>/<id>.json - a different directory AND a different
#      file extension from Python, PHP and Node, which all use
#      <TINA4_QUEUE_PATH|data/queue>/<topic>/*.queue-data.
#
# Ruby now uses the canonical layout, and Tina4::Queue.base_path is the single
# answer to "where do the queue files live" that the backend and every
# dev-admin queue handler ask.
#
# NO MOCKS, NO DOUBLES, NO STAND-INS. A real Puma server is booted from a real
# scaffolded project on a real free port. Every job is a real file on disk -
# written either by the real file-backed queue or, for the legacy-layout cases,
# by hand in the exact pre-alignment on-disk format an existing app would have.
# Every endpoint assertion is made over real HTTP.
#
# THERE ARE NO BARE CONSTANTS IN THIS FILE. A bare constant inside an
# RSpec.describe block is defined on Object: it leaks into every other spec
# file in the run and clobbers any same-named constant there, producing a
# cross-file failure that only appears at certain seeds. Everything here is a
# method or an instance variable.

require "spec_helper"
require "json"
require "time"
require "cgi"
require "socket"
require "securerandom"
require "net/http"
require "timeout"
require "fileutils"
require "tmpdir"

RSpec.describe "dev-admin queue store (live server, real job files)", :slow, order: :defined do
  require "puma"

  # ── helpers ────────────────────────────────────────────────────────────

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def get_json(path)
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 30) do |http|
      response = http.get(path)
      [response.code.to_i, (JSON.parse(response.body) rescue response.body)]
    end
  end

  # A real Queue against the SAME store the running server reads, constructed
  # with the project as the working directory exactly as the server has it.
  def real_queue(topic, max_retries: 3)
    with_queue_path(@store) do
      Dir.chdir(@project) { Tina4::Queue.new(backend: :file, topic: topic, max_retries: max_retries) }
    end
  end

  def with_queue_path(path)
    saved = ENV["TINA4_QUEUE_PATH"]
    ENV["TINA4_QUEUE_PATH"] = path
    yield
  ensure
    saved.nil? ? ENV.delete("TINA4_QUEUE_PATH") : ENV["TINA4_QUEUE_PATH"] = saved
  end

  # Write a job file in the LEGACY on-disk format an existing Ruby app has:
  # <root>/.queue/<topic>/<id>.json. Written by hand on purpose - the fixed
  # code cannot produce this format, so the fixture has to be independent of
  # the code under test.
  def write_legacy_job(root, topic, id, payload)
    directory = File.join(root, ".queue", topic)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{id}.json"), JSON.generate(
      id: id, topic: topic, payload: payload, status: "pending",
      priority: 0, attempts: 0, error: nil, created_at: Time.now.utc.iso8601(6)
    ))
  end

  def canonical_job_files(base, topic)
    Dir.glob(File.join(base, topic, "*.queue-data")).sort
  end

  def statuses_of(jobs)
    jobs.map { |job| job["status"] }
  end

  def stats_sum(stats)
    %w[pending completed failed reserved].sum { |key| stats[key].to_i }
  end

  # ── one real server, booted once ───────────────────────────────────────

  before(:all) do
    @project = Dir.mktmpdir("tina4-queue-store-project-")
    # The store lives deliberately OUTSIDE <project>/data/queue, so a handler
    # that re-derives the path from the working directory instead of asking
    # Tina4::Queue.base_path reads the wrong tree and the spec catches it.
    @store = File.join(Dir.mktmpdir("tina4-queue-store-env-"), "jobs")
    @port = free_port

    FileUtils.mkdir_p(File.join(@project, "src", "routes"))

    # A STALE tree at the location the old handlers hardcoded. Nothing writes
    # here any more; if it shows up in the API the handler is reading the
    # working directory instead of the configured store.
    FileUtils.mkdir_p(File.join(@project, "data", "queue", "ghost-topic-never-real"))
    File.write(
      File.join(@project, "data", "queue", "ghost-topic-never-real", "stale.queue-data"),
      JSON.generate(id: "stale-ghost", topic: "ghost-topic-never-real", payload: { "stale" => true },
                    status: "pending", priority: 0, attempts: 0, created_at: Time.now.utc.iso8601(6))
    )

    # Real jobs in the LEGACY layout, as an app upgrading across this change
    # has them. TINA4_QUEUE_PATH is set for this server, which is the case that
    # matters most: the old code ignored the variable, so even an operator who
    # had set it has their jobs sitting in .queue/.
    @legacy_ids = %w[legacy-job-alpha legacy-job-beta]
    @legacy_ids.each_with_index do |id, index|
      write_legacy_job(@project, "legacy", id, { "n" => index })
    end

    File.write(File.join(@project, ".env"), <<~ENV)
      TINA4_DEBUG=true
      TINA4_LOG_LEVEL=NONE
      TINA4_AUTO_MIGRATE=false
    ENV

    lib = File.expand_path("../lib", __dir__)
    File.write(File.join(@project, "config.ru"), <<~RU)
      $LOAD_PATH.unshift(#{lib.inspect})
      require "tina4"
      Tina4.initialize!(#{@project.inspect})
      run Tina4::RackApp.new(root_dir: #{@project.inspect})
    RU

    @log_path = File.join(@project, "puma.log")
    @pid = spawn(
      {
        "TINA4_DEBUG" => "true",
        "TINA4_LOG_LEVEL" => "NONE",
        "TINA4_AUTO_MIGRATE" => "false",
        "TINA4_QUEUE_PATH" => @store,
        "TINA4_NO_AI_PORT" => "true",
        "TINA4_OVERRIDE_CLIENT" => "true"
      },
      RbConfig.ruby, Gem.bin_path("puma", "puma"),
      "-b", "tcp://127.0.0.1:#{@port}", File.join(@project, "config.ru"),
      chdir: @project, out: @log_path, err: @log_path
    )

    ready = false
    deadline = Time.now + 30
    while Time.now < deadline
      begin
        code, = get_json("/__dev/api/status")
        (ready = true) && break if code == 200
      rescue StandardError
        # not up yet
      end
      sleep 0.2
    end
    unless ready
      log = File.exist?(@log_path) ? File.read(@log_path) : "(no log)"
      raise "Puma never came up on #{@port}\n--- puma.log ---\n#{log}"
    end
  end

  after(:all) do
    if @pid
      Process.kill("TERM", @pid) rescue nil
      begin
        Timeout.timeout(5) { Process.waitpid(@pid) }
      rescue StandardError
        Process.kill("KILL", @pid) rescue nil
      end
    end
    FileUtils.remove_entry(@project) rescue nil
    FileUtils.remove_entry(File.dirname(@store)) rescue nil
  end

  # ── 1. the legacy store is rescued, not stranded ───────────────────────
  #
  # Runs FIRST (order: :defined) so the rescue is performed by the SERVER at
  # its own first queue construction, over real HTTP, rather than by a Queue
  # this spec built.

  it "rescues jobs left in the legacy .queue store and serves them from the new one" do
    code, body = get_json("/__dev/api/queue?topic=legacy")
    expect(code).to eq(200)

    listed = body["jobs"].map { |job| job["id"] }
    expect(listed).to match_array(@legacy_ids)
    expect(body["stats"]["pending"]).to eq(2)
  end

  it "moved the legacy files onto the canonical path and extension, losing nothing" do
    migrated = canonical_job_files(@store, "legacy")
    expect(migrated.length).to eq(2)
    expect(migrated.map { |path| File.basename(path) })
      .to match_array(@legacy_ids.map { |id| "#{id}.queue-data" })

    # Payloads survived the move intact - a migration that loses the body is a
    # migration that lost the job.
    payloads = migrated.map { |path| JSON.parse(File.read(path))["payload"] }
    expect(payloads).to match_array([{ "n" => 0 }, { "n" => 1 }])

    # The legacy job files are gone from .queue (moved, not copied), so the
    # same job can never be delivered twice.
    expect(Dir.glob(File.join(@project, ".queue", "**", "*.json"))).to be_empty
  end

  it "hands a rescued legacy job to a real consumer" do
    queue = real_queue("legacy")
    job = queue.pop
    expect(job).not_to be_nil
    expect(@legacy_ids).to include(job.id)
    job.complete
    expect(queue.size(status: "pending")).to eq(1)
  end

  # ── 2. the topic list names the REAL store ─────────────────────────────

  it "lists topics from the configured store, not the working directory" do
    real_queue("orders").push({ "sku" => "A1" })

    code, body = get_json("/__dev/api/queue/topics")
    expect(code).to eq(200)
    expect(body["topics"]).to include("orders")

    # NEGATIVE: the stale tree under <cwd>/data/queue is not the store.
    expect(body["topics"]).not_to include("ghost-topic-never-real")
    # NEGATIVE: the shared dead-letter directory is a sibling of the topic
    # directories, not a topic.
    expect(body["topics"]).not_to include("dead_letter")
  end

  # ── 3. pending jobs are listed at all ──────────────────────────────────

  it "lists PENDING jobs, which the panel never showed before" do
    queue = real_queue("pendinglist")
    3.times { |index| queue.push({ "index" => index }) }

    code, body = get_json("/__dev/api/queue?topic=pendinglist")
    expect(code).to eq(200)
    expect(body["jobs"].length).to eq(3)
    expect(statuses_of(body["jobs"]).uniq).to eq(["pending"])
    expect(body["stats"]["pending"]).to eq(3)
  end

  # ── 4. reserved jobs are listed, exactly once ──────────────────────────

  it "lists a RESERVED job that stats.reserved counts" do
    queue = real_queue("reservedlist")
    queue.push({ "job" => "held" })
    held = queue.pop # writes a real reservation record under reserved/
    expect(held).not_to be_nil

    code, body = get_json("/__dev/api/queue?topic=reservedlist")
    expect(code).to eq(200)
    expect(body["stats"]["reserved"]).to eq(1)
    expect(body["stats"]["pending"]).to eq(0)

    reserved = body["jobs"].select { |job| job["status"] == "reserved" }
    expect(reserved.length).to eq(1)
    expect(reserved.first["id"]).to eq(held.id)
    expect(body["jobs"].length).to eq(1)
  end

  # ── 5. a dead letter under the app's own max_retries is listed ─────────

  it "lists a dead letter the dev admin's own max_retries would have hidden" do
    # max_retries: 1 means ONE failure dead-letters the job with attempts == 1.
    # queue.dead_letters filters on the dev admin's own max_retries (3), so a
    # list built from it counted this job and never showed it.
    queue = real_queue("shortretry", max_retries: 1)
    queue.push({ "job" => "doomed" })
    job = queue.pop
    job.fail("boom")

    code, body = get_json("/__dev/api/queue?topic=shortretry")
    expect(code).to eq(200)
    expect(body["stats"]["failed"]).to eq(1)

    dead = body["jobs"].select { |listed| listed["status"] == "dead_letter" }
    expect(dead.length).to eq(1)
    expect(dead.first["attempts"]).to eq(1)
  end

  it "shows that same dead letter on the dead-letters endpoint" do
    code, body = get_json("/__dev/api/queue/dead-letters?topic=shortretry")
    expect(code).to eq(200)
    expect(body["count"]).to eq(1)
    expect(body["jobs"].first["status"]).to eq("dead_letter")
  end

  # ── 6. a failed-but-retryable job is one row with one status ───────────

  it "lists a failed-but-retryable job ONCE, as the pending job it is" do
    # Under the auto-retry lifecycle this job is written back to the PENDING
    # directory with attempts == 1, so stats.pending counts it. It used to be
    # listed by queue.failed() as "failed" as well - one job, counted pending,
    # shown failed.
    queue = real_queue("retryable", max_retries: 3)
    queue.push({ "job" => "retry-me" })
    job = queue.pop
    job.fail("transient")

    code, body = get_json("/__dev/api/queue?topic=retryable")
    expect(code).to eq(200)
    expect(body["stats"]["pending"]).to eq(1)
    expect(body["stats"]["failed"]).to eq(0)

    expect(body["jobs"].length).to eq(1)
    expect(body["jobs"].first["status"]).to eq("pending")
    expect(body["jobs"].first["attempts"]).to eq(1)
    expect(statuses_of(body["jobs"])).not_to include("failed")
  end

  # ── 7. the invariant, on a topic holding one of everything ─────────────

  it "keeps sum(stats) == jobs.length with every bucket occupied at once" do
    queue = real_queue("mixed", max_retries: 1)
    queue.push({ "which" => "stays-pending" })
    queue.push({ "which" => "gets-reserved" })
    queue.push({ "which" => "gets-dead-lettered" })

    reserved = queue.pop
    doomed = queue.pop
    doomed.fail("dead")
    expect(reserved).not_to be_nil

    code, body = get_json("/__dev/api/queue?topic=mixed")
    expect(code).to eq(200)

    stats = body["stats"]
    expect(stats["pending"]).to eq(1)
    expect(stats["reserved"]).to eq(1)
    expect(stats["failed"]).to eq(1)
    expect(stats_sum(stats)).to eq(body["jobs"].length)

    expect(statuses_of(body["jobs"]).sort).to eq(%w[dead_letter pending reserved])
    expect(body["jobs"].map { |job| job["id"] }.uniq.length).to eq(3)
  end

  # ── 8. every ?status= filter returns exactly what its stat counts ──────

  it "returns exactly what each stat counts for every ?status= filter" do
    _, unfiltered = get_json("/__dev/api/queue?topic=mixed")
    stats = unfiltered["stats"]

    {
      "pending" => stats["pending"],
      "reserved" => stats["reserved"],
      "failed" => stats["failed"]
    }.each do |status, expected_count|
      _, filtered = get_json("/__dev/api/queue?topic=mixed&status=#{status}")
      expect(filtered["jobs"].length).to eq(expected_count),
                                        "?status=#{status} listed #{filtered["jobs"].length} " \
                                        "jobs but stats says #{expected_count}"
    end

    # "dead" is the alias for the failed bucket, as in Python and Node.
    _, dead = get_json("/__dev/api/queue?topic=mixed&status=dead")
    expect(dead["jobs"].length).to eq(stats["failed"])
    expect(statuses_of(dead["jobs"]).uniq).to eq(["dead_letter"])

    # "completed" is the fifth badge the panel itself sends. The file backend
    # deletes on complete, so its stat is 0 — and its list must be empty for
    # the same reason, not by accident.
    _, completed = get_json("/__dev/api/queue?topic=mixed&status=completed")
    expect(stats["completed"]).to eq(0)
    expect(completed["jobs"]).to eq([])
  end

  it "emits exactly one status key per job" do
    # j.merge(status: ...) added a SYMBOL key beside the record's existing
    # STRING one, so the JSON carried a duplicate "status" name.
    Net::HTTP.start("127.0.0.1", @port, open_timeout: 5, read_timeout: 30) do |http|
      raw = http.get("/__dev/api/queue?topic=mixed").body
      job_count = JSON.parse(raw)["jobs"].length
      expect(job_count).to eq(3)
      # No payload on this topic carries a "status" field, so every occurrence
      # in the wire bytes belongs to a job record. One per job means no record
      # went out with two of them.
      expect(raw.scan(/"status"\s*:/).length).to eq(job_count)
    end
  end

  it "lists an unreadable job file, because size() counts it" do
    # Queue#size globs without parsing, so a corrupt record still counts. If
    # the list quietly skipped it the panel would show a total it could not
    # account for - and nobody would ever learn the file was there.
    queue = real_queue("corrupt")
    queue.push({ "readable" => true })
    File.write(File.join(@store, "corrupt", "broken-job.queue-data"), "{ not json at all")

    code, body = get_json("/__dev/api/queue?topic=corrupt")
    expect(code).to eq(200)
    expect(body["stats"]["pending"]).to eq(2)
    expect(body["jobs"].length).to eq(2)
    expect(stats_sum(body["stats"])).to eq(body["jobs"].length)

    broken = body["jobs"].find { |job| job["id"] == "broken-job" }
    expect(broken).not_to be_nil
    expect(broken["status"]).to eq("pending")
    expect(broken["error"]).to match(/unreadable/i)
  end

  # ── 9. the topic comes off a query string, so it cannot address a path ──

  it "cannot be walked out of the store by a ../ topic" do
    # A REAL job file one level above the store, exactly where File.join(base,
    # "..") lands. An unsanitised topic would glob it up and serve it.
    escapee = File.join(File.dirname(@store), "outside-the-store.queue-data")
    File.write(escapee, JSON.generate(id: "escaped", topic: "..", payload: { "secret" => true },
                                      status: "pending", attempts: 0))

    code, body = get_json("/__dev/api/queue?topic=#{CGI.escape('..')}")
    expect(code).to eq(200)
    expect(body["jobs"]).to eq([])
    expect(body["stats"]["pending"]).to eq(0)

    code, deeper = get_json("/__dev/api/queue?topic=#{CGI.escape('../../../../etc')}")
    expect(code).to eq(200)
    expect(deeper["jobs"]).to eq([])

    # Still there — the traversal was refused, not served and not deleted.
    expect(File.exist?(escapee)).to be(true)
  ensure
    File.delete(escapee) if escapee && File.exist?(escapee)
  end

  # ── 10. TINA4_QUEUE_PATH is honoured by the store itself ───────────────

  it "writes jobs under TINA4_QUEUE_PATH, never under .queue" do
    real_queue("envpath").push({ "hello" => "store" })

    expect(canonical_job_files(@store, "envpath").length).to eq(1)
    expect(Dir.exist?(File.join(@project, ".queue", "envpath"))).to be(false)
    expect(Dir.exist?(File.join(@project, "data", "queue", "envpath"))).to be(false)
  end

  # ── 11. the DEFAULT store, with no TINA4_QUEUE_PATH set at all ─────────

  it "defaults to data/queue and rescues a legacy store there too" do
    project = Dir.mktmpdir("tina4-queue-default-")
    begin
      write_legacy_job(project, "defaulted", "legacy-default-job", { "kept" => true })

      job_id = nil
      payload = nil
      saved = ENV["TINA4_QUEUE_PATH"]
      ENV.delete("TINA4_QUEUE_PATH")
      begin
        Dir.chdir(project) do
          queue = Tina4::Queue.new(backend: :file, topic: "defaulted")
          expect(queue.size(status: "pending")).to eq(1)
          job = queue.pop
          job_id = job&.id
          payload = job&.payload
        end
      ensure
        ENV["TINA4_QUEUE_PATH"] = saved unless saved.nil?
      end

      expect(job_id).to eq("legacy-default-job")
      expect(payload).to eq({ "kept" => true })

      # It landed on the canonical default path, with the canonical extension.
      expect(Dir.exist?(File.join(project, "data", "queue", "defaulted"))).to be(true)
      expect(Dir.glob(File.join(project, ".queue", "**", "*.json"))).to be_empty
    ensure
      FileUtils.remove_entry(project) rescue nil
    end
  end

  it "does not touch a store handed to it explicitly" do
    # An explicit dir: is the caller's decision - no resolver, no migration.
    explicit = Dir.mktmpdir("tina4-queue-explicit-")
    project = Dir.mktmpdir("tina4-queue-explicit-project-")
    begin
      write_legacy_job(project, "untouched", "should-stay-put", { "x" => 1 })
      Dir.chdir(project) do
        backend = Tina4::QueueBackends::LiteBackend.new(dir: explicit)
        expect(backend.size("untouched")).to eq(0)
      end
      expect(File.exist?(File.join(project, ".queue", "untouched", "should-stay-put.json"))).to be(true)
    ensure
      FileUtils.remove_entry(explicit) rescue nil
      FileUtils.remove_entry(project) rescue nil
    end
  end
end
