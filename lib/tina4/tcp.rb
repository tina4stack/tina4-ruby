# frozen_string_literal: true

# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

require "socket"

module Tina4
  # Raw TCP service — a user-facing, non-HTTP, long-lived binary TCP listener.
  #
  # Governed by ADR-0102 (feature 142), and the Python reference
  # tina4_python/tcp. A Tina4 app exposes its own protocol — a GPS/GPRS
  # car-tracker gateway (GT06/TK103/Concox/Teltonika) is the driving case — in
  # the SAME process as its HTTP dashboard, reusing config, logging, ORM and
  # queue.
  #
  #   svc = Tina4::Tcp.service(5023, idle_timeout: 0, max_connections: 5000)
  #   svc.on_data do |conn, data|
  #     frame = parse(data)                 # the APP frames the stream
  #     conn.identify(frame.imei) if frame.login?
  #     conn.send(ack_for(frame))           # ACK on the same socket
  #   end
  #
  #   # server -> device push from an HTTP route:
  #   Tina4::Tcp.get.send_to(imei, build_command("set_interval", 30))
  #
  # Ruby's thread-per-connection model satisfies D1 (in-process): the acceptor
  # thread runs in the SAME VM as the HTTP server, so the device gateway and its
  # dashboard share one process. The framework owns the socket hard-parts:
  # lifecycle, max_connections refusal, an idle reaper (default OFF for
  # long-lived device sockets), graceful-shutdown drain, bounded write
  # backpressure, and single-owner bind under N workers.
  #
  # Non-goals in v1 (ADR-0102): no CRC/length framing helper beyond on_line, no
  # TLS termination, no UDP, no replacement for the WebSocket surface.

  # One live TCP connection — the uniform connection object (ADR-0102 D5). The
  # SAME surface exists in all four frameworks so the primitive ports.
  class TcpConnection
    # The raw TCP peer address ("127.0.0.1:54321"), never a forwarded header.
    attr_reader :remote_addr
    # Per-connection mutable state bag — the app's parse buffer, auth flag.
    attr_accessor :context
    attr_reader :socket
    # Stable registry key: the fd number captured at construction (see below).
    attr_reader :fileno

    def initialize(socket, service, remote_addr)
      @socket = socket
      # Cache the fd number now: once the socket is closed, #fileno raises
      # IOError, and the registry still needs a stable key to remove by.
      @fileno = begin
        socket.fileno
      rescue IOError, SystemCallError
        nil
      end
      @service = service
      @remote_addr = remote_addr
      @id = nil                 # the registry id (IMEI), nil until identify
      @context = {}
      @closed = false
      @close_fired = false
      @last_activity = monotonic
      @pending = +"".b
      @line_buffer = +"".b
      @write_lock = Mutex.new
    end

    # The registry id (the IMEI), or nil until identify is called.
    def id
      @id
    end

    def closed?
      @closed
    end

    def last_activity
      @last_activity
    end

    def touch
      @last_activity = monotonic
    end

    # Accessors the service's reader loop uses for on_line buffering.
    def line_buffer
      @line_buffer
    end

    def line_buffer=(value)
      @line_buffer = value
    end

    # Register this live connection under an app-chosen id (the IMEI). A second
    # connection identifying with the same id SUPERSEDES the first in the
    # registry — exactly a device that dropped and reconnected.
    def identify(app_id)
      @id = app_id.to_s
      @service.register_id(@id, self)
      self
    end

    # Write raw bytes to THIS socket. Returns true when queued/sent, false when
    # the connection is closed or dropped for backpressure. A stalled reader
    # (never draining) is bounded: once more than the service's max_backlog
    # bytes are outstanding, the connection is dropped rather than buffered
    # without end (mirrors the WebSocket TINA4_WS_MAX_BACKLOG posture).
    def send(data)
      return false if @closed

      bytes = data.to_s.dup.force_encoding(Encoding::BINARY)
      overflow = false
      @write_lock.synchronize do
        @pending << bytes
        flush_pending
        limit = @service.max_backlog
        overflow = (limit.positive? && @pending.bytesize > limit)
      end
      return false if @closed

      if overflow
        Tina4::Log.warning(
          "tcp_service '#{@service.name}': dropping a stalled reader — " \
          "#{@pending.bytesize} bytes queued exceeds the #{@service.max_backlog}-byte backlog limit"
        )
        close
        return false
      end
      true
    end

    # Flush the per-connection queue without blocking. Caller holds @write_lock.
    def flush_pending
      return if @socket.nil? || @pending.empty?

      until @pending.empty?
        written = @socket.write_nonblock(@pending, exception: false)
        break if written == :wait_writable

        @pending = @pending.byteslice(written..) || +"".b
      end
    rescue IOError, SystemCallError
      @closed = true
      close_socket
    end

    # Opportunistic flush from the reader loop (acquires the lock).
    def try_flush
      return if @closed

      @write_lock.synchronize { flush_pending }
    end

    # Close this connection. on_close fires exactly once (from the service's
    # removal path) and the registry entry is removed.
    def close
      return if @closed

      @closed = true
      close_socket
      @service.remove(self)
    end

    # Fire on_close exactly once. Called by the service when the connection
    # leaves (peer close, server close, reap, or drain).
    def fire_close
      return if @close_fired

      @close_fired = true
      @closed = true
      handler = @service.callback(:on_close)
      return if handler.nil?

      begin
        handler.call(self)
      rescue StandardError => e
        Tina4::Log.error("tcp_service '#{@service.name}' on_close error: #{e.message}")
      end
    end

    private

    def close_socket
      # Shut the socket down before closing so the peer sees EOF immediately.
      # A plain close is enough on macOS, but on Linux the FIN can be deferred
      # while the reader thread still holds the fd in IO.select, so the client
      # never observes end-of-stream. shutdown(SHUT_RDWR) forces it.
      @socket&.shutdown(Socket::SHUT_RDWR)
    rescue IOError, SystemCallError
      nil
    ensure
      begin
        @socket&.close
      rescue IOError, SystemCallError
        nil
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # A named raw TCP listener and its connection registry (ADR-0102).
  class TcpService
    READ_CHUNK = 65_536

    attr_reader :name, :port

    def initialize(port, name: "default", on_connect: nil, on_data: nil,
                   on_close: nil, on_line: nil, idle_timeout: 0,
                   max_connections: nil, max_backlog: nil, &block)
      @port = Integer(port)
      @name = name.to_s
      @callbacks = {
        on_connect: on_connect,
        on_data: on_data || block, # a bare block is the on_data handler
        on_close: on_close,
        on_line: on_line
      }
      # Default OFF: tracker sockets are deliberately long-lived and mostly idle
      # between location packets, so a default reaper would kill healthy devices.
      @idle_timeout = idle_timeout.to_f
      @max_connections = max_connections.nil? ? nil : Integer(max_connections)
      @max_backlog = self.class.resolve_max_backlog(max_backlog)

      @connections = {}     # socket.fileno => TcpConnection
      @by_id = {}           # app_id => TcpConnection
      @mutex = Mutex.new
      @server = nil
      @owner = false
      @bound_port = nil
      @acceptor = nil
      @readers = {}         # object_id => Thread
      @running = false
    end

    def self.resolve_max_backlog(explicit)
      default = 1 << 20 # 1 MiB
      return (explicit.to_i.positive? ? explicit.to_i : default) unless explicit.nil?

      raw = (ENV["TINA4_TCP_MAX_BACKLOG"] || "").strip
      return default if raw.empty?

      value = raw.to_i
      value.positive? ? value : default
    end

    def max_backlog
      @max_backlog
    end

    def callback(event)
      @callbacks[event]
    end

    def owner?
      @owner
    end

    def bound_port
      @bound_port || @port
    end

    def count
      @mutex.synchronize { @connections.size }
    end

    # ── Decorator-style setters (parity with the Python @svc.on_* handlers) ──

    def on_connect(&block) = set_callback(:on_connect, block)
    def on_data(&block) = set_callback(:on_data, block)
    def on_close(&block) = set_callback(:on_close, block)
    def on_line(&block) = set_callback(:on_line, block)

    # ── Registry (D4 — server -> device push) ──────────────────────────────

    def register_id(app_id, conn)
      @mutex.synchronize { @by_id[app_id] = conn } # supersede: the live one wins
    end

    # The live connection for an app id, or nil if unknown or closed.
    def connection(app_id)
      conn = @mutex.synchronize { @by_id[app_id.to_s] }
      return nil if conn.nil? || conn.closed?

      conn
    end

    # Write bytes to exactly the connection identified by app_id. A send to an
    # unknown or closed id is a NO-OP that returns false — never a raise.
    def send_to(app_id, data)
      conn = connection(app_id)
      return false if conn.nil?

      conn.send(data)
    end

    # Write bytes to every live connection. Returns how many received it.
    def broadcast(data)
      conns = @mutex.synchronize { @connections.values.dup }
      conns.count { |conn| conn.send(data) }
    end

    # ── Lifecycle ────────────────────────────────────────────────────────────

    # Bind the listener on host:port and start accepting on a dedicated thread.
    # SO_REUSEPORT is OFF, so under a multi-worker deployment exactly ONE worker
    # wins the bind; a worker that finds the port already bound skips silently
    # (single-owner, D1). Returns true when THIS call bound the port.
    def start(host = "0.0.0.0")
      return @owner unless @server.nil?

      begin
        @server = TCPServer.new(host, @port)
      rescue Errno::EADDRINUSE, Errno::EADDRNOTAVAIL => e
        @owner = false
        Tina4::Log.info(
          "tcp_service '#{@name}' port #{@port} is already bound by another worker — " \
          "single-owner, this worker will not bind (#{e.class})"
        )
        return false
      end
      @owner = true
      @running = true
      @bound_port = @server.addr[1]
      Tina4::Log.info("tcp_service '#{@name}' listening on #{host}:#{@bound_port}")
      @acceptor = Thread.new { accept_loop }
      true
    end

    # Stop accepting new connections (close the listener). Live connections stay.
    def stop_accepting
      @running = false
      srv = @server
      @server = nil
      srv&.close
    rescue IOError, SystemCallError
      nil
    end

    # Close every live connection (firing on_close) and release the listener.
    def drain(timeout: 5.0)
      stop_accepting
      @acceptor&.join(timeout)
      conns = @mutex.synchronize { @connections.values.dup }
      conns.each(&:close)
      readers = @mutex.synchronize { @readers.values.dup }
      deadline = monotonic + timeout
      readers.each do |thread|
        remaining = deadline - monotonic
        thread.join(remaining.positive? ? remaining : 0)
      end
    end

    alias stop drain

    # Remove a connection from the registry and fire on_close exactly once.
    # Called by TcpConnection#close and by the reader loop on EOF.
    def remove(conn)
      tracked = false
      @mutex.synchronize do
        key = conn.fileno
        if key && @connections[key].equal?(conn)
          @connections.delete(key)
          tracked = true
        else
          found = @connections.key(conn)
          unless found.nil?
            @connections.delete(found)
            tracked = true
          end
        end
        # Only drop the id when THIS connection still owns it; a newer
        # connection that superseded it keeps the id.
        @by_id.delete(conn.id) if conn.id && @by_id[conn.id].equal?(conn)
      end
      conn.fire_close if tracked
    end

    private

    def set_callback(event, block)
      @callbacks[event] = block if block
      self
    end

    def accept_loop
      while @running
        begin
          socket = @server&.accept
        rescue IOError, Errno::EBADF, Errno::ECONNABORTED
          break # listener closed by stop_accepting
        end
        break if socket.nil?

        handle_accept(socket)
      end
    rescue StandardError => e
      Tina4::Log.error("tcp_service '#{@name}' accept loop error: #{e.message}")
    end

    def handle_accept(socket)
      # Refuse past the limit BEFORE the connection joins the registry.
      over_limit = @mutex.synchronize do
        !@max_connections.nil? && @connections.size >= @max_connections
      end
      if over_limit
        socket.close rescue nil
        return
      end

      conn = TcpConnection.new(socket, self, peer_address(socket))
      @mutex.synchronize { @connections[conn.fileno] = conn }

      fire(:on_connect, conn)

      reader = Thread.new { reader_loop(conn) }
      @mutex.synchronize { @readers[conn.object_id] = reader }
    end

    def reader_loop(conn)
      socket = conn.socket
      line_handler = @callbacks[:on_line]
      sweep = @idle_timeout.positive? ? [@idle_timeout / 2.0, 1.0].min.clamp(0.05, 1.0) : nil
      loop do
        break if conn.closed?

        ready = IO.select([socket], nil, nil, sweep)
        if ready.nil?
          # Idle sweep: close a connection silent past the timeout.
          if @idle_timeout.positive? && (monotonic - conn.last_activity) >= @idle_timeout
            conn.close
            break
          end
          next
        end

        data = socket.read_nonblock(READ_CHUNK, exception: false)
        next if data == :wait_readable
        break if data.nil? # EOF — peer closed

        conn.touch
        dispatch_data(conn, data, line_handler)
        conn.try_flush
      end
    rescue IOError, EOFError, Errno::ECONNRESET, Errno::EBADF
      nil
    rescue StandardError => e
      Tina4::Log.error("tcp_service '#{@name}' handler error: #{e.message}")
    ensure
      @mutex.synchronize { @readers.delete(conn.object_id) }
      remove(conn)
    end

    def dispatch_data(conn, data, line_handler)
      on_data = @callbacks[:on_data]
      # Raw bytes, exactly as received — never newline-split, never decoded.
      if on_data
        begin
          on_data.call(conn, data)
        rescue StandardError => e
          Tina4::Log.error("tcp_service '#{@name}' on_data error: #{e.message}")
        end
      end

      return unless line_handler

      buffer = conn.line_buffer
      buffer << data
      while (index = buffer.index("\n"))
        line = buffer.byteslice(0, index)
        buffer = buffer.byteslice(index + 1..) || +"".b
        line = line.chomp("\r")
        begin
          line_handler.call(conn, line)
        rescue StandardError => e
          Tina4::Log.error("tcp_service '#{@name}' on_line error: #{e.message}")
        end
      end
      conn.line_buffer = buffer
    end

    def fire(event, conn)
      handler = @callbacks[event]
      return if handler.nil?

      begin
        handler.call(conn)
      rescue StandardError => e
        Tina4::Log.error("tcp_service '#{@name}' #{event} error: #{e.message}")
      end
    end

    def peer_address(socket)
      addr = socket.peeraddr(false)
      "#{addr[3]}:#{addr[1]}"
    rescue StandardError
      ""
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # Registry facade and the server-driven lifecycle hooks.
  module Tcp
    @services = {}
    @mutex = Mutex.new

    class << self
      # Register a named raw TCP service; the server binds it on boot (D1).
      def service(port, **options, &block)
        name = (options[:name] || "default").to_s
        svc = TcpService.new(port, **options, &block)
        @mutex.synchronize { @services[name] = svc }
        svc
      end

      # The registry for a named service, for server -> device push. Raises for
      # an unknown service name — a programming error, unlike a send to an
      # unknown device id, which is a runtime no-op.
      def get(name = "default")
        svc = @mutex.synchronize { @services[name.to_s] }
        return svc unless svc.nil?

        known = @services.keys.empty? ? "(none registered)" : @services.keys.join(", ")
        raise KeyError, "no tcp_service named '#{name}' is registered; known services: #{known}"
      end

      def registered
        @mutex.synchronize { @services.values.dup }
      end

      # Drop every registered service (test isolation; not used in production).
      def clear_registry
        @mutex.synchronize { @services = {} }
      end

      # Start every registered service on boot (called by the web server).
      def start_all(host = "0.0.0.0")
        registered.each do |svc|
          svc.start(host)
        rescue StandardError => e
          Tina4::Log.error("tcp_service '#{svc.name}' failed to start: #{e.message}")
        end
      end

      # Stop every service accepting (shutdown step 1).
      def stop_accepting_all
        registered.each do |svc|
          svc.stop_accepting
        rescue StandardError => e
          Tina4::Log.error("tcp_service '#{svc.name}' stop-accepting failed: #{e.message}")
        end
      end

      # Drain and release every service's connections (shutdown drain step).
      def drain_all(timeout: 5.0)
        registered.each do |svc|
          svc.drain(timeout: timeout)
        rescue StandardError => e
          Tina4::Log.error("tcp_service '#{svc.name}' drain failed: #{e.message}")
        end
      end
    end
  end
end
