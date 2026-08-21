# frozen_string_literal: true

# Bolt graph adapter — Neo4j AND Memgraph (both speak Bolt + Cypher).
#
# The portable node/edge/traverse surface is expressed in Cypher on top of a
# compact, self-contained Bolt 4.4 / PackStream v2 client (stdlib +socket+ only —
# NO third-party gem). Neo4j and Memgraph share this ONE adapter; the URL scheme
# only picks the engine label and default port.
#
# Why an embedded client rather than a community gem (proven on the lab, no mocks):
#   * +neo4j-ruby-driver+ (4.4.6) connects to Neo4j but NOT to Memgraph — its
#     handshake offers Bolt 4.4 only inside a 4.2–4.4 *range* entry, which this
#     Memgraph build does not accept, so negotiation falls back to Bolt v3 where
#     the driver's strict server-version parser rejects Memgraph's
#     "Neo4j/v5.11.0 compatible … Memgraph" agent string with an ArgumentError.
#     It also pulls in ActiveSupport and needs a connection_pool 2.x pin.
#   * The pure-Ruby +neo4j_bolt+ gem hardcodes +scheme => 'none'+ (no auth) and a
#     single process-global connection, so it cannot authenticate to Neo4j.
#   Both lab engines DO negotiate a *plain* Bolt 4.4 handshake, so a small real
#   client that offers plain 4.4 works against BOTH. This is a REAL driver hitting
#   REAL engines, not a mock.
#
# Cypher note (verified live against Neo4j + Memgraph): +id(n)+ is the portable
# node/edge id (an INTEGER on both — Neo4j's +elementId+ is Neo4j-only, Memgraph
# has no +elementId+); variable-length traversal is Cypher's +[*1..N]+ (the
# OPPOSITE of Ultipa's GQL +{1,N}+); +SET n += $props+ merges.

require "socket"

