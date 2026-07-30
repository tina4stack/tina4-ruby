# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "json"
require "stringio"

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

  # ── mtime-tracked hot reload ───────────────────────────────────
  # The dev pain point: editing an EXISTING route file should serve the
  # fresh handler after POST /__dev/api/reload, not the stale one. Ruby's
  # `load` re-executes the file and #add replaces the (method, path) in
  # place, so the latest handler wins. Mirrors the Python master fix.
  #
  # A same-second rewrite would have the same mtime, so we bump it
  # explicitly with File.utime to make "changed" unambiguous.

  it "rescan_routes! serves the NEW handler when an existing route file changes" do
    path = write_route("hot", <<~RUBY)
      Tina4::Router.get("/hot") { |_req, _res| "VERSION_1" }
    RUBY

    Tina4::Router.load_routes(routes_dir)
    route, = Tina4::Router.find_route("GET", "/hot")
    expect(route.handler.call(nil, nil)).to eq("VERSION_1")

    # Rewrite the SAME file with a new handler and bump its mtime so the
    # change is detected even within the same wall-clock second.
    File.write(path, <<~RUBY)
      Tina4::Router.get("/hot") { |_req, _res| "VERSION_2" }
    RUBY
    future = Time.now + 2
    File.utime(future, future, path)

    Tina4::Router.rescan_routes!

    route, = Tina4::Router.find_route("GET", "/hot")
    expect(route.handler.call(nil, nil)).to eq("VERSION_2")

    # Replace, not append: exactly one route for GET /hot.
    matches = Tina4::Router.routes.select { |r| r.method == "GET" && r.path == "/hot" }
    expect(matches.length).to eq(1)
    # And the method_index bucket must not carry a stale duplicate either.
    bucket = Tina4::Router.method_index["GET"].select { |r| r.path == "/hot" }
    expect(bucket.length).to eq(1)
  end

  it "does NOT re-load an unchanged file on a second scan (mtime map unchanged)" do
    path = write_route("stable", <<~RUBY)
      Tina4::Router.get("/stable") { |_req, _res| "ok" }
    RUBY

    Tina4::Router.load_routes(routes_dir)
    loaded = Tina4::Router.instance_variable_get(:@loaded_route_files)
    mtime_after_first = loaded[path]
    expect(mtime_after_first).to eq(File.mtime(path).to_i)

    # Second pass with no file change — the recorded mtime stays put and
    # the route is not re-registered (still exactly one).
    Tina4::Router.rescan_routes!
    loaded = Tina4::Router.instance_variable_get(:@loaded_route_files)
    expect(loaded[path]).to eq(mtime_after_first)

    matches = Tina4::Router.routes.select { |r| r.method == "GET" && r.path == "/stable" }
    expect(matches.length).to eq(1)
  end

  it "hot-reloads a changed file end-to-end via POST /__dev/api/reload" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")

    path = write_route("endpoint", <<~RUBY)
      Tina4::Router.get("/endpoint") { |_req, _res| "FIRST" }
    RUBY

    # Boot-time discovery primes @last_routes_dir so rescan_routes! (called
    # by the reload handler) knows where to look.
    Tina4::Router.load_routes(routes_dir)
    route, = Tina4::Router.find_route("GET", "/endpoint")
    expect(route.handler.call(nil, nil)).to eq("FIRST")

    File.write(path, <<~RUBY)
      Tina4::Router.get("/endpoint") { |_req, _res| "SECOND" }
    RUBY
    future = Time.now + 2
    File.utime(future, future, path)

    # Drive the real dev reload endpoint the Rust CLI POSTs to on a change.
    env = {
      "PATH_INFO" => "/__dev/api/reload",
      "REQUEST_METHOD" => "POST",
      "rack.input" => StringIO.new({ "file" => "src/routes/endpoint.rb", "type" => "reload" }.to_json)
    }
    status, _headers, body = Tina4::DevAdmin.handle_request(env)
    expect(status).to eq(200)
    expect(JSON.parse(body.first)["ok"]).to be true

    route, = Tina4::Router.find_route("GET", "/endpoint")
    expect(route.handler.call(nil, nil)).to eq("SECOND")
    matches = Tina4::Router.routes.select { |r| r.method == "GET" && r.path == "/endpoint" }
    expect(matches.length).to eq(1)
  end

  # Parity with tina4-python's
  # test_every_new_route_file_is_seen_by_a_later_discover. Python had a real
  # intermittent bug here: importlib served a cached directory listing, so a
  # file created after a prior discover warmed that cache was invisible to the
  # importer and its route silently never registered (~50% of the time). Ruby
  # re-globs the directory and `load` re-executes, so it should hold -- this
  # proves it under repetition. A single add-then-reload would pass half the
  # time on a broken implementation, which is exactly how the Python bug hid.
  it "sees EVERY new route file when they are added one at a time" do
    new_files = 12

    write_route("seed", <<~RUBY)
      Tina4::Router.get("/seed") { |req, res| res.json({ ok: true }) }
    RUBY
    Tina4::Router.load_routes(routes_dir)
    expect(Tina4::Router.routes.map(&:path)).to include("/seed")

    new_files.times do |i|
      write_route("added#{i}", <<~RUBY)
        Tina4::Router.get("/added-#{i}") { |req, res| res.json({ n: #{i} }) }
      RUBY
      Tina4::Router.load_routes(routes_dir)

      paths = Tina4::Router.routes.map(&:path)
      expect(paths).to include("/added-#{i}"),
        "iteration #{i}: the new route file was written to disk but its route never registered (got #{paths.inspect})"
    end

    # Every route from every iteration survives the later reloads.
    paths = Tina4::Router.routes.map(&:path)
    new_files.times { |i| expect(paths).to include("/added-#{i}") }
  end
end
