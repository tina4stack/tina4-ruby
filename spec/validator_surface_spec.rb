# frozen_string_literal: true
#
# Lock-in spec for D5 (feature-recount audit): Tina4::Validator MUST be reachable
# from the main `require "tina4"` surface, exactly like every other counted
# framework feature (Queue, Events, ServiceRunner, DocStore, ...). Python, PHP and
# Node all expose Validator on their main surface; Ruby was the odd one out —
# lib/tina4/validator.rb was neither required nor autoloaded, so
# `Tina4::Validator` raised NameError after a clean boot and only worked after an
# extra `require "tina4/validator"`.
#
# No mocks, no doubles, no stubs. The reachability check runs in a CLEAN CHILD
# RUBY PROCESS whose $LOAD_PATH is forced to THIS working tree's lib/ — so a
# stale installed tina4ruby gem can never make the assertion falsely pass, and an
# in-process `require "tina4/validator"` from some other spec can never pollute
# it. The child prints its provenance (the resolved lib/tina4.rb path and
# Tina4::VERSION) and this spec asserts on that too.
#
# Negative case: the same child boot must NOT need the extra
# `require "tina4/validator"` and the constant must NOT be a stub — it has to be
# the real class, resolving to lib/tina4/validator.rb, with a working rule chain.

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Tina4::Validator on the main require surface (D5)" do
  REPO_LIB = File.expand_path("../lib", __dir__)
  RUBY_BIN = RbConfig.ruby

  # Boot a clean child ruby with -I<working tree lib> and no bundler/RubyGems
  # tina4ruby on the path taking precedence. Returns [stdout+stderr, status].
  def boot_child(script)
    env = {
      "TINA4_SUPPRESS" => "1",       # no banner
      "TINA4_DEBUG" => "false",
      "RUBYOPT" => nil,              # drop any inherited -rbundler/setup
      "BUNDLE_GEMFILE" => nil
    }
    out, err, status = Open3.capture3(env, RUBY_BIN, "-I#{REPO_LIB}", "-e", script)
    ["#{out}#{err}", status]
  end

  it "resolves Tina4::Validator after a bare require \"tina4\" (working-tree provenance proven)" do
    script = <<~RUBY
      require "tina4"
      puts "PROVENANCE=" + $LOADED_FEATURES.grep(/#{'tina4\.rb'}$/).first.to_s
      puts "VERSION=" + Tina4::VERSION
      puts "RESOLVED=" + Tina4::Validator.name
      puts "SOURCE=" + Tina4::Validator.instance_method(:required).source_location.first
    RUBY
    output, status = boot_child(script)

    expect(status.exitstatus).to eq(0), "child boot failed:\\n#{output}"
    # Provenance: the tina4.rb that answered is THIS working tree, not a gem.
    expect(output).to include("PROVENANCE=#{File.join(REPO_LIB, 'tina4.rb')}")
    expect(output).to include("VERSION=#{Tina4::VERSION}")
    expect(output).to include("RESOLVED=Tina4::Validator")
    # The constant is backed by the real working-tree file, not a stub.
    expect(output).to include("SOURCE=#{File.join(REPO_LIB, 'tina4', 'validator.rb')}")
  end

  it "does NOT require an extra require \"tina4/validator\" to be usable" do
    # Full rule chain exercised on the bare surface: a valid payload passes and
    # an invalid one collects the real error message. If Validator were only
    # reachable via the extra require, this child would die with NameError.
    script = <<~RUBY
      require "tina4"
      good = Tina4::Validator.new({ "name" => "Alice", "email" => "a@example.com", "age" => 30 })
      good.required("name", "email").email("email").min_length("name", 2).integer("age").min("age", 0)
      puts "GOOD_VALID=" + good.is_valid?.to_s
      bad = Tina4::Validator.new({ "name" => "", "email" => "nope", "age" => "abc" })
      bad.required("name").email("email").integer("age")
      puts "BAD_VALID=" + bad.is_valid?.to_s
      puts "BAD_ERRORS=" + bad.errors.length.to_s
      puts "BAD_FIRST=" + bad.errors.first[:message]
      puts "EXTRA_REQUIRE_WAS_NEEDED=" + $LOADED_FEATURES.grep(/validator/).empty?.to_s
    RUBY
    output, status = boot_child(script)

    expect(status.exitstatus).to eq(0), "child boot failed:\\n#{output}"
    expect(output).to include("GOOD_VALID=true")
    expect(output).to include("BAD_VALID=false")
    expect(output).to include("BAD_ERRORS=3")
    expect(output).to include("BAD_FIRST=name is required")
    # validator.rb is genuinely loaded in the child — the autoload fired.
    expect(output).to include("EXTRA_REQUIRE_WAS_NEEDED=false")
  end

  it "is reachable in THIS process too (the suite's own boot surface)" do
    expect(defined?(Tina4::Validator)).to eq("constant")
    expect(Tina4::Validator.new({ "name" => "x" }).required("name").is_valid?).to be(true)
    expect(Tina4::Validator.new({}).required("name").is_valid?).to be(false)
  end

  it "keeps the explicit require \"tina4/validator\" working (no breakage for existing code)" do
    script = <<~RUBY
      require "tina4"
      require "tina4/validator"
      puts "STILL_OK=" + Tina4::Validator.new({}).required("name").errors.first[:message]
    RUBY
    output, status = boot_child(script)

    expect(status.exitstatus).to eq(0), "child boot failed:\\n#{output}"
    expect(output).to include("STILL_OK=name is required")
  end
end
