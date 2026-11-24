# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "json"
require "socket"
require "stringio"
require "tmpdir"
require_relative "spec_helper"
require_relative "support/real_log_capture"

# GHSA-h2mr-m3v3-cq8c - a connection URL's password must never be printed,
# whatever shape the URL has.
#
# spec/fixtures/db_url_redaction_cases.json is the SHARED case list (identical in
# all four frameworks). Every password x template is fed, for every scheme Ruby
# supports, to the REAL redaction primitive, the REAL parser and the REAL
# connect/error path. Nothing here is a double: connects go to a closed
# 127.0.0.1 port where the driver gem is installed, and to the framework's own
# pre-connect error path where it is not.
#
# Every output is checked - return values, exception messages, the WHOLE cause
# chain, the real Tina4 log file, and whatever reached $stdout/$stderr.
module DbUrlRedactionCases
  FIXTURE = JSON.parse(File.read(File.join(__dir__, "fixtures", "db_url_redaction_cases.json")))
  FRAGMENTS = FIXTURE["secret_fragments"].freeze
  PASSWORDS = FIXTURE["passwords"].freeze
  TEMPLATES = FIXTURE["templates"].freeze
  HOSTLESS = "{scheme}://u:{pw}"

  DB_SCHEMES = Tina4::DatabaseUrl::ENGINE_ALIASES.keys.freeze
  GRAPH_SCHEMES = Tina4::GraphUrl::SCHEME_ENGINE.keys.freeze
  MQTT_SCHEMES = %w[mqtt mqtts tcp].freeze
  # valkey:// is what a Tina4 user types for the cache; the redis gem rejects
  # it with `Unknown URL scheme: "<the whole URL>"`, which is the path that
  # proves the backplane's re-raise drops that error instead of chaining it.
  BACKPLANE_SCHEMES = %w[redis valkey].freeze

  module_function

  def build(template, scheme, password)
    template.sub("{scheme}", scheme).sub("{pw}", password)
  end

  # KNOWN LIMIT (documented, not a leak of anything that is provably a
  # password): in "scheme://u:Pq1@Rs2" the text after the last "@" IS the host
  # by RFC 3986, so "Rs2" is shown as the host. Only "Pq1" - the part that is
  # unambiguously the password - is asserted absent for that one shape.
  def fragments_for(template, password)
    template == HOSTLESS && password.include?("@") ? ["Pq1"] : FRAGMENTS
  end

  # The same URL aimed at a CLOSED local port, so a real driver fails fast.
  def connect_url(url, port)
    url.sub("@dbhost:5432", "@127.0.0.1:#{port}")
       .sub("@dbhost:notaport", "@127.0.0.1:notaport")
       .sub("@dbhost/", "@127.0.0.1:#{port}/")
  end

  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Every text an exception exposes, down the whole cause chain.
  def chain_texts(error)
    texts = []
    seen = 0
    while error && seen < 20
      texts << error.class.name.to_s << error.message.to_s << error.inspect.to_s
      error = error.cause
      seen += 1
    end
    texts
  end
end

