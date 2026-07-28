# frozen_string_literal: true

# REGRESSION: the scaffolded Dockerfile could not boot.
#
# `tina4ruby init` wrote a Dockerfile that set three LEGACY, un-prefixed env vars
# (SWAGGER_TITLE, SWAGGER_VERSION, SWAGGER_DESCRIPTION). lib/tina4/env.rb maps
# those to their TINA4_ forms, and Tina4.check_legacy_env_vars! REFUSES to boot
# when it finds any legacy name -- so the generated image shipped exactly the
# misconfiguration the framework rejects, and the container exited 2 during
# startup having served nothing.
#
# It also never set TINA4_OVERRIDE_CLIENT, which Tina4::WebServer#start requires
# unless the tina4 CLI launched the process (--managed). Without it the server
# prints "Tina4 must be started with the tina4 CLI" and exits 1. A container has
# no CLI supervising it.
#
# Both defects were invisible to every existing test, because nothing ever read
# the generated Dockerfile -- let alone built and ran it. These specs read it.
require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"

RSpec.describe "scaffolded Dockerfile" do
  let(:cli) { Tina4::CLI.new }

  # The full env-var rename table is the source of truth for what counts as
  # legacy. Any un-prefixed key in it, set with ENV in a Dockerfile, is a
  # boot-blocker -- so assert against the table rather than a hand-written list
  # that would drift as the table grows.
  let(:legacy_keys) { Tina4::LEGACY_ENV_VARS.keys }

  around(:each) do |example|
    Dir.mktmpdir("tina4_dockerfile_spec") do |dir|
      @tmp_dir = dir
      Dir.chdir(dir) { example.run }
    end
  end

  # Drive the REAL init command, not create_sample_files directly: the sample
  # writer assumes create_project_structure has already made src/templates, so
  # calling it alone raises Errno::ENOENT. Going through cmd_init is also the
  # honest test -- it is exactly what a user runs.
  def dockerfile
    suppress_output { cli.run(%w[init app]) }
    path = File.join(@tmp_dir, "app", "Dockerfile")
    expect(File.exist?(path)).to be(true), "tina4ruby init did not write a Dockerfile"
    File.read(path)
  end

  def suppress_output
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  it "sets no legacy un-prefixed env var that would refuse to boot" do
    offenders = dockerfile.lines.filter_map do |line|
      m = line.match(/^\s*ENV\s+([A-Z0-9_]+)\s*=/)
      m[1] if m && legacy_keys.include?(m[1])
    end

    expect(offenders).to be_empty,
      "Dockerfile sets legacy env var(s) #{offenders.inspect}. " \
      "check_legacy_env_vars! refuses to boot on these -- use the TINA4_ form."
  end

  it "sets the TINA4_ prefixed swagger defaults" do
    body = dockerfile
    expect(body).to include("TINA4_SWAGGER_TITLE")
    expect(body).to include("TINA4_SWAGGER_VERSION")
    expect(body).to include("TINA4_SWAGGER_DESCRIPTION")
  end

  it "sets TINA4_OVERRIDE_CLIENT so WebServer#start does not exit 1" do
    expect(dockerfile).to match(/^\s*ENV\s+TINA4_OVERRIDE_CLIENT\s*=\s*true\s*$/),
      "without this the container prints the must-use-the-CLI banner and exits 1"
  end

  it "starts the production server, not WEBrick" do
    cmd = dockerfile.lines.grep(/^\s*CMD /).first.to_s
    expect(cmd).to include("--production"),
      "cmd_start falls through to WEBrick without --production, so a " \
      "production image would serve from the development server"
  end

  it "binds 0.0.0.0, which is what makes the published port reachable" do
    cmd = dockerfile.lines.grep(/^\s*CMD /).first.to_s
    expect(cmd).to include("0.0.0.0"),
      "a server on 127.0.0.1 inside a container is unreachable via docker run -p"
  end
end
