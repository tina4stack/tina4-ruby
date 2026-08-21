# frozen_string_literal: true

# Contract suite for the graph data layer (Feature 139) — against REAL engines.
#
# No mocks. Every live case runs a real connection and real round-trips, and is
# PARAMETERISED over every provisioned engine (provider substitutability, exactly
# like the relational engine matrix): Ultipa, Neo4j, Memgraph, ArangoDB. Each
# engine's URL comes from its own TINA4_TEST_<ENGINE>_URL; an engine whose URL is
# unset or unreachable is skipped. Case names mirror the Python contract
# (tests/test_graph.py) and fixtures/graph_contract.json.
#
# Only the raw-query dialect and the cleanup differ per engine (GQL/Cypher vs
# AQL) — the portable node/edge/traverse surface is identical everywhere, which
# is the whole point of the layer.
#
# Ultipa note: edge ids need EDGE_ID enabled on the graph
# (`ALTER GRAPH <g> SET EDGE_ID ENABLED`) — a one-time per-graph setting the lab
# provisions.

require "socket"
require "uri"
require_relative "spec_helper"

# Namespaced so the constants never land on Object (a bare constant inside an
# RSpec.describe is GLOBAL — see spec_helper's warning).
module GraphSpecEnv
  LABEL = "T4GraphContractTest"

  # Cypher/GQL dialect (Ultipa, Neo4j, Memgraph) vs AQL dialect (ArangoDB).
  CYPHER_RAW = "MATCH (n:`#{LABEL}`) WHERE n.name = $nm RETURN n.name AS name"
  CYPHER_CLEAN = "MATCH (n:`#{LABEL}`) DETACH DELETE n"
  AQL_RAW = "FOR n IN tina4_nodes FILTER n.name == @nm RETURN {name: n.name}"
  AQL_CLEAN = "FOR n IN tina4_nodes FILTER '#{LABEL}' IN n._labels REMOVE n IN tina4_nodes"

  # engine -> { env var for its URL, raw read query in the native dialect, and
  # the cleanup statement for the test label }.
  ENGINES = {
    "ultipa" => { env: "TINA4_TEST_ULTIPA_URL", raw: CYPHER_RAW, clean: CYPHER_CLEAN },
    "neo4j" => { env: "TINA4_TEST_NEO4J_URL", raw: CYPHER_RAW, clean: CYPHER_CLEAN },
    "memgraph" => { env: "TINA4_TEST_MEMGRAPH_URL", raw: CYPHER_RAW, clean: CYPHER_CLEAN },
    "arango" => { env: "TINA4_TEST_ARANGO_URL", raw: AQL_RAW, clean: AQL_CLEAN },
  }.freeze

  def self.reachable?(url)
    parsed = URI.parse(url)
    Socket.tcp(parsed.host, parsed.port, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  def self.live?(name)
    url = ENV[ENGINES[name][:env]]
    !url.nil? && !url.empty? && reachable?(url)
  end
end

RSpec.describe "Graph data layer (Feature 139)" do
  # ── driver-optional + URL selection: run WITHOUT a live engine ────────────

  # graph-driver-optional
  it "graph-driver-optional: core loads driver-free; a missing driver raises an install error" do
    # The core is already required (spec_helper -> tina4). A scheme whose driver
    # is absent surfaces the install error. We cannot uninstall a gem mid-suite,
    # so point the registry at a missing require path (mirrors the Python
    # monkeypatch) and assert the message names the package.
    registry = Tina4::GraphDatabase::ENGINE_ADAPTERS
    saved = registry["ultipa"]
    registry["ultipa"] = {
      require: "tina4/drivers/_definitely_absent",
      class: "Tina4::Drivers::Nope",
      package: "tina4-ultipa",
      install: "gem install tina4-ultipa",
    }
    begin
      expect { Tina4::GraphDatabase.create("ultipa://h:60061/g") }
        .to raise_error(Tina4::GraphError, /tina4-ultipa/)
    ensure
      registry["ultipa"] = saved
    end
  end

  # graph-connect-by-url
  it "graph-connect-by-url: a URL scheme selects the right adapter; an unknown scheme is rejected" do
    expect(Tina4::GraphUrl.new("ultipa://h:60061/g").engine).to eq("ultipa")
    expect(Tina4::GraphUrl.new("neo4j://h/db").engine).to eq("bolt")
    expect(Tina4::GraphUrl.new("neo4j://h/db").port).to eq(7687)
    expect(Tina4::GraphUrl.new("memgraph://h/db").engine).to eq("bolt")
    expect(Tina4::GraphUrl.new("arango://h/db").engine).to eq("arango")
    expect(Tina4::GraphUrl.new("arango://h/db").port).to eq(8529)
    expect { Tina4::GraphUrl.new("mysql://h/db") }.to raise_error(ArgumentError)
  end

  # graph-connect-timeout — uses the built-in Bolt driver (no gem needed), so it
  # runs everywhere. 10.255.255.1 completes no handshake — a real black hole.
  it "graph-connect-timeout: an unreachable host raises GraphConnectTimeout within the bound, naming host/port" do
    previous = ENV["TINA4_GRAPH_CONNECT_TIMEOUT"]
    ENV["TINA4_GRAPH_CONNECT_TIMEOUT"] = "2"
    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Tina4::GraphDatabase.create("neo4j://neo4j:x@10.255.255.1:7699/neo4j").get_node("x")
      end.to raise_error(Tina4::GraphConnectTimeout, /10\.255\.255\.1.*7699|7699.*10\.255\.255\.1/m)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 6
    ensure
      if previous.nil?
        ENV.delete("TINA4_GRAPH_CONNECT_TIMEOUT")
      else
        ENV["TINA4_GRAPH_CONNECT_TIMEOUT"] = previous
      end
    end
  end

  # ── the portable core + raw pass-through, per LIVE engine ─────────────────

  GraphSpecEnv::ENGINES.each_key do |engine_name|
    context "against live #{engine_name}", :live do
      let(:label) { GraphSpecEnv::LABEL }
      let(:cfg) { GraphSpecEnv::ENGINES[engine_name] }

      before(:each) do
        unless GraphSpecEnv.live?(engine_name)
          skip "live #{engine_name} not configured/reachable (set #{GraphSpecEnv::ENGINES[engine_name][:env]})"
        end

        @graph = Tina4::GraphDatabase.create(ENV[cfg[:env]])
        @graph.execute(cfg[:clean])
      end

      after(:each) do
        next unless @graph

        begin
          @graph.execute(cfg[:clean])
        ensure
          @graph.close
        end
      end

      # graph-connect-by-url (live)
      it "graph-connect-by-url-live: the URL yields a connected adapter" do
        expect(@graph).to be_a(Tina4::GraphAdapter)
      end

      # graph-add-node
      it "graph-add-node: add_node returns a node with an id, labels and properties" do
        node = @graph.add_node(label, { "name" => "Ada", "age" => 36 })
        expect(node).to be_a(Tina4::GraphNode)
        expect(node.id).not_to be_nil
        expect(node.labels).to include(label)
        expect(node.properties["name"]).to eq("Ada")
        expect(node.properties["age"]).to eq(36)
      end

      # graph-add-edge
      it "graph-add-edge: add_edge links two nodes; the edge carries type + properties" do
        a = @graph.add_node(label, { "name" => "Ada" })
        b = @graph.add_node(label, { "name" => "Bob" })
        edge = @graph.add_edge(a.id, b.id, "KNOWS", { "since" => 2020 })
        expect(edge).to be_a(Tina4::GraphEdge)
        expect(edge.id).not_to be_nil
        expect(edge.type).to eq("KNOWS")
        expect(edge.from).to eq(a.id)
        expect(edge.to).to eq(b.id)
        expect(edge.properties["since"]).to eq(2020)
      end

      # graph-get-node (roundtrip + miss)
      it "graph-get-node: get_node round-trips the stored properties, a miss returns nil" do
        a = @graph.add_node(label, { "name" => "Ada", "age" => 36 })
        got = @graph.get_node(a.id)
        expect(got.properties["name"]).to eq("Ada")
        expect(got.properties["age"]).to eq(36)
        tmp = @graph.add_node(label, { "x" => 1 })
        @graph.delete_node(tmp.id)
        expect(@graph.get_node(tmp.id)).to be_nil # a miss is not an error
      end

      # graph-update-delete-node
      it "graph-update-delete-node: update_node merges, delete_node removes (verified by re-read)" do
        a = @graph.add_node(label, { "name" => "Ada", "age" => 36 })
        @graph.update_node(a.id, { "name" => "Ada Lovelace", "city" => "London" })
        updated = @graph.get_node(a.id)
        expect(updated.properties["name"]).to eq("Ada Lovelace")
        expect(updated.properties["city"]).to eq("London")
        expect(updated.properties["age"]).to eq(36) # merge, not replace
        @graph.delete_node(a.id)
        expect(@graph.get_node(a.id)).to be_nil
      end

      # graph-neighbors
      it "graph-neighbors: neighbors returns connected nodes for a direction and edge type; unmatched is empty" do
        a = @graph.add_node(label, { "name" => "Ada" })
        b = @graph.add_node(label, { "name" => "Bob" })
        @graph.add_edge(a.id, b.id, "KNOWS", {})
        out = @graph.neighbors(a.id, direction: "out", edge_type: "KNOWS").map(&:id)
        expect(out).to include(b.id)
        expect(out).not_to include(a.id)
        expect(@graph.neighbors(a.id, edge_type: "NOPE")).to eq([]) # unmatched -> empty
      end

      # graph-traverse-depth
      it "graph-traverse-depth: traverse to depth N returns the reachable set" do
        a = @graph.add_node(label, { "name" => "A" })
        b = @graph.add_node(label, { "name" => "B" })
        c = @graph.add_node(label, { "name" => "C" })
        @graph.add_edge(a.id, b.id, "KNOWS", {})
        @graph.add_edge(b.id, c.id, "KNOWS", {})
        reached = @graph.traverse(a.id, depth: 2, direction: "out", edge_type: "KNOWS").map(&:id)
        expect(reached).to include(b.id) # 2 hops reach both
        expect(reached).to include(c.id)
      end

      # graph-raw-query
      it "graph-raw-query: a native-dialect query round-trips through query() with bound params" do
        @graph.add_node(label, { "name" => "Bob" })
        result = @graph.query(cfg[:raw], { "nm" => "Bob" })
        expect(result).to be_a(Tina4::GraphResult)
        expect(result.length).to be >= 1
        expect(result.records[0]["name"]).to eq("Bob")
      end

      # graph-write-fails-loud
      it "graph-write-fails-loud: a bad raw statement raises and records the cause on get_error" do
        expect { @graph.execute("THIS IS NOT A VALID STATEMENT") }.to raise_error(Tina4::GraphError)
        expect(@graph.get_error).not_to be_nil
      end
    end
  end
end
