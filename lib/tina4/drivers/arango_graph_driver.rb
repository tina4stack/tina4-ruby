# frozen_string_literal: true

# ArangoDB graph adapter — the document/AQL engine behind the same surface.
#
# Arango is a document store, not a labelled-property graph, so the portable core
# maps onto ONE vertex collection + ONE edge collection: a node's +labels+ and an
# edge's +type+ live as document fields (+_labels+ / +_type+), ids are Arango
# +_id+ handles (e.g. +tina4_nodes/123+), and traversal uses AQL
# +FOR v IN 1..N OUTBOUND …+. Raw +query+/+execute+ take AQL directly.
#
# The transport is a small pure-Ruby client over Arango's REST AQL cursor
# endpoint (+POST /_api/cursor+) built on stdlib +Net::HTTP+ — NO third-party gem.
# This is a REAL driver hitting a REAL engine (proven live on the lab, no mocks),
# and it keeps the framework core zero-dependency: the community Arango gems are
# thin wrappers over the same REST API, and the AQL cursor surface is exactly what
# the graph layer needs.

require "net/http"
require "json"
require "uri"

module Tina4
  module Drivers
    class ArangoGraphDriver < Tina4::GraphAdapter
      VERTEX_COLLECTION = "tina4_nodes"
      EDGE_COLLECTION = "tina4_edges"
      # Arango collection types: 2 = document, 3 = edge (verified live — the edge
      # collection MUST be type 3 for AABB traversal to work).
      TYPE_DOCUMENT = 2
      TYPE_EDGE = 3
      RESERVED = %w[_id _key _rev _from _to _labels _type].freeze

      # A connect/transport failure (unreachable host, refused, timeout).
      class ArangoConnectError < StandardError; end
      # A request/AQL failure (bad query, engine error, HTTP error status).
      class ArangoError < StandardError; end

      def initialize(graph_url, username: "", password: "")
        @url = graph_url
        @last_error = nil
        @timeout = Tina4.resolve_graph_connect_timeout
        scheme = graph_url.use_tls ? "https" : "http"
        @base = "#{scheme}://#{graph_url.host}:#{graph_url.port}"
        @database = graph_url.graph || "_system"
        @user = graph_url.username
        @user = username unless @user && !@user.empty?
        @user = "root" if @user.nil? || @user.empty?
        @password = graph_url.password
        @password = password unless @password && !@password.empty?
        ensure_collections
      end

      # -- raw pass-through (native AQL) -----------------------------------

      def query(text, params = nil)
        rows = aql(text, params)
        columns = rows[0].is_a?(Hash) ? rows[0].keys : []
        Tina4::GraphResult.new(records: rows, columns: columns)
      end

      def execute(text, params = nil)
        query(text, params)
      end

      # -- portable node/edge/traverse core (AQL) --------------------------

      def add_node(label, properties = nil)
        doc = (properties || {}).dup
        doc["_labels"] = [label]
        rows = aql("INSERT @doc INTO #{VERTEX_COLLECTION} RETURN NEW", { "doc" => doc })
        node_from_doc(rows[0])
      end

      def add_edge(from_id, to_id, type, properties = nil)
        doc = (properties || {}).dup
        doc["_from"] = from_id
        doc["_to"] = to_id
        doc["_type"] = type
        rows = aql("INSERT @doc INTO #{EDGE_COLLECTION} RETURN NEW", { "doc" => doc })
        return nil if rows.empty?

        row = rows[0]
        Tina4::GraphEdge.new(
          id: row["_id"], type: row["_type"], from: row["_from"], to: row["_to"],
          properties: clean_props(row)
        )
      end

      def get_node(node_id)
        rows = aql("RETURN DOCUMENT(@id)", { "id" => node_id })
        return nil if rows.empty? || rows[0].nil?

        node_from_doc(rows[0])
      end

      def update_node(node_id, properties)
        rows = aql(
          "UPDATE PARSE_IDENTIFIER(@id).key WITH @props IN #{VERTEX_COLLECTION} RETURN NEW",
          { "id" => node_id, "props" => properties || {} }
        )
        node_from_doc(rows[0])
      end

      def delete_node(node_id)
        # Remove the node and any edges touching it, so a re-read is a clean miss.
        aql(
          "FOR e IN #{EDGE_COLLECTION} FILTER e._from == @id OR e._to == @id " \
          "REMOVE e IN #{EDGE_COLLECTION}", { "id" => node_id }
        )
        aql("REMOVE PARSE_IDENTIFIER(@id).key IN #{VERTEX_COLLECTION}", { "id" => node_id })
        true
      end

      def neighbors(node_id, direction: "both", edge_type: nil, limit: 100)
        rows = aql(traversal_query(1, direction, edge_type),
                   traversal_bind(node_id, limit, edge_type))
        rows.map { |doc| node_from_doc(doc) }
      end

      def traverse(start_id, depth: 1, direction: "both", edge_type: nil, limit: 1000)
        rows = aql(traversal_query(depth.to_i, direction, edge_type),
                   traversal_bind(start_id, limit, edge_type))
        rows.map { |doc| node_from_doc(doc) }
      end

      def close
        # Net::HTTP opens a fresh connection per request here — nothing to hold open.
        true
      end

      private

      def traversal_query(depth, direction, edge_type)
        dir = { "out" => "OUTBOUND", "in" => "INBOUND", "both" => "ANY" }.fetch(direction, "ANY")
        type_filter = edge_type ? "FILTER e._type == @etype " : ""
        # LIMIT BEFORE RETURN — the whole point of the depth-bounded traversal.
        "FOR v, e IN 1..#{depth} #{dir} @start #{EDGE_COLLECTION} " \
          "#{type_filter}LIMIT @limit RETURN DISTINCT v"
      end

      def traversal_bind(start_id, limit, edge_type)
        bind = { "start" => start_id, "limit" => limit.to_i }
        bind["etype"] = edge_type if edge_type
        bind
      end

      # -- AQL cursor transport --------------------------------------------

      # Run one AQL statement, paging the cursor to completion, returning the
      # full result array. Wraps transport errors as GraphConnectTimeout and AQL
      # errors as GraphError.
      def aql(query, bind = nil)
        body = { "query" => query }
        body["bindVars"] = bind if bind && !bind.empty?
        response = request("POST", "/_db/#{@database}/_api/cursor", body)
        results = Array(response["result"])
        cursor_id = response["id"]
        while response["hasMore"]
          response = request("PUT", "/_db/#{@database}/_api/cursor/#{cursor_id}", nil)
          results.concat(Array(response["result"]))
        end
        results
      rescue ArangoConnectError => e
        @last_error = e.message
        raise Tina4::GraphConnectTimeout,
              "Graph connect to #{@url.host}:#{@url.port} failed " \
              "(TINA4_GRAPH_CONNECT_TIMEOUT). Raise TINA4_GRAPH_CONNECT_TIMEOUT if the server is " \
              "simply slow, or set it to 0 to wait indefinitely. Cause: #{e.message}"
      rescue ArangoError => e
        @last_error = e.message
        raise Tina4::GraphError, e.message
      end

      def ensure_collections
        create_collection(VERTEX_COLLECTION, TYPE_DOCUMENT) unless collection?(VERTEX_COLLECTION)
        create_collection(EDGE_COLLECTION, TYPE_EDGE) unless collection?(EDGE_COLLECTION)
      rescue ArangoConnectError => e
        @last_error = e.message
        raise Tina4::GraphConnectTimeout,
              "Graph connect to #{@url.host}:#{@url.port} failed " \
              "(TINA4_GRAPH_CONNECT_TIMEOUT). Cause: #{e.message}"
      rescue ArangoError => e
        @last_error = e.message
        raise Tina4::GraphError, e.message
      end

      def collection?(name)
        request("GET", "/_db/#{@database}/_api/collection/#{name}", nil)
        true
      rescue ArangoError
        false
      end

      def create_collection(name, type)
        request("POST", "/_db/#{@database}/_api/collection", { "name" => name, "type" => type })
      end

      # Issue one HTTP request, parse the JSON body, raise on an error status.
      def request(method, path, body)
        uri = URI.parse("#{@base}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        if @timeout
          http.open_timeout = @timeout
          http.read_timeout = @timeout
        end
        klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
                  "PUT" => Net::HTTP::Put, "DELETE" => Net::HTTP::Delete }.fetch(method)
        req = klass.new(uri.request_uri)
        req.basic_auth(@user, @password.to_s)
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        response = http.request(req)
        parse_response(response)
      rescue Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ECONNREFUSED,
             Errno::ENETUNREACH, Net::OpenTimeout, Net::ReadTimeout,
             SocketError, Timeout::Error => e
        raise ArangoConnectError, e.message
      end

      def parse_response(response)
        parsed = response.body && !response.body.empty? ? JSON.parse(response.body) : {}
        code = response.code.to_i
        if code >= 400 || parsed["error"] == true
          message = parsed["errorMessage"] || parsed["error"] || "HTTP #{response.code}"
          raise ArangoError, "ArangoDB error #{parsed['errorNum'] || code}: #{message}"
        end
        parsed
      rescue JSON::ParserError => e
        raise ArangoError, "invalid ArangoDB response: #{e.message}"
      end

      def node_from_doc(doc)
        return nil if doc.nil?

        Tina4::GraphNode.new(
          id: doc["_id"], labels: doc["_labels"] || [], properties: clean_props(doc)
        )
      end

      def clean_props(doc)
        doc.reject { |key, _| RESERVED.include?(key) }
      end
    end
  end
end
