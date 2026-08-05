# frozen_string_literal: true
require "json"
require "fileutils"
require "time"

module Tina4
  module QueueBackends
    # File-based queue backend — JSON files on disk. Zero dependencies.
    #
    # Each job is stored as a separate .queue-data file under <dir>/<topic>/,
    # where <dir> is Tina4::Queue.base_path (TINA4_QUEUE_PATH, else data/queue)
    # — the canonical cross-framework layout Python, PHP and Node all use.
    # Dead-lettered jobs (those that exhausted their retries) live under the
    # shared <dir>/dead_letter/ directory, tagged with their topic.
    #
    # Dequeue policy: highest priority first, ties broken oldest-first by the
    # stored created_at (ISO-8601, so lexicographic == chronological). The
    # file name is NOT the ordering key — the stored priority/created_at are.
    class LiteBackend
      # The store's layout — extension, topic segment, dead-letter directory —
      # is defined once on Tina4::Queue and shared with the dev-admin panel
      # that reads the same files.
      JOB_EXTENSION = Tina4::Queue::JOB_EXTENSION

      # The pre-alignment Ruby store: Dir.pwd/.queue/<topic>/<id>.json. Read
      # once per backend so an upgrading app's jobs are rescued rather than
      # stranded (see migrate_legacy_store).
      LEGACY_DIRNAME = ".queue"
      LEGACY_JOB_EXTENSION = ".json"

      # Retry policy — settable so a Queue can propagate its own max_retries /
      # retry_backoff onto a backend instance passed directly (legacy path).
      attr_accessor :max_retries, :retry_backoff

      def initialize(options = {})
        # An explicit dir: is the caller's own store — take it as given. Only a
        # store we RESOLVED is one the legacy rescue may touch.
        resolved_store = options[:dir].nil?
        @dir = options[:dir] || Tina4::Queue.base_path
        @dead_letter_dir = File.join(@dir, Tina4::Queue::DEAD_LETTER_DIRNAME)
        # Retry policy. Mirrors the Python lite backend: a failed job is
        # re-enqueued while attempts < max_retries, then dead-lettered.
        @max_retries = options[:max_retries] || 3
        # Seconds to delay a job's next attempt when fail() re-enqueues it.
        # 0 (default) = retry on the very next pop/consume iteration.
        @retry_backoff = options[:retry_backoff] || 0
        # Reservation/visibility timeout (seconds). When a job is popped it is
        # held in <topic>/reserved/ with available_at = now + visibility_timeout.
        # If the consumer dies before complete()/fail() (crash, OOM, k8s
        # eviction) the next pop() reclaims it once the window expires —
        # incrementing attempts and re-enqueuing, or dead-lettering past
        # max_retries. <= 0 disables the reclaim (a reservation then lasts until
        # the consumer acks — the old at-most-once behaviour).
        @visibility_timeout = options[:visibility_timeout] || 300.0
        FileUtils.mkdir_p(@dir)
        FileUtils.mkdir_p(@dead_letter_dir)
        @mutex = Mutex.new
        migrate_legacy_store if resolved_store
      end

      # Retry/visibility policy is settable so a Queue can propagate its own
      # configuration onto a backend instance passed directly (legacy path).
      attr_accessor :visibility_timeout

      def enqueue(message)
        @mutex.synchronize do
          topic_dir = topic_path(message.topic)
          FileUtils.mkdir_p(topic_dir)
          path = job_file(topic_dir, message.id)
          File.write(path, message.to_json)
        end
      end

      def dequeue(topic)
        @mutex.synchronize do
          # First return any reservations whose consumer died mid-flight.
          reclaim_expired(topic)
          candidate = available_candidates(topic).first
          return nil unless candidate

          # Write the reservation BEFORE claiming the pending file, so a crash
          # between claim and reserve can never strand the job. Only the worker
          # that wins the delete owns — and returns — it.
          write_reserved(candidate[:data], topic)
          begin
            File.delete(candidate[:file])
          rescue Errno::ENOENT
            return nil # already consumed by another worker
          end
          job_from_data(candidate[:data], topic)
        end
      end

      def dequeue_batch(topic, count)
        @mutex.synchronize do
          reclaim_expired(topic)
          chosen = available_candidates(topic).first(count)
          chosen.filter_map do |c|
            write_reserved(c[:data], topic)
            begin
              File.delete(c[:file])
            rescue Errno::ENOENT
              next
            end
            job_from_data(c[:data], topic)
          end
        end
      end

      # Find a specific pending job by id, claim it (delete the file) and
      # return it. Returns nil when no pending job with that id exists.
      def find_by_id(topic, id)
        @mutex.synchronize do
          dir = topic_path(topic)
          return nil unless Dir.exist?(dir)

          target = id.to_s
          job_files(dir).each do |f|
            data = JSON.parse(File.read(f))
            next unless data["id"].to_s == target

            # Reserve (so a dead consumer's job is reclaimable) then claim the
            # pending file — mirrors dequeue.
            write_reserved(data, topic)
            File.delete(f)
            return job_from_data(data, topic)
          rescue JSON::ParserError
            next
          end
          nil
        end
      end

      def acknowledge(message)
        # File already deleted on dequeue — nothing to do.
      end

      def complete(message)
        # The pending file was claimed on dequeue and a reservation record
        # written; complete() is terminal, so drop the reservation. The job is
        # done and gone.
        clear_reservation(message.topic, message.id)
      end

      def requeue(message)
        enqueue(message)
      end

      # Record a failed attempt. Increments attempts and stores the error.
      # While attempts < max_retries the job is re-enqueued to pending (after
      # the configured retry_backoff). Once attempts >= max_retries it is moved
      # to the dead-letter store.
      def fail(job, error = "")
        # Clear the reservation — the consumer acknowledged (with a failure).
        clear_reservation(job.topic, job.id)
        job.attempts += 1
        job.error = error
        if job.attempts < @max_retries
          requeue_job(job, delay_seconds: @retry_backoff, error: error)
        else
          move_to_dead_letter(job, error)
        end
      end

      # Explicit re-queue requested by the caller (job.retry()). Always
      # re-enqueues regardless of the retry limit — a manual override, distinct
      # from the automatic fail() path. Increments attempts, clears the error.
      def retry(job, delay_seconds: 0)
        clear_reservation(job.topic, job.id)
        job.attempts += 1
        requeue_job(job, delay_seconds: delay_seconds, error: nil)
      end

      def dead_letter(message)
        path = job_file(@dead_letter_dir, message.id)
        data = message.to_hash
        data[:status] = "dead"
        File.write(path, JSON.generate(data))
      end

      def size(topic)
        dir = topic_path(topic)
        return 0 unless Dir.exist?(dir)
        job_files(dir).length
      end

      # No-op: the file backend holds no connection to release.
      #
      # It exists so Queue#close can call ONE method on every backend instead of
      # testing for it, and so switching TINA4_QUEUE_BACKEND to "lite" never
      # turns a working close into a NoMethodError. It was the ONLY backend
      # without one, so every `close if respond_to?(:close)` guard in the tree
      # silently did nothing here. Idempotent by construction - nothing to drop.
      def close; end

      # Count currently-reserved (in-flight) jobs for a topic.
      def reserved_count(topic)
        dir = reserved_path(topic)
        return 0 unless Dir.exist?(dir)
        job_files(dir).length
      end

      # Count dead-letter / failed messages for a topic.
      def dead_letter_count(topic)
        return 0 unless Dir.exist?(@dead_letter_dir)

        count = 0
        job_files(@dead_letter_dir).each do |file|
          data = JSON.parse(File.read(file))
          count += 1 if data["topic"] == topic.to_s
        rescue JSON::ParserError
          next
        end
        count
      end

      def topics
        return [] unless Dir.exist?(@dir)
        Dir.children(@dir)
           .reject { |d| d == Tina4::Queue::DEAD_LETTER_DIRNAME }
           .select { |d| File.directory?(File.join(@dir, d)) }
      end

      # Get dead letter jobs for a topic — messages that exceeded max retries.
      # Returns Hashes (raw job data with status "dead").
      def dead_letters(topic, max_retries: 3)
        return [] unless Dir.exist?(@dead_letter_dir)

        files = job_files(@dead_letter_dir).sort_by { |f| File.mtime(f) }
        jobs = []

        files.each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) < max_retries
          data["status"] = "dead"
          jobs << data
        rescue JSON::ParserError
          next
        end

        jobs
      end

      # Delete messages by status. For "failed"/"dead"/"dead_letter", removes
      # from the dead_letter directory. For "completed"/"pending", removes
      # matching jobs from the topic (pending) directory. Returns count purged.
      def purge(topic, status)
        count = 0

        if dead_status?(status)
          return 0 unless Dir.exist?(@dead_letter_dir)

          job_files(@dead_letter_dir).each do |file|
            data = JSON.parse(File.read(file))
            if data["topic"] == topic.to_s
              File.delete(file)
              count += 1
            end
          rescue JSON::ParserError
            next
          end
        else
          dir = topic_path(topic)
          return 0 unless Dir.exist?(dir)

          job_files(dir).each do |file|
            data = JSON.parse(File.read(file))
            if data["status"].to_s == status.to_s
              File.delete(file)
              count += 1
            end
          rescue JSON::ParserError
            next
          end
        end

        count
      end

      # Revive dead-letter jobs (under max_retries) back to pending.
      # Returns the number of jobs re-queued.
      def retry_failed(topic, max_retries: 3)
        return 0 unless Dir.exist?(@dead_letter_dir)

        dir = topic_path(topic)
        FileUtils.mkdir_p(dir)
        count = 0

        job_files(@dead_letter_dir).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if (data["attempts"] || 0) >= max_retries

          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            attempts: data["attempts"] || 0,
            error: data["error"]
          )
          enqueue(msg)
          File.delete(file)
          count += 1
        rescue JSON::ParserError
          next
        end

        count
      end

      # Remove all pending jobs from a topic (and any held reservations).
      # Returns count removed.
      def clear(topic)
        count = 0
        [topic_path(topic), reserved_path(topic)].each do |dir|
          next unless Dir.exist?(dir)
          job_files(dir).each do |file|
            File.delete(file)
            count += 1
          rescue Errno::ENOENT
            next
          end
        end
        count
      end

      # Jobs that have failed at least once but are still being retried.
      #
      # Under the auto-retry lifecycle a failed-but-retryable job lives in the
      # pending queue (not the dead-letter dir), so this scans the topic dir
      # for jobs with 0 < attempts < max_retries. Dead-lettered jobs are
      # returned by dead_letters(). Returns Hashes.
      def failed(topic, max_retries: 3)
        dir = topic_path(topic)
        return [] unless Dir.exist?(dir)
        jobs = []
        job_files(dir).sort_by { |f| File.mtime(f) }.each do |file|
          data = JSON.parse(File.read(file))
          attempts = data["attempts"] || 0
          next unless attempts > 0 && attempts < max_retries
          jobs << data
        rescue JSON::ParserError
          next
        end
        jobs
      end

      # Revive a specific dead-letter job by id back to the pending queue.
      # When job_id is nil, revives every dead-letter for the topic.
      #
      # This is a manual override (Queue#retry(job_id)) — it always revives a
      # dead-letter regardless of attempt count, mirroring job.retry. Returns
      # true if any job was re-queued.
      def retry_job(topic, job_id: nil, delay_seconds: 0)
        return false unless Dir.exist?(@dead_letter_dir)

        available_at = delay_seconds > 0 ? Time.now + delay_seconds : nil
        count = 0

        job_files(@dead_letter_dir).each do |file|
          data = JSON.parse(File.read(file))
          next unless data["topic"] == topic.to_s
          next if job_id && data["id"] != job_id.to_s

          msg = Tina4::Job.new(
            topic: data["topic"],
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            attempts: (data["attempts"] || 0) + 1,
            available_at: available_at,
            error: nil
          )
          enqueue(msg)
          File.delete(file)
          count += 1
          break if job_id  # found the specific job, stop scanning
        rescue JSON::ParserError
          next
        end

        count > 0
      end

      private

      DEAD_STATES = %w[failed dead dead_letter].freeze

      def dead_status?(status)
        DEAD_STATES.include?(status.to_s)
      end

      # Return [{file:, data:}, ...] for every pending, non-delayed job in the
      # topic, ordered by the dequeue policy: priority DESC, then created_at
      # ASC (oldest first).
      def available_candidates(topic)
        dir = topic_path(topic)
        return [] unless Dir.exist?(dir)

        now = Time.now
        candidates = []

        job_files(dir).each do |f|
          data = JSON.parse(File.read(f))
          # Skip messages that are not yet available (delayed).
          if data["available_at"]
            available_at = Time.parse(data["available_at"])
            next if available_at > now
          end
          candidates << { file: f, data: data }
        rescue JSON::ParserError
          next
        end

        # priority DESC, then created_at ASC. created_at is an ISO-8601 string
        # so lexicographic order == chronological order. Fall back to the file
        # name for jobs written before created_at was persisted.
        candidates.sort_by do |c|
          [-(c[:data]["priority"] || 0), c[:data]["created_at"].to_s, c[:file]]
        end
      end

      def job_from_data(data, topic)
        Tina4::Job.new(
          topic: data["topic"] || topic.to_s,
          payload: data["payload"],
          id: data["id"],
          priority: data["priority"] || 0,
          available_at: data["available_at"] ? Time.parse(data["available_at"]) : nil,
          attempts: data["attempts"] || 0,
          created_at: data["created_at"] ? Time.parse(data["created_at"]) : nil,
          error: data["error"]
        )
      end

      # Write the job back to the pending queue with a fresh created_at (so
      # within a priority tier it sorts behind jobs not yet attempted) and the
      # current attempts/error carried over.
      def requeue_job(job, delay_seconds: 0, error: nil)
        @mutex.synchronize { write_pending(job, delay_seconds: delay_seconds, error: error) }
      end

      # Mutex-free pending write. Callers already holding @mutex (e.g.
      # reclaim_expired, invoked from within dequeue's locked block) use this
      # directly — Ruby's Mutex is non-reentrant, so re-locking would deadlock.
      def write_pending(job, delay_seconds: 0, error: nil)
        available_at = delay_seconds > 0 ? (Time.now + delay_seconds).iso8601(6) : nil
        data = {
          id: job.id,
          topic: job.topic,
          payload: job.payload,
          status: "pending",
          priority: job.priority,
          attempts: job.attempts,
          error: error,
          created_at: Time.now.iso8601(6)
        }
        data[:available_at] = available_at if available_at
        topic_dir = topic_path(job.topic)
        FileUtils.mkdir_p(topic_dir)
        File.write(job_file(topic_dir, job.id), JSON.generate(data))
      end

      # Move a failed job to the dead-letter directory. Terminal until a manual
      # retry_failed/retry revives it.
      def move_to_dead_letter(job, error = "")
        @mutex.synchronize { write_dead_letter(job, error) }
      end

      # Mutex-free dead-letter write (see write_pending for the re-entrancy note).
      def write_dead_letter(job, error = "")
        data = {
          id: job.id,
          topic: job.topic,
          payload: job.payload,
          status: "dead",
          priority: job.priority,
          attempts: job.attempts,
          error: error,
          failed_at: Time.now.iso8601(6)
        }
        FileUtils.mkdir_p(@dead_letter_dir)
        File.write(job_file(@dead_letter_dir, job.id), JSON.generate(data))
      end

      # One place decides what a job file is called and where a topic lives, so
      # no call site here can be left addressing a directory or an extension
      # the dev-admin panel does not also read.
      def job_files(dir)
        Tina4::Queue.job_files(dir)
      end

      def job_file(dir, id)
        Tina4::Queue.job_file(dir, id)
      end

      def topic_path(topic)
        File.join(@dir, Tina4::Queue.topic_dirname(topic))
      end

      # Rescue a pre-alignment store, once, on the way past.
      #
      # Until this change the Ruby file backend stored jobs at
      # Dir.pwd/.queue/<topic>/<id>.json and read TINA4_QUEUE_PATH NOWHERE, so
      # EVERY existing Ruby app has its jobs there — including apps that had
      # TINA4_QUEUE_PATH set, because the variable did nothing at all. Moving
      # to the canonical <TINA4_QUEUE_PATH|data/queue>/<topic>/*.queue-data
      # layout without this would strand all of them, and a stranded job is
      # pending work somebody is still waiting on: data loss, not cosmetics.
      #
      # MOVE, never copy — a copy would leave the same job in two stores and
      # let it be delivered twice. Each file is moved individually and never
      # over an existing destination, so concurrent processes can each only win
      # a given file once and neither can overwrite a job the other placed.
      # FileUtils.mv (not File.rename) because the new store may be on another
      # filesystem, which is the whole point of TINA4_QUEUE_PATH.
      #
      # The trigger is the legacy directory EXISTING, not the new one being
      # absent: during a rolling upgrade an old instance can still be writing
      # to .queue after the new store exists, and those jobs must be collected
      # too. Emptied directories are pruned so the steady-state cost is the one
      # Dir.exist? below.
      def migrate_legacy_store
        legacy_root = File.expand_path(File.join(Dir.pwd, LEGACY_DIRNAME))
        return unless Dir.exist?(legacy_root)
        return if legacy_root == File.expand_path(@dir)

        moved = 0
        Dir.glob(File.join(legacy_root, "**", "*#{LEGACY_JOB_EXTENSION}")).sort.each do |source|
          relative = source.delete_prefix("#{legacy_root}#{File::SEPARATOR}")
          destination = File.join(@dir, "#{relative.delete_suffix(LEGACY_JOB_EXTENSION)}#{JOB_EXTENSION}")
          next if File.exist?(destination)

          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.mv(source, destination)
          moved += 1
        rescue SystemCallError
          next # another process won the race, or the file is not ours to move
        end

        prune_empty_dirs(legacy_root)
        return if moved.zero?

        Tina4::Log.info(
          "Queue: moved #{moved} job(s) from the legacy #{LEGACY_DIRNAME}/ store to #{@dir} " \
          "(now #{JOB_EXTENSION} files, matching Python/PHP/Node)"
        )
      end

      # Remove +root+ and every directory under it that is empty, deepest
      # first, so the migration's fast path stops firing once it has nothing
      # left to do. Anything still holding a file is left exactly as it is.
      def prune_empty_dirs(root)
        Dir.glob(File.join(root, "**", "*"))
           .select { |path| File.directory?(path) }
           .sort_by { |path| -path.length }
           .each { |path| Dir.rmdir(path) rescue nil }
        Dir.rmdir(root) rescue nil
      end

      # Directory holding a topic's reservation records (in-flight jobs).
      def reserved_path(topic)
        File.join(topic_path(topic), "reserved")
      end

      # Persist a reservation record so a dead consumer's job is reclaimable.
      # Stores reserved_at + available_at = now + visibility_timeout. The next
      # dequeue reclaims this job once available_at has passed (see
      # reclaim_expired). complete()/fail()/retry() delete the record.
      def write_reserved(data, topic)
        now = Time.now
        vt = @visibility_timeout || 0
        record = {
          id: data["id"],
          topic: data["topic"] || topic.to_s,
          payload: data["payload"],
          status: "reserved",
          priority: data["priority"] || 0,
          attempts: data["attempts"] || 0,
          error: data["error"],
          reserved_at: now.iso8601(6),
          available_at: (vt > 0 ? (now + vt) : now).iso8601(6),
          created_at: data["created_at"] || now.iso8601(6)
        }
        dir = reserved_path(topic)
        FileUtils.mkdir_p(dir)
        File.write(job_file(dir, record[:id]), JSON.generate(record))
      end

      # Delete a job's reservation record (best-effort).
      def clear_reservation(topic, id)
        File.delete(job_file(reserved_path(topic), id))
      rescue Errno::ENOENT
        nil
      end

      # Return expired reservations to the queue (at-least-once delivery).
      #
      # A reserved job whose available_at <= now means its consumer never
      # acknowledged in time (crash / OOM / pod eviction). Increment attempts and
      # either re-enqueue it (so the next dequeue picks it up) or dead-letter it
      # once it has hit max_retries. Disabled when visibility_timeout <= 0.
      def reclaim_expired(topic)
        return if @visibility_timeout.nil? || @visibility_timeout <= 0

        dir = reserved_path(topic)
        return unless Dir.exist?(dir)

        now = Time.now
        job_files(dir).each do |file|
          data = JSON.parse(File.read(file))
          available_at = data["available_at"] ? Time.parse(data["available_at"]) : now
          next if available_at > now # reservation still valid

          # Atomically claim the expired reservation by deleting its file.
          begin
            File.delete(file)
          rescue Errno::ENOENT
            next # another worker reclaimed it first
          end

          attempts = (data["attempts"] || 0) + 1
          error = "reservation timed out - consumer did not acknowledge within the visibility timeout"
          job = Tina4::Job.new(
            topic: data["topic"] || topic.to_s,
            payload: data["payload"],
            id: data["id"],
            priority: data["priority"] || 0,
            attempts: attempts,
            error: error
          )
          # Mutex-free writers: reclaim_expired runs inside dequeue's locked
          # block, and Ruby's Mutex is non-reentrant.
          if attempts >= @max_retries
            write_dead_letter(job, error)
          else
            write_pending(job, delay_seconds: 0, error: error)
          end
        rescue JSON::ParserError
          next
        end
      end
    end
  end
end
