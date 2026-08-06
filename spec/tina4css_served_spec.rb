# tina4css_contract.json :: tina4css-is-served-at-one-url-in-all-four
#
# tina4css is ONE artefact shipped by four packages. Every framework serves it
# at /css/tina4.css from its own built-in public directory, and the bytes are
# identical in all four.
#
# MEASURED 2026-08-06 on real servers over real sockets - including a PHP
# project built by `composer require` whose own src/public/css was empty - all
# four answered 200 with 35962 bytes for tina4.css and 28472 for
# tina4.min.css.
#
# That parity was true by luck. Nothing asserted it, so a packaging change in
# one framework would have gone unnoticed in the other three.
#
# The companion half - that the committed CSS is a current compile of its .scss
# source, and that the four sources have not drifted apart - is checked by
# tina4-documentation/scripts/build-tina4css.py --check. It caught a real one:
# the shipped tina4.min.css was 15 bytes adrift from the current toolchain
# because its producer, the per-framework SCSS compiler, had been deleted.
#
# No mocks: a real child server over a real loopback socket.

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"

RSpec.describe "tina4css served", :slow do
  repo_root = File.expand_path("..", __dir__)
  shipped_dir = File.join(repo_root, "lib", "tina4", "public", "css")

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def boot(root, port)
    FileUtils.mkdir_p(File.join(root, "src", "routes"))
    File.write(File.join(root, "Gemfile"), <<~RB)
      source "https://rubygems.org"
      gem "tina4ruby", path: "#{File.expand_path("..", __dir__)}"
    RB
    File.write(File.join(root, "app.rb"), <<~RB)
      require "tina4ruby"
      Tina4.run!(__dir__)
    RB
    log = File.join(root, "server.log")
    pid = Process.spawn(
      { "TINA4_OVERRIDE_CLIENT" => "true", "TINA4_NO_BROWSER" => "true",
        "TINA4_DEBUG" => "false", "TINA4_PORT" => port.to_s },
      "bundle", "exec", "ruby", "app.rb",
      chdir: root, out: log, err: log, pgroup: true
    )
    deadline = Time.now + 90
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return pid
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        raise "child server died:\n#{File.read(log)}" if Process.waitpid(pid, Process::WNOHANG)
        sleep 0.3
      end
    end
    raise "child server never bound the port:\n#{File.read(log)}"
  end

  def get(port, path)
    Net::HTTP.start("127.0.0.1", port, open_timeout: 10, read_timeout: 20) do |http|
      http.get(path)
    end
  end

  before(:all) do
    @root = Dir.mktmpdir("tina4-css-")
    Dir.chdir(@root) { system("bundle install --quiet", out: File::NULL, err: File::NULL) }
    @port = free_port
    @pid = boot(@root, @port)
  end

  after(:all) do
    # Signal the GROUP: bundle execs ruby, so killing only the wrapper orphans
    # the server holding the port.
    begin
      Process.kill("-TERM", @pid) if @pid
      Process.waitpid(@pid)
    rescue StandardError
      nil
    end
    FileUtils.rm_rf(@root) if @root
  end

  it "tina4css is served at the canonical url" do
    res = get(@port, "/css/tina4.css")
    expect(res.code).to eq("200")
    expect(res["content-type"].to_s).to include("text/css")
    # A real stylesheet, not an error page that happened to return 200.
    expect(res.body).to include(".container")
  end

  it "the minified build is served at the canonical url" do
    res = get(@port, "/css/tina4.min.css")
    expect(res.code).to eq("200")
    expect(res["content-type"].to_s).to include("text/css")
    full = get(@port, "/css/tina4.css").body
    expect(res.body.bytesize).to be < full.bytesize,
      "the minified build (#{res.body.bytesize}B) is not smaller than the full one " \
      "(#{full.bytesize}B) - it is probably a copy"
  end

  it "the served bytes are the shipped file byte for byte" do
    served = get(@port, "/css/tina4.css").body
    on_disk = File.binread(File.join(shipped_dir, "tina4.css"))
    # Byte equality, not a size check: a truncated or half-written asset still
    # has a plausible length.
    expect(served.b).to eq(on_disk),
      "served #{served.bytesize} bytes but the shipped file holds #{on_disk.bytesize}"
  end
end
