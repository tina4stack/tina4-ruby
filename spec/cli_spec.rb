# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "spec_helper"
require "tina4/cli"

RSpec.describe Tina4::CLI do
  describe "command parsing" do
    let(:cli) { Tina4::CLI.new }

    describe "version" do
      it "prints version without error" do
        expect { cli.run(["version"]) }.to output(/Tina4 Ruby v/).to_stdout
      end
    end

    describe "help" do
      it "prints help text" do
        expect { cli.run(["help"]) }.to output(/Usage: tina4ruby COMMAND/).to_stdout
      end

      it "prints help for --help flag" do
        expect { cli.run(["--help"]) }.to output(/Usage: tina4ruby COMMAND/).to_stdout
      end

      it "prints help for -h flag" do
        expect { cli.run(["-h"]) }.to output(/Usage: tina4ruby COMMAND/).to_stdout
      end
    end

    describe "unknown command" do
      it "prints error and exits" do
        expect {
          begin
            cli.run(["nonexistent"])
          rescue SystemExit
            # expected
          end
        }.to output(/Unknown command/).to_stdout
      end
    end

    describe "init" do
      let(:tmpdir) { Dir.mktmpdir }
      after { FileUtils.rm_rf(tmpdir) }

      it "creates project structure" do
        project_dir = File.join(tmpdir, "testproject")
        Dir.chdir(tmpdir) do
          cli.run(["init", "testproject"])
        end

        expect(Dir.exist?(File.join(project_dir, "src", "routes"))).to be true
        expect(Dir.exist?(File.join(project_dir, "src", "templates"))).to be true
        expect(Dir.exist?(File.join(project_dir, "src", "public"))).to be true
        expect(Dir.exist?(File.join(project_dir, "migrations"))).to be true
        expect(File.exist?(File.join(project_dir, "app.rb"))).to be true
        expect(File.exist?(File.join(project_dir, "Gemfile"))).to be true
      end

      # sqlite3 is an app dependency (ADR-0067), so the scaffold must declare it
      # or a fresh project's default SQLite database cannot open. The gem is
      # published as "tina4ruby"; the scaffold used to write "tina4-ruby", which
      # does not exist on rubygems.org, so `bundle install` failed outright.
      it "writes a Gemfile that bundles tina4ruby and sqlite3" do
        Dir.chdir(tmpdir) { cli.run(["init", "testproject"]) }
        gemfile = File.read(File.join(tmpdir, "testproject", "Gemfile"))
        expect(gemfile).to match(/^gem "tina4ruby"/)
        expect(gemfile).to match(/^gem "sqlite3"/)
        expect(gemfile).not_to include("tina4-ruby")
      end
    end
  end

  describe "COMMANDS dispatch" do
    let(:cli) { Tina4::CLI.new }

    # Run the CLI, capturing stdout and the SystemExit status (0 if it didn't
    # exit). Same pattern as metrics_cli_spec.rb#run_metrics.
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

    it "routes a known command to its real effect, not the Unknown-command branch" do
      # "version" is a representative COMMANDS entry. Running it must produce the
      # command's actual side effect (the version string on stdout), exit
      # cleanly, and must NOT fall through to the Unknown-command/exit path.
      # This ties the COMMANDS contract to real routing behaviour instead of
      # asserting the array against its own literals.
      expect(Tina4::CLI::COMMANDS).to include("version")
      out, status = run_cli(["version"])
      expect(out).to match(/Tina4 Ruby v#{Regexp.escape(Tina4::VERSION)}/)
      expect(out).not_to match(/Unknown command/)
      expect(status).to eq(0)
    end

    it "routes an entry NOT in COMMANDS to the Unknown-command/exit path" do
      # The dispatch's else branch prints "Unknown command:" and exit(1)s.
      # An entry that is genuinely absent from COMMANDS must hit it.
      expect(Tina4::CLI::COMMANDS).not_to include("nonexistent")
      out, status = run_cli(["nonexistent"])
      expect(out).to match(/Unknown command: nonexistent/)
      expect(status).to eq(1)
    end
  end

  describe ".start" do
    it "delegates to an instance #run and executes the command end-to-end" do
      # Tina4::CLI.start(argv) is defined as `new.run(argv)`. Drive it
      # end-to-end: the version effect on stdout proves .start built an
      # instance and dispatched the command through #run.
      expect { Tina4::CLI.start(["version"]) }
        .to output(/Tina4 Ruby v#{Regexp.escape(Tina4::VERSION)}/).to_stdout
    end
  end
end
