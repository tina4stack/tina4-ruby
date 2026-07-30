# frozen_string_literal: true

require "uri"

module Tina4
  # A parsed database connection URL, as a VALUE.
  #
  # Feature 5 of the feature audit. Ruby had no parser to call: URL handling was
  # inline in +Database#initialize+, so a URL could not be parsed without
  # building a connection object. The parse could not be unit tested on its own,
  # the four frameworks could not be compared without standing up a database,
  # and +tina4 doctor+ or the setup wizard had nothing to call to validate a URL
  # before using it.
  #
  # What was there instead was +detect_driver+: substring regex matching over the
  # whole connection string with a silent <tt>else "sqlite"</tt> fallback, so an
  # unrecognised URL did not fail - it quietly became SQLite. The app boots,
  # writes to a local file, and nobody learns the real database was never
  # reached. This class raises instead.
  #
  # Core Principle 6 says a connection string must mean literally the same thing
  # in every framework. +spec/fixtures/database_url_corpus.json+ is the answer
  # key, byte-identical in all four.
  class DatabaseUrl
    # URL scheme to CANONICAL engine. Aliases resolve ONCE, here, so nothing
    # downstream ever compares raw schemes.
    #
    # +sqlite3+ is accepted because the driver is literally named sqlite3 in
    # every framework (Python's sqlite3 module, Ruby's sqlite3 gem, PHP's
    # ext-sqlite3, Node's node:sqlite), so people type it. The "3" is a
    # file-format version, not a different engine, which is why the canonical
    # name stays +sqlite+.
    ENGINE_ALIASES = {
      "sqlite" => "sqlite",
      "sqlite3" => "sqlite",
      "postgres" => "postgres",
      "postgresql" => "postgres",
      "pgsql" => "postgres",
      "mysql" => "mysql",
      "mssql" => "mssql",
      "sqlserver" => "mssql",
      "firebird" => "firebird",
      "mongodb" => "mongodb",
      "mongo" => "mongodb",
      "odbc" => "odbc"
    }.freeze

    # Applied AT PARSE. The port is part of our contract, not the driver's
    # business: a URL with no port must yield the same struct in all four.
    DEFAULT_PORTS = {
      "postgres" => 5432,
      "mysql" => 3306,
      "mssql" => 1433,
      "firebird" => 3050,
      "mongodb" => 27017
    }.freeze

    attr_reader :engine, :host, :port, :database, :username, :password,
                :connection_string

    def initialize(url, username: nil, password: nil)
      raise ArgumentError, "DatabaseUrl: the URL is empty" if url.nil? || url.to_s.strip.empty?

      url = url.to_s
      @host = nil
      @port = nil
      @database = ""
      @username = nil
      @password = nil
      @connection_string = nil

      if url.start_with?("sqlite:", "sqlite3:")
        parse_sqlite(url)
      elsif url.start_with?("odbc:///")
        @engine = "odbc"
        @connection_string = url[("odbc:///".length)..]
      else
        parse_standard(url)
      end

      # Separate credentials fill in only when the URL carried none.
      @username = username if @username.nil? && username && !username.empty?
      @password = password if @password.nil? && password && !password.empty?
    end

    # Parse the configured URL, or nil when the variable is not set.
    def self.from_env(key = "TINA4_DATABASE_URL")
      url = (ENV[key] || "").strip
      return nil if url.empty?

      new(url, username: ENV["TINA4_DATABASE_USERNAME"], password: ENV["TINA4_DATABASE_PASSWORD"])
    end

    # Connection target. sqlite and odbc are the whole value.
    def dsn
      return @database if @engine == "sqlite"
      return @connection_string.to_s if @engine == "odbc"

      out = @host.to_s
      out += ":#{@port}" unless @port.nil?
      out += "/#{@database}" unless @database.empty?
      out
    end

    # The URL with the password replaced by <tt>***</tt>.
    #
    # The ONLY form allowed in a log line or an error message: a connection URL
    # in a log is a credential leak. It round-trips the input, so it stays
    # readable as well as safe.
    def to_safe_string
      return "sqlite:///#{@database}" if @engine == "sqlite"
      return "odbc:///#{@connection_string}" if @engine == "odbc"

      out = "#{@engine}://"
      unless @username.nil?
        out += @username
        out += ":***" unless @password.nil?
        out += "@"
      end
      out += @host.to_s
      out += ":#{@port}" unless @port.nil?
      out += "/#{@database}" unless @database.empty?
      out
    end

    # inspect lands in backtraces and the console, so it MUST be the safe form.
    def inspect
      "#<Tina4::DatabaseUrl #{to_safe_string}>"
    end

    private

    # Strip EXACTLY ONE leading slash: the URL path separator, never more.
    def strip_one_slash(path)
      path.start_with?("/") ? path[1..] : path
    end

    # sqlite is parsed on the RAW string, never through URI. URI collapses
    # "sqlite:/x" and "sqlite:///x", losing the difference between a one-slash
    # ABSOLUTE path and the documented three-slash RELATIVE form.
    #
    #   sqlite:///app.db       -> app.db        (three slashes = relative)
    #   sqlite:////abs/app.db  -> /abs/app.db   (four slashes = absolute)
    #   sqlite:/abs/app.db     -> /abs/app.db   (one slash = a real absolute)
    #   sqlite:app.db          -> app.db
    def parse_sqlite(url)
      @engine = "sqlite"
      url = "sqlite:#{url[("sqlite3:".length)..]}" if url.start_with?("sqlite3:")

      @database = if ["sqlite::memory:", "sqlite:///:memory:"].include?(url)
                    ":memory:"
                  elsif url.start_with?("sqlite:///")
                    strip_one_slash(url[("sqlite://".length)..])
                  elsif url.start_with?("sqlite://")
                    url[("sqlite://".length)..]
                  else
                    url[("sqlite:".length)..]
                  end
    end

    def parse_standard(url)
      parsed = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        raise ArgumentError, "DatabaseUrl: Invalid URL format '#{url}'"
      end

      scheme = parsed.scheme.to_s.downcase
      raise ArgumentError, "DatabaseUrl: Invalid URL format '#{url}'" if scheme.empty?

      engine = ENGINE_ALIASES[scheme]
      if engine.nil?
        raise ArgumentError,
              "DatabaseUrl: Unsupported database scheme '#{scheme}'. " \
              "Supported: #{ENGINE_ALIASES.keys.join(', ')}"
      end

      @engine = engine
      @host = parsed.host && !parsed.host.empty? ? parsed.host : nil
      @port = parsed.port || DEFAULT_PORTS[engine]
      @username = parsed.user ? URI.decode_www_form_component(parsed.user) : nil
      @password = parsed.password ? URI.decode_www_form_component(parsed.password) : nil

      # Strip EXACTLY ONE leading slash - the URL path separator. Stripping every
      # slash turns the documented absolute Firebird form
      # `firebird://host:3050//var/lib/db.fdb` into the RELATIVE
      # `var/lib/db.fdb`. Verified against live Firebird 5.0.4: the driver takes
      # one or two leading slashes and rejects a relative path outright.
      database = strip_one_slash(parsed.path.to_s)
      @database = database.empty? && engine == "mongodb" ? "tina4" : database
    end
  end
end