RSpec.describe "GHSA-h2mr-m3v3-cq8c: connection URL redaction (shared cases)" do
  include RealLogCapture
  include DbUrlRedactionCases

  def leaked(texts, fragments)
    texts.compact.map(&:to_s).select { |t| fragments.any? { |f| t.include?(f) } }
  end

  # Run a block with the REAL logger writing to a REAL file and $stdout/$stderr
  # captured; returns every text the block produced plus the log and streams.
  def capturing
    texts = []
    out = StringIO.new
    err = StringIO.new
    saved_out = $stdout
    saved_err = $stderr
    log = capture_real_log(level: "DEBUG") do
      $stdout = out
      $stderr = err
      begin
        yield texts
      ensure
        $stdout = saved_out
        $stderr = saved_err
      end
    end
    texts << log << out.string << err.string
  end

  def with_env(values)
    saved = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Every connect runs inside capturing, whose real-log helper chdirs into its
  # own temp dir - so a mangled sqlite URL cannot litter the repo with files.
  around(:each) do |example|
    with_env("TINA4_DATABASE_CONNECT_TIMEOUT" => "2", "TINA4_GRAPH_CONNECT_TIMEOUT" => "1",
             "TINA4_DB_POOL" => nil, "TINA4_DATABASE_USERNAME" => nil,
             "TINA4_DATABASE_PASSWORD" => nil) { example.run }
  end

  let(:port) { DbUrlRedactionCases.closed_port }

  # ── Database URLs ──────────────────────────────────────────────────────────
  DbUrlRedactionCases::DB_SCHEMES.each do |scheme|
    DbUrlRedactionCases::TEMPLATES.each do |template|
      DbUrlRedactionCases::PASSWORDS.each do |password|
        url = DbUrlRedactionCases.build(template, scheme, password)
        fragments = DbUrlRedactionCases.fragments_for(template, password)

        it "db #{url.inspect}: redact, parse and connect never print the password" do
          texts = []

          # 1. The redaction primitive - and it must stay USEFUL.
          redacted = Tina4::DatabaseUrl.redact(url)
          texts << redacted << Tina4::DatabaseUrl.without_credentials(url)
          expect(redacted).to start_with(scheme)
          expect(redacted).to include("u")
          expect(redacted).to include("dbhost") if template.include?("dbhost")
          expect(redacted).to include("***") if fragments == DbUrlRedactionCases::FRAGMENTS

          # 2. The parser: accepted URLs expose no fragment through any field a
          # log prints; refused URLs name none in the message or the cause chain.
          begin
            parsed = Tina4::DatabaseUrl.new(url)
            texts << parsed.to_safe_string << parsed.inspect << parsed.to_s << parsed.to_json <<
              parsed.dsn << parsed.host << parsed.database << parsed.username
          rescue StandardError => e
            texts.concat(DbUrlRedactionCases.chain_texts(e))
          end

          # 3. The real connect / error path, real log included.
          target = DbUrlRedactionCases.connect_url(url, port)
          texts.concat(capturing do |out|
            db = nil
            begin
              db = Tina4::Database.new(target)
              out << db.safe_connection_target << db.inspect
              unless %w[mongodb mongo].include?(scheme) # server selection is a 30s wait
                begin
                  db.fetch_one("SELECT 1 AS ok")
                rescue StandardError => e
                  out.concat(DbUrlRedactionCases.chain_texts(e))
                end
              end
            rescue StandardError, ScriptError => e
              out.concat(DbUrlRedactionCases.chain_texts(e))
            ensure
              begin
                db&.close
              rescue StandardError
                nil
              end
            end
          end)

          expect(leaked(texts, fragments)).to eq([])
        end
      end
    end
  end

  # ── Startup banner: Tina4.setup_database names the database at boot ───────
  DbUrlRedactionCases::TEMPLATES.each do |template|
    DbUrlRedactionCases::PASSWORDS.each do |password|
      url = DbUrlRedactionCases.build(template, "postgres", password)
      fragments = DbUrlRedactionCases.fragments_for(template, password)

      it "boot #{url.inspect}: setup_database logs no password" do
        target = DbUrlRedactionCases.connect_url(url, port)
        texts = with_env("TINA4_DATABASE_URL" => target) do
          capturing do |out|
            Tina4.send(:setup_database)
            out << Tina4.instance_variable_get(:@database_setup_error).to_s
          ensure
            begin
              Tina4.database&.close
            rescue StandardError
              nil
            end
          end
        end
        expect(leaked(texts, fragments)).to eq([])
      end
    end
  end

  # ── Graph URLs ─────────────────────────────────────────────────────────────
  DbUrlRedactionCases::GRAPH_SCHEMES.each do |scheme|
    DbUrlRedactionCases::TEMPLATES.each do |template|
      DbUrlRedactionCases::PASSWORDS.each do |password|
        url = DbUrlRedactionCases.build(template, scheme, password)
        fragments = DbUrlRedactionCases.fragments_for(template, password)

        it "graph #{url.inspect}: GraphUrl and GraphDatabase.create never print the password" do
          texts = []
          begin
            parsed = Tina4::GraphUrl.new(url)
            texts << parsed.dsn << parsed.host << parsed.graph << parsed.username <<
              parsed.inspect << parsed.to_s << parsed.params.inspect
          rescue StandardError => e
            texts.concat(DbUrlRedactionCases.chain_texts(e))
          end

          target = DbUrlRedactionCases.connect_url(url, port)
          texts.concat(capturing do |out|
            graph = nil
            begin
              graph = Tina4::GraphDatabase.create(target)
              begin
                graph.query("RETURN 1")
              rescue StandardError => e
                out.concat(DbUrlRedactionCases.chain_texts(e))
              end
            rescue StandardError, ScriptError => e
              out.concat(DbUrlRedactionCases.chain_texts(e))
            ensure
              begin
                graph&.close
              rescue StandardError
                nil
              end
            end
          end)

          expect(leaked(texts, fragments)).to eq([])
        end
      end
    end
  end

  # ── MQTT URLs ──────────────────────────────────────────────────────────────
  DbUrlRedactionCases::MQTT_SCHEMES.each do |scheme|
    DbUrlRedactionCases::TEMPLATES.each do |template|
      DbUrlRedactionCases::PASSWORDS.each do |password|
        url = DbUrlRedactionCases.build(template, scheme, password)
        fragments = DbUrlRedactionCases.fragments_for(template, password)

        it "mqtt #{url.inspect}: parse_url and connect never print the password" do
          texts = []
          begin
            parsed = Tina4::Mqtt.parse_url(url)
            texts << parsed[:host] << parsed[:username] << parsed[:port].to_s
          rescue StandardError => e
            texts.concat(DbUrlRedactionCases.chain_texts(e))
          end

          target = DbUrlRedactionCases.connect_url(url, port)
          texts.concat(capturing do |out|
            client = nil
            begin
              client = Tina4::Mqtt.new(url: target, timeout: 1)
            rescue StandardError => e
              out.concat(DbUrlRedactionCases.chain_texts(e))
            ensure
              begin
                client&.disconnect
              rescue StandardError
                nil
              end
            end
          end)

          expect(leaked(texts, fragments)).to eq([])
        end
      end
    end
  end

  # ── WebSocket Redis backplane ──────────────────────────────────────────────
  DbUrlRedactionCases::BACKPLANE_SCHEMES.each do |scheme|
    DbUrlRedactionCases::TEMPLATES.each do |template|
      DbUrlRedactionCases::PASSWORDS.each do |password|
        url = DbUrlRedactionCases.build(template, scheme, password)
        fragments = DbUrlRedactionCases.fragments_for(template, password)

        it "backplane #{url.inspect}: RedisBackplane never prints the password" do
          begin
            require "redis"
          rescue LoadError
            skip "redis gem not installed"
          end
          target = DbUrlRedactionCases.connect_url(url, port)
          texts = capturing do |out|
            plane = nil
            begin
              plane = Tina4::RedisBackplane.new(url: target)
              begin
                plane.publish("tina4-redaction", "x")
              rescue StandardError => e
                out.concat(DbUrlRedactionCases.chain_texts(e))
              end
            rescue StandardError => e
              out.concat(DbUrlRedactionCases.chain_texts(e))
            ensure
              begin
                plane&.close
              rescue StandardError
                nil
              end
            end
          end
          expect(leaked(texts, fragments)).to eq([])
        end
      end
    end
  end

  # ── AMQP queue URL ─────────────────────────────────────────────────────────
  DbUrlRedactionCases::TEMPLATES.each do |template|
    DbUrlRedactionCases::PASSWORDS.each do |password|
      url = DbUrlRedactionCases.build(template, "amqp", password)
      fragments = DbUrlRedactionCases.fragments_for(template, password)

      # parse_amqp_url's host/port/vhost reach Bunny's connection errors.
      it "amqp #{url.inspect}: the parsed host, port and vhost carry no password" do
        texts = begin
          config = Tina4::Queue.parse_amqp_url(url)
          [config[:host], config[:port].to_s, config[:vhost], config[:username]]
        rescue ArgumentError => e
          DbUrlRedactionCases.chain_texts(e)
        end
        expect(leaked(texts, fragments)).to eq([])
      end
    end
  end

  # ── MongoDB session handler, zero-dependency transport ─────────────────────
  # parse_host_port picks the host the wire client dials - and quotes in its
  # "MongoDB transport failed" error. Called on a real (allocated) handler.
  DbUrlRedactionCases::TEMPLATES.each do |template|
    DbUrlRedactionCases::PASSWORDS.each do |password|
      url = DbUrlRedactionCases.build(template, "mongodb", password)
      fragments = DbUrlRedactionCases.fragments_for(template, password)

      it "mongo session #{url.inspect}: the host it dials carries no password" do
        handler = Tina4::SessionHandlers::MongoHandler.allocate
        host, port = handler.send(:parse_host_port, url)
        expect(leaked([host, port.to_s], fragments)).to eq([])
      end
    end
  end

  # ── Dev MCP env_list: connection URLs are listed masked ────────────────────
  it "env_list masks every *_URL value with the shared primitive" do
    urls = DbUrlRedactionCases::TEMPLATES.flat_map do |template|
      DbUrlRedactionCases::PASSWORDS.reject { |pw| template == DbUrlRedactionCases::HOSTLESS && pw.include?("@") }
                                    .map { |pw| DbUrlRedactionCases.build(template, "postgres", pw) }
    end
    keys = urls.each_index.map { |i| "TINA4_REDACTION_CASE_#{i}_URL" }
    with_env(keys.zip(urls).to_h) do
      Dir.mktmpdir("tina4-mcp-env") do |tmp|
        Dir.chdir(tmp) do
          server = Tina4::McpServer.new("/redaction-cases", name: "Redaction Cases")
          Tina4::McpDevTools.register(server)
          body = server.handle_message({
            "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
            "params" => { "name" => "env_list", "arguments" => {} }
          })
          keys.each { |k| expect(body).to include(k) }
          expect(leaked([body], DbUrlRedactionCases::FRAGMENTS)).to eq([])
        end
      end
    end
  end

  # ── Values that must keep parsing ──────────────────────────────────────────
  DbUrlRedactionCases::FIXTURE["must_still_parse"].each do |c|
    it "still parses #{c['url'].inspect}" do
      parsed = Tina4::DatabaseUrl.new(c["url"])
      expect(parsed.host).to eq(c["host"])
      expect(parsed.port).to eq(c["port"] || 5432)
      expect(parsed.username).to eq(c["user"])
      expect(parsed.password).to eq(c["password"])
      expect(parsed.database).to eq(c["database"])
      expect(parsed.to_safe_string).not_to include("Pq1")
    end
  end

  # ── Generic refusals carry no cause holding the URL ────────────────────────
  [
    "postgres:/u:Pq1Rs2@dbhost/appdb",
    "postgres//u:Pq1Rs2@dbhost/appdb",
    "postgres://dbhost/appdb?note=Pq1@Rs2"
  ].each do |url|
    it "refuses #{url.inspect} with a generic message and no cause" do
      expect { Tina4::DatabaseUrl.new(url) }.to raise_error(ArgumentError) { |e|
        expect(e.cause).to be_nil
        expect(leaked(DbUrlRedactionCases.chain_texts(e), DbUrlRedactionCases::FRAGMENTS)).to eq([])
      }
    end
  end

  # ── Shapes the shared list does not reach on its own ───────────────────────

  # URI.parse on a whole value reads `u:12?x@h` as host "u", port 12 and the
  # password tail in the query. Userinfo must end at the LAST "@" instead.
  {
    "DatabaseUrl" => ->(u) { Tina4::DatabaseUrl.new(u) },
    "GraphUrl" => ->(u) { Tina4::GraphUrl.new(u.sub("postgres", "bolt")) }
  }.each do |label, parse|
    it "#{label} reads a digit-led password with '?' as userinfo, never as host:port" do
      parsed = parse.call("postgres://u:12?Pq1Rs2@dbhost:5432/appdb")
      expect(parsed.host).to eq("dbhost")
      expect(parsed.username).to eq("u")
      expect(parsed.password).to eq("12?Pq1Rs2")
      outputs = [parsed.inspect, parsed.to_s, parsed.host, parsed.port.to_s]
      outputs << parsed.params.inspect if parsed.respond_to?(:params)
      expect(leaked(outputs, DbUrlRedactionCases::FRAGMENTS)).to eq([])
    end

    it "#{label} still parses a password holding an unencoded '/'" do
      parsed = parse.call("postgres://u:Pq1/Rs2@dbhost/appdb")
      expect(parsed.host).to eq("dbhost")
      expect(parsed.password).to eq("Pq1/Rs2")
    end
  end

  # The DRIVER must read the same password the framework parsed - otherwise
  # libpq / the mongo gem cut the userinfo at the first "/" or "@" and quote
  # the rest back as a host or a database name. Checked with the real drivers'
  # own URI parsers, on the string Database really hands them.
  DbUrlRedactionCases::PASSWORDS.each do |password|
    {
      "postgres" => lambda { |u|
        require "pg"
        PG::Connection.conninfo_parse(u).find { |o| o[:keyword] == "password" }[:val]
      },
      "mongodb" => lambda { |u|
        require "mongo"
        Mongo::URI.get(u).credentials[:password]
      }
    }.each do |scheme, driver_password|
      it "the #{scheme} driver reads #{password.inspect} exactly as the framework does" do
        url = "#{scheme}://u:#{password}@127.0.0.1:#{port}/appdb"
        db = nil
        capturing { db = Tina4::Database.new(url) }
        handed = db.send(:driver_connection_string)
        expect(Tina4::DatabaseUrl.new(url).password).to eq(password)
        expect(driver_password.call(handed)).to eq(password)
      ensure
        begin
          db&.close
        rescue StandardError
          nil
        end
      end
    end
  end

  # A driver that splits the value on its own terms quotes a PART of it, which
  # a whole-string replace never finds. These are the messages libpq and the
  # mongo gem really produce for such values (measured), fed through the
  # Database's own scrub.
  [
    ["postgres://u:Pq1 Rs2@127.0.0.1:1/appdb",
     'unexpected spaces found in "Pq1 Rs2", use percent-encoded spaces (%20) instead'],
    ["pgsql://u:Pq1 Rs2@127.0.0.1:1/appdb",
     'missing "=" after "pgsql://u:Pq1" in connection info string'],
    ["postgres://u:Pq1/Rs2@127.0.0.1:1/appdb",
     'invalid integer value "Pq1" for connection option "port"'],
    ["mongodb://u:Pq1/Rs2@127.0.0.1:1/appdb",
     "Bad URI: mongodb://u:Pq1/Rs2@127.0.0.1:1/appdb\nDatabase name contains an unescaped slash (/): Rs2@127.0.0.1:1/appdb"]
  ].each do |url, driver_message|
    it "a driver message quoting part of #{url.inspect} is scrubbed" do
      db = Tina4::Database.allocate
      db.instance_variable_set(:@connection_string, url)
      expect(leaked([db.send(:scrub_connection_string, driver_message)], DbUrlRedactionCases::FRAGMENTS)).to eq([])
    end
  end

  # The scrub must not shred the message it is protecting. CI measured this on
  # live PostgreSQL: the wrong password "s3ntinel-Pa55 word" split into the
  # piece "word", and "password authentication failed" became
  # "pass*** authentication failed" - the reason was gone.
  it "a password piece is masked only where it stands alone, never inside a word" do
    db = Tina4::Database.allocate
    db.instance_variable_set(:@connection_string, "postgres://tina4:s3ntinel-Pa55%20word@localhost:55432/tina4_rb")
    db.instance_variable_set(:@driver_name, "postgres")
    db.instance_variable_set(:@connect_error, RuntimeError.new(
      'connection to server at "::1", port 55432 failed: FATAL:  password authentication failed for user "tina4"'
    ))
    message = db.send(:connect_error_message)
    expect(message).to include("password authentication failed")
    expect(message).to include("postgres://tina4:***@localhost:55432/tina4_rb")
    expect(message).not_to include("s3ntinel")
    quoted = db.send(:scrub_connection_string, 'missing "=" after "word" in connection info string')
    expect(quoted).not_to include('"word"')
  end

  # `postgres//u:pw@h` (the ":" lost) is a URL typo: refused by the parser,
  # never handed to a driver that would quote part of it.
  DbUrlRedactionCases::DB_SCHEMES.reject { |s| s.start_with?("sqlite") }.each do |scheme|
    it "Database.new refuses the #{scheme}// typo instead of connecting with it" do
      expect { Tina4::Database.new("#{scheme}//u:Pq1Rs2@127.0.0.1:#{port}/appdb") }
        .to raise_error(ArgumentError) { |e|
          expect(e.cause).to be_nil
          expect(leaked(DbUrlRedactionCases.chain_texts(e), DbUrlRedactionCases::FRAGMENTS)).to eq([])
        }
    end
  end

  [
    "mqtt:/u:Pq1Rs2@dbhost:1883",
    "mqtt//u:Pq1Rs2@dbhost:1883",
    "mqtt://dbhost/x?note=Pq1@Rs2"
  ].each do |url|
    it "MQTT refuses #{url.inspect} generically, with no cause" do
      expect { Tina4::Mqtt.parse_url(url) }.to raise_error(ArgumentError) { |e|
        expect(e.cause).to be_nil
        expect(e.message).to include("not shown")
        expect(leaked(DbUrlRedactionCases.chain_texts(e), DbUrlRedactionCases::FRAGMENTS)).to eq([])
      }
    end
  end

  it "GraphUrl refuses a malformed URL with no cause" do
    expect { Tina4::GraphUrl.new("bolt://u:Pq1Rs2@dbhost:notaport/g") }.to raise_error(ArgumentError) { |e|
      expect(e.cause).to be_nil
    }
  end

  # KNOWN LIMIT, pinned so a change in it is noticed: a host-less URL whose
  # password is all digits cannot be told apart from host:port.
  it "documents the all-digit host-less password limit" do
    expect(Tina4::DatabaseUrl.redact("postgres://u:123/x")).to eq("postgres://u:123/x")
  end
end
