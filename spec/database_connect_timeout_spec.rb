# frozen_string_literal: true
#
# Regression lock: a database connect must be BOUNDED.
#
# The defect: a connect that can block forever hangs the whole application with
# no log, no error and no signal. MEASURED on Ruby 3.2.3 / Ubuntu 24.04.4
# against a real TCPServer that accepts the TCP connection and then never
# replies - pg, mysql2, tiny_tds and fb ALL sat past 20 seconds and needed
# SIGKILL, because `timeout`'s SIGTERM could not even be delivered while a C
# client held the GVL.
#
# Everything below uses a REAL server socket. A closed port is deliberately NOT
# used as the blocking case: it refuses in ~0.00s and tests nothing.
#
# NOTE ON CONSTANTS: there are none in here on purpose. A bare constant declared
# inside an RSpec.describe block lands on Object, leaks into every other spec
# file and clobbers same-named constants, producing failures that only appear at
# some seeds. Everything is a method.

require "spec_helper"
require "socket"
require_relative "support/live_postgres"

RSpec.describe "TINA4_DATABASE_CONNECT_TIMEOUT bounds every network connect" do
  # ── real fixtures, no doubles ───────────────────────────────────────────────

  # A REAL listening server that completes the TCP handshake and then never
  # writes a byte. This is the failure mode being fixed.
  def with_silent_server
    server = TCPServer.new("127.0.0.1", 0)
    accepted = []
    acceptor = Thread.new do
      loop { accepted << server.accept }
    rescue StandardError
      nil
    end
    yield("127.0.0.1", server.addr[1])
  ensure
    acceptor&.kill
    accepted.each { |socket| socket.close rescue nil }
    server&.close
  end

  # RFC 5737 TEST-NET-1: reserved for documentation and never routed, so the SYN
  # is silently dropped and connect() blocks. A real blackhole, not a stand-in.
  def blackhole_host
    "192.0.2.1"
  end

  # Confirm this environment really does blackhole that address. Returns nil
  # when it does, or the REASON it does not - which goes into the skip message,
  # so a skip explains itself instead of leaving the next person to re-derive it.
  #
  # Classified by ELAPSED TIME, not by error class. A blackhole swallows the SYN
  # so the probe burns its whole budget; a refusal or an unreachable route comes
  # back immediately. The first version rescued Errno::ETIMEDOUT alone and
  # treated every other error as "no blackhole here", which silently skipped
  # this example at seed 9999 for a reason it did not record - a guard that
  # quietly turns a real test off is exactly the ghost this suite exists to
  # prevent. The probe is stable in isolation (30/30 Errno::ETIMEDOUT, all
  # >= 0.9s, measured on the lab), so anything fast is a genuine environment
  # difference worth naming rather than swallowing.
  def blackhole_unavailable_reason
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      Socket.tcp(blackhole_host, 3050, connect_timeout: 1, &:close)
      "#{blackhole_host} ANSWERED - it is not a blackhole on this network"
    rescue StandardError => error
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      return nil if elapsed >= 0.9

      "#{blackhole_host} failed fast (#{error.class} after " \
        "#{format("%.2f", elapsed)}s) - not a blackhole, so the bound cannot be observed"
    end
  end

  def with_connect_timeout(raw)
    previous = ENV.key?("TINA4_DATABASE_CONNECT_TIMEOUT") ? ENV["TINA4_DATABASE_CONNECT_TIMEOUT"] : :unset
    if raw.nil?
      ENV.delete("TINA4_DATABASE_CONNECT_TIMEOUT")
    else
      ENV["TINA4_DATABASE_CONNECT_TIMEOUT"] = raw
    end
    yield
  ensure
    if previous == :unset
      ENV.delete("TINA4_DATABASE_CONNECT_TIMEOUT")
    else
      ENV["TINA4_DATABASE_CONNECT_TIMEOUT"] = previous
    end
  end

  def seconds_spent
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  end

  # Make Tina4::Log's CONSOLE sink deterministic for the duration of a block.
  #
  # Tina4::Log memoises its output destination and console level in class ivars
  # at configure time, and an earlier spec in a full-suite run can leave the
  # destination set to "file" - MEASURED at seed 1111, where the warning example
  # failed with out="file" and an empty capture while passing in isolation,
  # because Log#log gates the console branch on `@output != "file"` and the
  # warning went to the log FILE instead of $stdout. Nothing is memoised about
  # the WARNING itself: Env.float warns on every single parse failure.
  #
  # Log must be initialized BEFORE the ivars are forced, or the first Log.log
  # call would run `configure unless @initialized` and overwrite them. The exact
  # previous values go back afterwards, so this neither depends on nor changes
  # global logger state - restoring by re-configuring would swap one leak for
  # another.
  def with_console_logging
    Tina4::Log.configure unless Tina4::Log.instance_variable_get(:@initialized)
    previous_output = Tina4::Log.instance_variable_get(:@output)
    previous_level = Tina4::Log.instance_variable_get(:@console_level)
    Tina4::Log.instance_variable_set(:@output, "stdout")
    Tina4::Log.instance_variable_set(:@console_level, 0)
    yield
  ensure
    Tina4::Log.instance_variable_set(:@output, previous_output)
    Tina4::Log.instance_variable_set(:@console_level, previous_level)
  end

  # Prove a connect is REALLY unbounded without hanging the suite: run it in a
  # forked child and ask whether the child is still blocked afterwards. The
  # child is SIGKILLed and reaped either way - when this was measured, a wedged
  # C call could not be stopped any other way (SIGTERM was never delivered).
  def still_blocked_after?(seconds)
    child = fork do
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end
      exit!(0)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    reaped = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      reaped = Process.waitpid(child, Process::WNOHANG)
      break if reaped

      sleep 0.05
    end
    if reaped
      false
    else
      Process.kill("KILL", child) rescue nil
      Process.waitpid(child) rescue nil
      true
    end
  end

  def expect_contract_error(host, port)
    error = nil
    begin
      yield
    rescue Tina4::DatabaseConnectionError => e
      error = e
    end
    expect(error).not_to be_nil, "expected a Tina4::DatabaseConnectionError, got none"
    # The contract: the message names the host, the port, the elapsed seconds
    # and the variable that tunes it.
    expect(error.message).to include(host.to_s)
    expect(error.message).to include(port.to_s)
    expect(error.message).to match(/timed out after \d+\.\d+s/)
    expect(error.message).to include("TINA4_DATABASE_CONNECT_TIMEOUT")
    error
  end

  # ── the shared contract, identical in all four frameworks ───────────────────

  describe "the shared contract" do
    it "defaults to 10 seconds when the variable is unset" do
      with_connect_timeout(nil) do
        expect(Tina4::DatabaseAdapter.connect_timeout_seconds).to eq(10)
      end
    end

    it "uses the operator's value when one is set" do
      with_connect_timeout("3") do
        expect(Tina4::DatabaseAdapter.connect_timeout_seconds).to eq(3)
      end
      with_connect_timeout("2.5") do
        expect(Tina4::DatabaseAdapter.connect_timeout_seconds).to eq(2.5)
      end
    end

    it "treats zero and negatives as DISABLED - unbounded, the old behaviour" do
      ["0", "0.0", "-1", "-30"].each do |raw|
        with_connect_timeout(raw) do
          expect(Tina4::DatabaseAdapter.connect_timeout_seconds)
            .to be_nil, "#{raw.inspect} should disable the bound"
          expect(Tina4::DatabaseAdapter.connect_timeout_whole_seconds).to be_nil
        end
      end
    end

    it "warns and falls back to 10 seconds on a value that is not a number" do
      ["abc", "ten", "10s", "", "  "].each do |raw|
        captured = StringIO.new
        original_stdout = $stdout
        begin
          with_console_logging do
            $stdout = captured
            with_connect_timeout(raw) do
              expect(Tina4::DatabaseAdapter.connect_timeout_seconds)
                .to eq(10), "#{raw.inspect} should fall back to the default"
            end
          end
        ensure
          $stdout = original_stdout
        end
        expect(captured.string).to include("TINA4_DATABASE_CONNECT_TIMEOUT"),
                                   "#{raw.inspect} should have warned"
      end
    end

    it "warns EVERY time, not once per process - an operator greps the log after the incident" do
      # Deliberate, not emergent: Env.float has no warn memo, and neither does
      # Python's, PHP's or Node's. If a memo is ever added, this reddens.
      captured = StringIO.new
      original_stdout = $stdout
      begin
        with_console_logging do
          $stdout = captured
          3.times do
            with_connect_timeout("not-a-number") { Tina4::DatabaseAdapter.connect_timeout_seconds }
          end
        end
      ensure
        $stdout = original_stdout
      end
      expect(captured.string.scan("TINA4_DATABASE_CONNECT_TIMEOUT").length).to eq(3)
    end

    it "never rounds a sub-second bound DOWN to zero for the whole-second options" do
      # libpq reads connect_timeout=0 as WAIT FOREVER, so rounding 0.4 down to 0
      # would silently disable the very bound being set.
      with_connect_timeout("0.4") do
        expect(Tina4::DatabaseAdapter.connect_timeout_whole_seconds).to eq(1)
      end
      with_connect_timeout("2.1") do
        expect(Tina4::DatabaseAdapter.connect_timeout_whole_seconds).to eq(3)
      end
    end
  end

  # ── PostgreSQL: libpq's own connect_timeout ─────────────────────────────────

  describe "PostgreSQL (libpq connect_timeout)" do
    before do
      require "pg"
    rescue LoadError
      skip "pg gem not installed"
    end

    it "gives up on a server that accepts and never replies, naming host, port, elapsed and the variable" do
      with_silent_server do |host, port|
        with_connect_timeout("2") do
          driver = Tina4::Drivers::PostgresDriver.new
          elapsed = seconds_spent do
            expect_contract_error(host, port) do
              driver.connect("postgres://tina4:tina4@#{host}:#{port}/probe")
            end
          end
          # Unbounded this same connect sat past 20s and needed SIGKILL.
          expect(elapsed).to be < 10
        end
      end
    end

    it "keeps the driver's own error as the CAUSE, not merely as text" do
      # The contract's message is the framework's, but the driver's diagnosis is
      # often the more specific one and must not be thrown away. It survives
      # twice over: appended to the message, and as the exception's cause chain.
      with_silent_server do |host, port|
        with_connect_timeout("2") do
          error = expect_contract_error(host, port) do
            Tina4::Drivers::PostgresDriver.new.connect("postgres://tina4:tina4@#{host}:#{port}/probe")
          end
          expect(error.cause).to be_a(PG::Error)
          expect(error.message).to include(error.cause.message.split("\n").first.strip)
        end
      end
    end

    it "does NOT fire on a healthy connect to the live PostgreSQL" do
      skip "PostgreSQL not reachable at #{LivePostgres.host}:#{LivePostgres.port}" unless LivePostgres.reachable?

      with_connect_timeout("10") do
        driver = Tina4::Drivers::PostgresDriver.new
        expect { driver.connect(LivePostgres.url) }.not_to raise_error
        # ...and it is a genuinely usable connection, not just a non-raising call.
        expect(driver.execute_query("SELECT 1 AS one").first[:one]).to eq(1)
        driver.close
      end
    end

    it "leaves an operator's own connect_timeout in the URL alone" do
      skip "PostgreSQL not reachable at #{LivePostgres.host}:#{LivePostgres.port}" unless LivePostgres.reachable?

      with_connect_timeout("10") do
        driver = Tina4::Drivers::PostgresDriver.new
        expect { driver.connect("#{LivePostgres.url}?connect_timeout=7") }.not_to raise_error
        driver.close
      end
    end

    it "restores the OLD UNBOUNDED behaviour when the variable is 0" do
      # The deadline MUST sit past the 10s DEFAULT bound. With a 5s deadline
      # this example cannot fail: a regression where 0 silently fell back to the
      # default would still be blocked at 5s and the example would pass green,
      # proving nothing. 13s outlives the default, so only a genuinely unbounded
      # connect is still running when we look.
      expect(Tina4::DatabaseAdapter::DEFAULT_CONNECT_TIMEOUT_SECONDS).to be < 13
      with_silent_server do |host, port|
        blocked = with_connect_timeout("0") do
          still_blocked_after?(13) do
            Tina4::Drivers::PostgresDriver.new
                                          .connect("postgres://tina4:tina4@#{host}:#{port}/probe")
          end
        end
        expect(blocked).to be(true), "0 must disable the bound, not shorten it to the default"
      end
    end
  end

  # ── MySQL: mysql2's own connect_timeout ─────────────────────────────────────

  describe "MySQL (mysql2 connect_timeout)" do
    before do
      require "mysql2"
    rescue LoadError
      skip "mysql2 gem not installed"
    end

    it "gives up on a server that accepts and never replies, naming host, port, elapsed and the variable" do
      with_silent_server do |host, port|
        with_connect_timeout("2") do
          driver = Tina4::Drivers::MysqlDriver.new
          elapsed = seconds_spent do
            expect_contract_error(host, port) do
              driver.connect("mysql://tina4:tina4@#{host}:#{port}/probe")
            end
          end
          expect(elapsed).to be < 10
        end
      end
    end

    it "does NOT fire on a healthy connect to the live MySQL" do
      host = ENV.fetch("TINA4_TEST_MYSQL_HOST", "localhost")
      port = ENV.fetch("TINA4_TEST_MYSQL_PORT", "3306").to_i
      reachable = begin
        Socket.tcp(host, port, connect_timeout: 2, &:close)
        true
      rescue StandardError
        false
      end
      skip "MySQL not reachable at #{host}:#{port}" unless reachable

      user = ENV.fetch("TINA4_TEST_MYSQL_USERNAME", "tina4")
      pass = ENV.fetch("TINA4_TEST_MYSQL_PASSWORD", "tina4")
      name = ENV.fetch("TINA4_TEST_MYSQL_DB", "tina4_test")
      with_connect_timeout("10") do
        driver = Tina4::Drivers::MysqlDriver.new
        expect { driver.connect("mysql://#{user}:#{pass}@#{host}:#{port}/#{name}") }.not_to raise_error
        driver.close
      end
    end
  end

  # ── MSSQL: FreeTDS login_timeout ────────────────────────────────────────────

  describe "MSSQL (FreeTDS login_timeout)" do
    before do
      require "tiny_tds"
    rescue LoadError
      skip "tiny_tds gem not installed"
    end

    it "gives up on a server that accepts and never replies, naming host, port, elapsed and the variable" do
      with_silent_server do |host, port|
        with_connect_timeout("2") do
          driver = Tina4::Drivers::MssqlDriver.new
          elapsed = seconds_spent do
            expect_contract_error(host, port) do
              driver.connect("mssql://sa:probe@#{host}:#{port}/probe")
            end
          end
          expect(elapsed).to be < 10
        end
      end
    end

    it "does NOT fire on a healthy connect to the live MSSQL" do
      host = ENV.fetch("TINA4_TEST_MSSQL_HOST", "localhost")
      port = ENV.fetch("TINA4_TEST_MSSQL_PORT", "1433").to_i
      reachable = begin
        Socket.tcp(host, port, connect_timeout: 2, &:close)
        true
      rescue StandardError
        false
      end
      skip "MSSQL not reachable at #{host}:#{port}" unless reachable

      user = ENV.fetch("TINA4_TEST_MSSQL_USERNAME", "sa")
      pass = ENV.fetch("TINA4_TEST_MSSQL_PASSWORD", "TinaSQL123!Secure")
      name = ENV.fetch("TINA4_TEST_MSSQL_DB", "tina4_test")
      with_connect_timeout("10") do
        driver = Tina4::Drivers::MssqlDriver.new
        expect { driver.connect("mssql://#{user}:#{pass}@#{host}:#{port}/#{name}") }.not_to raise_error
        driver.close
      end
    end
  end

  # ── Firebird: a stdlib reachability bound, because nothing else can ─────────
  #
  # These run WITHOUT the fb gem: bound_reachability! is the boundable part and
  # it only needs a socket. The attach itself is unbounded by measurement - see
  # the comment on FirebirdDriver.bound_reachability! for the numbers.

  describe "Firebird (stdlib reachability probe)" do
    it "gives up on an unreachable host, naming host, port, elapsed and the variable" do
      blackhole_reason = blackhole_unavailable_reason
      skip "[needs:blackhole-route] #{blackhole_reason}" if blackhole_reason

      with_connect_timeout("2") do
        elapsed = seconds_spent do
          expect_contract_error(blackhole_host, 3050) do
            Tina4::Drivers::FirebirdDriver.bound_reachability!(blackhole_host, 3050)
          end
        end
        expect(elapsed).to be_within(1.5).of(2)
      end
    end

    it "does NOT fire on a host that answers - a healthy connect is never cut short" do
      with_silent_server do |host, port|
        with_connect_timeout("2") do
          elapsed = seconds_spent do
            expect { Tina4::Drivers::FirebirdDriver.bound_reachability!(host, port) }.not_to raise_error
          end
          expect(elapsed).to be < 1
        end
      end
    end

    it "does NOT report a refused connection as a timeout" do
      # A closed port refuses instantly. Reporting that as a timeout would be a
      # lie, and it would hide the real cause from libfbclient's own message.
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.addr[1]
      closed.close
      with_connect_timeout("2") do
        expect { Tina4::Drivers::FirebirdDriver.bound_reachability!("127.0.0.1", port) }.not_to raise_error
      end
    end

    it "restores the OLD UNBOUNDED behaviour when the variable is 0" do
      blackhole_reason = blackhole_unavailable_reason
      skip "[needs:blackhole-route] #{blackhole_reason}" if blackhole_reason

      with_connect_timeout("0") do
        elapsed = seconds_spent do
          expect { Tina4::Drivers::FirebirdDriver.bound_reachability!(blackhole_host, 3050) }.not_to raise_error
        end
        # No probe at all - it must not even spend the bound it was given.
        expect(elapsed).to be < 0.5
      end
    end

    it "is WIRED INTO connect, not merely available to call" do
      # Without this the probe could be perfect and never run. Driven end to end
      # through the real FirebirdDriver#connect against a real blackhole: with no
      # bound this connect never returns at all.
      begin
        require "fb"
      rescue LoadError
        skip "fb gem not installed"
      end
      blackhole_reason = blackhole_unavailable_reason
      skip "[needs:blackhole-route] #{blackhole_reason}" if blackhole_reason

      with_connect_timeout("2") do
        driver = Tina4::Drivers::FirebirdDriver.new
        elapsed = seconds_spent do
          expect_contract_error(blackhole_host, 3050) do
            driver.connect("firebird://sysdba:masterkey@#{blackhole_host}:3050//data/probe.fdb")
          end
        end
        expect(elapsed).to be < 10
      end
    end
  end

  # ── MongoDB: the driver's own connect_timeout ───────────────────────────────

  describe "MongoDB (mongo connect_timeout)" do
    it "hands the bound to the real client instead of the gem's hard-coded 10s default" do
      begin
        require "mongo"
      rescue LoadError
        skip "mongo gem not installed"
      end
      uri = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017/tina4_rb")
      host = URI.parse(uri).host || "127.0.0.1"
      port = URI.parse(uri).port || 27017
      reachable = begin
        Socket.tcp(host, port, connect_timeout: 2, &:close)
        true
      rescue StandardError
        false
      end
      skip "MongoDB not reachable at #{host}:#{port}" unless reachable

      Mongo::Logger.logger.level = Logger::FATAL
      with_connect_timeout("3") do
        driver = Tina4::Drivers::MongodbDriver.new
        driver.connect(uri)
        client = driver.instance_variable_get(:@client)
        expect(client.options[:connect_timeout]).to eq(3)
        driver.close
      end
    end

    it "leaves a connectTimeoutMS the operator spelled in the URI alone" do
      begin
        require "mongo"
      rescue LoadError
        skip "mongo gem not installed"
      end
      uri = ENV.fetch("TINA4_TEST_MONGO_URI", "mongodb://127.0.0.1:27017/tina4_rb")
      host = URI.parse(uri).host || "127.0.0.1"
      port = URI.parse(uri).port || 27017
      reachable = begin
        Socket.tcp(host, port, connect_timeout: 2, &:close)
        true
      rescue StandardError
        false
      end
      skip "MongoDB not reachable at #{host}:#{port}" unless reachable

      Mongo::Logger.logger.level = Logger::FATAL
      with_connect_timeout("3") do
        driver = Tina4::Drivers::MongodbDriver.new
        driver.connect("#{uri}#{uri.include?("?") ? "&" : "?"}connectTimeoutMS=7000")
        client = driver.instance_variable_get(:@client)
        expect(client.options[:connect_timeout]).to eq(7)
        driver.close
      end
    end
  end
end
