# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# The startup banner names the host and port the server REALLY binds.
#
# Observed on the lab (Ubuntu, Ruby 3.2.3, Puma 6.6.1, 2026-09-24):
# `Tina4.run!(__dir__, port: 47343, host: "127.0.0.1")` bound Puma to
# 127.0.0.1:47343 (`ss -ltnp`), while the banner said
# `Server:    http://localhost:7147 (puma)`. Tina4.initialize! printed the banner
# with print_banner's DEFAULTS, before run! had resolved the bind. The built-in
# server path printed that wrong banner and then a second, correct one.
#
# Each example boots a REAL `ruby app.rb` child (spec/support/shutdown_probe.rb),
# proves the server answers on the port under test, and then reads the banner
# out of the child's own log. No mocks.
#
# Case names:
#   - banner_names_the_explicit_port_and_host        (Puma and built-in)
#   - banner_names_tina4_port_and_tina4_host         (Puma and built-in)
#   - explicit_port_argument_beats_tina4_port        (ADR-0041)
#
# Mutation-proved: see plan/banner-real-bind.md.

require "spec_helper"
require "rbconfig"
require_relative "support/shutdown_probe"

module BannerProbe
  module_function

  SERVER_LINE = /^\s*Server:\s+(\S+)/

  # app.rb calls Tina4.run! exactly the way a scaffolded app does. $stdout is
  # synced because the child writes to a file, where Ruby buffers output.
  def write_app(dir, run_arguments)
    File.write(File.join(dir, "app.rb"), <<~RUBY)
      $stdout.sync = true
      #{ShutdownProbe.load_guard}
      Tina4.run!(__dir__#{run_arguments})
    RUBY
  end

  def boot(port:, run_arguments: "", builtin: false, env: {})
    dir = SpecTmpdir.create("tina4-banner-bind")
    write_app(dir, run_arguments)
    log_path = File.join(dir, "server.log")

    child_env = ShutdownProbe.base_env(
      {
        # Never inherit a bind or a banner switch from the shell running rspec.
        "TINA4_PORT" => nil, "TINA4_HOST" => nil, "PORT" => nil, "HOST" => nil,
        "TINA4_SUPPRESS" => nil,
        "TINA4_DEFAULT_WEBSERVER" => (builtin ? "TRUE" : nil),
        "TINA4_OVERRIDE_CLIENT" => "true"
      }.merge(env)
    )

    pid = spawn(child_env, RbConfig.ruby, "app.rb",
                chdir: dir, out: log_path, err: log_path, pgroup: true)
    ShutdownProbe::Server.new(pid, port, dir, log_path).wait_until_serving!("/health")
  end

  def server_urls(log)
    log.scan(SERVER_LINE).flatten
  end
end

RSpec.describe "Startup banner names the real bind", :slow do
  before(:all) do
    require "puma"
  rescue LoadError
    skip "the puma gem is NOT installed, so the Puma banner path cannot be exercised"
  end

  [
    ["Puma", false],
    ["the built-in server", true]
  ].each do |server_label, builtin|
    context "on #{server_label}" do
      it "banner_names_the_explicit_port_and_host" do
        port = ShutdownProbe.free_port
        server = BannerProbe.boot(port: port, builtin: builtin,
                                  run_arguments: ", port: #{port}, host: \"127.0.0.1\"")
        begin
          expect(BannerProbe.server_urls(server.log)).to eq(["http://127.0.0.1:#{port}"]),
            "expected exactly one banner naming http://127.0.0.1:#{port}\n--- server log ---\n#{server.log}"
          # The built-in server used to be labelled "(puma)" whenever the puma
          # gem was merely installed.
          expect(server.log.include?("(puma)")).to eq(!builtin), "--- server log ---\n#{server.log}"
        ensure
          server.destroy!
        end
      end

      it "banner_names_tina4_port_and_tina4_host" do
        port = ShutdownProbe.free_port
        server = BannerProbe.boot(port: port, builtin: builtin,
                                  env: { "TINA4_PORT" => port.to_s, "TINA4_HOST" => "127.0.0.1" })
        begin
          expect(BannerProbe.server_urls(server.log)).to eq(["http://127.0.0.1:#{port}"]),
            "expected exactly one banner naming http://127.0.0.1:#{port}\n--- server log ---\n#{server.log}"
        ensure
          server.destroy!
        end
      end
    end
  end

  # ADR-0041: an explicit argument beats the environment (Python: CLI arg >
  # ENV > default). run! used to write port: into the deprecated bare PORT,
  # which TINA4_PORT outranks, so the argument lost AND the app was warned
  # about a variable it never set.
  it "explicit_port_argument_beats_tina4_port" do
    port = ShutdownProbe.free_port
    environment_port = ShutdownProbe.free_port
    server = BannerProbe.boot(port: port,
                              run_arguments: ", port: #{port}, host: \"127.0.0.1\"",
                              env: { "TINA4_PORT" => environment_port.to_s })
    begin
      expect(BannerProbe.server_urls(server.log)).to eq(["http://127.0.0.1:#{port}"]),
        "--- server log ---\n#{server.log}"
      expect(server.log).not_to include("PORT is deprecated")
      expect(server.log).not_to include("HOST is deprecated")
    ensure
      server.destroy!
    end
  end
end