module Tina4
  module Drivers
    # A minimal Bolt 4.4 / PackStream v2 client — just enough to run Cypher with
    # bound parameters and read records back. Not a general Bolt library; it
    # implements exactly the message set the graph layer needs (HELLO, RUN, PULL,
    # RESET, GOODBYE) and the PackStream types Cypher returns.
    class BoltConnection
      # PackStream markers reused across encode/decode.
      NULL = 0xC0
      FALSE = 0xC2
      TRUE = 0xC3
      FLOAT64 = 0xC1
      INT8 = 0xC8
      INT16 = 0xC9
      INT32 = 0xCA
      INT64 = 0xCB
      # Bolt request message struct tags.
      MSG_HELLO = 0x01
      MSG_GOODBYE = 0x02
      MSG_RESET = 0x0F
      MSG_RUN = 0x10
      MSG_PULL = 0x3F
      # Bolt response message struct tags.
      MSG_SUCCESS = 0x70
      MSG_RECORD = 0x71
      MSG_IGNORED = 0x7E
      MSG_FAILURE = 0x7F
      # Structure tags for graph values (only meaningful for raw queries that
      # return whole nodes/relationships; the portable core returns decomposed
      # id/labels/props scalars and never hits these).
      NODE = 0x4E
      RELATIONSHIP = 0x52
      UNBOUND_RELATIONSHIP = 0x72
      PATH = 0x50

      # A Bolt-layer failure carrying the server's error code + message.
      class BoltError < StandardError; end
      # A connect/socket failure (unreachable host, handshake, timeout).
      class BoltConnectError < StandardError; end

      def initialize(host:, port:, user: nil, password: nil, connect_timeout: nil, use_tls: false)
        @host = host
        @port = port
        @user = user
        @password = password
        @connect_timeout = connect_timeout
        @use_tls = use_tls
        connect
      end

      # Run one Cypher statement, PULL all records, return an array of row hashes
      # keyed by the RETURN column names (string keys — parity with the Ultipa
      # driver and the Python master's +record.data()+).
      def run(cypher, params = nil)
        fields = send_run(cypher, params || {})
        records = []
        pull_all do |values|
          records << fields.zip(values).to_h
        end
        records
      end

      def close
        write_message(MSG_GOODBYE)
        @socket&.close
      rescue StandardError
        # closing is best-effort — a dead socket needs no goodbye.
      ensure
        @socket = nil
      end

      private

      # -- connection + handshake ------------------------------------------

      def connect
        @socket = open_socket
        # Bolt handshake: magic preamble + four offered versions, MSB first.
        # We offer plain 4.4 only (both Neo4j and Memgraph accept it); the three
        # zero slots are "no further offer".
        @socket.write(["6060B017".to_i(16), 0x00000404, 0, 0, 0].pack("N5"))
        negotiated = @socket.read(4)&.unpack1("N")
        if negotiated.nil? || negotiated.zero?
          raise BoltConnectError, "server offered no compatible Bolt version"
        end

        hello
      rescue BoltError => e
        # An auth/HELLO rejection is a real Bolt failure, not a connect timeout.
        raise BoltConnectError, e.message
      rescue IOError, SystemCallError, SocketError => e
        raise BoltConnectError, e.message
      end

      def open_socket
        if @connect_timeout
          Socket.tcp(@host, @port, connect_timeout: @connect_timeout)
        else
          Socket.tcp(@host, @port)
        end
      rescue Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ECONNREFUSED,
             Errno::ENETUNREACH, SocketError, Timeout::Error => e
        raise BoltConnectError, e.message
      end

      def hello
        extra = { "user_agent" => "tina4-ruby-bolt/1.0" }
        if @user && !@user.empty?
          extra["scheme"] = "basic"
          extra["principal"] = @user
          extra["credentials"] = @password.to_s
        else
          extra["scheme"] = "none"
        end
        write_message(MSG_HELLO, extra)
        read_success # raises BoltError on FAILURE (bad credentials, etc.)
      end

      # -- Bolt request/response cycle -------------------------------------

      # Send RUN, return the ordered list of result column names.
      def send_run(cypher, params)
        write_message(MSG_RUN, cypher, stringify_keys(params), {})
        meta = read_success
        Array(meta["fields"])
      rescue BoltError
        # A failed RUN leaves the connection FAILED; RESET clears it so the same
        # connection can serve the next statement.
        reset
        raise
      end

      # Send PULL(n:-1) and yield each RECORD's value list until SUCCESS.
      def pull_all
        write_message(MSG_PULL, { "n" => -1 })
        loop do
          tag, value = read_message
          case tag
          when MSG_RECORD
            yield value
          when MSG_SUCCESS
            break
          when MSG_FAILURE
            reset
            raise BoltError, bolt_failure_message(value)
          when MSG_IGNORED
            reset
            raise BoltError, "server ignored PULL"
          else
            raise BoltError, "unexpected Bolt response 0x#{tag.to_s(16)}"
          end
        end
      end

      def reset
        write_message(MSG_RESET)
        # Drain until the RESET SUCCESS/FAILURE so the stream is clean.
        loop do
          tag, = read_message
          break if [MSG_SUCCESS, MSG_FAILURE].include?(tag)
        end
      rescue StandardError
        # If RESET itself cannot complete the connection is unusable; the next
        # operation will surface it.
        nil
      end

      def read_success
        tag, value = read_message
        case tag
        when MSG_SUCCESS then value || {}
        when MSG_FAILURE then raise BoltError, bolt_failure_message(value)
        when MSG_IGNORED then raise BoltError, "server ignored request"
        else raise BoltError, "unexpected Bolt response 0x#{tag.to_s(16)}"
        end
      end

      def bolt_failure_message(value)
        return "Bolt failure" unless value.is_a?(Hash)

        [value["code"], value["message"]].compact.join(": ")
      end

      # -- chunked message framing -----------------------------------------

      # Serialize (tag + fields) as a struct, split into 64KB chunks, terminate
      # with a zero-length chunk.
      def write_message(tag, *fields)
        body = +"".b
        body << [0xB0 | fields.length].pack("C") << [tag].pack("C")
        fields.each { |f| pack(f, body) }
        offset = 0
        while offset < body.bytesize
          slice = body.byteslice(offset, 65_535)
          @socket.write([slice.bytesize].pack("n"))
          @socket.write(slice)
          offset += slice.bytesize
        end
        @socket.write([0].pack("n")) # message boundary
      end

      # Read one chunked message, return [struct_tag, single_field_value].
      # Bolt response messages are one-field structs (SUCCESS/RECORD/FAILURE).
      def read_message
        buffer = +"".b
        loop do
          size = read_exact(2).unpack1("n")
          break if size.zero?

          buffer << read_exact(size)
        end
        parse_struct(StringScanner.new(buffer))
      end

      def read_exact(n)
        data = +"".b
        while data.bytesize < n
          chunk = @socket.read(n - data.bytesize)
          raise BoltConnectError, "connection closed mid-message" if chunk.nil?

          data << chunk
        end
        data
      end

      # A struct at the top of a response message: returns [tag, first_field].
      def parse_struct(scanner)
        marker = scanner.byte
        raise BoltError, "expected struct, got 0x#{marker.to_s(16)}" unless (marker & 0xF0) == 0xB0

        size = marker & 0x0F
        tag = scanner.byte
        fields = Array.new(size) { unpack(scanner) }
        [tag, fields[0]]
      end

      # -- PackStream v2 encode --------------------------------------------

      def pack(value, out)
        case value
        when nil then out << [NULL].pack("C")
        when true then out << [TRUE].pack("C")
        when false then out << [FALSE].pack("C")
        when Integer then pack_integer(value, out)
        when Float then out << [FLOAT64].pack("C") << [value].pack("G")
        when String, Symbol then pack_string(value.to_s, out)
        when Array then pack_list(value, out)
        when Hash then pack_map(value, out)
        else pack_string(value.to_s, out)
        end
      end

      def pack_integer(value, out)
        if value >= -16 && value <= 127
          out << [value].pack("c")
        elsif value >= -128 && value <= 127
          out << [INT8, value].pack("Cc")
        elsif value >= -32_768 && value <= 32_767
          out << [INT16].pack("C") << [value].pack("s>")
        elsif value >= -2_147_483_648 && value <= 2_147_483_647
          out << [INT32].pack("C") << [value].pack("l>")
        else
          out << [INT64].pack("C") << [value].pack("q>")
        end
      end

      def pack_string(str, out)
        bytes = str.b
        size = bytes.bytesize
        if size < 16
          out << [0x80 | size].pack("C")
        elsif size < 256
          out << [0xD0, size].pack("CC")
        elsif size < 65_536
          out << [0xD1].pack("C") << [size].pack("n")
        else
          out << [0xD2].pack("C") << [size].pack("N")
        end
        out << bytes
      end

      def pack_list(list, out)
        size = list.length
        if size < 16
          out << [0x90 | size].pack("C")
        elsif size < 256
          out << [0xD4, size].pack("CC")
        elsif size < 65_536
          out << [0xD5].pack("C") << [size].pack("n")
        else
          out << [0xD6].pack("C") << [size].pack("N")
        end
        list.each { |item| pack(item, out) }
      end

      def pack_map(map, out)
        size = map.length
        if size < 16
          out << [0xA0 | size].pack("C")
        elsif size < 256
          out << [0xD8, size].pack("CC")
        elsif size < 65_536
          out << [0xD9].pack("C") << [size].pack("n")
        else
          out << [0xDA].pack("C") << [size].pack("N")
        end
        map.each do |key, val|
          pack_string(key.to_s, out)
          pack(val, out)
        end
      end

      # -- PackStream v2 decode --------------------------------------------

      def unpack(scanner)
        marker = scanner.byte
        # Tiny int (positive 0..127, negative -16..-1).
        return marker if marker < 0x80
        return marker - 0x100 if marker >= 0xF0

        case marker
        when 0x80..0x8F then scanner.str(marker & 0x0F).force_encoding("UTF-8")
        when 0x90..0x9F then Array.new(marker & 0x0F) { unpack(scanner) }
        when 0xA0..0xAF then unpack_map(scanner, marker & 0x0F)
        when 0xB0..0xBF then unpack_structure(scanner, marker & 0x0F)
        when NULL then nil
        when TRUE then true
        when FALSE then false
        when FLOAT64 then scanner.str(8).unpack1("G")
        when INT8 then scanner.str(1).unpack1("c")
        when INT16 then scanner.str(2).unpack1("s>")
        when INT32 then scanner.str(4).unpack1("l>")
        when INT64 then scanner.str(8).unpack1("q>")
        when 0xD0 then scanner.str(scanner.byte).force_encoding("UTF-8")
        when 0xD1 then scanner.str(scanner.str(2).unpack1("n")).force_encoding("UTF-8")
        when 0xD2 then scanner.str(scanner.str(4).unpack1("N")).force_encoding("UTF-8")
        when 0xD4 then Array.new(scanner.byte) { unpack(scanner) }
        when 0xD5 then Array.new(scanner.str(2).unpack1("n")) { unpack(scanner) }
        when 0xD6 then Array.new(scanner.str(4).unpack1("N")) { unpack(scanner) }
        when 0xD8 then unpack_map(scanner, scanner.byte)
        when 0xD9 then unpack_map(scanner, scanner.str(2).unpack1("n"))
        when 0xDA then unpack_map(scanner, scanner.str(4).unpack1("N"))
        else raise BoltError, "unknown PackStream marker 0x#{marker.to_s(16)}"
        end
      end

      def unpack_map(scanner, size)
        result = {}
        size.times do
          key = unpack(scanner)
          result[key] = unpack(scanner)
        end
        result
      end

      # A nested structure inside a RECORD — decode the known graph structs to
      # plain hashes so a raw query that returns whole nodes still yields data.
      def unpack_structure(scanner, size)
        tag = scanner.byte
        fields = Array.new(size) { unpack(scanner) }
        case tag
        when NODE
          { "id" => fields[0], "labels" => fields[1], "properties" => fields[2] }
        when RELATIONSHIP
          { "id" => fields[0], "start" => fields[1], "end" => fields[2],
            "type" => fields[3], "properties" => fields[4] }
        when UNBOUND_RELATIONSHIP
          { "id" => fields[0], "type" => fields[1], "properties" => fields[2] }
        else
          fields
        end
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
      end

      # A tiny forward-only byte cursor over a binary string (avoids pulling in
      # StringScanner, which is text-oriented and not binary-safe for our needs).
      class StringScanner
        def initialize(bytes)
          @bytes = bytes
          @pos = 0
        end

        def byte
          b = @bytes.getbyte(@pos)
          @pos += 1
          b
        end

        def str(n)
          s = @bytes.byteslice(@pos, n)
          @pos += n
          s
        end
      end
    end

    # The Bolt graph adapter — Neo4j + Memgraph behind the portable surface.
    class BoltGraphDriver < Tina4::GraphAdapter
      def initialize(graph_url, username: "", password: "")
        @url = graph_url
        @last_error = nil
        timeout = Tina4.resolve_graph_connect_timeout
        user = graph_url.username
        user = username unless user && !user.empty?
        pwd = graph_url.password
        pwd = password unless pwd && !pwd.empty?
        user = "neo4j" if (user.nil? || user.empty?) && graph_url.engine == "bolt" && !password.to_s.empty?
        @conn = BoltConnection.new(
          host: graph_url.host, port: graph_url.port,
          user: user, password: pwd,
          connect_timeout: timeout, use_tls: graph_url.use_tls
        )
      rescue BoltConnection::BoltConnectError => e
        @last_error = e.message
        raise Tina4::GraphConnectTimeout,
              "Graph connect to #{graph_url.host}:#{graph_url.port} timed out or was refused " \
              "(TINA4_GRAPH_CONNECT_TIMEOUT). Raise TINA4_GRAPH_CONNECT_TIMEOUT if the server is " \
              "simply slow, or set it to 0 to wait indefinitely. Cause: #{e.message}"
      end

      # -- raw pass-through (native Cypher) --------------------------------

      def query(text, params = nil)
        rows = run(text, params)
        columns = rows.empty? ? [] : rows[0].keys
        Tina4::GraphResult.new(records: rows, columns: columns)
      end

      def execute(text, params = nil)
        query(text, params)
      end

      # -- portable node/edge/traverse core (Cypher) -----------------------

      def add_node(label, properties = nil)
        cypher = "CREATE (n:`#{label}` $props) " \
                 "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(cypher, { "props" => properties || {} })
        node_from_row(rows[0])
      end

      def add_edge(from_id, to_id, type, properties = nil)
        cypher = "MATCH (a), (b) WHERE id(a) = $from_id AND id(b) = $to_id " \
                 "CREATE (a)-[e:`#{type}` $props]->(b) " \
                 "RETURN id(e) AS id, type(e) AS type, id(a) AS f, id(b) AS t, " \
                 "properties(e) AS props"
        rows = run(cypher, { "from_id" => from_id, "to_id" => to_id, "props" => properties || {} })
        return nil if rows.empty?

        row = rows[0]
        Tina4::GraphEdge.new(
          id: row["id"], type: row["type"], from: row["f"], to: row["t"],
          properties: row["props"] || {}
        )
      end

      def get_node(node_id)
        cypher = "MATCH (n) WHERE id(n) = $id " \
                 "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(cypher, { "id" => node_id })
        node_from_row(rows[0])
      end

      def update_node(node_id, properties)
        cypher = "MATCH (n) WHERE id(n) = $id SET n += $props " \
                 "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(cypher, { "id" => node_id, "props" => properties || {} })
        node_from_row(rows[0])
      end

      def delete_node(node_id)
        run("MATCH (n) WHERE id(n) = $id DETACH DELETE n", { "id" => node_id })
        true
      end

      def neighbors(node_id, direction: "both", edge_type: nil, limit: 100)
        edge = edge_type ? ":`#{edge_type}`" : ""
        pattern = case direction
                  when "out" then "(n)-[#{edge}]->(m)"
                  when "in" then "(n)<-[#{edge}]-(m)"
                  else "(n)-[#{edge}]-(m)"
                  end
        cypher = "MATCH #{pattern} WHERE id(n) = $id " \
                 "RETURN DISTINCT id(m) AS id, labels(m) AS labels, properties(m) AS props " \
                 "LIMIT #{limit.to_i}"
        run(cypher, { "id" => node_id }).map { |row| node_from_row(row) }
      end

      def traverse(start_id, depth: 1, direction: "both", edge_type: nil, limit: 1000)
        # Cypher variable-length path `[*1..N]` — Neo4j AND Memgraph (the OPPOSITE
        # of Ultipa's GQL quantifier `{1,N}`).
        edge = edge_type ? ":`#{edge_type}`" : ""
        n = depth.to_i
        arrow = case direction
                when "out" then "-[#{edge}*1..#{n}]->"
                when "in" then "<-[#{edge}*1..#{n}]-"
                else "-[#{edge}*1..#{n}]-"
                end
        cypher = "MATCH (n)#{arrow}(m) WHERE id(n) = $start " \
                 "RETURN DISTINCT id(m) AS id, labels(m) AS labels, properties(m) AS props " \
                 "LIMIT #{limit.to_i}"
        run(cypher, { "start" => start_id }).map { |row| node_from_row(row) }
      end

      def close
        @conn&.close
      end

      private

      # Run a Cypher statement, wrapping the client's Bolt errors as the
      # framework's GraphConnectTimeout / GraphError.
      def run(cypher, params)
        @conn.run(cypher, params)
      rescue BoltConnection::BoltConnectError => e
        @last_error = e.message
        raise Tina4::GraphConnectTimeout,
              "Graph connect to #{@url.host}:#{@url.port} failed " \
              "(TINA4_GRAPH_CONNECT_TIMEOUT). Cause: #{e.message}"
      rescue BoltConnection::BoltError => e
        @last_error = e.message
        raise Tina4::GraphError, e.message
      end

      def node_from_row(row)
        return nil if row.nil?

        Tina4::GraphNode.new(
          id: row["id"], labels: row["labels"], properties: row["props"] || {}
        )
      end
    end
  end
end
