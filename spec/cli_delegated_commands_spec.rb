# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Real tests for the client-owned commands the CLI reaches by DELEGATION.
#
# `doctor`, `setup` and `deploy` are owned by the Rust `tina4` client. This CLI
# recognises them (the closed Tina4::CLI::DELEGATED registry) and runs the client
# with the same argv, propagating its exit code — so `tina4ruby doctor` behaves
# exactly like `tina4 doctor` without cloning the client into four languages.
#
# NO MOCKS. Every example spawns the REAL exe/tina4ruby as a child process. The
# positive examples put a REAL executable named `tina4` on a real temp PATH and
# assert the CLI actually ran it with the exact argv and propagated its exit
# status — real process, real PATH resolution, real exit status. The negative
# examples use a real PATH with no `tina4` on it at all.

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"

RSpec.describe "tina4ruby delegated client commands" do
  DELEGATED_REPO_ROOT = File.expand_path("..", __dir__)
  DELEGATED_EXE = File.join(DELEGATED_REPO_ROOT, "exe", "tina4ruby")

  around do |example|
    Dir.mktmpdir("tina4-delegated") do |dir|
      @tmp = dir
      example.run
    end
  end

  # Run the REAL exe/tina4ruby as a child with a controlled PATH.
  # Returns [combined output, exit status].
  #
  # Bundler is stripped from the child environment (RUBYOPT/BUNDLE_*): loading
  # `bundler/setup` in the child PREPENDS the gem bindir back onto PATH, which
  # would defeat the whole point of controlling what `tina4` resolves to. A plain
  # interpreter + -Ilib is also exactly how a user's installed binstub runs.
  def run_cli(argv, path:, extra_env: {})
    env = {
      "PATH" => path,
      "TINA4_CLI_DELEGATED" => nil,
      "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil,
      "BUNDLER_VERSION" => nil, "BUNDLE_PATH" => nil,
    }.merge(extra_env)
    output = IO.popen(
      env,
      [RUBY_BIN, "-I#{File.join(DELEGATED_REPO_ROOT, 'lib')}", DELEGATED_EXE, *argv,
       { err: [:child, :out], chdir: @tmp }],
      &:read
    )
    [output, $?.exitstatus]
  end

  # A real PATH directory that genuinely has NO `tina4` executable on it.
  def path_without_client
    dir = File.join(@tmp, "nobin")
    FileUtils.mkdir_p(dir)
    expect(File.exist?(File.join(dir, "tina4"))).to be(false)
    dir
  end

  # Install a REAL executable named `tina4` on a fresh temp PATH.
  #
  # It is a genuine program (not a test double standing in for one): a small
  # shell script that records the argv and guard variable it was invoked with,
  # then exits with `exit_code`. That is exactly the collaborator the delegation
  # code has — "whatever executable named tina4 is first on PATH" — so the
  # example exercises the real PATH lookup, real spawn and real exit-status
  # propagation, with no in-process substitution anywhere.
  #
  # Windows runs neither a shebang nor an extensionless file, so there the same
  # program is a `tina4.cmd` (one of the names find_client looks up) that hands
  # its arguments to a Ruby recorder with %*, the way a batch wrapper forwards
  # them. cmd.exe re-parses that command line, which is what makes the hostile
  # arguments example below mean something on Windows.
  def path_with_real_client(exit_code: 0)
    dir = File.join(@tmp, "clientbin")
    FileUtils.mkdir_p(dir)
    return windows_batch_client(dir, exit_code) if Tina4::BatchSpawn.windows?

    client = File.join(dir, "tina4")
    File.write(client, <<~SH)
      #!/bin/sh
      for arg in "$@"; do printf "%s\\n" "$arg" >> "#{argv_file}"; done
      printf "%s\\n" "$TINA4_CLI_DELEGATED" > "#{guard_file}"
      echo "REAL-CLIENT-RAN $*"
      exit #{exit_code}
    SH
    FileUtils.chmod(0o755, client)
    dir
  end

  def windows_batch_client(dir, exit_code)
    recorder = File.join(dir, "client.rb")
    source = <<~'RUBY'
      File.open(ARGV_FILE, "ab") { |f| ARGV.each { |arg| f.write(arg.b + "\n") } }
      File.write(GUARD_FILE, "#{ENV["TINA4_CLI_DELEGATED"]}\n")
      puts "REAL-CLIENT-RAN #{ARGV.join(" ")}"
      exit EXIT_CODE
    RUBY
    File.write(recorder, source.sub("ARGV_FILE", argv_file.inspect).sub("GUARD_FILE", guard_file.inspect)
                               .sub("EXIT_CODE", exit_code.to_s))
    windows = ->(path) { path.tr("/", "\\") }
    File.write(File.join(dir, "tina4.cmd"),
               %(@"#{windows.call(RUBY_BIN)}" "#{windows.call(recorder)}" %*\r\n@exit /b %ERRORLEVEL%\r\n))
    dir
  end

  def argv_file
    File.join(@tmp, "argv.txt")
  end

  def guard_file
    File.join(@tmp, "guard.txt")
  end

  # One argument per line. chomp + split(-1) keeps an empty argument, even a
  # trailing one, which a plain split("\n") would drop.
  def recorded_argv
    return [] unless File.exist?(argv_file)

    File.binread(argv_file).force_encoding("UTF-8").chomp("\n").split("\n", -1)
  end

  def recorded_guard
    File.exist?(guard_file) ? File.read(guard_file).strip : nil
  end

  def client_invoked?
    File.exist?(guard_file)
  end

  describe "the DELEGATED registry" do
    it "declares exactly doctor, setup and deploy" do
      expect(Tina4::CLI::DELEGATED.keys).to eq(%w[doctor setup deploy])
    end

    it "never shadows a natively dispatched command" do
      overlap = Tina4::CLI::DELEGATED.keys & Tina4::CLI::COMMANDS.keys
      expect(overlap).to be_empty, "ambiguous dispatch for: #{overlap.inspect}"
    end

    it "gives every delegated command a summary" do
      Tina4::CLI::DELEGATED.each do |name, spec|
        expect(spec[:summary].to_s).not_to be_empty, "#{name} has no summary"
      end
    end
  end

  describe "delegation reaches the client (positive)" do
    it "runs the client for doctor with the same argv" do
      output, status = run_cli(["doctor"], path: path_with_real_client)

      expect(status).to eq(0), output
      expect(output).to include("REAL-CLIENT-RAN doctor")
      expect(recorded_argv).to eq(["doctor"])
    end

    it "passes deploy's arguments and flags through unchanged" do
      _output, status = run_cli(["deploy", "docker", "--force"], path: path_with_real_client)

      expect(status).to eq(0)
      expect(recorded_argv).to eq(["deploy", "docker", "--force"])
    end

    # Each of these is mangled or executed when cmd.exe re-parses a batch
    # client's command line without escaping (BatBadBut): `%PATH%` expands, `^`
    # vanishes, `x|y` runs `y`, and `cd.>marker` creates the marker file if an
    # `&` or `|` is obeyed. `say "x|y"` and `q"&cd.>marker` put a metacharacter
    # outside the argument's own quotes, which on Windows takes the other of the
    # two command lines Tina4::BatchSpawn can hand Ruby's spawn.
    hostile_args = ["a&b", "100%PATH%", 'say "hi"', "a^b", "x|y", "<in", "(p)", "!bang!", "",
                    "tail\\", "x&cd.>marker", "x|cd.>marker", 'say "x|y"', 'q"&cd.>marker'].freeze

    it "passes hostile arguments through verbatim and never runs one as a command" do
      marker = File.join(@tmp, "marker")
      broken = hostile_args.filter_map do |arg|
        FileUtils.rm_f([argv_file, marker])
        output, status = run_cli(["deploy", arg], path: path_with_real_client)
        got = recorded_argv
        executed = File.exist?(marker)
        next if status.zero? && got == ["deploy", arg] && !executed

        "#{arg.inspect} -> exit #{status}, client got #{got.inspect}" \
          "#{' (MARKER CREATED)' if executed} #{output.strip[0, 120]}"
      end
      expect(broken).to be_empty, "mangled or executed:\n  #{broken.join("\n  ")}"

      FileUtils.rm_f([argv_file, marker])
      _output, status = run_cli(["deploy", *hostile_args], path: path_with_real_client)
      expect(status).to eq(0)
      expect(recorded_argv).to eq(["deploy", *hostile_args])
      expect(File.exist?(marker)).to be(false), "an argument ran as a command"
    end

    it "propagates the client's exit code instead of swallowing it" do
      _output, status = run_cli(["doctor"], path: path_with_real_client(exit_code: 3))

      expect(status).to eq(3)
    end

    it "sets the loop guard on the child" do
      run_cli(["setup"], path: path_with_real_client)

      expect(recorded_guard).to eq("setup")
    end
  end

  describe "delegation fails actionably (negative)" do
    it "names the command and how to install when the client is missing" do
      output, status = run_cli(["doctor"], path: path_without_client)

      expect(status).to eq(Tina4::CLI::EXIT_CLIENT_UNAVAILABLE)
      expect(output).to include("doctor")
      expect(output).to include("tina4 client")
      expect(output).to include("install.sh")
      expect(output).not_to include("backtrace")
    end

    it "refuses to respawn when the loop guard is already set" do
      # Otherwise a `tina4` that resolves back to a framework CLI would fork-bomb.
      output, status = run_cli(["doctor"], path: path_with_real_client,
                                           extra_env: { "TINA4_CLI_DELEGATED" => "doctor" })

      expect(status).to eq(Tina4::CLI::EXIT_CLIENT_UNAVAILABLE)
      expect(output).to include("Refusing to delegate")
      expect(client_invoked?).to be(false), "it spawned the client anyway"
    end

    it "exits non-zero on a genuinely unknown command" do
      output, status = run_cli(["definitely-not-a-command"], path: path_without_client)

      expect(status).to eq(Tina4::CLI::EXIT_UNKNOWN_COMMAND)
      expect(output).to include("Unknown command: definitely-not-a-command")
    end

    it "never forwards an unknown command to the client" do
      # Delegation is allow-listed — that is how a forward loop is prevented.
      _output, status = run_cli(["not-a-real-command"], path: path_with_real_client)

      expect(status).to eq(Tina4::CLI::EXIT_UNKNOWN_COMMAND)
      expect(client_invoked?).to be(false), "forwarded an unknown command"
    end
  end

  describe "help tells the truth" do
    it "lists the delegated commands in their own section" do
      output, status = run_cli(["help"], path: path_without_client)

      expect(status).to eq(0)
      expect(output).to include("Delegated to the tina4 client")
      Tina4::CLI::DELEGATED.each_key do |name|
        expect(output).to include(name), "help omits #{name}"
      end
    end
  end
end
