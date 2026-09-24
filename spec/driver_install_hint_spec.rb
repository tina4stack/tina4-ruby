# frozen_string_literal: true

# "Driver not installed" messages name the gem AND the exact install command.
#
# The standard (tina4-nodejs#67): "The 'X' ... is required for FEATURE. Install it
# with: <command>". Ruby spells the command the way Bundler users type it:
#   bundle add <gem> (or add gem "<gem>" to your Gemfile)
#
# MEASURED at v3 HEAD in a real zero-gem subprocess, before this change:
#   * Tina4::Realtime::S3Storage.new -> bare "cannot load such file -- aws-sdk-s3",
#     and Realtime::Storage.select logged "S3 storage unavailable (cannot load such
#     file -- aws-sdk-s3)" - no gem named as a gem, no command.
#   * the mongodb cache backend rescued LoadError and StandardError TOGETHER, so the
#     fallback warning could only say "(driver missing or service unreachable)",
#     whichever it was.
#
# HOW THE GEM IS MADE GENUINELY UNAVAILABLE, WITHOUT ANY DOUBLE: the same instrument
# as session_zero_dependency_fallback_spec.rb. A REAL ruby subprocess whose GEM_HOME
# and GEM_PATH are an EMPTY directory, with every bundler variable removed, and the
# framework reachable only through -I<repo>/lib. `require` is the real Kernel#require
# and the LoadError is the one RubyGems really raises. The child SELF-REPORTS that
# the gems really are gone, and every example asserts that FIRST.
#
# NEGATIVE CONTROL: with the `mongo` gem PRESENT (the bundle's own environment) and
# the service unreachable, the install hint must NOT be appended - that fallback is
# about the service, and telling the operator to install a gem they already have
# sends them the wrong way.

require_relative "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"

RSpec.describe "Driver-not-installed messages name the gem and the install command" do
  let(:repository_root) { File.expand_path("..", __dir__) }
  let(:s3_hint) do
    "The 'aws-sdk-s3' gem is required for S3Storage. Install it with: bundle add aws-sdk-s3 " \
      "(or add gem \"aws-sdk-s3\" to your Gemfile)"
  end
  let(:mongo_hint) do
    "The 'mongo' gem is required for the mongodb cache backend. Install it with: bundle add mongo " \
      "(or add gem \"mongo\" to your Gemfile)"
  end

  # gem_free: a nil value REMOVES the variable from the child, so bundler cannot
  # re-inject the bundle's load paths. Without it the child inherits the bundle
  # (the negative control runs with the real `mongo` gem on purpose).
  def run_ruby(source, gem_free:)
    Dir.mktmpdir("tina4-install-hint") do |sandbox|
      script = File.join(sandbox, "case.rb")
      File.write(script, source)
      environment = { "TINA4_DEBUG" => "false", "TINA4_NO_BROWSER" => "true",
                      "TINA4_LOG_LEVEL" => "ALL", "TINA4_LOG_DIR" => File.join(sandbox, "logs") }
      if gem_free
        empty_gem_home = File.join(sandbox, "gems")
        FileUtils.mkdir_p(empty_gem_home)
        environment.merge!(
          "GEM_HOME" => empty_gem_home, "GEM_PATH" => empty_gem_home,
          "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
          "BUNDLE_PATH" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil
        )
      end
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby,
                                              "-I#{File.join(repository_root, "lib")}", script,
                                              chdir: sandbox)
      line = stdout.lines.find { |candidate| candidate.start_with?("TINA4_REPORT ") }
      raise "subprocess reported nothing (exit #{status.exitstatus})\n#{stdout}\n#{stderr}" if line.nil?

      # The logger's console sink writes one JSON record per line; the assertions
      # read the decoded messages plus the raw stderr.
      messages = stdout.lines.filter_map do |candidate|
        record = JSON.parse(candidate)
        record["message"] if record.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
      [JSON.parse(line.sub("TINA4_REPORT ", "")), "#{messages.join("\n")}\n#{stdout}\n#{stderr}"]
    end
  end

  def instrument_source
    <<~RUBY
      require "json"
      def gem_gone?(name)
        require name
        false
      rescue LoadError
        true
      end
      report = {
        "aws_gone" => gem_gone?("aws-sdk-s3"),
        "mongo_gone" => gem_gone?("mongo"),
        "gem_load_paths" => $LOAD_PATH.grep(/gems/).length
      }
    RUBY
  end

  def expect_gems_really_unavailable(report)
    expect(report["aws_gone"]).to be(true), "aws-sdk-s3 still loaded - the missing-gem path was not measured"
    expect(report["mongo_gone"]).to be(true), "mongo still loaded - the missing-gem path was not measured"
    expect(report["gem_load_paths"]).to eq(0), "bundler re-injected #{report["gem_load_paths"]} gem paths"
  end

  it "S3Storage without aws-sdk-s3 raises a LoadError naming the gem and the command, and select falls back carrying it" do
    source = <<~RUBY
      #{instrument_source}
      require "tina4"
      begin
        Tina4::Realtime::S3Storage.new(bucket: "tina4-install-hint")
        report["s3_error"] = nil
      rescue LoadError => error
        report["s3_error_class"] = error.class.name
        report["s3_error"] = error.message
      end
      ENV["TINA4_STORAGE_BACKEND"] = "s3"
      ENV["TINA4_STORAGE_BUCKET"] = "tina4-install-hint"
      report["selected"] = Tina4::Realtime::Storage.select.class.name
      puts "TINA4_REPORT \#{JSON.generate(report)}"
    RUBY

    report, output = run_ruby(source, gem_free: true)
    expect_gems_really_unavailable(report)

    expect(report["s3_error_class"]).to eq("LoadError")
    expect(report["s3_error"]).to eq(s3_hint)
    # The fallback still works, and its warning now carries the remedy.
    expect(report["selected"]).to eq("Tina4::Realtime::LocalStorage")
    expect(output).to include("S3 storage unavailable (#{s3_hint})")
  end

  it "the mongodb cache fallback warning appends the install hint when the gem is missing" do
    source = <<~RUBY
      #{instrument_source}
      require "tina4"
      backend = Tina4::CacheBackends.create_backend(backend: "mongodb", url: "mongodb://127.0.0.1:27017")
      report["backend"] = backend.class.name
      puts "TINA4_REPORT \#{JSON.generate(report)}"
    RUBY

    report, output = run_ruby(source, gem_free: true)
    expect_gems_really_unavailable(report)

    expect(report["backend"]).to eq("Tina4::CacheBackends::FileBackend")
    expect(output).to include("Cache backend 'mongodb' is unavailable")
    expect(output).to include(mongo_hint)
  end

  it "does NOT append the install hint when the gem is present and only the service is unreachable" do
    source = <<~RUBY
      #{instrument_source}
      require "tina4"
      # Port 1 on loopback: nothing listens there, so the SERVICE is the fault.
      backend = Tina4::CacheBackends.create_backend(backend: "mongodb", url: "mongodb://127.0.0.1:1/tina4_install_hint")
      report["backend"] = backend.class.name
      puts "TINA4_REPORT \#{JSON.generate(report)}"
    RUBY

    report, output = run_ruby(source, gem_free: false)
    # The control only means something if the gem really IS loadable here.
    skip "mongo gem not installed in this bundle - negative control not available" if report["mongo_gone"]

    expect(report["backend"]).to eq("Tina4::CacheBackends::FileBackend")
    expect(output).to include("Cache backend 'mongodb' is unavailable")
    expect(output).not_to include("bundle add mongo")
  end
end
