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

    # What replaces a credential everywhere. One spelling, so a test can assert
    # on it and a reader recognises it on sight.
    REDACTED = "***"

    # RFC 3986 scheme grammar. A scheme cannot contain ":", "@", "/" or a space,
    # which is what makes it the ONLY part of an unparseable string that is
    # provably not a password.
    SCHEME = /\A[A-Za-z][A-Za-z0-9+.\-]*\z/.freeze

    # host[:port][/path] with a NUMERIC port. The digit requirement is what does
    # the work: it is why "user:secret" (a URL with the host left off) fails to
    # match and gets redacted, while "192.168.88.99:55432/tina4_py" is echoed.
    HOST_PORT = %r{\A(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(?::\d+)?(?:/.*)?\z}m.freeze

    # Credential KEYWORDS in the two keyword=value forms that carry one: the
    # ODBC connection string (";"-separated) and the libpq/JDBC query string
    # ("&"-separated). A braced value is matched FIRST because an ODBC value
    # containing ";" must be braced - stopping at the ";" would leave the tail
    # of the password in the output, which is exactly the bug shape this file
    # exists to close.
    #
    # UID/USER are deliberately NOT redacted: a username is not a secret, and it
    # is most of what makes a failed connection diagnosable.
    CREDENTIAL_KEYWORDS = /\b(PWD|PASSWORD)\s*=\s*(?:\{[^}]*\}|[^;&]*)/i.freeze

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

      # Separate credentials fill in only when the URL carried NONE.
      #
      # ABSENT and BLANK are different values, and the difference is load
      # bearing: the gate is `nil?`, never `empty?`. A URL written
      #   postgres://user:@host/db
      # states an explicitly EMPTY password, so the TINA4_DATABASE_PASSWORD
      # fallback must NOT fire; only
      #   postgres://user@host/db
      # is absent and takes the env value. Measured 2026-08-02: Ruby and PHP
      # obey this, Python and Node return None for the blank form and therefore
      # authenticate with a DIFFERENT password off the SAME .env - which is the
      # kind of divergence nobody notices until an account locks out.
      @username = username if @username.nil? && username && !username.empty?
      @password = password if @password.nil? && password && !password.empty?
    end

    # Parse the configured URL, or nil when the variable is not set.
    def self.from_env(key = "TINA4_DATABASE_URL")
      url = (ENV[key] || "").strip
      return nil if url.empty?

      new(url, username: ENV["TINA4_DATABASE_USERNAME"], password: ENV["TINA4_DATABASE_PASSWORD"])
    end

    # THE redaction primitive. Every connection string that is about to reach a
    # log line, an exception message or a dump goes through here.
    #
    # It takes a RAW string and never raises, because the paths that most need
    # redacting are exactly the ones where parsing already failed.
    #
    # Measured in this repo on 2026-08-02, before this existed:
    #   * Database#safe_connection_target carried its OWN regex, and
    #       postgres://u:p@ss@h:5432/db -> postgres://u:***@ss@h:5432/db
    #     leaked the password tail past the first "@" (the Ruby twin of the PHP
    #     `password=\S*` tail leak), and
    #       odbc:///...;PWD=<secret>    -> returned VERBATIM
    #     went straight into DatabaseConnectionError, which is raised at the
    #     first query and lands in a 500 body.
    #   * DatabaseUrl's own invalid-URL ArgumentError interpolated the whole raw
    #     URL, and detect_driver raises it on the BOOT path, so one typo in
    #     TINA4_DATABASE_URL wrote the password into the boot log and CI output.
    # One primitive means the next such bug is fixed once, not four times.
    def self.redact(raw)
      text = raw.to_s
      return "" if text.empty?

      begin
        # A URL that PARSES gets the round-tripping form rebuilt from the parsed
        # FIELDS. That form cannot leak: the password is never copied into it.
        new(text).to_safe_string
      rescue StandardError
        # Unparseable - fall back to the structural scrub. Redaction must never
        # raise; a raise here would mask the error we were called to describe.
        scrub(text)
      end
    end

    # Structural redaction of a string that did NOT parse.
    def self.scrub(text)
      head, separator, rest = text.to_s.partition("://")

      # No "://" - a bare file path, or an ODBC/keyword string. There is no
      # userinfo to find, so only the keyword form can hide a secret here.
      return scrub_keywords(text.to_s) if separator.empty?

      # A head that is not a scheme is unknown text, and unknown text may BE the
      # secret (the measured Python case was `notaurl-with-SuperSecret123`).
      # Say nothing about it rather than guess.
      return REDACTED unless head.match?(SCHEME)

      # The authority is taken to the first "?" or "#", NOT to the first "/".
      # An unencoded "/" inside a password would otherwise cut the region short,
      # push the "@" outside it, and let the password prefix survive.
      cut = rest.index(/[?#]/) || rest.length
      "#{head}://#{redact_authority(rest[0, cut])}#{scrub_keywords(rest[cut..].to_s)}"
    end

    # Take the credential out of a URL authority.
    #
    #   user:pass@host:5432/db -> user:***@host:5432/db
    #   host:5432/db           -> host:5432/db   (no credential present)
    #   user:pass              -> user:***       (host left off - a real typo,
    #                                             and the only reason the no-"@"
    #                                             branch cannot echo blindly)
    def self.redact_authority(authority)
      # The LAST "@", because userinfo ends at the last "@" (RFC 3986). Splitting
      # on the FIRST one is how an unencoded "@" inside a password leaves a tail
      # in the output.
      at = authority.rindex("@")
      if at
        userinfo = authority[0, at]
        host = authority[(at + 1)..].to_s
        name, colon, = userinfo.partition(":")
        return colon.empty? ? "#{name}@#{host}" : "#{name}:#{REDACTED}@#{host}"
      end

      return authority if authority.match?(HOST_PORT)

      name, colon, = authority.partition(":")
      colon.empty? ? name : "#{name}:#{REDACTED}"
    end

    # Redact the value side of a credential keyword, leaving every other
    # keyword visible so the string is still diagnosable.
    def self.scrub_keywords(text)
      text.gsub(CREDENTIAL_KEYWORDS) { "#{Regexp.last_match(1)}=#{REDACTED}" }
    end

    # The invalid-URL message, with the credential taken OUT.
    #
    # It still has to be diagnosable, so it keeps the scheme, the host, the port
    # as written (the usual fault) and the database name - only the password
    # becomes ***. When the value has no "://" there is no structure to trust,
    # so the value is not shown at all and the message says why.
    def self.invalid_url_error(url)
      text = url.to_s
      if text.include?("://")
        "DatabaseUrl: Invalid URL format '#{scrub(text)}' - expected " \
          "scheme://user:password@host:port/database"
      else
        "DatabaseUrl: Invalid URL format - no '://', so there is no scheme to " \
          "connect with. The URL itself is not shown because it can contain a " \
          "password. Expected scheme://user:password@host:port/database"
      end
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
      # ODBC used to return the connection string VERBATIM here, PWD= included -
      # measured 2026-08-02. The negative test "never leaks the password" passed
      # anyway, because the shared corpus had no odbc row for it to check: the
      # guard existed, the test was green, and it protected nothing. Every other
      # keyword stays visible so a failed ODBC connection is still diagnosable.
      return "odbc:///#{self.class.scrub_keywords(@connection_string.to_s)}" if @engine == "odbc"

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

    # Interpolation ("connecting to #{url}") and JSON both have to be safe, not
    # just inspect. Ruby's inspect already guarded the console and backtraces -
    # these two close the same class of leak PHP has through print_r/var_dump
    # and Node through JSON.stringify, and they make the useless default
    # "#<Tina4::DatabaseUrl:0x000...>" say something instead.
    def to_s
      to_safe_string
    end

    def to_json(*args)
      to_safe_string.to_json(*args)
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
        # NEVER interpolate the raw URL here. Measured 2026-08-02: a malformed
        # TINA4_DATABASE_URL put the password verbatim into this ArgumentError,
        # and Database#detect_driver raises it during boot - so the credential
        # reached the boot log, the error overlay, a crash report and CI output.
        raise ArgumentError, self.class.invalid_url_error(url)
      end

      scheme = parsed.scheme.to_s.downcase
      raise ArgumentError, self.class.invalid_url_error(url) if scheme.empty?

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
