# frozen_string_literal: true

require "socket"

module Tina4
  module SessionHandlers
    # A MongoDB command that came back with `ok != 1`, or a transport failure,
    # surfaced as an exception so the handler can tell a real error apart from a
    # genuine miss (an empty firstBatch). Same split RespError makes for RESP.
    class MongoWireError < StandardError; end

    # Zero-dependency synchronous MongoDB client speaking the wire protocol
    # (OP_MSG, opcode 2013) over a TCP socket, with a minimal BSON codec.
    #
    # WHY IT EXISTS (session_contract.json #6, ADR-0024). Python, PHP and Node
    # have always shipped a raw OP_MSG fallback for the mongodb SESSION backend;
    # Ruby alone hard-required the `mongo` gem and RAISED without it. The same
    # .env therefore worked in three frameworks and failed in the fourth, which
    # breaks the zero-dependency promise ASYMMETRICALLY - worse than breaking it
    # consistently, because nothing about the configuration hints at it. This is
    # the missing fourth transport, ported from the proven Python master
    # (tina4_python/session_handlers/mongodb_handler.py) rather than invented.
    #
    # It is deliberately NOT a general Mongo driver. It implements exactly the
    # four operations the session handler performs - find_one by _id, upsert by
    # _id, delete_one by _id, and delete_many for gc - and it mirrors the SHAPE
    # of the `mongo` gem's Collection for those four so the handler's read,
    # write, destroy and gc bodies are IDENTICAL on both transports. That is not
    # cosmetic: a branch inside each operation is a branch that can be wrong on
    # one path only, and this fallback would then ship untested behind a
    # condition nobody exercises.
    #
    # HARD-WON DETAILS, preserved from the three siblings:
    #   * The COMMAND NAME comes FIRST in the document and `$db` LAST. Reversed,
    #     the server reads `$db` as the command name and answers CommandNotFound.
    #   * BSON is little-endian throughout, string lengths are BYTE counts (not
    #     character counts), and a Time is encoded as BSON UTC datetime (0x09,
    #     int64 milliseconds) so a document written here is byte-identical in
    #     shape to one the gem writes.
    #   * An OP_MSG reply can arrive split across TCP segments, so the body is
    #     read by its exact declared byte count rather than one recv().
    #
    # NO NETWORK I/O IN A CONSTRUCTOR (ADR-0021, session_contract.json #4): the
    # socket is opened on the FIRST command, inside the log-loud-and-degrade
    # policy, never here.
    class MongoWireClient
      OP_MSG = 2013

      # BSON element type bytes, named so the codec reads as the spec does.
      TYPE_DOUBLE    = 0x01
      TYPE_STRING    = 0x02
      TYPE_DOCUMENT  = 0x03
      TYPE_ARRAY     = 0x04
      TYPE_BINARY    = 0x05
      TYPE_OBJECT_ID = 0x07
      TYPE_BOOLEAN   = 0x08
      TYPE_DATETIME  = 0x09
      TYPE_NULL      = 0x0A
      TYPE_INT32     = 0x10
      TYPE_TIMESTAMP = 0x11
      TYPE_INT64     = 0x12

      INT32_MIN = -2_147_483_648
      INT32_MAX = 2_147_483_647

      def initialize(host:, port:, database:, collection:, timeout: 10)
        @host = host
        @port = port
        @database = database
        @collection = collection
        @timeout = timeout
        @socket = nil
        @request_id = 0
      end

      # Documents matching +filter+, capped at one.
      #
      # Returns an ARRAY so the caller can write `find(...).first` exactly as it
      # does against the gem's Collection, which answers a lazy view. One shared
      # call site, two transports.
      def find(filter)
        reply = command("find" => @collection, "filter" => filter, "limit" => 1, "$db" => @database)
        reply.dig("cursor", "firstBatch") || []
      end

      # Apply +update+ (an operator document such as `{"$set" => {...}}`, or a
      # full replacement) to the single document matching +filter+.
      def update_one(filter, update, upsert: false)
        command(
          "update" => @collection,
          "updates" => [{ "q" => filter, "u" => update, "upsert" => upsert }],
          "$db" => @database
        )
      end

      def delete_one(filter)
        delete(filter, 1)
      end

      def delete_many(filter)
        delete(filter, 0)
      end

      def close
        @socket&.close
      rescue StandardError
        nil # already closed / never opened - nothing to do
      ensure
        @socket = nil
      end

      private

      def delete(filter, limit)
        command(
          "delete" => @collection,
          "deletes" => [{ "q" => filter, "limit" => limit }],
          "$db" => @database
        )
      end

      # Send one OP_MSG command and return the decoded reply document.
      #
      # RAISES MongoWireError on a transport failure or on `ok != 1`, so the
      # Session boundary can log loud and degrade. A genuine MISS is not a
      # failure and comes back as an empty firstBatch, never as an exception -
      # collapsing the two is how a dead backend silently logs everyone out.
      def command(document)
        socket = connection
        @request_id += 1
        body = "\x00\x00\x00\x00".b + "\x00".b + encode_document(document) # flagBits(4) + section kind 0
        header = [16 + body.bytesize, @request_id, 0, OP_MSG].pack("V4")
        socket.write(header + body)
        reply = read_reply(socket)
        return reply if reply["ok"].to_f == 1.0

        raise MongoWireError, "MongoDB command failed: #{reply["errmsg"] || reply.inspect}"
      rescue MongoWireError
        raise
      rescue StandardError => e
        # A broken pipe or a half-read reply leaves the socket unusable; drop it
        # so the NEXT command reconnects instead of inheriting the damage.
        close
        raise MongoWireError, "MongoDB transport failed: #{e.message}"
      end

      def connection
        @socket ||= begin
          socket = Socket.tcp(@host, @port, connect_timeout: @timeout)
          socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [@timeout, 0].pack("l_2"))
          socket
        end
      end

      def read_reply(socket)
        header = read_exact(socket, 16)
        message_length = header.unpack1("V")
        payload = read_exact(socket, message_length - 16)
        # OP_MSG payload: flagBits(4) + section kind(1), then the body document.
        decode_document(payload, [5])
      end

      def read_exact(socket, count)
        buffer = +"".b
        while buffer.bytesize < count
          chunk = socket.read(count - buffer.bytesize)
          raise MongoWireError, "connection closed mid-reply" if chunk.nil? || chunk.empty?

          buffer << chunk
        end
        buffer
      end

      # ── Minimal BSON encoder ────────────────────────────────────────────

      def encode_document(document)
        body = +"".b
        document.each { |key, value| body << encode_element(key.to_s, value) }
        body << "\x00".b
        [body.bytesize + 4].pack("V") + body
      end

      def encode_element(key, value)
        ckey = key.b + "\x00".b

        case value
        when nil          then TYPE_NULL.chr + ckey
        when true, false  then TYPE_BOOLEAN.chr + ckey + (value ? "\x01".b : "\x00".b)
        when Integer      then encode_integer(ckey, value)
        when Float        then TYPE_DOUBLE.chr + ckey + [value].pack("E")
        when Time         then TYPE_DATETIME.chr + ckey + [(value.to_f * 1000).round].pack("q<")
        when Hash         then TYPE_DOCUMENT.chr + ckey + encode_document(value)
        when Array        then TYPE_ARRAY.chr + ckey + encode_document(indexed(value))
        when Symbol       then encode_string(ckey, value.to_s)
        when String       then encode_string(ckey, value)
        else                   encode_string(ckey, value.to_s)
        end
      end

      def encode_integer(ckey, value)
        return TYPE_INT32.chr + ckey + [value].pack("l<") if value.between?(INT32_MIN, INT32_MAX)

        TYPE_INT64.chr + ckey + [value].pack("q<")
      end

      # A BSON string is a BYTE count followed by the bytes and a terminator, so
      # the length must be bytesize - a UTF-8 payload counted in characters
      # under-reports and the server rejects the document.
      def encode_string(ckey, value)
        bytes = value.b
        TYPE_STRING.chr + ckey + [bytes.bytesize + 1].pack("V") + bytes + "\x00".b
      end

      # A BSON array is a document whose keys are the string indexes.
      def indexed(array)
        array.each_with_index.to_h { |value, index| [index.to_s, value] }
      end

      # ── Minimal BSON decoder ────────────────────────────────────────────
      #
      # +position+ is a single-element array used as a shared cursor, matching
      # the Python master's `pos = [0]` - nested documents advance the one
      # cursor rather than each level tracking its own offset.

      def decode_document(data, position)
        document_length = data[position[0], 4].unpack1("V")
        position[0] += 4
        finish = position[0] + document_length - 5

        document = {}
        while position[0] < finish
          type = data.getbyte(position[0])
          position[0] += 1

          key_end = data.index("\x00".b, position[0])
          key = data[position[0]...key_end].force_encoding(Encoding::UTF_8)
          position[0] = key_end + 1

          document[key] = decode_value(data, position, type, finish)
        end

        position[0] += 1 # document terminator
        document
      end

      def decode_value(data, position, type, finish)
        case type
        when TYPE_DOUBLE    then take(data, position, 8).unpack1("E")
        when TYPE_STRING    then decode_string(data, position)
        when TYPE_DOCUMENT  then decode_document(data, position)
        when TYPE_ARRAY     then decode_document(data, position).values
        when TYPE_BINARY    then decode_binary(data, position)
        when TYPE_OBJECT_ID then take(data, position, 12).unpack1("H*")
        when TYPE_BOOLEAN   then take(data, position, 1).getbyte(0) != 0
        when TYPE_DATETIME  then Time.at(take(data, position, 8).unpack1("q<") / 1000.0)
        when TYPE_NULL      then nil
        when TYPE_INT32     then take(data, position, 4).unpack1("l<")
        when TYPE_TIMESTAMP then take(data, position, 8).unpack1("Q<")
        when TYPE_INT64     then take(data, position, 8).unpack1("q<")
        else
          # An unknown type cannot be sized, so its length cannot be skipped.
          # Stop at the document boundary rather than loop forever on a byte
          # this codec does not understand.
          position[0] = finish
          nil
        end
      end

      def decode_string(data, position)
        length = take(data, position, 4).unpack1("V")
        value = data[position[0], length - 1].force_encoding(Encoding::UTF_8)
        position[0] += length
        value
      end

      def decode_binary(data, position)
        length = take(data, position, 4).unpack1("V")
        position[0] += 1 # subtype
        take(data, position, length)
      end

      def take(data, position, count)
        slice = data[position[0], count]
        position[0] += count
        slice
      end
    end
  end
end
