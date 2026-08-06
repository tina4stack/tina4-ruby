# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A temp directory that gets reaped.
#
# `Dir.mktmpdir` WITH A BLOCK removes the directory when the block ends. WITHOUT
# one it does not, and nothing else will either. Audited across spec/: 173 bare
# (blockless) calls in 105 files, and almost all of them pair with an
# `after { FileUtils.remove_entry(...) }` — but NINE FILES had no cleanup
# anywhere, 17 sites between them:
#
#   env_vars_spec (8)          docstore_substitutability_spec (2)
#   db_query_cache_spec (1)    form_token_spec (1)
#   graceful_shutdown_spec (1) parity_test_class_spec (1)
#   puma_shutdown_spec (1)     queue_backend_validation_spec (1)
#   queue_failure_lifecycle_spec (1)
#
# MEASURED on the lab: /tmp held ~55-59 `d<date>-<pid>-` entries per rspec
# process — that is Ruby's DEFAULT mktmpdir prefix — across dozens of pids, and
# it grew on every run.
#
# Every one of those sites is an INLINE expression:
#
#     Tina4::Frond.new(template_dir: Dir.mktmpdir)
#     ENV["TINA4_QUEUE_PATH"] = Dir.mktmpdir
#     File.join(Dir.mktmpdir, "qc.db")
#
# There is no local to hang an `after` hook on, which is exactly why they were
# missed: the fix is not "add a teardown", it is "make the creation itself
# tracked". Hence a helper rather than nine sets of hooks.
#
# NOT a monkey-patch of Dir.mktmpdir. Instrumenting stdlib for the whole spec
# process would reap directories belonging to code that never opted in, and the
# repo already treats surprising test-harness behaviour as a defect in its own
# right. Call sites say what they are doing.
module SpecTmpdir
  @created = []

  class << self
    # Create a tracked temp directory. Same signature shape as Dir.mktmpdir.
    def create(prefix = "tina4-spec-")
      dir = Dir.mktmpdir(prefix)
      @created << dir
      dir
    end

    # Remove everything still present.
    #
    # NEVER RAISES. Cleanup that can fail a run is worse than the leak it fixes:
    # a directory may be held open or have been removed already by the spec that
    # asked for it, and a reaper that raised at_exit would turn a green suite
    # into a non-zero exit for a reason unrelated to any behaviour under test.
    def reap
      @created.each do |dir|
        FileUtils.remove_entry(dir)
      rescue StandardError
        # already gone, or not ours to remove
      end
      @created = []
    end

    # Test seam: how many directories are still tracked.
    def tracked_count
      @created.size
    end
  end
end
