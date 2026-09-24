# frozen_string_literal: true

require "socket"
require "io/wait"
require "stringio"
require "json"

module Tina4
  # Tina4's own HTTP/1.1 server, on stdlib `socket` only.
  #
  # It replaced WEBrick (development) and Puma (production) as the default, the
  # way Python's built-in asyncio server and PHP's Tina4/Server.php are their
  # frameworks' defaults; Puma is still used when the APPLICATION bundles it
  # (ADR-0067). The app is any Rack-style object answering call(env) with
  # [status, headers, body], so Tina4::RackApp runs here unchanged and any Rack
  # server can still run Tina4.
  #
  # The wire rules are ADR-0068's, the same in every built-in Tina4 server:
  #
  #   TINA4_MAX_REQUEST_HEADER  head bytes before 431          (65536)
  #   TINA4_MAX_UPLOAD_SIZE     declared AND running body cap  (10485760)
  #   TINA4_REQUEST_TIMEOUT     silent seconds before 408      (30, 0 disables)
  #
  # A declared Content-Length over the cap is refused BEFORE any body byte is
  # read, the body is read in bounded chunks under a running count (chunked
  # included), malformed framing is 400, and every rejection has one shape:
  # a JSON {"error": ...} body with the canonical security headers and
  # Connection: close.
  #
  # tina4: one thread per connection, capped at MAX_CONNECTIONS (the accept
  # loop waits for a free slot). Swap for a reactor + worker pool if idle
  # keep-alive connections ever need to outnumber threads.
  class HttpServer
    DEFAULT_REQUEST_TIMEOUT = 30
    DEFAULT_MAX_REQUEST_HEADER = 65_536
    MAX_CONNECTIONS = 1024
    READ_SIZE = 16_384
    SOFTWARE = "tina4-server"

    # RFC 9110 token: what a header field name (and a method) may contain.
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    # A bare CR, LF or NUL anywhere in a request head is a smuggling attempt.
    ILLEGAL_HEAD_BYTE = /[\r\n\0]/
    # CR, LF or NUL in a RESPONSE header would split it into attacker-chosen
    # headers or a second response (ADR-0068). Such a header is never written.
    ILLEGAL_RESPONSE_VALUE = /[\r\n\0]/
    MALFORMED_HEAD = "Malformed request head"
    INVALID_LENGTH = "Invalid Content-Length"
    INVALID_ENCODING = "Invalid Transfer-Encoding"
    TIMED_OUT = "Request timed out before it was complete"
    # After a rejection, what the client is still sending is read and thrown
    # away for this long, so it sees the answer instead of a reset.
    LINGER_SECONDS = 2
    STATUSES_WITHOUT_BODY = [204, 304].freeze

    Listener = Struct.new(:socket, :app, :port)

    # An answer the server gives itself, before (or instead of) the app.
    class RequestRefused < StandardError
      attr_reader :status

      def initialize(status, message)
        super(message)
        @status = status
      end
    end

    # The peer went away; nothing to answer.
    class ClientGone < StandardError; end

    # The app handed the writer a header it must not write (ADR-0068 s2).
    class UnsafeHeader < StandardError; end

    attr_reader :request_timeout, :max_request_header, :max_upload_size

    def initialize(server_name:)
      @server_name = server_name
      @listeners = []
      @connections = {}
      @lock = Mutex.new
      @slot_freed = ConditionVariable.new
      @running = false
      @request_timeout = self.class.resolve_limit("TINA4_REQUEST_TIMEOUT", DEFAULT_REQUEST_TIMEOUT, zero_allowed: true)
      @max_request_header = self.class.resolve_limit("TINA4_MAX_REQUEST_HEADER", DEFAULT_MAX_REQUEST_HEADER)
      @max_upload_size = Tina4::Request.max_upload_size
    end

    # A numeric limit from the environment. A non-number or a negative value (or
    # 0 where 0 would switch the guard off) warns and falls back, because a typo
    # must never be the thing that disables a DoS guard. PHP Server::resolveLimit.
    def self.resolve_limit(name, default, zero_allowed: false)
      raw = ENV[name]
      return default if raw.nil? || raw.strip.empty?

      unless raw.strip.match?(/\A-?\d+\z/)
        Tina4::Log.warning("#{name}=#{raw} is not a number - using #{default}")
        return default
      end
      value = raw.to_i
      if value.negative? || (value.zero? && !zero_allowed)
        Tina4::Log.warning("#{name}=#{raw} is not a usable limit - using #{default}")
        return default
      end
      value
    end

    # Bind a listener. Raises on a failed bind (the caller decides whether that
    # is fatal - the main port is, a loopback sibling or the AI port is not).
    def listen(host, port, app)
      socket = TCPServer.new(host, port)
      @listeners << Listener.new(socket, app, port.to_s)
      socket
    end

    # Serve until #shutdown. Blocks on the FIRST listener's accept loop.
    def start
      @running = true
      others = @listeners.drop(1).map { |listener| Thread.new { accept_loop(listener) } }
      accept_loop(@listeners.first) if @listeners.first
      others.each { |thread| thread.join(1) }
    end

    # Stop accepting: close every listener (a new connection is then REFUSED by
    # the kernel) and close keep-alive connections waiting for their next
    # request. A request already being served runs to completion; draining it is
    # Tina4::Shutdown's job (TINA4_SHUTDOWN_TIMEOUT).
    def shutdown
      @running = false
      @listeners.each do |listener|
        listener.socket.close
      rescue IOError, SystemCallError
        # already closed
      end
      @lock.synchronize do
        @connections.each do |socket, state|
          next unless state == :idle

          @connections[socket] = :closed
          begin
            socket.close
          rescue IOError, SystemCallError
            # already closed
          end
        end
        @slot_freed.broadcast
      end
    end

    def running?
      @running
    end

    private

    def accept_loop(listener)
      while @running
        wait_for_slot
        break unless @running

        begin
          socket = listener.socket.accept
        rescue IOError, Errno::EBADF, Errno::EINVAL
          break # closed by #shutdown
        rescue Errno::ECONNABORTED, Errno::EPROTO, Errno::ECONNRESET
          next
        rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM => e
          Tina4::Log.warning("accept failed (#{e.class}), backing off")
          sleep 0.1
          next
        end
        @lock.synchronize { @connections[socket] = :idle }
        thread = Thread.new(socket, listener) { |client, owner| serve_connection(client, owner) }
        thread.report_on_exception = false
      end
    end

    def wait_for_slot
      @lock.synchronize do
        @slot_freed.wait(@lock, 1) while @running && @connections.size >= MAX_CONNECTIONS
      end
    end

    def serve_connection(socket, listener)
      hijacked = false
      begin
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      rescue SystemCallError, IOError
        # not fatal - a unix-domain or odd socket
      end
      peer = peer_address(socket)
      buffer = +"".b
      loop do
        outcome = serve_request(socket, buffer, listener, peer)
        hijacked = outcome == :hijacked
        break unless outcome == :keep_alive && @running
      end
    rescue ClientGone, IOError, SystemCallError
      # the peer vanished, or #shutdown closed an idle keep-alive connection
    rescue StandardError => e
      Tina4::Log.error("HTTP connection error: #{e.class}: #{e.message}")
    ensure
      unless hijacked
        begin
          socket.close
        rescue IOError, SystemCallError
          # already closed
        end
      end
      @lock.synchronize do
        @connections.delete(socket)
        @slot_freed.signal
      end
    end

    # The raw TCP peer. Never empty: an empty REMOTE_ADDR would count as loopback
    # in the dev gates, so a socket that cannot name its peer is not served.
    def peer_address(socket)
      address = socket.remote_address.ip_address.to_s
      raise ClientGone if address.empty?

      address.start_with?("::ffff:") && address.include?(".") ? address.delete_prefix("::ffff:") : address
    end

    # Serve ONE request off the connection. Returns :keep_alive, :close or
    # :hijacked.
    def serve_request(socket, buffer, listener, peer)
      head = read_head(socket, buffer)
      return :close if head.nil?

      method, target, version, headers = parse_head(head)
      body_bytes = read_body(socket, buffer, headers, version)
      env = build_env(method, target, version, headers, body_bytes, listener, peer)
      keep_alive = keep_alive?(version, headers)

      if Tina4::Shutdown.shutting_down?
        send_error(socket, 503, "Service shutting down")
        return :close
      end

      hijacked = false
      env["rack.hijack?"] = true
      env["rack.hijack"] = lambda do
        hijacked = true
        env["rack.hijack_io"] = socket
      end

      Tina4::Shutdown.track_request do
        status, response_headers, body = call_app(listener.app, env)
        if hijacked
          @lock.synchronize { @connections.delete(socket) }
          next
        end
        keep_alive = write_response(socket, status, response_headers, body,
                                    head_request: method == "HEAD", keep_alive: keep_alive && @running,
                                    http10: version == "HTTP/1.0")
      end
      return :hijacked if hijacked

      keep_alive ? :keep_alive : :close
    rescue RequestRefused => e
      send_error(socket, e.status, e.message)
      :close
    rescue UnsafeHeader => e
      # Nothing of that response has been written; it is replaced whole.
      Tina4::Log.error("Refused to write response header #{e.message}: " \
                       "a header name must be a token and a value may not contain CR, LF or NUL")
      send_error(socket, 500, "Invalid response header")
      :close
    end

    # A Rack app that raises gets a 500 rather than a dropped connection.
    # (Tina4::RackApp rescues its own errors; this is for any other app.)
    def call_app(app, env)
      app.call(env)
    rescue StandardError => e
      Tina4::Log.error("Unhandled application error: #{e.class}: #{e.message}")
      body = JSON.generate({ "error" => "Internal Server Error" })
      [500, { "content-type" => "application/json" }, [body]]
    end

    # ── reading ─────────────────────────────────────────────────────────────

    # Read up to the blank line that ends the head. nil when the client closed
    # (or went idle) before sending anything - that is not a request, so it
    # gets no answer. A client that STARTS a request and stalls gets 408.
    def read_head(socket, buffer)
      # RFC 9112 s2.2: ignore empty lines before a request line.
      buffer.slice!(0, 2) while buffer.start_with?("\r\n")

      if buffer.empty?
        mark(socket, :idle)
        return nil unless wait_for_bytes(socket, buffer, idle: true)

        buffer.slice!(0, 2) while buffer.start_with?("\r\n")
      end
      mark(socket, :busy)

      deadline = @request_timeout.positive? ? monotonic + @request_timeout : nil
      until (head_end = buffer.index("\r\n\r\n"))
        if buffer.bytesize > @max_request_header
          raise RequestRefused.new(431, header_cap_message)
        end
        raise RequestRefused.new(408, TIMED_OUT) unless
          wait_for_bytes(socket, buffer, deadline: deadline)
      end
      raise RequestRefused.new(431, header_cap_message) if head_end > @max_request_header

      buffer.slice!(0, head_end + 4).byteslice(0, head_end)
    end

    # Append whatever the socket has. false on timeout; ClientGone on EOF
    # mid-request; nil-safe EOF on an idle connection returns false.
    def wait_for_bytes(socket, buffer, idle: false, deadline: nil)
      timeout = if idle
                  @request_timeout.positive? ? @request_timeout : nil
                elsif deadline
                  [deadline - monotonic, 0].max
                end
      return false unless socket.wait_readable(timeout)

      buffer << socket.read_nonblock(READ_SIZE)
      true
    rescue IO::WaitReadable
      true
    rescue EOFError, Errno::ECONNRESET
      raise ClientGone unless idle

      false
    end

    def header_cap_message
      "Request header fields exceed TINA4_MAX_REQUEST_HEADER (#{@max_request_header} bytes)"
    end

    # The head is split on CRLF, so any CR, LF or NUL left inside a line is a
    # bare one. A name must be a token, which also refuses obs-fold (a
    # continuation line starting with SP/HTAB, RFC 9112 s5.2).
    def parse_head(head)
      lines = head.split("\r\n", -1)
      raise RequestRefused.new(400, MALFORMED_HEAD) if lines.any? { |line| line.match?(ILLEGAL_HEAD_BYTE) }

      method, target, version, extra = lines.shift.to_s.split(" ", -1)
      unless extra.nil? && method.to_s.match?(TOKEN) && target && !target.empty? &&
             !target.match?(/[\x00-\x20\x7F]/) && %w[HTTP/1.1 HTTP/1.0].include?(version)
        raise RequestRefused.new(400, MALFORMED_HEAD)
      end

      headers = lines.map do |line|
        name, value = line.split(":", 2)
        raise RequestRefused.new(400, MALFORMED_HEAD) if value.nil? || !name.match?(TOKEN)

        [name.downcase, value.strip]
      end
      [method, target, version, headers]
    end

    def header_values(headers, name)
      headers.filter_map { |key, value| value if key == name }
    end

    def read_body(socket, buffer, headers, version)
      lengths = header_values(headers, "content-length")
      encodings = header_values(headers, "transfer-encoding")

      unless encodings.empty?
        # Exactly "chunked", and never alongside Content-Length (smuggling).
        unless lengths.empty? && encodings.length == 1 && encodings.first.casecmp?("chunked")
          raise RequestRefused.new(400, INVALID_ENCODING)
        end

        send_continue(socket, headers, version)
        return read_chunked(socket, buffer)
      end
      return +"".b if lengths.empty?

      # Exactly one Content-Length, all digits. Two are refused even when they
      # agree (ADR-0068): a proxy in front may pick the other one.
      raise RequestRefused.new(400, INVALID_LENGTH) unless lengths.length == 1 && lengths.first.match?(/\A\d+\z/)

      declared = lengths.first.to_i
      # Refused on the DECLARED length, before one body byte is read.
      raise RequestRefused.new(413, upload_cap_message(declared)) if declared > @max_upload_size

      send_continue(socket, headers, version)
      read_exactly(socket, buffer, declared)
    end

    def upload_cap_message(bytes)
      "Request body (#{bytes} bytes) exceeds TINA4_MAX_UPLOAD_SIZE (#{@max_upload_size} bytes)"
    end

    # Expect: 100-continue - the client is waiting for permission before it
    # sends the body. Only reached when the declared size already passed.
    def send_continue(socket, headers, version)
      return unless version == "HTTP/1.1"
      return unless header_values(headers, "expect").any? { |value| value.casecmp?("100-continue") }

      write_fully(socket, "HTTP/1.1 100 Continue\r\n\r\n")
    end

    # Body reads use an INACTIVITY timeout: a large upload on a slow link keeps
    # going while bytes arrive; a peer that stops sending gets 408.
    def read_exactly(socket, buffer, length)
      fill(socket, buffer) while buffer.bytesize < length
      buffer.slice!(0, length)
    end

    def read_line(socket, buffer, limit)
      until (line_end = buffer.index("\r\n"))
        raise RequestRefused.new(400, INVALID_ENCODING) if buffer.bytesize > limit

        fill(socket, buffer)
      end
      buffer.slice!(0, line_end + 2).byteslice(0, line_end)
    end

    def fill(socket, buffer)
      deadline = @request_timeout.positive? ? monotonic + @request_timeout : nil
      return if wait_for_bytes(socket, buffer, deadline: deadline)

      raise RequestRefused.new(408, TIMED_OUT)
    end

    def read_chunked(socket, buffer)
      body = +"".b
      loop do
        size_line = read_line(socket, buffer, 1024)
        size_text = size_line.split(";", 2).first.to_s.strip
        raise RequestRefused.new(400, INVALID_ENCODING) unless size_text.match?(/\A\h{1,16}\z/)

        size = size_text.to_i(16)
        break if size.zero?

        # The running counter: refuse the moment the ACTUAL bytes pass the cap.
        if body.bytesize + size > @max_upload_size
          raise RequestRefused.new(413, upload_cap_message(body.bytesize + size))
        end

        body << read_exactly(socket, buffer, size)
        raise RequestRefused.new(400, INVALID_ENCODING) unless read_exactly(socket, buffer, 2) == "\r\n"
      end
      # Trailer section: header lines up to an empty line, bounded like headers.
      trailer_bytes = 0
      loop do
        line = read_line(socket, buffer, @max_request_header)
        break if line.empty?

        trailer_bytes += line.bytesize
        raise RequestRefused.new(431, header_cap_message) if trailer_bytes > @max_request_header
      end
      body
    end

    def keep_alive?(version, headers)
      tokens = header_values(headers, "connection").join(",").downcase.split(",").map(&:strip)
      return false if tokens.include?("close")

      version == "HTTP/1.1" || tokens.include?("keep-alive")
    end

    # ── the Rack env ────────────────────────────────────────────────────────

    def build_env(method, target, version, headers, body_bytes, listener, peer)
      target = absolute_form_path(target)
      raw_path, query = target.split("?", 2)
      path_info = normalize_path(percent_decode(raw_path.to_s))

      env = {
        "REQUEST_METHOD" => method,
        "SCRIPT_NAME" => "",
        "PATH_INFO" => path_info,
        "REQUEST_PATH" => raw_path.to_s,
        "REQUEST_URI" => target,
        "QUERY_STRING" => query.to_s,
        "SERVER_NAME" => @server_name,
        "SERVER_PORT" => listener.port,
        "SERVER_PROTOCOL" => version,
        "HTTP_VERSION" => version,
        "SERVER_SOFTWARE" => SOFTWARE,
        "REMOTE_ADDR" => peer,
        "CONTENT_TYPE" => header_values(headers, "content-type").last.to_s,
        "CONTENT_LENGTH" => body_bytes.bytesize.to_s,
        "rack.input" => StringIO.new(body_bytes),
        "rack.errors" => $stderr,
        "rack.url_scheme" => "http",
        "rack.version" => [1, 3],
        "rack.multithread" => true,
        "rack.multiprocess" => false,
        "rack.run_once" => false
      }

      # A dashed name wins over an underscored one that maps to the same env
      # key, whatever the order: "X_Forwarded_For" must not clobber a proxy's
      # X-Forwarded-For.
      dashed, underscored = headers.partition { |name, _| !name.include?("_") }
      (dashed + underscored).each do |name, value|
        next if name == "content-type" || name == "content-length" || name == "transfer-encoding"

        key = "HTTP_#{name.upcase.tr('-', '_')}"
        if name.include?("_") && dashed.any? { |other, _| "HTTP_#{other.upcase.tr('-', '_')}" == key }
          next
        end

        env[key] = env.key?(key) ? "#{env[key]}#{name == 'cookie' ? '; ' : ', '}#{value}" : value
      end
      env
    end

    def absolute_form_path(target)
      return target unless target.match?(%r{\Ahttps?://}i)

      path = target.sub(%r{\Ahttps?://[^/?]*}i, "")
      path.start_with?("/") ? path : "/#{path}"
    end

    def percent_decode(path)
      path.b.gsub(/%\h\h/) { |escape| escape[1, 2].hex.chr }
    end

    # The same normalisation the previous built-in server (WEBrick) applied
    # before routing: collapse "//", resolve "." and ".." segments, and refuse a
    # path that climbs above the root or carries a NUL.
    def normalize_path(path)
      raise RequestRefused.new(400, MALFORMED_HEAD) if path.include?("\0")
      return path if path == "*"
      raise RequestRefused.new(400, MALFORMED_HEAD) unless path.start_with?("/")

      normalized = path.gsub(%r{/+}, "/")
      nil while normalized.sub!(%r{/\.(?:/|\z)}, "/")
      nil while normalized.sub!(%r{/(?!\.\./)[^/]+/\.\.(?:/|\z)}, "/")
      raise RequestRefused.new(400, MALFORMED_HEAD) if normalized.match?(%r{/\.\.(?:/|\z)})

      normalized
    end

    # ── writing ─────────────────────────────────────────────────────────────

    # Returns whether the connection may be reused.
    def write_response(socket, status, headers, body, head_request:, keep_alive:, http10:)
      status = status.to_i
      buffered = body.is_a?(Array)
      no_body = head_request || STATUSES_WITHOUT_BODY.include?(status) || status < 200
      lines = ["HTTP/1.1 #{status} #{Tina4.http_reason(status)}"]
      declared_length = nil

      header_lines(headers).each do |name, value|
        lowered = name.downcase
        case lowered
        when "connection"
          keep_alive = false if value.downcase.include?("close")
          next
        when "transfer-encoding"
          next # framing is the server's, never the app's
        when "content-length"
          declared_length = value
          next
        end
        lines << "#{name}: #{value}"
      end

      chunks = buffered ? body.map(&:to_s) : nil
      if status < 200 || STATUSES_WITHOUT_BODY.include?(status)
        # 304 may state the representation's length; 1xx and 204 never do.
        lines << "content-length: #{declared_length}" if declared_length && status == 304
      elsif buffered
        # HEAD reports the length the GET would have sent (the app computed it).
        length_value = head_request && declared_length ? declared_length : chunks.sum(&:bytesize).to_s
        lines << "content-length: #{length_value}"
      elsif declared_length
        lines << "content-length: #{declared_length}"
      else
        # A stream of unknown length is delimited by closing the connection
        # (PHP streamToClient / Python's built-in server do the same).
        keep_alive = false unless no_body
      end

      if keep_alive
        lines << "connection: keep-alive" if http10
      else
        lines << "connection: close"
      end

      head = "#{lines.join("\r\n")}\r\n\r\n".b
      if no_body
        write_fully(socket, head)
      elsif buffered
        payload = chunks.sum(&:bytesize) <= 65_536 ? head + chunks.join.b : nil
        if payload
          write_fully(socket, payload)
        else
          write_fully(socket, head)
          chunks.each { |chunk| write_fully(socket, chunk.b) }
        end
      else
        write_fully(socket, head)
        body.each { |chunk| write_fully(socket, chunk.to_s.b) unless chunk.to_s.empty? }
      end
      keep_alive
    ensure
      body.close if body.respond_to?(:close)
    end

    # Every [name, value] line to write, checked BEFORE any byte goes out. An
    # Array value (Rack 3) or a "\n"-joined Set-Cookie (Rack 2, and
    # Tina4::Response#to_rack) is one line per element. A name that is not a
    # token, or a value carrying CR, LF or NUL, raises UnsafeHeader (ADR-0068):
    # it would let the value choose its own headers - or a second response.
    # Response#header refuses these at the call site already; this catches a
    # header appended to the hash directly.
    def header_lines(headers)
      headers.flat_map do |name, value|
        name = name.to_s
        next [] if name.start_with?("rack.")

        values = if value.is_a?(Array)
                   value.map(&:to_s)
                 elsif name.casecmp?("set-cookie")
                   value.to_s.split("\n")
                 else
                   [value.to_s]
                 end
        values.map do |single|
          raise UnsafeHeader, JSON.generate(name) if !name.match?(TOKEN) || single.match?(ILLEGAL_RESPONSE_VALUE)

          [name, single]
        end
      end
    end

    # Write every byte, or give up when the peer stops reading for
    # TINA4_REQUEST_TIMEOUT (a slow reader must not hold a thread forever).
    def write_fully(socket, data)
      data = data.b
      offset = 0
      while offset < data.bytesize
        begin
          offset += socket.write_nonblock(data.byteslice(offset, data.bytesize - offset))
        rescue IO::WaitWritable
          timeout = @request_timeout.positive? ? @request_timeout : nil
          raise ClientGone unless socket.wait_writable(timeout)
        end
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      raise ClientGone
    end

    # A transport rejection, in ADR-0068's one shape: the JSON {"error": ...}
    # body, the canonical security headers (no HSTS - the scheme is not known
    # yet) and Connection: close. The close is a lingering one - stop writing,
    # throw away what the client is still sending for up to LINGER_SECONDS -
    # so a client mid-upload reads the answer instead of a reset.
    def send_error(socket, status, message)
      body = JSON.generate({ "error" => message })
      lines = ["HTTP/1.1 #{status} #{Tina4.http_reason(status)}",
               "Content-Type: application/json",
               "Content-Length: #{body.bytesize}",
               "Connection: close"]
      Tina4::SecurityHeadersMiddleware.canonical_headers.each do |name, value|
        lines << "#{name}: #{value}" unless value.to_s.match?(ILLEGAL_RESPONSE_VALUE)
      end
      write_fully(socket, "#{lines.join("\r\n")}\r\n\r\n#{body}")
      socket.close_write
      deadline = monotonic + LINGER_SECONDS
      discard = +"".b # one reused buffer: draining must not allocate per read
      while (remaining = deadline - monotonic).positive? && socket.wait_readable(remaining)
        socket.read_nonblock(READ_SIZE, discard)
      end
    rescue ClientGone, IOError, SystemCallError, IO::WaitReadable
      # the peer is gone - nothing more to say
    end

    def mark(socket, state)
      @lock.synchronize do
        raise ClientGone if @connections[socket] == :closed

        @connections[socket] = state
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
