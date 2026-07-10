# frozen_string_literal: true
#
# Real tests for the `build` CLI command (Phase 3, self-describing CLI epic —
# Ruby mirror of the Python master's `build`). `build` shells out to the real
# `docker` CLI to produce the deployable image.
#
# NO mocks. The fail-loud guards are exercised for real (a genuinely missing
# Dockerfile; a genuinely empty PATH so `docker` cannot be found), and — when a
# real docker daemon is available — a REAL `docker build` runs against a trivial
# `FROM scratch` Dockerfile (no network, instant) and the resulting image is
# read back from `docker images`, then removed. When docker is genuinely absent
# the real-build example SKIPS LOUDLY with the reason (never a mock).

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "tina4ruby build" do
  let(:cli) { Tina4::CLI.new }

  around(:each) do |example|
    Dir.mktmpdir("tina4clibuild") do |dir|
      @tmp = dir
      Dir.chdir(dir) { example.run }
    end
  end

  def run_cli(args)
    out = +""
    status = 0
    orig = $stdout
    $stdout = StringIO.new
    begin
      cli.run(args)
    rescue SystemExit => e
      status = e.status
    ensure
      out = $stdout.string
      $stdout = orig
    end
    [out, status]
  end

  # Real docker daemon reachable? (binary on PATH AND `docker info` succeeds).
  def docker_available?
    system("docker", "info", out: File::NULL, err: File::NULL)
  rescue StandardError
    false
  end

  it "fails loud (exit 1) when there is no Dockerfile" do
    out, status = run_cli(["build"])
    expect(status).to eq(1)
    expect(out).to include("✗ No Dockerfile found.")
    expect(out).to include("A Tina4 app deploys as a container")
  end

  it "fails loud naming a missing custom --file" do
    out, status = run_cli(["build", "--file", "docker/Custom.Dockerfile"])
    expect(status).to eq(1)
    expect(out).to include("✗ No docker/Custom.Dockerfile found.")
  end

  it "fails loud when docker is not on PATH, printing the manual command + default tag" do
    File.write(File.join(@tmp, "Dockerfile"), "FROM scratch\n")
    default_tag = "#{File.basename(@tmp).downcase}:latest"

    original_path = ENV["PATH"]
    begin
      ENV["PATH"] = "" # docker genuinely cannot be found
      out, status = run_cli(["build"])
    ensure
      ENV["PATH"] = original_path
    end

    expect(status).to eq(1)
    expect(out).to include("✗ docker was not found on PATH.")
    # The manual-build hint carries the DEFAULT tag: <cwd-basename>:latest.
    expect(out).to include("docker build -t #{default_tag} -f Dockerfile .")
  end

  it "runs a REAL docker build against FROM scratch when docker is available" do
    skip "docker daemon not available (binary missing or daemon down)" unless docker_available?

    tag = "tina4-p3-build-spec:latest"
    File.write(File.join(@tmp, "Dockerfile"), "FROM scratch\n")

    begin
      out, status = run_cli(["build", "--tag", tag])

      expect(status).to eq(0)
      expect(out).to include("Building image #{tag} from Dockerfile ...")
      expect(out).to include("✓ Built image #{tag}")
      expect(out).to include("Run: docker run -p 7147:7147 #{tag}")

      # Read the image back from the REAL daemon — it genuinely exists now.
      listed = `docker images #{tag} --format '{{.Repository}}:{{.Tag}}'`.strip
      expect(listed).to eq(tag)
    ensure
      system("docker", "rmi", "-f", tag, out: File::NULL, err: File::NULL)
    end
  end
end
