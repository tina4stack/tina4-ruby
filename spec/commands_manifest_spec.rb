# frozen_string_literal: true
#
# Real tests for the self-describing `commands` CLI subcommand.
#
# No mocks. These exercise the ACTUAL CLI code path two ways:
#
#   * in-process — the real `commands` / `commands --json` handler (through
#     Tina4::CLI#run dispatch) and the `commands_manifest` builder, asserting
#     the manifest's shape and that it is DERIVED from the single-source
#     COMMANDS / GENERATORS registries (so it can never drift from dispatch);
#   * as a real subprocess running the `exe/tina4ruby` entrypoint in a clean
#     temp dir with NO database configured — proving `commands --json` is cheap
#     and side-effect-free (no bootstrap, no DB, no migrations, no files). This
#     is the contract the tina4 client relies on when it calls the command on
#     every `tina4 --help`, in any directory.

require "spec_helper"
require "tina4/cli"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require "rbconfig"

RSpec.describe "tina4ruby commands manifest" do
  REPO_ROOT = File.expand_path("..", __dir__)
  EXE = File.join(REPO_ROOT, "exe", "tina4ruby")

  let(:cli) { Tina4::CLI.new }

  # The command set the tina4 client must be able to discover truthfully.
  KNOWN_COMMANDS = %w[migrate seed test routes generate commands].freeze

  # Run the CLI in-process, capturing stdout and any SystemExit status (0 if it
  # did not exit). Same StringIO-swap pattern as spec/cli_spec.rb#run_cli.
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

  # Parse the JSON printed by the REAL `commands --json` dispatch path.
  def manifest_from_handler
    out, status = run_cli(["commands", "--json"])
    expect(status).to eq(0)
    JSON.parse(out)
  end

  describe "manifest content (in-process, real handler)" do
    it "prints exactly the manifest the builder returns" do
      # The --json handler serializes precisely what commands_manifest builds.
      expect(manifest_from_handler).to eq(cli.send(:commands_manifest))
    end

    it "reports framework == ruby" do
      expect(manifest_from_handler["framework"]).to eq("ruby")
    end

    it "reports a non-empty, version-looking version equal to Tina4::VERSION" do
      version = manifest_from_handler["version"]
      expect(version).to be_a(String)
      expect(version.strip).not_to be_empty
      expect(version).to match(/\A\d+\.\d+/)
      expect(version).to eq(Tina4::VERSION)
    end

    it "lists a non-empty set of commands, each with a name and summary" do
      commands = manifest_from_handler["commands"]
      expect(commands).to be_a(Array)
      expect(commands).not_to be_empty
      commands.each do |entry|
        expect(entry["name"].to_s).not_to be_empty, "entry missing name: #{entry.inspect}"
        expect(entry["summary"].to_s).not_to be_empty, "entry missing summary: #{entry.inspect}"
      end
    end

    it "includes every known command the tina4 client discovers" do
      names = manifest_from_handler["commands"].map { |c| c["name"] }
      missing = KNOWN_COMMANDS - names
      expect(missing).to be_empty, "manifest missing commands: #{missing.inspect}"
    end

    it "lists exactly the dispatchable commands (anti-drift lock-in)" do
      # The manifest is DERIVED from the dispatch registries, so it lists exactly
      # what #run can dispatch — the native COMMANDS plus the DELEGATED commands
      # handed to the tina4 client — in order, with no separate hand-kept list.
      names = manifest_from_handler["commands"].map { |c| c["name"] }
      expect(names).to eq(Tina4::CLI::COMMANDS.keys + Tina4::CLI::DELEGATED.keys)
    end

    it "flags only the delegated commands as delegated" do
      # The flag says WHO implements a command; a native one must never claim to
      # be delegated, and a delegated one must never look native.
      entries = manifest_from_handler["commands"].to_h { |c| [c["name"], c] }
      Tina4::CLI::DELEGATED.each_key do |name|
        expect(entries[name]["delegated"]).to be(true), "#{name} not flagged delegated"
      end
      Tina4::CLI::COMMANDS.each_key do |name|
        expect(entries[name]).not_to have_key("delegated"), "#{name} wrongly flagged delegated"
      end
    end

    it "gives generate subcommands including model and crud, derived from GENERATORS" do
      generate = manifest_from_handler["commands"].find { |c| c["name"] == "generate" }
      expect(generate).not_to be_nil
      subcommands = generate["subcommands"]
      expect(subcommands).to be_a(Array)
      expect(subcommands).not_to be_empty
      expect(subcommands).to include("model", "crud")
      # Derived from the GENERATORS registry — never a hand-kept fourth list.
      expect(subcommands).to eq(Tina4::CLI::GENERATORS.keys)
    end

    it "declares seed:create's positional arg in the manifest" do
      entry = manifest_from_handler["commands"].find { |c| c["name"] == "seed:create" }
      expect(entry["args"]).to eq(["name"])
    end

    it "exposes queue BOTH as a top-level command (with subcommands) and a generator" do
      # Phase 3 (self-describing CLI epic): `queue` is now a top-level command
      # that runs workers / manages jobs, mirroring the Python master. It is
      # ALSO still a generator (scaffolds a consumer file) — the two are
      # distinct, so both registries carry it.
      queue = manifest_from_handler["commands"].find { |c| c["name"] == "queue" }
      expect(queue).not_to be_nil, "manifest missing the top-level queue command"
      expect(queue["subcommands"]).to eq(%w[work stats retry clear])
      # Derived from the single-source QUEUE_SUBCOMMANDS registry — never a
      # hand-kept list.
      expect(queue["subcommands"]).to eq(Tina4::CLI::QUEUE_SUBCOMMANDS.keys)
      expect(Tina4::CLI::GENERATORS.keys).to include("queue")
    end

    it "declares migrate:create's positional arg and lists build in the manifest" do
      create = manifest_from_handler["commands"].find { |c| c["name"] == "migrate:create" }
      expect(create).not_to be_nil
      expect(create["args"]).to eq(["description"])
      expect(manifest_from_handler["commands"].map { |c| c["name"] }).to include("build")
    end
  end

  describe "human output (default, non-JSON)" do
    it "lists every command name" do
      out, status = run_cli(["commands"])
      expect(status).to eq(0)
      Tina4::CLI::COMMANDS.each_key do |name|
        expect(out).to include(name), "human output omits #{name.inspect}"
      end
    end
  end

  describe "app/DB-free (real subprocess, clean temp dir, no DB)" do
    # Run the REAL exe/tina4ruby entrypoint the way the tina4 client drives it:
    # a fresh ruby process, in an empty project dir, with NO database configured.
    # Requiring the CLI must not bootstrap / migrate / open a DB. Returns
    # [exit_status, combined_output].
    def run_exe(dir)
      # Unset every DB/bootstrap trigger so a bootstrap attempt could not even
      # find a DB to open. nil value in the env hash UNSETS the key for the child.
      env = { "TINA4_DATABASE_URL" => nil, "TINA4_DATABASE_USERNAME" => nil,
              "TINA4_DATABASE_PASSWORD" => nil, "TINA4_DEBUG" => nil,
              "TINA4_AUTO_MIGRATE" => nil }
      cmd = [RbConfig.ruby, EXE, "commands", "--json"]
      out = nil
      status = nil
      block = lambda do
        out = IO.popen(env, cmd, chdir: dir, err: [:child, :out], &:read)
        status = $?.exitstatus
      end
      if defined?(Bundler)
        Bundler.with_unbundled_env(&block)
      else
        block.call
      end
      [status, out]
    end

    it "exits 0 with valid JSON, opens no DB, and creates no files" do
      Dir.mktmpdir("tina4_commands_manifest") do |dir|
        # A genuinely empty project: no migrations/, no app.rb, no DB.
        expect(Dir.exist?(File.join(dir, "migrations"))).to be false
        expect(File.exist?(File.join(dir, "app.rb"))).to be false

        status, out = run_exe(dir)

        expect(status).to eq(0), "non-zero exit; output:\n#{out}"

        manifest = JSON.parse(out) # raises if the output is not valid JSON
        expect(manifest["framework"]).to eq("ruby")
        expect(manifest["version"].to_s.strip).not_to be_empty
        names = manifest["commands"].map { |c| c["name"] }
        expect(names).to include("commands", "generate")

        # Nothing under the project dir: no SQLite file (nothing opened a DB) and
        # no scaffolding — `commands` is pure output, zero side effects.
        created = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH)
                     .reject { |p| %w[. ..].include?(File.basename(p)) }
        expect(created).to eq([]), "commands created files: #{created.inspect}"
      end
    end
  end
end
