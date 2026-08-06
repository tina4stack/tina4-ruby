# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Temp directories that cannot outlive the run.
#
# THE MEASUREMENT THAT SET THE DESIGN. A first attempt converted the 17 blockless
# `Dir.mktmpdir` calls that had no cleanup (nine spec files) to a tracked helper.
# Run against the FULL suite on the lab, /tmp still gained 59 entries. Converting
# call sites does not converge: `spec/` has 173 blockless calls across 105 files,
# new specs add more, and CHILD PROCESSES the specs spawn create their own.
#
# So the primary mechanism is not a call-site convention at all -- it is a
# SANDBOX. `sandbox!` points TMPDIR at one per-run directory before anything
# uses it, so every temp path any spec creates lands inside it, and the whole
# tree is removed at exit. Measured, because Ruby's own rule here is easy to get
# wrong: `Dir.tmpdir` honours ENV["TMPDIR"] only when that directory EXISTS --
# it silently falls through to /var/folders or /tmp otherwise, which is exactly
# what a first probe of this showed. It must be created before it is announced.
#
#   ENV["TMPDIR"]=/tmp/probe-rb  ->  Dir.mktmpdir -> /tmp/probe-rb/d20260806-...
#
# Child processes inherit TMPDIR, so a spec that shells out to another ruby or
# to a server gets the same sandbox without knowing about it.
#
# `create` remains for call sites that want to say plainly that they are making
# a temp directory. It is no longer load-bearing for cleanup -- the sandbox is --
# but it keeps the intent visible where a bare inline `Dir.mktmpdir` said nothing:
#
#     Tina4::Frond.new(template_dir: SpecTmpdir.create)
#
# reap/remove NEVER raise. A directory may be held open, or already gone, and a
# reaper that raised at_exit would turn a green suite into a non-zero exit for a
# reason unrelated to any behaviour under test.
module SpecTmpdir
  @created = []
  @root = nil

  class << self
    attr_reader :root

    # Point TMPDIR at a per-run directory. Call ONCE, as early as possible.
    def sandbox!
      return @root if @root

      base = ENV["TMPDIR"].to_s.empty? ? Dir.tmpdir : ENV["TMPDIR"]
      root = File.join(base, "tina4-rspec-#{Process.pid}")
      FileUtils.mkdir_p(root)          # must exist BEFORE TMPDIR announces it
      ENV["TMPDIR"] = root
      @root = root
    end

    # A tracked temp directory. Same signature shape as Dir.mktmpdir.
    def create(prefix = "tina4-spec-")
      dir = Dir.mktmpdir(prefix)
      @created << dir
      dir
    end

    # Remove the sandbox and anything tracked outside it.
    def reap
      (@created + [@root]).compact.each do |dir|
        FileUtils.remove_entry(dir)
      rescue StandardError
        # already gone, held open, or not ours -- never fail a run over cleanup
      end
      @created = []
      @root = nil
    end

    # Test seam.
    def tracked_count
      @created.size
    end
  end
end
