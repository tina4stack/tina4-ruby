# frozen_string_literal: true

# Which server production runs (ADR-0067).
#
# Puma is no longer a Tina4 dependency. `tina4ruby serve --production` (and
# Tina4.run! outside debug) hand off to Puma ONLY when the application has
# installed it; otherwise Tina4's built-in server serves production too, the
# way Python's asyncio server does when uvicorn is absent.
#
# The "installed" case is spec/puma_shutdown_spec.rb (a child outside Bundler,
# where the installed puma gem is loadable). This file is the other half: a
# REAL application bundle whose Gemfile names only tina4ruby, resolved by real
# Bundler, booted with --production. Under Bundler an unlisted gem is not on
# the load path even when it is installed, which is exactly the application
# that never asked for Puma.

require "spec_helper"
require "open3"
require_relative "support/shutdown_probe"

RSpec.describe "Production server selection", :slow do
  def write_bundle(dir)
    FileUtils.mkdir_p(File.join(dir, "src", "routes"))
    File.write(File.join(dir, "src", "routes", "ping.rb"), <<~RUBY)
      Tina4.get("/ping") { |_request, response| response.json({ pong: true }) }
    RUBY
    File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      gem "tina4ruby", path: #{File.expand_path("..", __dir__).inspect}
    GEMFILE
  end

  # Bundler settings the suite's own run may export must not leak into the
  # application's bundle (groups it does not have, a frozen lockfile).
  def bundle_env(dir)
    ShutdownProbe.base_env(
      "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"),
      "BUNDLE_WITH" => nil, "BUNDLE_WITHOUT" => nil,
      "BUNDLE_FROZEN" => nil, "BUNDLE_DEPLOYMENT" => nil,
      "TINA4_OVERRIDE_CLIENT" => "true"
    )
  end

  # The suite runs under `bundle exec`, which exports its own Gemfile, lockfile
  # and RUBYOPT; a child bundler inheriting them resolves (and rewrites) the
  # FRAMEWORK's lockfile instead of the application's. Start from the
  # environment as it was before Bundler touched it.
  def unbundled(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end

  it "serves production from the built-in server when the app bundle has no puma" do
    dir = SpecTmpdir.create("tina4-server-selection")
    write_bundle(dir)
    output, status = unbundled { Open3.capture2e(bundle_env(dir), "bundle", "lock", "--local", chdir: dir) }
    expect(status.success?).to be(true), "could not resolve the app bundle offline:\n#{output}"
    expect(File.read(File.join(dir, "Gemfile.lock"))).not_to match(/^\s+puma /),
                                                            "tina4ruby must not pull puma into an app bundle"

    port = ShutdownProbe.free_port
    log_path = File.join(dir, "server.log")
    pid = unbundled do
      # `bundle exec ruby <checkout>/exe/tina4ruby`, not `bundle exec tina4ruby`:
      # Bundler 2.x (what Ruby 3.2 ships, and what CI runs) finds a PATH gem's
      # executable only after `bundle install` has written its binstub, so the
      # bare form fails there with "command not found". The app's bundle still
      # governs the load path either way - which is the whole point here.
      spawn(bundle_env(dir), "bundle", "exec", "ruby", File.expand_path("../exe/tina4ruby", __dir__),
            "serve", "--production",
            "--host", "127.0.0.1", "--port", port.to_s, "--no-browser",
            chdir: dir, out: log_path, err: log_path, pgroup: true)
    end
    server = ShutdownProbe::Server.new(pid, port, dir, log_path)
    begin
      server.wait_until_serving!("/ping", timeout: 60)
      expect(server.log).to include("(tina4-server)")
      expect(server.log).not_to include("Production server: puma")

      server.signal("TERM")
      expect(server.wait_for_exit(25)&.exitstatus).to eq(0), server.log
    ensure
      server.destroy!
    end
  end
end
