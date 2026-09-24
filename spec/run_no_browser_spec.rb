# frozen_string_literal: true

# REGRESSION: Tina4.run! opened a browser tab no matter what.
#
# open_browser checked nothing: not TINA4_NO_BROWSER, not --no-browser, not
# production, not CI. Every app booted through Tina4.run! - the documented
# app.rb entry point, and several specs - fired `open <url>` on macOS and popped
# a real tab on the developer's screen, even with TINA4_NO_BROWSER=true set.
#
# The browser now opens only when ALL of these hold:
#   * TINA4_DEBUG is truthy (development only - never production or Puma)
#   * TINA4_NO_BROWSER is not truthy
#   * --no-browser was not passed
#   * no CI environment variable is set
#
# NO MOCKS. A real `ruby app.rb` child runs Tina4.run!. The launcher is the
# documented TINA4_BROWSER_COMMAND hook pointed at a real script that writes a
# marker file, so the assertion is about a real process being spawned (or not)
# - and nothing on the test machine ever opens a real browser.

require "spec_helper"
require "rbconfig"
require_relative "support/shutdown_probe"

RSpec.describe "Tina4.run! browser launch", :slow do
  # A method, not a constant: a constant in a describe block lands on Object.
  def ci_variables
    %w[CI CONTINUOUS_INTEGRATION GITHUB_ACTIONS GITLAB_CI BUILDKITE JENKINS_URL TEAMCITY_VERSION]
  end

  def boot(env: {}, argv: [])
    dir = SpecTmpdir.create("tina4-run-browser")
    marker = File.join(dir, "browser_opened")
    launcher = File.join(dir, "launcher.sh")
    File.write(launcher, "#!/bin/sh\necho \"$@\" >> #{marker}\n")
    File.chmod(0o755, launcher)
    # Belt and braces: the OS launchers are shadowed on PATH by the same
    # recording script, so even a launch that ignored the hook is observed -
    # and never reaches a real browser.
    shim_dir = File.join(dir, "shim")
    FileUtils.mkdir_p(shim_dir)
    %w[open xdg-open].each { |name| FileUtils.cp(launcher, File.join(shim_dir, name)) }
    File.write(File.join(dir, "app.rb"), <<~RUBY)
      #{ShutdownProbe.load_guard}
      Tina4.get("/ping") { |_request, response| response.json({ pong: true }) }
      Tina4.run!(#{dir.inspect})
    RUBY
    port = ShutdownProbe.free_port
    log_path = File.join(dir, "server.log")
    child_env = ShutdownProbe.base_env(
      {
        "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_SUPPRESS" => "true", "TINA4_PORT" => port.to_s,
        "TINA4_NO_AI_PORT" => "true", "TINA4_DEBUG" => "true", "TINA4_NO_BROWSER" => nil,
        "TINA4_BROWSER_COMMAND" => launcher,
        "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
      }.merge(ci_variables.to_h { |name| [name, nil] }).merge(env)
    )
    pid = spawn(child_env, RbConfig.ruby, File.join(dir, "app.rb"), *argv,
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    server = ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/ping")
    # open_browser waits 2s before launching; give it room to do so.
    sleep 3
    [server, marker]
  end

  def expect_no_launch(**options)
    server, marker = boot(**options)
    expect(File.exist?(marker)).to be(false), "a browser launcher ran: #{File.read(marker) rescue ''}"
  ensure
    server&.destroy!
  end

  it "launches in debug when nothing suppresses it (the one case that opens)" do
    server, marker = boot
    expect(File.exist?(marker)).to be(true), "no browser launcher ran\n#{server.log}"
    expect(File.read(marker)).to include("http://")
  ensure
    server&.destroy!
  end

  it "does not launch when TINA4_NO_BROWSER=true" do
    expect_no_launch(env: { "TINA4_NO_BROWSER" => "true" })
  end

  it "does not launch when TINA4_NO_BROWSER=on" do
    expect_no_launch(env: { "TINA4_NO_BROWSER" => "on" })
  end

  it "does not launch when --no-browser is passed" do
    expect_no_launch(argv: ["--no-browser"])
  end

  it "does not launch outside debug (production)" do
    expect_no_launch(env: { "TINA4_DEBUG" => "false" })
  end

  it "does not launch under CI" do
    expect_no_launch(env: { "CI" => "true" })
  end
end
