# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


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
  # DISPLAY REDACTS, FIDELITY DOES NOT. #inspect, #to_s and #to_safe_string
  # replace the password with the redaction marker, so a log line, a backtrace or
  # a status payload is safe. Marshal deliberately does not: its contract is a
  # faithful round trip, and a masked Marshal would load an object whose password
  # is the literal "***".
  #
  # The consequence: DO NOT PERSIST THIS OBJECT. A DatabaseUrl marshalled into a
  # cache, a session or a queue payload puts the password in cleartext on disk.
  # Record #to_safe_string instead. spec/database_url_redaction_spec.rb fails the
  # build if framework code ever marshals one.
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

    # sqlite's in-memory spellings. ":memory:" looks like host:port to the
    # credential locator, and is not one.
    SQLITE_MEMORY_FORMS = ["sqlite::memory:", "sqlite:///:memory:", "sqlite://:memory:"].freeze

    # RFC 3986 scheme grammar. A scheme cannot contain ":", "@", "/" or a space,
    # which is what makes it the ONLY part of an unparseable string that is
    # provably not a password.
    SCHEME = /\A[A-Za-z][A-Za-z0-9+.\-]*\z/.freeze

    # Where the authority starts (GHSA-h2mr-m3v3-cq8c): after "scheme://", and
    # ALSO after the two typos "scheme:/" and "scheme//". A URL that lost a "/"
    # or its ":" still carries the password in the same place, and treating the
    # rest as an opaque path is how `postgres:/u:pw@h` was printed verbatim.
    AUTHORITY_START = %r{\A[A-Za-z][A-Za-z0-9+.\-]*(?:://|:/|//)}.freeze

    # "scheme:" alone - only trusted as a prefix when an "@" follows.
    OPAQUE_SCHEME = /\A[A-Za-z][A-Za-z0-9+.\-]*:/.freeze

    # The only prefix a PARSER accepts. Anything else is refused.
    URL_PREFIX = %r{\A([A-Za-z][A-Za-z0-9+.\-]*)://}.freeze

    # The generic refusal: it never echoes the value, because a value whose
    # shape the parser cannot trust is exactly one where the password could be
    # anywhere.
    AMBIGUOUS_URL = "Invalid URL format - the value is not scheme://[user[:password]@]host[:port][/path], " \
                    "or an '@' appears outside the user:password part (percent-encode it as %40). " \
                    "The URL itself is not shown because it can contain a password."

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
    #
    # GHSA-h2mr-m3v3-cq8c: this used to trust URI.parse, which ACCEPTS
    # `postgres:/u:pw@h` (password in the path), `u:p@/q@h` and `u:12?q@h`
    # (password in the query), and its fallback cut the authority at the first
    # "?" or "#" - so a password holding / ? # @ % or a space, a URL with one
    # slash or no colon after the scheme, a URL with no host, and a non-numeric
    # port were all printed in clear. It is now purely structural: the ONE
    # locator, #password_span, decides what the password is, and every caller
    # in the framework goes through it.
    def self.redact(raw)
      text = raw.to_s
      return "" if text.empty?

      # A head before "://" that is not a scheme is unknown text, and unknown
      # text may BE the secret (the measured Python case was
      # `notaurl-with-SuperSecret123://`). Say nothing about it rather than guess.
      head, separator, = text.partition("://")
      return REDACTED if !separator.empty? && !head.match?(SCHEME)

      span = password_span(text)
      text = "#{text[0, span.first]}#{REDACTED}#{text[span.last..]}" if span
      scrub_keywords(text)
    rescue StandardError
      # Redaction must never raise - a raise here would mask the error we were
      # called to describe - and must never fall back to the input.
      REDACTED
    end

    # Where the password is in a raw connection string, as [start, stop)
    # character offsets, or nil when there is none. THE rule, shared by every
    # redaction and every parser in the framework:
    #
    # * The authority starts after "scheme://", "scheme:/" or "scheme//".
    # * Userinfo ends at the LAST "@" on the value (RFC 3986); the password
    #   starts at the first ":" after the authority start. A "/" before that
    #   ":" means the text is a path, not a password.
    # * With no "@", a non-numeric port is the password of a URL that lost its
    #   host (`postgres://u:secret`), masked to the end of the value - except a
    #   trailing "?key=value" query, which is kept.
    #
    # KNOWN LIMIT: a host-less URL whose password is all digits
    # (`postgres://u:123/x`) cannot be told apart from host:port, so it stays
    # unmasked. Likewise in `postgres://u:pw@word` the text after the last "@"
    # IS the host, by the RFC, and is shown as one.
    def self.password_span(raw)
      text = raw.to_s
      start = authority_start(text)
      return nil if start.nil?

      rest = text[start..]
      span = rest.include?("@") ? userinfo_span(rest) : port_span(rest)
      span && [start + span.first, start + span.last]
    end

    # Offset where the authority starts: after "scheme://", "scheme:/" or
    # "scheme//"; when the value has an "@" but none of those, after a bare
    # "scheme:" or at the very start. nil when there is nothing to look in.
    def self.authority_start(text)
      prefix = text[AUTHORITY_START]
      return prefix.length if prefix
      return nil unless text.include?("@")

      text[OPAQUE_SCHEME].to_s.length
    end
    private_class_method :authority_start

    # With an "@": the password runs from the first ":" to the LAST "@".
    def self.userinfo_span(rest)
      at = rest.rindex("@")
      colon = rest.index(":")
      return nil if colon.nil? || colon > at || path_before?(rest, colon)

      [colon + 1, at]
    end
    private_class_method :userinfo_span

    # No "@": only a non-numeric PORT can be a password (an IPv6 literal is
    # skipped). Masked to the end, keeping a trailing "?key=value" query.
    def self.port_span(rest)
      host_end = rest.start_with?("[") ? (rest.index("]") || rest.length) : 0
      colon = rest.index(":", host_end)
      return nil if colon.nil? || path_before?(rest, colon)
      return nil if rest[(colon + 1)..][%r{\A[^/?#\\]*}].match?(/\A\d*\z/)

      [colon + 1, kept_query_start(rest, colon) || rest.length]
    end
    private_class_method :port_span

    def self.kept_query_start(rest, colon)
      query = rest.rindex("?")
      return nil if query.nil? || query < colon

      query if rest[(query + 1)..].match?(/\A[A-Za-z_][A-Za-z0-9_.\-]*=/)
    end
    private_class_method :kept_query_start

    def self.path_before?(rest, colon)
      separator = rest.index(%r{[/\\]})
      !separator.nil? && separator < colon
    end
    private_class_method :path_before?

    # The connection string with the whole `user:pass@` removed, for log lines
    # that only need to say WHICH database. Stricter than #redact (the user name
    # goes too), and built on it so a password never survives an odd URL shape.
    def self.without_credentials(raw)
      redact(raw).gsub(%r{://[^/\s@]*@}, "://")
    end

    # Kept for callers of the old name; it is #redact.
    def self.scrub(text)
      redact(text)
    end

    # Redact the value side of a credential keyword, leaving every other
    # keyword visible so the string is still diagnosable.
    def self.scrub_keywords(text)
      text.gsub(CREDENTIAL_KEYWORDS) { "#{Regexp.last_match(1)}=#{REDACTED}" }
    end

    # A third party's error message (a driver, a client gem) with the
    # connection string taken out. The whole raw value is replaced by its
    # redacted form, and so is the password itself and every piece of it: a
    # driver that splits the value on its own terms (libpq splits a conninfo on
    # whitespace, the mongo gem quotes "the database name" after a "/") quotes a
    # PART of it, which a whole-string replace never finds. Pieces shorter than
    # three characters are left alone - masking them would shred the message.
    def self.scrub_message(message, raw, replacement = nil)
      text = message.to_s
      raw = raw.to_s
      return text if raw.empty?

      text = text.gsub(raw) { replacement || redact(raw) }
      secrets = []
      span = password_span(raw)
      secrets << raw[span.first...span.last] if span
      begin
        secrets << new(raw).password
      rescue StandardError
        nil
      end
      mask_pieces(text, secrets.compact)
    rescue StandardError
      REDACTED
    end

    # Replace each secret, and each piece of it, with the marker. A piece is
    # only masked where it is not part of a longer word: the driver quotes it
    # cut at a delimiter, so it stands alone there - while "word" from a
    # password "my word" must not turn "password authentication failed" into
    # "pass*** authentication failed".
    def self.mask_pieces(text, secrets)
      pieces = secrets.flat_map { |s| [s, *s.split(%r{[\s/?#@:%]+})] }
      pieces.select { |p| p.length >= 3 }.uniq.sort_by { |p| -p.length }.each do |piece|
        text = text.gsub(standalone(piece), REDACTED)
      end
      text
    end
    private_class_method :mask_pieces

    # A pattern for +piece+ that does not match inside a longer alphanumeric
    # run (a boundary is only required on a side where the piece itself ends
    # in a letter or digit).
    def self.standalone(piece)
      left = piece.match?(/\A[[:alnum:]]/) ? "(?<![[:alnum:]])" : ""
      right = piece.match?(/[[:alnum:]]\z/) ? "(?![[:alnum:]])" : ""
      Regexp.new("#{left}#{Regexp.escape(piece)}#{right}")
    end
    private_class_method :standalone

    # Split what follows "scheme://" into [userinfo, host_and_rest]. Userinfo
    # ends at the LAST "@". REFUSES (generic message, nothing echoed, no cause)
    # when that "@" cannot be ending a userinfo - a "/", "?", "#" or a bracket
    # before the user name's end means it sits in the path or query - because
    # then the parser and the redaction would disagree about where the password
    # is. Shared by every URL parser in the framework.
    def self.split_userinfo(rest, label = "DatabaseUrl")
      at = rest.rindex("@")
      return [nil, rest] if at.nil?

      userinfo = rest[0, at]
      name = userinfo.partition(":").first
      raise ArgumentError.new("#{label}: #{AMBIGUOUS_URL}"), cause: nil if name.match?(%r{[/?#\[\]\\]})

      [userinfo, rest[(at + 1)..]]
    end

    # URI.parse of the userinfo-free remainder, or nil. Never raises, so a
    # caller's refusal cannot chain the InvalidURIError (which quotes it).
    def self.parse_hostpart(scheme, hostpart)
      URI.parse("#{scheme}://#{hostpart}")
    rescue URI::InvalidURIError
      nil
    end

    # [user, password] decoded from a userinfo, [nil, nil] without one. No
    # ":" means no password (nil); "user:" is an explicitly EMPTY one ("").
    def self.split_credentials(userinfo)
      return [nil, nil] if userinfo.nil?

      user, colon, pass = userinfo.partition(":")
      [decode_userinfo(user), colon.empty? ? nil : decode_userinfo(pass)]
    end

    # Percent-decode one userinfo part. A "%" that does not start a valid %XX
    # is a literal "%": URI.decode_www_form_component RAISES on it with the
    # value in the message, which put the password in the exception.
    def self.decode_userinfo(part)
      URI.decode_www_form_component(part.gsub(/%(?![0-9A-Fa-f]{2})/, "%25"))
    end

    # Characters a userinfo part cannot carry literally. Encoding them is what
    # lets a driver that re-parses the URL itself see the same password the
    # framework did, instead of cutting it at the first "/" or "@". ":" is
    # encoded too: the mongo gem refuses an unencoded ":" inside a password,
    # and every driver decodes %3A back to ":".
    USERINFO_UNSAFE = %r{[:/?#@\[\]\s"<>^`{|}\\]|%(?![0-9A-Fa-f]{2})}.freeze

    # Percent-encode a DECODED user name or password for a URL's userinfo:
    # every byte outside RFC 3986 "unreserved", "%" included, so the receiver
    # decodes exactly the original. #driver_url leaves an existing %XX alone
    # because its input is already a URL; this takes a raw credential.
    def self.encode_credential(value)
      value.to_s.gsub(/[^A-Za-z0-9\-._~]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join }
    end

    # The URL a DRIVER should be handed: identical to the input except that the
    # userinfo's unsafe characters are percent-encoded. A value that does not
    # parse, or needs nothing encoding, is returned unchanged.
    def self.driver_url(raw)
      text = raw.to_s
      prefix = text[URL_PREFIX]
      return text if prefix.nil? || text.start_with?("sqlite", "odbc:")

      userinfo, hostpart = split_userinfo(text[prefix.length..])
      return text if userinfo.nil?

      user, colon, pass = userinfo.partition(":")
      encode = ->(s) { s.gsub(USERINFO_UNSAFE) { |c| c.bytes.map { |b| format("%%%02X", b) }.join } }
      "#{prefix}#{encode.call(user)}#{colon}#{encode.call(pass)}@#{hostpart}"
    rescue StandardError
      text
    end

    # Raise unless +url+ is a URL whose userinfo a URI.parse-based client (the
    # redis gem, nats-pure) will read the way #password_span does: it has
    # "scheme://", URI.parse accepts it, and every "@" is accounted for by the
    # userinfo URI took. `redis://u:12?q@h` parses as host "u", port 12, query
    # "q@h" - a client would dial "u" and quote the password tail - so it is
    # refused. No "scheme://", or an "@" that cannot end the userinfo, gets the
    # generic message; a URL URI.parse merely rejects (a space, a bad port) is
    # named in its redacted form so it stays diagnosable. Never a cause.
    def self.assert_client_url!(url, label)
      text = url.to_s
      prefix = text[URL_PREFIX]
      raise ArgumentError.new("#{label}: #{AMBIGUOUS_URL}"), cause: nil if prefix.nil?

      split_userinfo(text[prefix.length..], label)
      parsed = begin
        URI.parse(text)
      rescue URI::InvalidURIError
        nil
      end
      raise ArgumentError.new("#{label}: #{redact(text)}"), cause: nil if parsed.nil?
      raise ArgumentError.new("#{label}: #{AMBIGUOUS_URL}"), cause: nil if text.count("@") != (parsed.userinfo ? 1 : 0)

      parsed
    end

    # The invalid-URL message, with the credential taken OUT.
    #
    # It still has to be diagnosable, so it keeps the scheme, the host, the port
    # as written (the usual fault) and the database name - only the password
    # becomes ***. When the value does not start with "scheme://" there is no
    # structure to trust, so the value is not shown at all and the message says
    # why.
    def self.invalid_url_error(url)
      text = url.to_s
      if text.match?(URL_PREFIX)
        "DatabaseUrl: Invalid URL format '#{redact(text)}' - expected " \
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

      # A sqlite URL names a FILE and carries no credentials. One that has a
      # user:password part anyway (`sqlite://u:secret@host/db`) would otherwise
      # become a filename - and a filename is printed in the connected line, in
      # the "resolves outside the project" refusal and in the driver's own
      # error. Refused, generically. The in-memory forms are not credentials.
      if !SQLITE_MEMORY_FORMS.include?(url) && self.class.password_span(url)
        raise ArgumentError.new("DatabaseUrl: a sqlite URL names a file and carries no " \
                                "user:password, but this one has one. The URL itself is not " \
                                "shown because it can contain a password."), cause: nil
      end

      @database = if SQLITE_MEMORY_FORMS.include?(url)
                    ":memory:"
                  elsif url.start_with?("sqlite:///")
                    strip_one_slash(url[("sqlite://".length)..])
                  elsif url.start_with?("sqlite://")
                    url[("sqlite://".length)..]
                  else
                    url[("sqlite:".length)..]
                  end
    end

    # GHSA-h2mr-m3v3-cq8c: no longer URI.parse on the whole value. URI.parse
    # accepts `postgres:/u:pw@h` (password in the path) and `u:12?q@h` (host
    # "u", port 12, password tail in the query), and its InvalidURIError quotes
    # the raw URL - which used to be kept as this error's `cause`. Now:
    #   * "scheme://" is required; anything else is refused, generically;
    #   * userinfo is split off at the LAST "@" by the shared #split_userinfo,
    #     which refuses an "@" that cannot be ending a userinfo;
    #   * only the userinfo-free remainder goes through URI.parse, and every
    #     refusal is raised with `cause: nil`.
    def parse_standard(url)
      match = url.match(URL_PREFIX)
      raise ArgumentError.new(self.class.invalid_url_error(url)), cause: nil if match.nil?

      scheme = match[1].downcase
      @engine = engine_for!(scheme)
      userinfo, hostpart = self.class.split_userinfo(url[match[0].length..])
      parsed = self.class.parse_hostpart(scheme, hostpart)
      # Raised OUTSIDE any rescue, and with cause: nil, so the InvalidURIError
      # (whose message holds the value) is never chained onto this one.
      raise ArgumentError.new(self.class.invalid_url_error(url)), cause: nil if parsed.nil?

      @host = parsed.host.to_s.empty? ? nil : parsed.host
      @port = parsed.port || DEFAULT_PORTS[@engine]
      @username, @password = self.class.split_credentials(userinfo)

      # Strip EXACTLY ONE leading slash - the URL path separator. Stripping every
      # slash turns the documented absolute Firebird form
      # `firebird://host:3050//var/lib/db.fdb` into the RELATIVE
      # `var/lib/db.fdb`. Verified against live Firebird 5.0.4: the driver takes
      # one or two leading slashes and rejects a relative path outright.
      database = strip_one_slash(parsed.path.to_s)
      @database = database.empty? && @engine == "mongodb" ? "tina4" : database
    end

    # The canonical engine for a scheme, or a refusal naming the scheme only.
    def engine_for!(scheme)
      engine = ENGINE_ALIASES[scheme]
      return engine if engine

      raise ArgumentError.new("DatabaseUrl: Unsupported database scheme '#{scheme}'. " \
                              "Supported: #{ENGINE_ALIASES.keys.join(', ')}"), cause: nil
    end
  end
end
