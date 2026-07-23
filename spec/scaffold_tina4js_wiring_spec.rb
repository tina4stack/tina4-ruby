# frozen_string_literal: true
#
# Lock-in spec for D11 (feature-recount audit): the framework ships
# lib/tina4/public/js/tina4js.min.js (~27KB) and serves it 200, but nothing in
# lib/ referenced it — no scaffold, template or docstring. `grep -rn tina4js lib/`
# returned zero hits outside the asset itself, so a scaffolded Ruby app shipped
# the bytes and could never use tina4-js. frond.min.js and tina4.min.js ARE wired
# into the scaffolded base.twig; tina4js.min.js was not.
#
# The majority of the family wires it as a <script> tag alongside frond.min.js:
#   tina4-python/example/src/templates/base.twig:47-48
#   tina4-php/example/src/templates/base.twig:47-48
# and neither of those copies the file into the project — it is served from the
# framework's own bundled public dir (Ruby: RackApp::FRAMEWORK_PUBLIC_DIR). Ruby
# now matches that exactly.
#
# NO mocks. This runs the REAL `tina4ruby init` scaffolder into a REAL temp dir,
# then boots a REAL Tina4::WebServer over a REAL TCP socket rooted at that
# scaffolded project and fetches /js/tina4js.min.js for real.

require "spec_helper"
require "tina4/cli"
require "socket"
require "net/http"
require "tmpdir"
require "fileutils"

RSpec.describe "scaffolded app can actually use tina4-js (D11)" do
  let(:asset_path) { File.expand_path("../lib/tina4/public/js/tina4js.min.js", __dir__) }

  # Run the REAL scaffolder into a real temp dir and yield the dir.
  def scaffold
    Dir.mktmpdir("tina4_scaffold_tina4js") do |dir|
      project = File.join(dir, "demoapp")
      prev_pwd = Dir.pwd
      begin
        Dir.chdir(dir)
        # The real CLI entrypoint — not a re-implementation of it.
        silence_stdout { Tina4::CLI.new.run(["init", project]) }
      ensure
        Dir.chdir(prev_pwd)
      end
      yield project
    end
  end

  def silence_stdout
    prior = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = prior
  end

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  it "ships the asset in the framework's bundled public dir" do
    expect(File.file?(asset_path)).to be(true)
    expect(File.size(asset_path)).to be > 1_000
  end

  it "references tina4js.min.js from the scaffolded base.twig, next to frond.min.js" do
    scaffold do |project|
      base = File.read(File.join(project, "src", "templates", "base.twig"))

      # POSITIVE: the wiring exists.
      expect(base).to include('<script src="/js/tina4js.min.js"></script>')
      # ...and it sits with the other two script tags, matching Python/PHP order
      # (frond.min.js then tina4js.min.js).
      expect(base.index('/js/frond.min.js')).to be < base.index('/js/tina4js.min.js')
      expect(base).to include('<script src="/js/tina4.min.js"></script>')
    end
  end

  it "is referenced somewhere in lib/ (the D11 grep that returned zero hits)" do
    lib_dir = File.expand_path("../lib", __dir__)
    hits = Dir.glob(File.join(lib_dir, "**", "*.rb")).select do |f|
      File.read(f).include?("tina4js")
    end
    expect(hits).not_to be_empty, "no file under lib/ references tina4js: the asset is wired to nothing"
  end

  it "serves /js/tina4js.min.js 200 over a real socket from a scaffolded project" do
    scaffold do |project|
      app = Tina4::RackApp.new(root_dir: project)
      port = free_port
      server = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)

      prev_override = ENV["TINA4_OVERRIDE_CLIENT"]
      prev_no_ai = ENV["TINA4_NO_AI_PORT"]
      ENV["TINA4_OVERRIDE_CLIENT"] = "true"
      ENV["TINA4_NO_AI_PORT"] = "true"
      thread = Thread.new { server.start }
      thread.abort_on_exception = false

      begin
        deadline = Time.now + 10
        loop do
          begin
            TCPSocket.new("127.0.0.1", port).close
            break
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
            raise "server never came up on port #{port}" if Time.now > deadline
            sleep 0.05
          end
        end

        uri = URI("http://127.0.0.1:#{port}/js/tina4js.min.js")
        res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end

        expect(res.code.to_i).to eq(200)
        expect(res.body.bytesize).to eq(File.size(asset_path))
        expect(res["content-type"].to_s).to include("javascript")

        # NEGATIVE: a sibling asset that does NOT exist must still 404, so the
        # 200 above is a real file read and not a catch-all.
        missing = URI("http://127.0.0.1:#{port}/js/tina4js-not-real.min.js")
        res404 = Net::HTTP.start(missing.host, missing.port) { |h| h.request(Net::HTTP::Get.new(missing)) }
        expect(res404.code.to_i).to eq(404)
      ensure
        server.stop
        thread.kill
        if prev_override.nil? then ENV.delete("TINA4_OVERRIDE_CLIENT") else ENV["TINA4_OVERRIDE_CLIENT"] = prev_override end
        if prev_no_ai.nil? then ENV.delete("TINA4_NO_AI_PORT") else ENV["TINA4_NO_AI_PORT"] = prev_no_ai end
      end
    end
  end
end
