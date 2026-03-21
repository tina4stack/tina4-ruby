# frozen_string_literal: true

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
    end
  end

  describe "COMMANDS constant" do
    it "includes all expected commands" do
      %w[init start migrate seed test version routes console help].each do |cmd|
        expect(Tina4::CLI::COMMANDS).to include(cmd)
      end
    end
  end

  describe ".start" do
    it "is a class method" do
      expect(Tina4::CLI).to respond_to(:start)
    end
  end
end
