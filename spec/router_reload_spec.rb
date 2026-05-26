# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# Covers the developer pain point where a fresh `tina4 init` + a file
# added to src/routes/ did not load until a server restart.
RSpec.describe "Tina4::Router reload-aware discovery" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_router_reload_") }
  let(:routes_dir) { File.join(tmp_dir, "src", "routes") }

  before do
    @original_cwd = Dir.pwd # Capture BEFORE chdir so after-block restores correctly.
    FileUtils.mkdir_p(routes_dir)
    Dir.chdir(tmp_dir)
    Tina4::Router.clear!
    Tina4::Router.reset_route_discovery!
  end

  after do
    Tina4::Router.clear!
    Tina4::Router.reset_route_discovery!
    Dir.chdir(@original_cwd) if @original_cwd && Dir.exist?(@original_cwd)
    FileUtils.remove_entry(tmp_dir) if Dir.exist?(tmp_dir)
  end

  def write_route(name, body)
    path = File.join(routes_dir, "#{name}.rb")
    File.write(path, body)
    path
  end

  it "load_routes is idempotent — re-running it does not double-register" do
    write_route("hello", <<~RUBY)
      Tina4::Router.get("/idem-hello") { |req, res| res.json({ ok: true }) }
    RUBY

    Tina4::Router.load_routes(routes_dir)
    first_count = Tina4::Router.routes.length

    Tina4::Router.load_routes(routes_dir)
    second_count = Tina4::Router.routes.length

    expect(second_count).to eq(first_count)
    matches = Tina4::Router.routes.select { |r| r.path == "/idem-hello" }
    expect(matches.length).to eq(1)
  end

  it "rescan_routes! picks up files added after the initial scan" do
    write_route("first", <<~RUBY)
      Tina4::Router.get("/first") { |req, res| res.json({ ok: true }) }
    RUBY

    Tina4::Router.load_routes(routes_dir)
    before_count = Tina4::Router.routes.length
    expect(Tina4::Router.routes.map(&:path)).to include("/first")

    # Simulate the user dropping a new file after the server is running.
    write_route("second", <<~RUBY)
      Tina4::Router.get("/second") { |req, res| res.json({ ok: true }) }
    RUBY

    added = Tina4::Router.rescan_routes!
    expect(added).to eq(1)
    expect(Tina4::Router.routes.length).to eq(before_count + 1)
    expect(Tina4::Router.routes.map(&:path)).to include("/second")
  end

  it "rescan_routes! is a no-op when load_routes has never been called" do
    expect(Tina4::Router.rescan_routes!).to eq([])
  end

  it "writes a .broken sentinel when a route file blows up at load time" do
    write_route("broken", <<~RUBY)
      # Deliberate syntax error — invalid Ruby
      Tina4::Router.get("/will-not-load") { |req, res
    RUBY

    Tina4::Router.load_routes(routes_dir)

    broken_dir = File.join(tmp_dir, "data", ".broken")
    expect(Dir.exist?(broken_dir)).to be true
    sentinels = Dir.glob(File.join(broken_dir, "discover_*.broken"))
    expect(sentinels).not_to be_empty

    payload = File.read(sentinels.first)
    expect(payload).to include("auto_discover_failure")
    expect(payload).to include("broken.rb")
  end
end
