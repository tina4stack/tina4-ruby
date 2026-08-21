# frozen_string_literal: true

# Ultipa graph adapter — the portable core built in GQL over tina4-ultipa.
#
# Wraps the standalone +tina4-ultipa+ gem (an OPTIONAL dependency — required
# here, so +require "tina4/graph"+ stays driver-free). The portable
# node/edge/traverse surface is expressed in Ultipa GQL on top of the driver's
# +query+/+execute+; raw +query+/+execute+ send GQL straight through.
#
# GQL note: the exact statements are verified against the live Ultipa community
# edition on the lab (no mocks). Ultipa node ids come back as UUID strings; edge
# ids need EDGE_ID enabled on the graph (a one-time per-graph setting the lab
# provisions).

# The gem is optional: this require is what makes a missing driver surface as the
# actionable install error in GraphDatabase.create.
require "tina4_ultipa"

module Tina4
  module Drivers
    class UltipaGraphDriver < Tina4::GraphAdapter
      # nil (unbounded) is mapped to a very large finite deadline for the gRPC
      # driver, whose connect deadline is Time.now + connect_timeout (a 0 there
      # would mean "do not wait", not "wait forever").
      UNBOUNDED_CONNECT_TIMEOUT = 315_360_000 # ~10 years

      def initialize(graph_url, username: "", password: "")
        @url = graph_url
        @last_error = nil
        timeout = Tina4.resolve_graph_connect_timeout
        @client = Tina4Ultipa::Client.new(
          host: graph_url.host,
          port: graph_url.port,
          username: graph_url.username || (username unless username.to_s.empty?),
          password: graph_url.password || (password unless password.to_s.empty?),
          graph: graph_url.graph,
          connect_timeout: timeout.nil? ? UNBOUNDED_CONNECT_TIMEOUT : timeout,
          use_tls: graph_url.use_tls,
        )
      end

      # -- connection + raw pass-through -----------------------------------

      def query(text, params = nil)
        result = run(text, params: params, read_only: true)
        Tina4::GraphResult.new(records: result.dicts, columns: result.columns)
      end

      def execute(text, params = nil)
        result = run(text, params: params, read_only: false)
        Tina4::GraphResult.new(records: result.dicts, columns: result.columns)
      end

      # -- portable node/edge/traverse core (GQL) --------------------------

      def add_node(label, properties = nil)
        prop_map, params = prop_clause(properties)
        gql = "INSERT (n:`#{label}` #{prop_map}) " \
              "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(gql, params: params, read_only: false).dicts
        node_from_row(rows[0])
      end

      def add_edge(from_id, to_id, type, properties = nil)
        # id(e) requires EDGE_ID enabled on the Ultipa graph
        # (`ALTER GRAPH <g> SET EDGE_ID ENABLED`), a one-time per-graph setting.
        prop_map, params = prop_clause(properties)
        params["from_id"] = from_id
        params["to_id"] = to_id
        gql = "MATCH (a), (b) WHERE id(a) = $from_id AND id(b) = $to_id " \
              "INSERT (a)-[e:`#{type}` #{prop_map}]->(b) " \
              "RETURN id(e) AS id, type(e) AS type, id(a) AS f, id(b) AS t, " \
              "properties(e) AS props"
        rows = run(gql, params: params, read_only: false).dicts
        return nil if rows.empty?

        row = rows[0]
        Tina4::GraphEdge.new(
          id: row["id"], type: row["type"], from: row["f"], to: row["t"],
          properties: row["props"] || {},
        )
      end

      def get_node(node_id)
        gql = "MATCH (n) WHERE id(n) = $id " \
              "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(gql, params: { "id" => node_id }, read_only: true).dicts
        node_from_row(rows[0])
      end

      def update_node(node_id, properties)
        properties ||= {}
        sets = properties.keys.map { |key| "n.#{key} = $p_#{key}" }.join(", ")
        params = {}
        properties.each { |key, value| params["p_#{key}"] = value }
        params["id"] = node_id
        gql = "MATCH (n) WHERE id(n) = $id SET #{sets} " \
              "RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props"
        rows = run(gql, params: params, read_only: false).dicts
        node_from_row(rows[0])
      end

      def delete_node(node_id)
        run("MATCH (n) WHERE id(n) = $id DETACH DELETE n",
            params: { "id" => node_id }, read_only: false)
        true
      end

      def neighbors(node_id, direction: "both", edge_type: nil, limit: 100)
        edge = edge_type ? ":`#{edge_type}`" : ""
        pattern = case direction
                  when "out" then "(n)-[#{edge}]->(m)"
                  when "in" then "(n)<-[#{edge}]-(m)"
                  else "(n)-[#{edge}]-(m)"
                  end
        gql = "MATCH #{pattern} WHERE id(n) = $id " \
              "RETURN DISTINCT id(m) AS id, labels(m) AS labels, properties(m) AS props " \
              "LIMIT #{limit.to_i}"
        rows = run(gql, params: { "id" => node_id }, read_only: true).dicts
        rows.map { |row| node_from_row(row) }
      end

      def traverse(start_id, depth: 1, direction: "both", edge_type: nil, limit: 1000)
        # Ultipa GQL uses the ISO quantified-path form `-[]->{1,N}`, NOT Cypher's
        # `-[*1..N]->` (which is a parse error on gqldb).
        edge = edge_type ? ":`#{edge_type}`" : ""
        quant = "{1,#{depth.to_i}}"
        pattern = case direction
                  when "out" then "(n)-[#{edge}]->#{quant}(m)"
                  when "in" then "(n)<-[#{edge}]-#{quant}(m)"
                  else "(n)-[#{edge}]-#{quant}(m)"
                  end
        gql = "MATCH #{pattern} WHERE id(n) = $start " \
              "RETURN DISTINCT id(m) AS id, labels(m) AS labels, properties(m) AS props " \
              "LIMIT #{limit.to_i}"
        rows = run(gql, params: { "start" => start_id }, read_only: true).dicts
        rows.map { |row| node_from_row(row) }
      end

      def close
        @client.close
      end

      private

      # Run a GQL statement, wrapping the driver's connect/query errors as the
      # framework's GraphConnectTimeout / GraphError. ConnectError is rescued
      # FIRST because it subclasses the driver's Error.
      def run(gql, params: nil, read_only: true)
        @client.query(gql, params: params, read_only: read_only)
      rescue Tina4Ultipa::ConnectError => e
        @last_error = e.message
        raise Tina4::GraphConnectTimeout,
              "Graph connect to #{@url.host}:#{@url.port} timed out " \
              "(TINA4_GRAPH_CONNECT_TIMEOUT). Raise TINA4_GRAPH_CONNECT_TIMEOUT if the " \
              "server is simply slow, or set it to 0 to wait indefinitely. Cause: #{e.message}"
      rescue Tina4Ultipa::Error => e
        @last_error = e.message
        raise Tina4::GraphError, e.message
      end

      # Build a GQL property map `{k1: $p_k1, ...}` + the param hash for it.
      #
      # Params are BOUND (never interpolated), matching the relational
      # ?-placeholder rule. Keys are namespaced (`p_`) so they never collide with
      # an id param.
      def prop_clause(properties)
        properties ||= {}
        return ["{}", {}] if properties.empty?

        pairs = properties.keys.map { |key| "#{key}: $p_#{key}" }.join(", ")
        params = {}
        properties.each { |key, value| params["p_#{key}"] = value }
        ["{#{pairs}}", params]
      end

      def node_from_row(row)
        return nil if row.nil?

        Tina4::GraphNode.new(
          id: row["id"], labels: row["labels"], properties: row["props"] || {},
        )
      end
    end
  end
end
