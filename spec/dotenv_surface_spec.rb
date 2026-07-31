# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Feature 1, step 5: the dotenv SURFACE is the same shape in all four.
#
# The parser behaviour was reconciled on 2026-07-30 and is pinned by the shared
# corpus. The CALL SHAPE was not, and that is what these lock in.
#
# Ruby is the framework the directory form came FROM - Env.load_env(root_dir)
# already encapsulated the precedence rule (real-env > .env.local > .env) that
# Python, PHP and Node made the caller repeat at every boot site. What Ruby
# lacked was the top-level surface: Tina4.load_env raised NoMethodError while
# the other three exposed a plain function, so the obvious cross-framework call
# was wrong here.
#
# NO MOCKS and no doubles: a .env is a file, so the real dependency is a real
# file in a real temp directory, and the real process environment.
#
# Identical case names in all four frameworks:
#   tina4-python/tests/test_dotenv_surface.py
#   tina4-php/tests/DotEnvSurfaceTest.php
#   tina4-nodejs/test/dotenvSurface.test.ts
RSpec.describe "DotEnv surface" do
  KEYS = %w[SURFACE_BASE SURFACE_SHARED SURFACE_LOCAL].freeze

  around do |example|
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".env"), "SURFACE_BASE=from_env\nSURFACE_SHARED=from_env\n")
      File.write(File.join(root, ".env.local"), "SURFACE_SHARED=from_local\nSURFACE_LOCAL=only_local\n")
      KEYS.each { |k| ENV.delete(k) }
      @root = root
      example.run
      KEYS.each { |k| ENV.delete(k) }
    end
  end

  # POSITIVE: the canonical form. A directory loads BOTH files, in order.
  it "load_env accepts a root directory" do
    result = Tina4.load_env(@root)

    expect(ENV["SURFACE_BASE"]).to eq("from_env"), "the .env was not read"
    expect(ENV["SURFACE_LOCAL"]).to eq("only_local"), "the .env.local was not read"
    expect(result["SURFACE_BASE"]).to eq("from_env")
  end

  # The whole reason the directory form exists: .env.local beats .env. A caller
  # doing this by hand in the wrong order gets the opposite, silently.
  it "load_env directory form gives env local precedence" do
    Tina4.load_env(@root)
    expect(ENV["SURFACE_SHARED"]).to eq("from_local")
  end

  # NEGATIVE: the obvious call must not raise. This is the case Ruby failed.
  it "load_env is reachable from the top level namespace" do
    %i[load_env get_env require_env has_env? all_env reset_env truthy?
       env_bool env_int env_float env_str].each do |name|
      expect(Tina4).to respond_to(name), "Tina4.#{name} is not reachable"
    end
  end

  # The top-level surface must DELEGATE, not reimplement - two copies of the
  # precedence rule is exactly the defect this feature exists to remove.
  it "the top level surface delegates to the same loader" do
    Tina4.load_env(@root)
    from_top = ENV["SURFACE_SHARED"]
    KEYS.each { |k| ENV.delete(k) }
    Tina4::Env.load_env(@root)
    expect(ENV["SURFACE_SHARED"]).to eq(from_top)
  end

  # A fresh checkout has no .env.local, and the directory form reads it anyway.
  it "a missing env local is not an error" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".env"), "SOLO=1\n")
      ENV.delete("SOLO")
      expect { Tina4.load_env(root) }.not_to raise_error
      expect(ENV["SOLO"]).to eq("1")
      ENV.delete("SOLO")
    end
  end
end
