# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"

# The shared .env corpus (feature 1 of the feature audit).
#
# spec/fixtures/dotenv_corpus.json is byte-identical in all four frameworks. One
# answer key, four suites: a line that parses here and differently in Node is a
# parity bug with a name, not a difference somebody has to notice.
#
# Ruby held two of the three silent bugs this row fixed: an `export FOO=bar` line
# was dropped entirely and said nothing, and a trailing comment stayed inside the
# value. Both are wrong-or-missing VALUES rather than errors, which is why they
# survived so long.
#
# Real files on disk in a temp directory, real process environment. A .env is a
# file, so the real dependency is trivially available and there is nothing to mock.
#
# LOCALS, not constants: a constant defined inside RSpec.describe leaks globally
# and spec/frond_expression_parity_spec.rb already defines CORPUS.
dotenv_corpus = JSON.parse(File.read(File.join(__dir__, "fixtures", "dotenv_corpus.json"))).freeze

RSpec.describe "Tina4 .env corpus" do
  let(:corpus) { dotenv_corpus }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      # Loading is FIRST-WINS, so a key left over from another example would mask
      # the file and quietly pass a test that proves nothing.
      keys = dotenv_corpus["expected"].keys + dotenv_corpus["_never_set"]["keys"] +
             dotenv_corpus["precedence"]["expected_without_real_env"].keys
      keys.each { |k| ENV.delete(k) }
      File.write(File.join(dir, ".env"), dotenv_corpus["env_file"])
      example.run
      keys.each { |k| ENV.delete(k) }
    end
  end

  def load_dir
    Tina4::Env.load_env(@dir)
  end

  describe "every key" do
    dotenv_corpus["expected"].each do |key, want|
      it "parses #{key} to the agreed value" do
        load_dir
        expect(ENV[key]).to eq(want)
      end
    end
  end

  describe "the export prefix" do
    it "reads an export prefixed line" do
      load_dir
      expect(ENV["EXPORTED"]).to eq("shellstyle")
    end

    # Absent is the failure mode that hid this: a .env copied out of a shell
    # profile lost keys, and the failure surfaced somewhere unrelated - a blank
    # TINA4_SECRET, a missing database URL.
    it "does not silently skip an export line" do
      load_dir
      expect(ENV).to have_key("EXPORTED")
    end
  end

  describe "a trailing comment" do
    it "is stripped from an unquoted value" do
      load_dir
      expect(ENV["WITH_HASH"]).to eq("value")
    end

    it "is not kept in the value" do
      load_dir
      expect(ENV["WITH_HASH"]).not_to include("#")
    end

    it "keeps a hash INSIDE a quoted value" do
      load_dir
      expect(ENV["QUOTED_HASH"]).to eq("a # b")
    end

    it "does not truncate a quoted value at a hash" do
      load_dir
      expect(ENV["QUOTED_HASH"]).to end_with("b")
    end
  end

  describe "interpolation" do
    it "expands a dollar-brace reference" do
      load_dir
      expect(ENV["INTERP"]).to eq("example.com/api")
      expect(ENV["DQ_INTERP"]).to eq("example.com/v2")
    end

    # Single quotes are the documented escape for a literal ${...}, and the
    # migration path for the breaking half of this change.
    it "does not expand inside single quotes" do
      load_dir
      expect(ENV["LITERAL"]).to eq("${HOST}/api")
    end

    it "leaves an unknown reference literal" do
      load_dir
      expect(ENV["UNKNOWN"]).to eq("${NOPE}/x")
    end

    # PHP emptied it, so `URL=${DB_HOST}/db` with a typo became `/db` - a
    # plausible-looking wrong value that reaches a connection attempt before
    # failing, rather than a visible one.
    it "does not resolve an unknown reference to nothing" do
      load_dir
      expect(ENV["UNKNOWN"]).not_to eq("/x")
    end
  end

  describe "an empty value" do
    it "sets an empty string for a bare equals" do
      load_dir
      expect(ENV["EMPTY"]).to eq("")
    end

    # An empty value IS a value. Absent and blank are different things.
    it "does not unset a key declared empty" do
      load_dir
      expect(ENV).to have_key("EMPTY")
    end
  end

  describe "escapes and whitespace" do
    it "processes escapes in a double-quoted value" do
      load_dir
      expect(ENV["ESCAPES"]).to eq("line1\nline2\ttabbed")
    end

    it "trims whitespace around a key" do
      load_dir
      expect(ENV["SPACED_KEY"]).to eq("spaced")
    end
  end

  describe "a malformed line" do
    # The malformed lines sit in the MIDDLE of the fixture, so keys declared
    # after them must still load and the bad keys must not exist.
    it "does not abort the whole file" do
      load_dir
      expect(ENV["ESCAPES"]).to eq("line1\nline2\ttabbed")
      dotenv_corpus["_never_set"]["keys"].each do |key|
        expect(ENV).not_to have_key(key), key
      end
    end
  end

  describe "precedence: real environment > .env.local > .env" do
    it "lets .env.local override .env" do
      p = dotenv_corpus["precedence"]
      File.write(File.join(@dir, ".env"), p["env"])
      File.write(File.join(@dir, ".env.local"), p["env_local"])
      load_dir
      p["expected_without_real_env"].each { |k, want| expect(ENV[k]).to eq(want), k }
    end

    # A stray gitignored .env.local must never clobber a production value. This
    # is the security-correct ordering, not a convenience.
    it "does not overwrite an existing process variable" do
      p = dotenv_corpus["precedence"]
      real = p["real_env_wins"]
      ENV[real["key"]] = real["value"]
      File.write(File.join(@dir, ".env"), p["env"])
      File.write(File.join(@dir, ".env.local"), p["env_local"])
      load_dir
      expect(ENV[real["key"]]).to eq(real["value"])
    end
  end

  # One truthiness table, every subsystem, every framework. The parser is only
  # half the contract - the other half is what a parsed value MEANS as a
  # boolean. Ruby is where this broke: Env.bool accepted y/t/n/f while Ruby's
  # OWN Log and Mcp checks did not, so one .env gave two answers in one process.
  describe "env truthiness" do
    let(:table) { dotenv_corpus["truthiness"] }

    # Every entry point that answers an env boolean in this framework. Each must
    # give the SAME answer - that is the whole finding.
    def entry_points(value)
      {
        "Env.is_truthy" => Tina4::Env.is_truthy(value),
        "Env.bool"      => (ENV["TINA4_TRUTHINESS_PROBE"] = value
                            Tina4::Env.bool("TINA4_TRUTHINESS_PROBE")),
        "Tina4.truthy?" => Tina4.truthy?(value),
        "Log.truthy?"   => Tina4::Log.send(:truthy?, value)
      }
    ensure
      ENV.delete("TINA4_TRUTHINESS_PROBE")
    end

    it "treats every corpus truthy value as true, at every entry point" do
      table["truthy"].each do |value|
        entry_points(value).each do |name, got|
          expect(got).to eq(true), "#{name} said #{got.inspect} for #{value.inspect}"
        end
      end
    end

    it "treats every corpus falsy value as false, at every entry point" do
      table["falsy"].each do |value|
        entry_points(value).each do |name, got|
          expect(got).to eq(false), "#{name} said #{got.inspect} for #{value.inspect}"
        end
      end
    end

    # Env.bool's `default` applies to an UNSET var only. A value that IS set is
    # answered by the table - never quietly replaced by the default.
    it "applies the default only when the variable is unset" do
      ENV.delete("TINA4_TRUTHINESS_PROBE")
      expect(Tina4::Env.bool("TINA4_TRUTHINESS_PROBE", default: true)).to eq(true)
      ENV["TINA4_TRUTHINESS_PROBE"] = "maybe"
      expect(Tina4::Env.bool("TINA4_TRUTHINESS_PROBE", default: true)).to eq(false)
    ensure
      ENV.delete("TINA4_TRUTHINESS_PROBE")
    end
  end
end
