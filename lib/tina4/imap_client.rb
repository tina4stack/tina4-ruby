# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require_relative "mail_socket"

module Tina4
  class Messenger
    # Tina4's own IMAP4rev1 client (RFC 3501), replacing the net-imap gem. It
    # speaks exactly the commands Messenger uses -- LOGIN, SELECT, UID SEARCH,
    # UID FETCH, UID STORE, EXPUNGE, LIST, LOGOUT, plus STARTTLS -- and returns
    # the shapes Messenger already consumed from Net::IMAP: FetchData#attr with
    # "UID" (Integer), "FLAGS" (system flags as Symbols, :Seen), "ENVELOPE"
    # (Envelope / Address structs) and "BODY[]" (the raw message, binary).
    #
    #   imap = ImapClient.new("imap.example.com", port: 993, tls: true)
    #   imap.login("user", "secret")
    #   imap.select("INBOX")
    #   imap.uid_search(["UNSEEN"])   # => [4, 7]
    class ImapClient
      # A NO / BAD / BYE from the server (#status says which; the message is the
      # server's text, as Net::IMAP::ResponseError gave), or an unparseable reply.
      class Error < StandardError
        attr_reader :status

        def initialize(message = nil, status: nil)
          @status = status
          super(message)
        end
      end

      FetchData = Struct.new(:seqno, :attr)
      Envelope = Struct.new(:date, :subject, :from, :sender, :reply_to,
                            :to, :cc, :bcc, :in_reply_to, :message_id)
      Address = Struct.new(:name, :route, :mailbox, :host)

      SEQUENCE_SET = /\A(?:\d+|\*)(?::(?:\d+|\*))?(?:,(?:\d+|\*)(?::(?:\d+|\*))?)*\z/

      # tls: implicit TLS from the first byte (IMAPS). starttls: plain connect,
      # then STARTTLS before anything else is said; the upgrade is REQUIRED.
      def initialize(host, port:, tls: false, starttls: false, timeout: 30)
        @host = host
        @tag_number = 0
        @socket = MailSocket.open(host, port, tls: tls, timeout: timeout)
        greeting = read_response
        raise Error, "#{host}:#{port} refused the connection: #{text(greeting.strip)}" if greeting.start_with?("* BYE")
        raise Error, "#{host}:#{port} is not an IMAP server: #{text(greeting.strip)}" unless greeting.start_with?("* ")

        start_tls if starttls && !tls
      rescue StandardError
        disconnect
        raise
      end

      def login(username, password)
        command("LOGIN", astring(username), astring(password))
      end

      def select(mailbox)
        command("SELECT", astring(mailbox))
      end

      # UID SEARCH with Net::IMAP-style criteria: ["SUBJECT", "hello", "UNSEEN"].
      # Non-ASCII criteria are sent as literals under CHARSET UTF-8.
      def uid_search(criteria)
        arguments = Array(criteria).map { |criterion| criterion.is_a?(Integer) ? criterion.to_s : astring(criterion.to_s) }
        arguments.unshift("CHARSET", "UTF-8") if Array(criteria).any? { |c| !c.to_s.ascii_only? }
        command("UID SEARCH", *arguments).flat_map do |line|
          next [] unless line.start_with?("* SEARCH")

          line.sub("* SEARCH", "").split.filter_map { |number| Integer(number, exception: false) }
        end
      end

      # UID FETCH. +set+ is a UID, an Array of UIDs or a sequence-set String;
      # +items+ e.g. ["ENVELOPE", "FLAGS", "BODY.PEEK[]"]. Returns FetchData rows
      # in the order the server sent them (servers answer in ascending order).
      def uid_fetch(set, items)
        lines = command("UID FETCH", sequence_set(set), "(#{Array(items).join(' ')})")
        lines.filter_map do |line|
          match = line.match(/\A\* (\d+) FETCH /)
          next unless match

          pairs = Parser.new(line, match.end(0)).value
          attr = {}
          pairs.each_slice(2) do |name, value|
            key = name.to_s.upcase.force_encoding(Encoding::UTF_8)
            attr[key] = fetch_value(key, value)
          end
          next unless attr.key?("UID") # an unsolicited flag update for another message

          FetchData.new(match[1].to_i, attr)
        end
      end

      # UID STORE set +FLAGS|-FLAGS (\Seen ...). flags: [:Seen] or ["\\Seen"].
      def uid_store(set, action, flags)
        flag_list = Array(flags).map { |flag| flag.is_a?(Symbol) ? "\\#{flag}" : flag.to_s }
        if flag_list.any? { |flag| !flag.match?(/\A\\?[A-Za-z0-9$_.\-]+\z/) }
          raise Error, "invalid flag list #{flags.inspect}"
        end

        raise Error, "invalid STORE action #{action.inspect}" unless action.to_s.match?(/\A[+-]?FLAGS(\.SILENT)?\z/i)

        command("UID STORE", sequence_set(set), action.to_s, "(#{flag_list.join(' ')})")
      end

      def expunge
        command("EXPUNGE")
      end

      # LIST reference pattern. Returns the mailbox names (INBOX normalised).
      def list(reference, pattern)
        command("LIST", astring(reference), astring(pattern)).filter_map do |line|
          next unless line.start_with?("* LIST ")

          parser = Parser.new(line, "* LIST ".length)
          parser.value # attributes
          parser.value # hierarchy delimiter
          name = text(parser.value)
          name.casecmp?("INBOX") ? "INBOX" : name
        end
      end

      def logout
        command("LOGOUT")
      rescue EOFError
        nil # some servers close straight after the BYE
      end

      def disconnect
        @socket&.close
        @socket = nil
      end

      private

      def start_tls
        command("STARTTLS")
        @socket.start_tls
      end

      # Send a tagged command and collect the untagged lines until its completion.
      # Arguments are already encoded (atoms, quoted strings or literals).
      def command(name, *arguments)
        raise Error, "not connected" unless @socket

        tag = "T#{@tag_number += 1}"
        send_command(tag, [name, *arguments])
        untagged = []
        loop do
          response = read_response
          if response.start_with?("#{tag} ")
            status, detail = response[(tag.length + 1)..].chomp.split(" ", 2)
            return untagged if status.casecmp?("OK")

            raise Error.new(text(detail.to_s.strip), status: status.upcase)
          end
          if response.start_with?("* BYE") && name != "LOGOUT"
            raise Error.new(text(response.chomp.sub(/\A\* BYE ?/, "")), status: "BYE")
          end

          untagged << response
        end
      end

      # Literal arguments ({n}) go out one chunk at a time, each after the
      # server's "+" continuation, exactly as RFC 3501 7.5 requires.
      def send_command(tag, parts)
        buffer = +"#{tag}"
        parts.each do |part|
          buffer << " "
          if part.is_a?(Literal)
            @socket.write("#{buffer}{#{part.bytes.bytesize}}\r\n")
            await_continuation
            buffer = part.bytes.dup
          else
            buffer << part
          end
        end
        @socket.write("#{buffer}\r\n")
      end

      def await_continuation
        loop do
          response = read_response
          return if response.start_with?("+")
          raise Error, text(response.chomp) if response.match?(/\AT\d+ (NO|BAD)/)
        end
      end

      # One complete server response, literals inlined: a line ending in {n}
      # is followed by n raw bytes and then the rest of the response.
      def read_response
        response = @socket.read_line
        while (match = response.match(/\{(\d+)\+?\}\r\n\z/n))
          response << @socket.read_bytes(match[1].to_i)
          response << @socket.read_line
        end
        response
      end

      Literal = Struct.new(:bytes)

      # astring (RFC 3501): an atom when it is safe, a quoted string when it has
      # specials, a literal when it has 8-bit bytes or CR/LF (the rule Net::IMAP
      # follows, with "]" also quoted).
      def astring(value)
        string = value.to_s
        return '""' if string.empty?
        return Literal.new(string.b) if string.b.match?(/[\x80-\xff\r\n\x00]/n)
        return %("#{string.gsub(/["\\]/) { |c| "\\#{c}" }}") if string.match?(/[(){ \x00-\x1f\x7f%*"\\\]]/)

        string
      end

      def sequence_set(set)
        text = Array(set).map(&:to_s).join(",")
        raise Error, "invalid UID set #{set.inspect}" unless text.match?(SEQUENCE_SET)

        text
      end

      def fetch_value(name, value)
        case name
        when "UID", "RFC822.SIZE" then value.to_i
        when "FLAGS" then Array(value).map { |flag| flag.start_with?("\\") ? flag[1..].capitalize.to_sym : flag }
        when "ENVELOPE" then envelope(value)
        else value
        end
      end

      def envelope(fields)
        return nil unless fields.is_a?(Array)

        date, subject, from, sender, reply_to, to, cc, bcc, in_reply_to, message_id = fields
        Envelope.new(text(date), text(subject), addresses(from), addresses(sender), addresses(reply_to),
                     addresses(to), addresses(cc), addresses(bcc), text(in_reply_to), text(message_id))
      end

      def addresses(list)
        return nil unless list.is_a?(Array)

        list.filter_map do |parts|
          next unless parts.is_a?(Array)

          name, route, mailbox, host = parts.map { |part| text(part) }
          Address.new(name, route, mailbox, host)
        end
      end

      # Envelope text is 7-bit by RFC, but servers relay raw 8-bit headers; make
      # it valid UTF-8 so the MIME-word decoding downstream can never raise.
      def text(value)
        return nil if value.nil?

        value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # Parses one IMAP value (parenthesised list, quoted string, literal, NIL,
      # or atom -- including "BODY[...]" section atoms) from a response line.
      # Strings stay binary; the caller decides their encoding.
      class Parser
        def initialize(line, position)
          @line = line.b
          @position = position
        end

        def value
          skip_spaces
          case @line.getbyte(@position)
          when 0x28 then list                  # (
          when 0x22 then quoted                # "
          when 0x7B then literal               # {
          else atom_or_nil
          end
        end

        private

        def skip_spaces
          @position += 1 while @line.getbyte(@position) == 0x20
        end

        def list
          @position += 1
          items = []
          loop do
            skip_spaces
            byte = @line.getbyte(@position)
            raise Error, "unterminated list in IMAP response" if byte.nil?

            if byte == 0x29 # )
              @position += 1
              return items
            end
            items << value
          end
        end

        def quoted
          @position += 1
          result = +"".b
          loop do
            byte = @line.getbyte(@position)
            raise Error, "unterminated quoted string in IMAP response" if byte.nil?

            @position += 1
            return result if byte == 0x22

            if byte == 0x5C # backslash escapes \ and "
              result << @line.byteslice(@position, 1)
              @position += 1
            else
              result << byte
            end
          end
        end

        def literal
          close = @line.index("}", @position) or raise Error, "malformed literal in IMAP response"
          size = @line.byteslice(@position + 1, close - @position - 1).delete("+").to_i
          start = close + 3 # past "}\r\n"
          @position = start + size
          @line.byteslice(start, size)
        end

        def atom_or_nil
          start = @position
          depth = 0
          loop do
            byte = @line.getbyte(@position)
            break if byte.nil? || byte == 0x0D || byte == 0x0A
            break if depth.zero? && [0x20, 0x28, 0x29].include?(byte)

            depth += 1 if byte == 0x5B # [ ... ] may hold spaces and parentheses
            depth -= 1 if byte == 0x5D && depth.positive?
            @position += 1
          end
          atom = @line.byteslice(start, @position - start)
          raise Error, "unexpected character in IMAP response at #{start}" if atom.empty?

          atom.casecmp?("NIL") ? nil : atom
        end
      end
    end
  end
end
