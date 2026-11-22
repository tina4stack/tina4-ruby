# frozen_string_literal: true

# ADR-0108: a failing seed file fails loud. Real seed files on disk and the
# real exe/tina4ruby in a subprocess; no doubles.

require "spec_helper"
require "open3"
require "tmpdir"
require "rbconfig"
require "securerandom"

RSpec.describe "Tina4.seed_dir fails loud (ADR-0108)" do
  SEED_REPO_ROOT = File.expand_path("..", __dir__)
  SEED_EXE = File.join(SEED_REPO_ROOT, "exe", "tina4ruby")
  SEED_LIB = File.join(SEED_REPO_ROOT, "lib")

  around do |example|
    Dir.mktmpdir("tina4-seed-fail-loud") do |dir|
      @root = dir
      @seeds = File.join(dir, "seeds")
      FileUtils.mkdir_p(@seeds)
      @tracker = File.join(dir, "ran.txt")
      example.run
    end
  end

  def record(name)
    "File.open(#{@tracker.inspect}, \"a\") { |f| f.puts #{name.inspect} }\n"
  end

  def ran
    File.exist?(@tracker) ? File.read(@tracker).split : []
  end

  def three_files
    files = {
      ok_first: File.join(@seeds, "001_ok.rb"),
      raises: File.join(@seeds, "002_raises.rb"),
      ok_last: File.join(@seeds, "003_ok.rb")
    }
    File.write(files[:ok_first], record("001_ok"))
    File.write(files[:raises], "raise \"seed exploded\"\n")
    File.write(files[:ok_last], record("003_ok"))
    files
  end

  it "stops at a failing seed file and raises naming it" do
    files = three_files

    error = nil
    begin
      Tina4.seed_dir(seed_folder: @seeds)
    rescue Tina4::SeedError => e
      error = e
    end

    expect(error).not_to be_nil, "seed_dir must raise when a seed file raises"
    expect(error.seed_file).to eq(files[:raises])
    expect(error.completed).to eq([files[:ok_first]])
    expect(error.cause).to be_a(RuntimeError)
    expect(error.message).to include("002_raises.rb").and include("seed exploded")
    # 001 ran, 003 never did: the run stopped at the failing file.
    expect(ran).to eq(["001_ok"])
  end

  it "returns the executed files in order and skips underscore files" do
    second = File.join(@seeds, "002_second.rb")
    first = File.join(@seeds, "001_first.rb")
    File.write(second, record("002_second"))
    File.write(first, record("001_first"))
    File.write(File.join(@seeds, "_helper.rb"), "raise \"a helper must never run\"\n")
    # Not a .rb seed file: a runner that loads every file would run it.
    File.write(File.join(@seeds, "README.txt"), "raise \"a README must never run\"\n")

    expect(Tina4.seed_dir(seed_folder: @seeds)).to eq([first, second])
    expect(ran).to eq(%w[001_first 002_second])
  end

  it "returns an empty list for a missing folder" do
    expect(Tina4.seed_dir(seed_folder: File.join(@root, "missing"))).to eq([])
  end

  it "dev-admin's seed runner stops at the failing file and names it" do
    three_files
    payload = Dir.chdir(@root) { Tina4::DevAdmin.send(:run_seeds_payload) }

    expect(payload).to eq(seeded: 1, failed: 1, error: "002_raises.rb: seed exploded")
    expect(ran).to eq(["001_ok"])
  end

  def run_cli_seed
    env = ENV.to_h.select { |key, _| key.start_with?("TINA4_") }.transform_values { nil }.merge(
      "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
      "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "TINA4_OVERRIDE_CLIENT" => "true",
      "TINA4_AUTO_MIGRATE" => "false", "TINA4_SECRET" => SecureRandom.hex(32)
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{SEED_LIB}", SEED_EXE, "seed",
                                      chdir: @root, stdin_data: "")
    [status.exitstatus, out + err]
  end

  it "CLI seed exits 1 naming the failing file" do
    three_files

    code, output = run_cli_seed

    expect(code).to eq(1), output
    expect(output).to include("002_raises.rb")
    expect(ran).to eq(["001_ok"])
  end

  it "CLI seed exits 0 when every file runs" do
    File.write(File.join(@seeds, "001_ok.rb"), record("001_ok"))

    code, output = run_cli_seed

    expect(code).to eq(0), output
    expect(ran).to eq(["001_ok"])
  end
end
