# frozen_string_literal: true

# Contract suite for the graph data layer (Feature 139) — against a REAL engine.
#
# No mocks. Every live case runs a real connection and real round-trips against a
# provisioned graph engine. Ultipa community edition is the first engine; the URL
# comes from TINA4_TEST_ULTIPA_URL (the suite skips those cases when it is unset
# or unreachable, exactly like the relational live-database specs). Case names
# mirror the Python tests/test_graph.py contract.
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
  ULTIPA_URL = ENV["TINA4_TEST_ULTIPA_URL"]
  LABEL = "T4GraphContractTest"

  def self.reachable?(url)
    parsed = URI.parse(url)
    Socket.tcp(parsed.host, parsed.port || 60_061, connect_timeout: 2) { true }
  rescue StandardError
    false
  end

  def self.live?
    !ULTIPA_URL.nil? && !ULTIPA_URL.empty? && reachable?(ULTIPA_URL)
  end

  # The connect-timeout case needs the driver gem present (it targets an
  # unreachable host, so the server need not be live — but create() requires the
  # gem). Runs on the lab where the gem is installed.
  def self.driver_available?
    require "tina4_ultipa"
    true
  rescue LoadError
    false
  end
end

RSpec.describe "Graph data layer (Feature 139)" do
  # ── driver-optional + URL selection: run WITHOUT a live engine ────────────

  # graph-driver-optional
  it "graph-driver-optional: core loads driver-free; a missing driver raises an install error" do
    # The core is already required (spec_helper -> tina4). A scheme whose driver
    # is absent surfaces the install error. We cannot uninstall the gem
    # mid-suite, so point the registry at a missing require path (mirrors the
    # Python monkeypatch) and assert the message names the package.
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
    expect { Tina4::GraphUrl.new("mysql://h/db") }.to raise_error(ArgumentError)
  end

  # graph-connect-timeout
  it "graph-connect-timeout: an unreachable host raises GraphConnectTimeout within the bound, naming host/port" do
    skip "tina4-ultipa driver not installed" unless GraphSpecEnv.driver_available?

    previous = ENV["TINA4_GRAPH_CONNECT_TIMEOUT"]
    ENV["TINA4_GRAPH_CONNECT_TIMEOUT"] = "2"
    begin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # 10.255.255.1 completes no handshake — a real black hole, not a refusal.
      expect do
        Tina4::GraphDatabase.create("ultipa://admin:x@10.255.255.1:60071/default").get_node("x")
      end.to raise_error(Tina4::GraphConnectTimeout, /10\.255\.255\.1.*60071|60071.*10\.255\.255\.1/m)
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

  # ── the portable core + raw pass-through, against LIVE Ultipa ─────────────

  context "against live Ultipa", :live do
    let(:label) { GraphSpecEnv::LABEL }

    before(:each) do
      skip "live Ultipa not configured/reachable (set TINA4_TEST_ULTIPA_URL)" unless GraphSpecEnv.live?

      @graph = Tina4::GraphDatabase.create(GraphSpecEnv::ULTIPA_URL)
      @graph.execute("MATCH (n:`#{GraphSpecEnv::LABEL}`) DETACH DELETE n")
    end

    after(:each) do
      next unless @graph

      begin
        @graph.execute("MATCH (n:`#{GraphSpecEnv::LABEL}`) DETACH DELETE n")
      ensure
        @graph.close
      end
    end

    # graph-connect-by-url (live)
    it "graph-connect-by-url-live: the URL yields an Ultipa adapter" do
      expect(@graph).to be_a(Tina4::Drivers::UltipaGraphDriver)
    end

    # graph-add-node
    it "graph-add-node: addNode returns a node with an id, labels and properties" do
      node = @graph.add_node(label, { "name" => "Ada", "age" => 36 })
      expect(node).to be_a(Tina4::GraphNode)
      expect(node.id).not_to be_nil
      expect(node.labels).to include(label)
      expect(node.properties["name"]).to eq("Ada")
    end

    # graph-add-edge
    it "graph-add-edge: addEdge links two nodes; the edge carries type + properties" do
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
    it "graph-get-node: getNode round-trips the stored properties, a miss returns nil" do
      a = @graph.add_node(label, { "name" => "Ada", "age" => 36 })
      got = @graph.get_node(a.id)
      expect(got.properties["name"]).to eq("Ada")
      expect(got.properties["age"]).to eq(36)
      expect(@graph.get_node("no-such-id")).to be_nil # a miss is not an error
    end

    # graph-update-delete-node
    it "graph-update-delete-node: updateNode merges, deleteNode removes (verified by re-read)" do
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
      result = @graph.query(
        "MATCH (n:`#{GraphSpecEnv::LABEL}`) WHERE n.name = $nm RETURN n.name AS name",
        { "nm" => "Bob" },
      )
      expect(result).to be_a(Tina4::GraphResult)
      expect(result.length).to be >= 1
      expect(result.records[0]["name"]).to eq("Bob")
    end

    # graph-write-fails-loud
    it "graph-write-fails-loud: a bad raw statement raises and records the cause on get_error" do
      expect { @graph.execute("THIS IS NOT GQL") }.to raise_error(Tina4::GraphError)
      expect(@graph.get_error).not_to be_nil
    end
  end
end
