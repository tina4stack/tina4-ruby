# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# `--help` / `-h` print usage and change nothing, for every command; unknown
# options are refused.
#
# Handlers never looked for a help flag, so it ran the command for real:
# `generate model --help` wrote a model named `--help`, `migrate --help` opened
# the database. NO MOCKS: each case runs the REAL exe/tina4ruby as a child
# process in a real temp project and hashes the tree before and after. Ruby
# mirror of the Python master's tests/test_cli_help_flags.py.
#
# Ruby exception: `serve` / `start` already define `-h` as `--host`, so there
# only `--help` is help and `-h HOST` keeps meaning host.

require "spec_helper"
require "tina4/cli"
require "open3"
require "digest"
require "find"
require "tmpdir"
require "rbconfig"
require_relative "support/shutdown_probe"

RSpec.describe "tina4ruby --help and option checking" do
  HELP_REPO_ROOT = File.expand_path("..", __dir__)
  HELP_EXE = File.join(HELP_REPO_ROOT, "exe", "tina4ruby")
  HELP_LIB = File.join(HELP_REPO_ROOT, "lib")
  HOST_SHORT = %w[serve start].freeze # -h means --host here
  CLI_TIMEOUT = 60
  BACKTRACE = /\.rb:\d+:in |\(OptionParser::/

  around do |example|
    Dir.mktmpdir("tina4-help") do |dir|
      @project = dir
      example.run
    end
  end

  # Run the REAL exe/tina4ruby in `cwd`. Bundler is stripped (the temp project
  # has no Gemfile it could resolve) and TINA4_ settings are not inherited.
  # stdin is closed so an interactive prompt can't wait forever.
  def run_cli(argv, cwd: @project, path: ENV.fetch("PATH"))
    env = ENV.to_h.select { |key, _| key.start_with?("TINA4_") }.transform_values { nil }.merge(
      "PATH" => path, "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
      "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil,
      "TINA4_NO_BROWSER" => "true", "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true"
    )
    # A child that never exits (unfixed v3: `queue work --onse` polled forever)
    # is killed after CLI_TIMEOUT and reports a nil exit code.
    Open3.popen3(env, RbConfig.ruby, "-I#{HELP_LIB}", HELP_EXE, *argv, chdir: cwd) do |stdin, out, err, waiter|
      stdin.close
      readers = [out, err].map { |io| Thread.new { io.read.force_encoding(Encoding::UTF_8).scrub } }
      unless waiter.join(CLI_TIMEOUT)
        Process.kill("KILL", waiter.pid)
        waiter.join
      end
      [readers[0].value, readers[1].value, waiter.value.exitstatus]
    end
  end

  # Every path under root with a hash of its bytes.
  def snapshot(root = @project)
    seen = {}
    Find.find(root) do |path|
      next if path == root

      rel = path.delete_prefix("#{root}/")
      seen[rel] = File.directory?(path) ? "dir" : Digest::SHA256.file(path).hexdigest
    end
    seen
  end

  # A minimal project: an app.rb and a Gemfile that `lint` could rewrite.
  def make_project
    File.write(File.join(@project, "app.rb"), "puts 'app'\n")
    File.write(File.join(@project, "Gemfile"), "source \"https://rubygems.org\"\n")
  end

  before { make_project }

  def summary_for(argv)
    registry = argv.length == 2 ? Tina4::CLI::GENERATORS : Tina4::CLI::COMMANDS
    registry.fetch(argv.last)[:summary]
  end

  command_cases = Tina4::CLI::COMMANDS.keys.reject { |name| name == "help" }.map { |name| [name] }
  generator_cases = Tina4::CLI::GENERATORS.keys.map { |name| ["generate", name] }

  (command_cases + generator_cases).each do |argv|
    %w[--help -h].each do |flag|
      next if flag == "-h" && HOST_SHORT.include?(argv.first)

      it "#{argv.join(' ')} #{flag} prints usage, exits 0 and writes nothing" do
        before = snapshot
        stdout, stderr, code = run_cli([*argv, flag])
        expect(code).to eq(0), stdout + stderr
        expect(stdout).to include("Usage: tina4ruby #{argv.join(' ')}")
        # One format for every command (OptionParser's own --help banner is not it).
        expect(stdout).to include(argv == ["generate"] ? "\n\nGenerators:\n" : "\n\n  #{summary_for(argv)}\n")
        expect(snapshot).to eq(before), "a #{flag} run changed the project"
      end
    end
  end

  %w[--help -h].each do |flag|
    it "#{flag} after the name and options still wins" do
      before = snapshot
      stdout, stderr, code = run_cli(["generate", "model", "Product", "--fields", "name:string", flag])
      expect(code).to eq(0), stdout + stderr
      expect(stdout).to include("Usage: tina4ruby generate model")
      expect(snapshot).to eq(before)
    end

    it "top-level #{flag} prints the full reference" do
      stdout, stderr, code = run_cli([flag])
      expect(code).to eq(0), stdout + stderr
      expect(stdout).to include("Usage: tina4ruby COMMAND")
      expect(stdout).to include("Generators:")
    end
  end

  # `help` is not option-checked: whatever follows it, it prints the reference.
  [%w[help], %w[help --help], %w[help -h]].each do |argv|
    it "#{argv.join(' ')} prints the full reference and exits 0" do
      stdout, stderr, code = run_cli(argv)
      expect(code).to eq(0), stdout + stderr
      expect(stdout).to include("Usage: tina4ruby COMMAND")
      expect(stdout).not_to include("Unknown option")
    end
  end

  it "uses the per-command format: usage, blank line, indented summary, subcommands" do
    stdout, = run_cli(%w[queue --help])
    expect(stdout).to eq(<<~OUT)
      Usage: tina4ruby queue <work|stats|retry|clear> [topic]

        Run queue workers and manage jobs
        Subcommands: work, stats, retry, clear
    OUT
  end

  it "generate --help lists every generator" do
    stdout, _stderr, code = run_cli(%w[generate --help])
    expect(code).to eq(0)
    expect(stdout).to start_with("Usage: tina4ruby generate <what> <name> [options]\n\nGenerators:\n")
    Tina4::CLI::GENERATORS.each_key { |name| expect(stdout).to match(/^  #{name} /) }
  end

  it "generate <unknown> --help lists the generators too" do
    stdout, _stderr, code = run_cli(%w[generate bogus --help])
    expect(code).to eq(0)
    expect(stdout).to include("Generators:")
  end

  # ---- serve / start: -h stays --host -------------------------------------

  describe "serve -h is still --host" do
    it "takes the next argument as the host (option checking continues past it)" do
      stdout, stderr, code = run_cli(%w[serve -h 127.0.0.1 --prot 9000])
      expect(code).to eq(1), stdout + stderr
      expect(stdout).not_to include("Usage:")
      expect(stdout).to include('Unknown option --prot for "serve". Did you mean --port?')
    end

    it "needs a value like --host does" do
      stdout, stderr, code = run_cli(%w[start -h])
      expect(code).to eq(1)
      expect(stdout).to include('Option --host for "start" needs a value: --host <value>')
      expect(stderr).not_to match(BACKTRACE)
    end

    it "boots a real server bound to the -h host" do
      attempts = 3
      attempts.times do |attempt|
        dir = Dir.mktmpdir("tina4-help-serve") # destroy! removes it
        port = ShutdownProbe.free_port
        log = File.join(dir, "serve.log")
        FileUtils.mkdir_p(File.join(dir, "src", "routes"))
        env = ShutdownProbe.base_env("TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_TAKEOVER" => "true",
                                     "TINA4_DEFAULT_WEBSERVER" => "true")
        pid = Process.spawn(env, RbConfig.ruby, "-I", HELP_LIB, HELP_EXE, "serve", "-p", port.to_s,
                            "-h", "127.0.0.1", "--no-browser", chdir: dir, out: log, err: log, pgroup: true)
        server = ShutdownProbe::Server.new(pid, port, dir, log)
        begin
          server.wait_until_serving!("/health", timeout: 30, require_log: %r{Server:\s+http://127\.0\.0\.1:#{port}\b})
          expect(server.get("/health")&.first).to eq(200)
          expect(server.log).not_to include("Usage:")
          break
        rescue ShutdownProbe::BootError
          raise if attempt == attempts - 1
        ensure
          server.destroy!
        end
      end
    end
  end

  describe "a name that looks like an option" do
    [
      %w[generate model --fields name:string], # name forgotten
      %w[generate route --public],
    ].each do |argv|
      it "is refused: #{argv.join(' ')}" do
        before = snapshot
        stdout, stderr, code = run_cli(argv)
        expect(code).to eq(1), stdout + stderr
        expect(stdout).to include("Invalid #{argv[1]} name: '#{argv[2]}' - names can't start with '-'.")
        expect(snapshot).to eq(before)
      end
    end
  end

  # ---- options: unknown ones, missing values, --name=value, ai --all -------

  describe "a misspelled option" do
    [
      [%w[generate model Product --feilds name:string], "--feilds", "--fields", "generate model"],
      [%w[generate route products --publc], "--publc", "--public", "generate route"],
      [%w[serve --prot 9000], "--prot", "--port", "serve"],
      [%w[queue work --onse], "--onse", "--once", "queue work"],
      [%w[generate model Product --feilds=name:string], "--feilds", "--fields", "generate model"],
    ].each do |argv, wrong, suggestion, label|
      it "is refused with a suggestion: #{argv.join(' ')}" do
        before = snapshot
        stdout, stderr, code = run_cli(argv)
        expect(code).to eq(1), stdout + stderr
        expect(stdout).to include(%(Unknown option #{wrong} for "#{label}". Did you mean #{suggestion}?))
        expect(stdout).to include(%(Run "tina4ruby #{label} --help" for its options.))
        expect(snapshot).to eq(before)
      end
    end
  end

  describe "an option the command does not have" do
    [
      %w[generate model Product -f name:string], # short options don't exist here
      %w[lint --everything],
      %w[migrate --force],
      %w[serve -x],
      %w[test -q], # Ruby's `test` runs Tina4::Testing and reads no arguments
      %w[generate auth --fields a:string], # Ruby's auth generator takes no options
    ].each do |argv|
      it "is refused: #{argv.join(' ')}" do
        before = snapshot
        stdout, stderr, code = run_cli(argv)
        expect(code).to eq(1), stdout + stderr
        expect(stdout).to include("Unknown option #{argv.find { |a| a.start_with?('-') }} for")
        expect(snapshot).to eq(before)
      end
    end
  end

  describe "a value option without a value" do
    [
      [%w[generate model Product --fields], "--fields"],
      [%w[generate service Nightly --every], "--every"], # used to be ignored
      [%w[generate model Product --fields --no-migration], "--fields"],
      [%w[serve --port], "--port"], # used to be an OptionParser::MissingArgument backtrace
      [%w[migrate:rollback -n], "--steps"],
      [%w[queue work --poll], "--poll"],
    ].each do |argv, option|
      it "is refused without a backtrace: #{argv.join(' ')}" do
        before = snapshot
        stdout, stderr, code = run_cli(argv)
        expect(code).to eq(1), stdout + stderr
        expect(stdout).to include("Option #{option} for")
        expect(stdout).to include("needs a value: #{option} <value>")
        expect(stderr).not_to match(BACKTRACE)
        expect(snapshot).to eq(before)
      end
    end
  end

  it "an option value OptionParser can't convert is refused without a backtrace" do
    stdout, stderr, code = run_cli(%w[serve --port abc])
    expect(code).to eq(1)
    expect(stdout).to include("invalid argument: --port abc")
    expect(stderr).not_to match(BACKTRACE)
  end

  [%w[--fields price:float], %w[--fields=price:float]].each do |fields_arg|
    it "a value option works as #{fields_arg.join(' ')}" do
      stdout, stderr, code = run_cli(["generate", "model", "Product", *fields_arg])
      expect(code).to eq(0), stdout + stderr
      expect(File.read(File.join(@project, "src", "orm", "product.rb"))).to include("price")
    end
  end

  # `generate model` suggests `generate crud <Name> --skip-model`; it is a real option.
  it "generate crud --skip-model keeps the existing model and still writes the crud route" do
    _out, err, code = run_cli(%w[generate model Product --fields price:float])
    expect(code).to eq(0), err
    model = File.join(@project, "src", "orm", "product.rb")
    model_bytes = File.binread(model)
    migrations = Dir.glob(File.join(@project, "migrations", "*")).sort

    stdout, stderr, code = run_cli(%w[generate crud Product --skip-model])
    expect(code).to eq(0), stdout + stderr
    expect(stdout + stderr).not_to include("already exists")
    expect(File.binread(model)).to eq(model_bytes)
    expect(Dir.glob(File.join(@project, "migrations", "*")).sort).to eq(migrations)
    expect(File).to exist(File.join(@project, "src", "routes", "product.rb"))
  end

  it "--name=value works for an OptionParser command too" do
    stdout, stderr, code = run_cli(%w[serve --port=abc])
    expect(code).to eq(1), stdout + stderr
    expect(stdout).to include("invalid argument: --port=abc")
  end

  # PATH holds only the ruby interpreter, so `which pip3` finds nothing and the
  # optional tina4-ai pip install is skipped for real (nothing installed on the
  # machine running the suite).
  %w[--all all].each do |form|
    it "ai #{form} installs every context file without the menu" do
      stdout, stderr, code = run_cli(["ai", form], path: File.dirname(RbConfig.ruby))
      expect(code).to eq(0), stdout + stderr
      expect(stdout).not_to include("Select (comma-separated")
      expect(File).to exist(File.join(@project, "CLAUDE.md"))
    end
  end

  it "every option in a usage string is an accepted option (drift guard)" do
    cli = Tina4::CLI
    cli::COMMANDS.each do |name, spec|
      usage = spec[:usage].to_s
      usage.scan(/--([a-z][a-z-]*)/).flatten.each do |option|
        expect(spec.fetch(:flags, {})).to have_key(option), "#{name}: --#{option} documented, not accepted"
      end
      usage.scan(/(?<![\w-])-([a-z])\b/).flatten.each do |short|
        expect(spec.fetch(:short, {})).to have_key(short), "#{name}: -#{short} documented, not accepted"
      end
      (spec[:short] || {}).each_value do |long|
        expect(spec[:flags]).to have_key(long), "#{name}: short alias for unknown --#{long}"
      end
    end
    cli::GENERATORS.each do |name, spec|
      accepted = cli::RESOLUTION_TARGETS.include?(name) ? spec[:flags].merge(cli::RESOLUTION_FLAGS) : spec[:flags]
      spec[:usage].scan(/--([a-z][a-z-]*)/).flatten.each do |option|
        expect(accepted).to have_key(option), "generate #{name}: --#{option} documented, not accepted"
      end
    end
    expect(cli::QUEUE_FLAGS.keys).to eq(cli::COMMANDS["queue"][:subcommands])
  end
end
