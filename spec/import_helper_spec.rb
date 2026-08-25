# frozen_string_literal: true
#
# lib/tina4/import_helper.rb — AI-agent experience.
#
# Real subprocess only (Open3.capture3 + RbConfig.ruby): NO mocks, NO stubs.
# Every case boots a fresh Ruby process against the real lib/ tree, requires
# the real `tina4` entry point (which installs the hooks), and asserts on the
# child's real stderr/exit-status. This is the ONLY way to prove the boot-time
# `Tina4::ImportHelper.install` wires the hooks correctly — an in-process
# spec would inherit the already-installed state and prove nothing about the
# install path.
#
# The wrong-guess targets are deliberately picked to be MISSING from the
# framework AND unambiguous suggestions:
#
#   * `Tina4::Routr`   — a Router typo, top DidYouMean match is `Router`
#                        (the sibling class `Route`, which really exists at
#                        `lib/tina4/router.rb:7`, is a farther edit).
#   * `Tina4::Zzzzz`   — nothing close; used to prove the "no match" fallback
#                        still names real constants so the reader has options.
#   * `require "tina4/route"` — `lib/tina4/route.rb` genuinely does not exist
#                               (the class Route lives in router.rb), so the
#                               require legitimately fails and gets our hint.
#
# `Tina4::Route` on its own would resolve to the real Route class in
# `router.rb`, so it would never trip the constant hook — the spec deliberately
# avoids that trap.

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "Tina4::ImportHelper (import-hint hooks)" do
  # Run a child ruby with the framework `lib/` on the load path, requiring
  # tina4 up front so the hook install happens through the real boot.
  # `extra_load_paths` accepts additional -I directories (used by the require
  # masking-gate test to make a fixture visible).
  def run_child(code, extra_load_paths: [])
    cmd = [RUBY_BIN, "-I", REPO_LIB]
    extra_load_paths.each { |path| cmd += ["-I", path] }
    cmd += ["-rtina4", "-e", code]
    Open3.capture3(*cmd)
  end

  describe "positive path (happy)" do
    it "resolves a real Tina4 constant without any hint noise" do
      stdout, stderr, status = run_child(%q(puts Tina4.const_get(:Router).name))
      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      expect(stdout.strip).to eq("Tina4::Router")
      expect(stderr).not_to match(/Did you mean/i)
    end

    it "requires a real framework file without any hint noise" do
      _stdout, stderr, status = run_child(%q(require "tina4/router"))
      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      expect(stderr).not_to match(/Did you mean/i)
      expect(stderr).not_to match(/cannot load such file/i)
    end
  end

  describe "negative path — constant hint" do
    it "raises NameError naming both the missing const AND the suggestion" do
      _stdout, stderr, status = run_child("Tina4::Routr")

      expect(status.exitstatus).not_to eq(0)
      expect(stderr).to include("uninitialized constant Tina4::Routr")
      expect(stderr).to include("Tina4::Router")
    end
  end

  describe "negative path — require hint" do
    it "raises LoadError naming both the missing path AND the suggestion" do
      _stdout, stderr, status = run_child(%q(require "tina4/route"))

      expect(status.exitstatus).not_to eq(0)
      expect(stderr).to include("cannot load such file")
      expect(stderr).to include("tina4/router")
    end
  end

  describe "negative path — no close match" do
    it "still names at least 3 real Tina4 constants so the reader has options" do
      _stdout, stderr, status = run_child("Tina4::Zzzzz")

      expect(status.exitstatus).not_to eq(0)
      expect(stderr).to include("uninitialized constant Tina4::Zzzzz")

      # Extract the Tina4::XXX tokens the child printed to stderr and count
      # them — the message reads "... include: Tina4::AI, Tina4::API, ..."
      mentioned = stderr.scan(/Tina4::([A-Z][A-Za-z0-9_]*)/).flatten
                        .reject { |const| const == "Zzzzz" }
                        .uniq
      expect(mentioned.length).to be >= 3,
        "expected 3+ real Tina4 constants, got #{mentioned.inspect}\nstderr:\n#{stderr}"

      # And each one should actually exist on the module (not fabricated).
      real = Tina4.constants.map(&:to_s)
      unknown = mentioned - real
      expect(unknown).to be_empty,
        "constants listed but not real: #{unknown.inspect}"
    end
  end

  describe "masking gate — a genuine missing gem must NOT be rewritten" do
    # Fixture written into a temp dir and cleaned up in around(:each). Its
    # only job is to `require "definitely_missing_gem"` from a top-level
    # require whose OWN path ("broken_module") is unrelated to `tina4/*`.
    around(:each) do |ex|
      Dir.mktmpdir("tina4_import_masking") do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec_fixtures"))
        fixture = File.join(dir, "spec_fixtures", "broken_module.rb")
        File.write(fixture, %q(require "definitely_missing_gem") + "\n")
        @fixture_dir = File.join(dir, "spec_fixtures")
        ex.run
      end
    end

    it "propagates the ORIGINAL LoadError from the nested require" do
      _stdout, stderr, status = run_child(
        %q(require "broken_module"),
        extra_load_paths: [@fixture_dir]
      )

      expect(status.exitstatus).not_to eq(0)
      expect(stderr).to include("cannot load such file -- definitely_missing_gem")
      # Critically, our hint text must NOT appear — that would mean we masked
      # the genuine error with a spurious "did you mean tina4/router?" line.
      expect(stderr).not_to match(%r{tina4/router})
      expect(stderr).not_to match(%r{No close match under tina4/\*})
    end
  end

  describe "mutation gate — the const-hint spec is a real gate, not a ghost" do
    # A test that never fails is not known to work. Prove the negative-hint
    # spec is a GATE by mutation: stash import_helper.rb, rerun the child,
    # expect the un-hinted stock NameError; unstash, expect our hint back.
    #
    # The stash swaps the file for a stub that keeps
    # `Tina4::ImportHelper.install` as a no-op — the framework's boot calls
    # that method, so replacing it with `raise` would break unrelated tests.
    # `install` doing nothing means neither the const nor the require hook is
    # installed for the mutation child, so a wrong `Tina4::Routr` reads with
    # Ruby's stock NameError.
    it "goes red when the import_helper is stubbed out, green when restored" do
      helper_path = File.join(REPO_LIB, "tina4", "import_helper.rb")
      backup      = File.read(helper_path)

      stub = <<~RUBY
        # frozen_string_literal: true
        # Mutation-gate stub — the real file was stashed by import_helper_spec.
        module Tina4
          module ImportHelper
            def self.install; end
          end
        end
      RUBY

      begin
        File.write(helper_path, stub)
        _out, stderr_mut, status_mut = run_child("Tina4::Routr")
        expect(status_mut.exitstatus).not_to eq(0),
          "the child should still fail — but WITHOUT our hint"
        expect(stderr_mut).to include("uninitialized constant Tina4::Routr")
        # Ruby's stock NameError does NOT know about our suggestion — it
        # cannot mention "Tina4::Router" as an alternative here.
        #
        # (DidYouMean's own SpellChecker only augments a NameError raised by
        # Ruby itself — it does not run on a suggestion Ruby wasn't asked to
        # compute. With our hook stubbed, the message never mentions Router.)
        expect(stderr_mut).not_to include("Did you mean Tina4::Router?")
      ensure
        File.write(helper_path, backup)
      end

      # Restore-and-verify the gate reopens: our hint is back on the same
      # input, in a fresh child (no leaked state from the mutation run).
      _out, stderr_ok, status_ok = run_child("Tina4::Routr")
      expect(status_ok.exitstatus).not_to eq(0)
      expect(stderr_ok).to include("uninitialized constant Tina4::Routr")
      expect(stderr_ok).to include("Tina4::Router")
    end
  end

  describe "install is idempotent" do
    it "does not double-install its hooks when called more than once" do
      # If prepend were re-applied the method chain would grow one link per
      # call. Two installs, then a normal require: no exception, no doubled
      # output, no LoadError.
      _out, stderr, status = run_child(<<~RUBY)
        Tina4::ImportHelper.install
        Tina4::ImportHelper.install
        require "tina4/router"
        puts Tina4.const_get(:Router).name
      RUBY

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      expect(stderr).not_to match(/Did you mean/i)
    end
  end
end
