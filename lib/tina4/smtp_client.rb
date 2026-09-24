# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require "socket"
require_relative "mail_socket"
require_relative "base64"

module Tina4
  class Messenger
    # Tina4's own SMTP client (RFC 5321), replacing the net-smtp gem. It covers
    # exactly what Messenger sends with:
    #
    #   * transport: plain, STARTTLS, or implicit TLS. Implicit TLS defaults to
    #     port 465, the rule Python (SMTP_SSL), PHP (ssl://) and Node (tls.connect)
    #     already follow; the caller may also ask for it on any port (tls: true).
    #     STARTTLS is REQUIRED when asked for: a server that does not offer it
    #     fails the send rather than silently getting the message and the
    #     credentials in clear (Net::SMTP#enable_starttls did the same).
    #   * AUTH PLAIN, or AUTH LOGIN when that is all the server offers.
    #   * MAIL FROM / RCPT TO / DATA with CRLF normalisation and dot-stuffing.
    #
    #   SmtpClient.start(host: "smtp.example.com", port: 587, starttls: true,
    #                    username: "u", password: "p") do |smtp|
    #     smtp.send_message(raw_message, "from@example.com", ["to@example.com"])
    #   end
    class SmtpClient
      # A server reply outside the expected codes; the message is the reply text.
      class Error < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      IMPLICIT_TLS_PORT = 465

      def self.start(**options)
        client = new(**options)
        client.connect
        return client unless block_given?

        begin
          yield client
        ensure
          client.quit
        end
      end

      # auth_mechanism forces "PLAIN" or "LOGIN"; nil picks from the server's
      # EHLO list (PLAIN preferred, as Net::SMTP's :plain always sent).
      def initialize(host:, port:, tls: nil, starttls: false, username: nil, password: nil,
                     auth_mechanism: nil, timeout: 30, helo_domain: nil)
        @host = host
        @port = port.to_i
        @implicit_tls = tls.nil? ? @port == IMPLICIT_TLS_PORT : tls
        @starttls = starttls
        @username = username
        @password = password
        @auth_mechanism = auth_mechanism&.upcase
        @timeout = timeout
        @helo_domain = helo_domain || local_host_name
        @capabilities = []
        @socket = nil
      end

      attr_reader :capabilities

      def implicit_tls?
        @implicit_tls
      end

      def tls?
        @socket&.tls? || false
      end

      def connect
        @socket = MailSocket.open(@host, @port, tls: implicit_tls?, timeout: @timeout)
        read_reply(220)
        greet
        upgrade_to_tls if @starttls && !implicit_tls?
        authenticate if @username && @password
        self
      rescue StandardError
        close
        raise
      end

      def send_message(message, from, recipients)
        recipients = Array(recipients).map { |recipient| envelope_address(recipient) }
        raise ArgumentError, "at least one recipient is required" if recipients.empty?

        command("MAIL FROM:<#{envelope_address(from)}>", 250)
        recipients.each { |recipient| command("RCPT TO:<#{recipient}>", 250, 251) }
        command("DATA", 354)
        @socket.write(self.class.data_block(message))
        read_reply(250)
      end

      # QUIT politely, then close. Never raises: the message is already queued.
      def quit
        return unless @socket

        begin
          command("QUIT", 221)
        rescue StandardError
          nil
        end
        close
      end

      def close
        @socket&.close
        @socket = nil
      end

      # The DATA payload: every line ending normalised to CRLF, a line starting
      # with "." doubled (RFC 5321 4.5.2), terminated by CRLF.CRLF.
      def self.data_block(message)
        data = message.to_s.b.gsub(/\r\n|\r|\n/n, "\r\n")
        data << "\r\n" unless data.end_with?("\r\n")
        data.gsub(/^\./n, "..") + ".\r\n"
      end

      private

      def greet
        @capabilities = command("EHLO #{@helo_domain}", 250).drop(1)
      rescue Error => e
        raise unless (500..599).cover?(e.code)

        # A server that does not speak ESMTP: plain HELO, no extensions.
        command("HELO #{@helo_domain}", 250)
        @capabilities = []
      end

      def upgrade_to_tls
        unless capability?("STARTTLS")
          raise Error.new(0, "STARTTLS was requested but #{@host}:#{@port} does not offer it")
        end

        command("STARTTLS", 220)
        @socket.start_tls
        greet # capabilities change once the channel is encrypted (AUTH often appears)
      end

      def authenticate
        case auth_mechanism
        when "PLAIN"
          command("AUTH PLAIN #{Tina4::Base64.strict_encode64("\0#{@username}\0#{@password}")}", 235)
        when "LOGIN"
          command("AUTH LOGIN", 334)
          command(Tina4::Base64.strict_encode64(@username.to_s), 334)
          command(Tina4::Base64.strict_encode64(@password.to_s), 235)
        end
      end

      def auth_mechanism
        return @auth_mechanism if @auth_mechanism

        offered = @capabilities.filter_map { |line| line[/\AAUTH[ =](.*)\z/i, 1] }
                               .flat_map { |list| list.upcase.split }
        return "PLAIN" if offered.empty? || offered.include?("PLAIN")
        return "LOGIN" if offered.include?("LOGIN")

        raise Error.new(0, "#{@host}:#{@port} offers no supported AUTH mechanism (offered: #{offered.join(' ')})")
      end

      def capability?(name)
        @capabilities.any? { |line| line.split(/[ =]/, 2).first.casecmp?(name) }
      end

      # Send one command line and read its reply; returns the reply lines.
      def command(line, *expected)
        if line.match?(/[\r\n]/)
          raise ArgumentError, "SMTP command contains a line break"
        end

        @socket.write("#{line}\r\n")
        read_reply(*expected)
      end

      # A reply is one or more "NNN-text" lines ending with "NNN text".
      def read_reply(*expected)
        lines = []
        code = nil
        loop do
          raw = @socket.read_line.force_encoding(Encoding::UTF_8).scrub.chomp
          code = raw[0, 3].to_i
          lines << raw[4..].to_s
          break unless raw[3] == "-"
        end
        return lines if expected.empty? || expected.include?(code)

        raise Error.new(code, "#{code} #{lines.join(' ')}".strip)
      end

      # The bare address for the envelope: "Name <a@b>" -> "a@b". CR, LF and
      # angle brackets inside it would let a caller inject SMTP commands.
      def envelope_address(address)
        text = address.to_s.strip
        text = Regexp.last_match(1).strip if text =~ /<([^<>]*)>\s*\z/
        raise ArgumentError, "invalid email address #{address.inspect}" if text.match?(/[\r\n<>]/)

        text
      end

      def local_host_name
        name = Socket.gethostname.to_s
        name.match?(/\A[A-Za-z0-9.\-]+\z/) ? name : "localhost"
      rescue StandardError
        "localhost"
      end
    end
  end
end
