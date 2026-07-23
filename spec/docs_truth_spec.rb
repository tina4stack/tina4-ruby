# frozen_string_literal: true
#
# Lock-in spec for D12 (feature-recount audit): the two documentation claims the
# audit found drifting from the code, pinned so the drift cannot silently return.
# CLAUDE.md's own First Principle is "Documentation Matches Code Reality" — this
# is the machine-checkable half of it for the claims that were wrong.
#
#   1. CLAUDE.md placed QueryCache in sql_translator.rb. It is
#      lib/tina4/cache.rb:13. sql_translator.rb does not define it at all.
#   2. lib/tina4/router.rb claimed the data/.broken sentinel is surfaced by
#      "/health and the dev dashboard". lib/tina4/health.rb contains no `broken`
#      reference, and /__dev/api/broken serves the in-memory ErrorTracker (its
#      own Dir.tmpdir JSON store), not data/.broken. Nothing under lib/ reads it.
#
# NO mocks: this reads the REAL files off disk and asks the REAL Ruby runtime
# where the REAL constant is defined (Module.const_source_location).

require "spec_helper"

RSpec.describe "documentation matches code reality (D12)" do
  LIB_DIR = File.expand_path("../lib", __dir__)
  CLAUDE_MD = File.expand_path("../CLAUDE.md", __dir__)

  # The repo's sources and CLAUDE.md are UTF-8; read them as UTF-8 explicitly so
  # the assertions never depend on the ambient Encoding.default_external (which
  # is US-ASCII under some CI locales and raises on the first non-ASCII byte).
  def read_utf8(path)
    File.read(path, encoding: "UTF-8")
  end

  describe "QueryCache location" do
    it "is defined in lib/tina4/cache.rb, per the runtime itself" do
      file, line = Object.const_source_location("Tina4::QueryCache")
      expect(File.expand_path(file)).to eq(File.join(LIB_DIR, "tina4", "cache.rb"))
      expect(line).to eq(13)
    end

    it "is NOT defined in sql_translator.rb (negative)" do
      source = read_utf8(File.join(LIB_DIR, "tina4", "sql_translator.rb"))
      expect(source).not_to match(/class\s+QueryCache/)
      expect(source).not_to include("QueryCache")
    end

    it "CLAUDE.md does not attribute the query cache to sql_translator.rb" do
      doc = read_utf8(CLAUDE_MD)
      # The exact stale project-structure line the audit flagged.
      expect(doc).not_to include("sql_translator.rb   # Cross-engine SQL translator & query cache")
      expect(doc).not_to match(/sql_translator\.rb.*query cache/i)
      # POSITIVE: the correct home is stated.
      expect(doc).to include("lib/tina4/cache.rb:13")
    end
  end

  describe "the data/.broken sentinel" do
    it "is written by router.rb" do
      router = read_utf8(File.join(LIB_DIR, "tina4", "router.rb"))
      expect(router).to include('File.join(Dir.pwd, "data", ".broken")')
    end

    it "is not referenced by health.rb at all (the code behind the corrected comment)" do
      health = read_utf8(File.join(LIB_DIR, "tina4", "health.rb"))
      expect(health).not_to include("broken")
    end

    it "is read by nothing under lib/ (negative — Ruby only writes it)" do
      readers = Dir.glob(File.join(LIB_DIR, "**", "*.rb")).select do |f|
        next false if File.basename(f) == "router.rb" # the writer

        src = read_utf8(f)
        src.include?("data/.broken") || src.include?('"data", ".broken"')
      end
      expect(readers).to be_empty,
                         "lib/ gained a data/.broken reader (#{readers.inspect}) — update the " \
                         "router.rb comment and this spec: the parity gap may now be closed"
    end

    it "router.rb no longer claims /health and the dev dashboard surface it" do
      router = read_utf8(File.join(LIB_DIR, "tina4", "router.rb"))
      expect(router).not_to include("so /health and the dev dashboard surface")
    end
  end
end
