# frozen_string_literal: true
#
# Issue #136 parity (tina4-python #136): with TINA4_SESSION_BACKEND=mongodb,
# every request builds a Session, every Session builds a NEW MongoHandler, and
# the handler opened a NEW Mongo::Client on first use - its own SDAM monitor
# threads and connection pool - that nothing ever closed. Threads and MongoDB
# connections grew with every request until the process or the server ran out.
#
# Expected: ONE shared transport per process for a given (uri, database), reused
# by every request. Both transports are covered:
#
#   * the `mongo` gem path, driven by REAL HTTP requests against a REAL
#     Tina4::WebServer, measuring the threads left behind (each Mongo::Client
#     starts its own SDAM monitor threads);
#   * the zero-dependency wire path (MongoWireClient), in a REAL subprocess that
#     cannot load any gem, measuring the TCP sockets it holds open to MongoDB.
#
# NO MOCKS: a real MongoDB, real sockets, real sessions. Everything is written
# to the dedicated database tina4_issue136_rb, dropped afterwards.

require "spec_helper"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"

RSpec.describe "Issue #136: the MongoDB session backend shares one client per process" do
  let(:issue136_host) { ENV["TINA4_TEST_MONGO_HOST"] || "127.0.0.1" }
  let(:issue136_port) { (ENV["TINA4_TEST_MONGO_PORT"] || 27_017).to_i }
  let(:issue136_uri) { "mongodb://#{issue136_host}:#{issue136_port}" }
  let(:issue136_db) { "tina4_issue136_rb" }
  let(:issue136_collection) { "sessions_#{SecureRandom.hex(6)}" }
  let(:issue136_requests) { 20 }

  def issue136_reachable?
    Socket.tcp(issue136_host, issue136_port, connect_timeout: 2).close
    true
  rescue StandardError
    false
  end

  def issue136_mongo_gem?
    require "mongo"
    defined?(::Mongo::VERSION) ? true : false
  rescue LoadError
    false
  end

  def issue136_free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def issue136_boot(app, port)
    server = Tina4::WebServer.new(app, host: "127.0.0.1", port: port)
    thread = Thread.new { server.start }
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise "server never came up on port #{port}" if Time.now > deadline

      sleep 0.05
      retry
    end
    [server, thread]
  end

  around(:each) do |example|
    keys = %w[TINA4_SESSION_BACKEND TINA4_SESSION_MONGO_URI TINA4_SESSION_MONGO_DB
              TINA4_SESSION_MONGO_COLLECTION TINA4_OVERRIDE_CLIENT TINA4_NO_AI_PORT]
    saved = keys.to_h { |key| [key, ENV[key]] }
    begin
      example.run
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end

  after(:each) do
    Tina4::SessionHandlers::MongoHandler.close_shared_clients if
      Tina4::SessionHandlers::MongoHandler.respond_to?(:close_shared_clients)
    next unless issue136_reachable? && issue136_mongo_gem?

    client = Mongo::Client.new(issue136_uri, database: issue136_db, server_selection_timeout: 5)
    begin
      client.database.drop
    ensure
      client.close
    end
  end

  it "reuses ONE Mongo::Client across many real HTTP requests (gem path)" do
    skip "mongo not reachable at #{issue136_host}:#{issue136_port}" unless issue136_reachable?
    skip "mongo gem not installed - mongo gem path cannot be measured" unless issue136_mongo_gem?

    ENV["TINA4_SESSION_BACKEND"] = "mongodb"
    ENV["TINA4_SESSION_MONGO_URI"] = issue136_uri
    ENV["TINA4_SESSION_MONGO_DB"] = issue136_db
    ENV["TINA4_SESSION_MONGO_COLLECTION"] = issue136_collection
    ENV["TINA4_OVERRIDE_CLIENT"] = "true"
    ENV["TINA4_NO_AI_PORT"] = "true"

    Tina4::Router.get("/issue136/visit") do |request, response|
      visits = request.session.get("visits").to_i + 1
      request.session.set("visits", visits)
      response.json({ "visits" => visits })
    end

    port = issue136_free_port
    server, thread = issue136_boot(Tina4::RackApp.new(root_dir: Dir.pwd), port)
    begin
      threads_before = Thread.list.count

      # Every request arrives WITHOUT a cookie, so every one builds a brand new
      # Session and therefore a brand new MongoHandler - the per-request path
      # the issue is about. Each must still persist its session.
      cookies = Array.new(issue136_requests) do
        res = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/issue136/visit"))
        expect(res.code).to eq("200")
        res["set-cookie"].to_s.split(";").first
      end
      expect(cookies.compact.uniq.length).to eq(issue136_requests)

      # A follow-up with a cookie reads the stored session back through the
      # SAME shared client, so sharing did not break persistence.
      res = Net::HTTP.start("127.0.0.1", port) do |http|
        http.get("/issue136/visit", { "Cookie" => cookies.first })
      end
      expect(JSON.parse(res.body)).to eq({ "visits" => 2 })

      leaked_threads = Thread.list.count - threads_before
      expect(leaked_threads).to be < 10,
                                "#{issue136_requests + 1} requests left #{leaked_threads} extra threads " \
                                "(SDAM monitors of per-request clients)"
    ensure
      server.stop
      thread.join(5)
    end
  end

  it "reuses ONE socket across many sessions on the zero-dependency wire path" do
    skip "mongo not reachable at #{issue136_host}:#{issue136_port}" unless issue136_reachable?

    source = <<~RUBY
      require "json"
      require "socket"
      gem_gone = begin
        require "mongo"
        false
      rescue LoadError
        true
      end
      require "tina4"

      # GC is OFF for the whole run: a per-session socket is closed only when its
      # Ruby object happens to be collected, so with GC running the count would
      # measure the collector, not the transport. Off, it counts every socket
      # the sessions opened and never closed.
      GC.disable

      def open_mongo_sockets(port)
        ObjectSpace.each_object(BasicSocket).count do |socket|
          !socket.closed? && socket.remote_address.ip_port == port
        rescue StandardError
          false
        end
      end

      port = #{issue136_port}
      transports = []
      #{issue136_requests}.times do |i|
        session = Tina4::Session.new({})
        session.set("n", i)
        session.save
        handler = session.instance_variable_get(:@handler)
        transports << handler.send(:collection).class.name
        # the next request reads it back through a NEW Session / handler
        cookie = { "HTTP_COOKIE" => "tina4_session=\#{session.get_session_id}" }
        raise "session \#{i} did not persist" unless Tina4::Session.new(cookie).get("n") == i
      end

      puts "TINA4_REPORT " + JSON.generate(
        "gem_gone" => gem_gone,
        "transports" => transports.uniq,
        "open_sockets" => open_mongo_sockets(port)
      )
    RUBY

    Dir.mktmpdir("tina4-issue136") do |sandbox|
      gem_home = File.join(sandbox, "gems")
      Dir.mkdir(gem_home)
      script = File.join(sandbox, "case.rb")
      File.write(script, source)
      environment = {
        "GEM_HOME" => gem_home, "GEM_PATH" => gem_home,
        "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil,
        "BUNDLE_PATH" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil,
        "TINA4_SESSION_STRICT" => "true", "TINA4_DEBUG" => "false", "TINA4_LOG_LEVEL" => "NONE",
        "TINA4_SESSION_BACKEND" => "mongodb", "TINA4_SESSION_MONGO_URI" => issue136_uri,
        "TINA4_SESSION_MONGO_DB" => issue136_db, "TINA4_SESSION_MONGO_COLLECTION" => issue136_collection
      }
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby,
                                              "-I#{File.expand_path('../lib', __dir__)}", script)
      line = stdout.lines.find { |candidate| candidate.start_with?("TINA4_REPORT ") }
      raise "subprocess reported nothing (#{status.exitstatus}):\n#{stdout}\n#{stderr}" unless line

      report = JSON.parse(line.sub("TINA4_REPORT ", ""))
      expect(report["gem_gone"]).to be(true)
      expect(report["transports"]).to eq(["Tina4::SessionHandlers::MongoWireClient"])
      expect(report["open_sockets"]).to eq(1),
                                        "#{issue136_requests * 2} sessions left #{report['open_sockets']} sockets " \
                                        "open to MongoDB - one per session instead of one per process"
    end
  end
end
