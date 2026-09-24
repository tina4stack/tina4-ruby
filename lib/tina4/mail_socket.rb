# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "socket"
require "openssl"
require "ipaddr"

module Tina4
  class Messenger
    # A line-oriented TCP connection with optional TLS, shared by Tina4's own SMTP
    # and IMAP clients (which replace the net-smtp and net-imap gems).
    #
    # TLS is VERIFIED, as it was under Net::SMTP / Net::IMAP: the peer certificate
    # must chain to the default trust store (OpenSSL honours SSL_CERT_FILE and
    # SSL_CERT_DIR) and match the host name, or the handshake fails.
    #
    # Every read is bounded by the timeout, so a silent server raises
    # MailSocket::TimeoutError (an IOError) instead of hanging the caller.
    class MailSocket
      class TimeoutError < IOError; end

      READ_CHUNK = 16_384

      def self.open(host, port, tls: false, timeout: 30)
        socket = new(Socket.tcp(host, port, connect_timeout: timeout), host, timeout)
        socket.start_tls if tls
        socket
      rescue StandardError
        socket&.close
        raise
      end

      def initialize(io, host, timeout)
        @io = io
        @host = host
        @timeout = timeout
        @buffer = +"".b
      end

      def tls?
        @io.is_a?(OpenSSL::SSL::SSLSocket)
      end

      # Upgrade to TLS in place (implicit TLS right after connect, or STARTTLS).
      def start_tls
        # Bytes the server sent before the handshake would be read as if they came
        # over TLS -- the STARTTLS command-injection attack (CVE-2011-0411 class).
        raise IOError, "#{@host} sent data before the TLS handshake" unless @buffer.empty?

        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(@io, context)
        ssl.sync_close = true
        ssl.hostname = @host unless ip_address?(@host) # SNI never carries an IP literal
        until (state = ssl.connect_nonblock(exception: false)) == ssl
          wait(state)
        end
        ssl.post_connection_check(@host)
        @io = ssl
      end

      # One line, CRLF included, as binary. Raises EOFError if the peer closes.
      def read_line
        until (newline = @buffer.index("\n"))
          fill
        end
        @buffer.slice!(0..newline)
      end

      # Exactly +count+ bytes (an IMAP literal), as binary.
      def read_bytes(count)
        fill while @buffer.bytesize < count
        @buffer.slice!(0, count)
      end

      def write(data)
        @io.write(data.b)
      end

      def buffered?
        !@buffer.empty?
      end

      def close
        @io.close
      rescue StandardError
        nil
      end

      private

      def fill
        loop do
          chunk = @io.read_nonblock(READ_CHUNK, exception: false)
          case chunk
          when :wait_readable, :wait_writable then wait(chunk)
          when nil then raise EOFError, "#{@host} closed the connection"
          else
            @buffer << chunk
            return
          end
        end
      end

      def wait(state)
        raw = @io.to_io
        ready = state == :wait_writable ? IO.select(nil, [raw], nil, @timeout) : IO.select([raw], nil, nil, @timeout)
        raise TimeoutError, "#{@host} did not respond within #{@timeout}s" unless ready
      end

      def ip_address?(host)
        IPAddr.new(host)
        true
      rescue ArgumentError # IPAddr::InvalidAddressError / AddressFamilyError
        false
      end
    end
  end
end
