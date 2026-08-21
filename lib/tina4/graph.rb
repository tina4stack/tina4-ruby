# frozen_string_literal: true

require "uri"

# Tina4 graph data layer — a URL-selected graph database, shaped like Database.
#
# Feature 139. One factory (+GraphDatabase.create+ / +.from_env+), one portable
# node/edge/traverse surface plus a raw +query+/+execute+ pass-through, and
# neutral +GraphNode+ / +GraphEdge+ / +GraphResult+ shapes — the exact mirror of
# the relational +Database+ layer, for graph engines (Ultipa first). Engine
# drivers are OPTIONAL and loaded only on first use, so the zero-dependency core
# is preserved.
#
# See ADR-0059 and tina4-documentation/plan/v3/features/139-graph-databases.md.
module Tina4
  # The graph connect bound — sibling of TINA4_DATABASE_CONNECT_TIMEOUT.
  GRAPH_CONNECT_TIMEOUT_VAR = "TINA4_GRAPH_CONNECT_TIMEOUT"
  DEFAULT_GRAPH_CONNECT_TIMEOUT_SECONDS = 10.0

  # Seconds a graph connect may block; +nil+ means unbounded (a value <= 0).
  #
  # Mirrors the relational connect-timeout resolver: a value <= 0 disables the
  # bound, a non-number warns and falls back to the default rather than waiting
  # forever.
  def self.resolve_graph_connect_timeout
    raw = (ENV[GRAPH_CONNECT_TIMEOUT_VAR] || "").strip
    return DEFAULT_GRAPH_CONNECT_TIMEOUT_SECONDS if raw.empty?

    begin
      seconds = Float(raw)
    rescue ArgumentError, TypeError
      Tina4::Log.warning(
        "#{GRAPH_CONNECT_TIMEOUT_VAR}=#{raw.inspect} is not a number of seconds — " \
        "bounding graph connects at the #{DEFAULT_GRAPH_CONNECT_TIMEOUT_SECONDS.to_i}s default instead",
      )
      return DEFAULT_GRAPH_CONNECT_TIMEOUT_SECONDS
    end
    seconds <= 0 ? nil : seconds
  end

  # A graph operation failed (bad statement, engine error).
  class GraphError < StandardError; end

  # A graph connect exceeded TINA4_GRAPH_CONNECT_TIMEOUT.
  #
  # A subclass of +GraphError+, so a +rescue GraphError+ catches a connect
  # timeout too — mirroring the driver's ConnectError < Error hierarchy.
  class GraphConnectTimeout < GraphError; end

  # A parsed graph connection URL — the DatabaseUrl sibling for graph engines.
  #
  # +engine+ is the CANONICAL name the factory selects an adapter by; a scheme
  # alias resolves to its engine here. bolt/neo4j/memgraph all speak Bolt/Cypher
  # and share ONE adapter ("bolt"); the engine label only tunes per-engine
  # defaults.
  class GraphUrl
    SCHEME_ENGINE = {
      "ultipa" => "ultipa",
      "ultipas" => "ultipa", # TLS variant
      "neo4j" => "bolt",
      "neo4j+s" => "bolt",
      "bolt" => "bolt",
      "bolt+s" => "bolt",
      "memgraph" => "bolt",
      "arango" => "arango",
      "arangodb" => "arango",
    }.freeze

    # Default port per engine when the URL omits one.
    ENGINE_DEFAULT_PORT = {
      "ultipa" => 60_061,
      "bolt" => 7687,
      "arango" => 8529,
    }.freeze

    attr_reader :raw, :scheme, :engine, :host, :port, :graph, :username,
                :password, :params, :use_tls

    def initialize(url)
      @raw = url
      parsed = begin
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        raise ArgumentError, "GraphUrl: Invalid URL format — expected scheme://host:port/graph"
      end

      scheme = (parsed.scheme || "").downcase
      engine = SCHEME_ENGINE[scheme]
      if engine.nil?
        raise ArgumentError,
              "GraphUrl: Unsupported graph URL scheme '#{scheme}'. Supported: " \
              "#{SCHEME_ENGINE.keys.sort.join(', ')} (e.g. ultipa://host:60061/mygraph)."
      end

      @scheme = scheme
      @engine = engine
      @host = parsed.host && !parsed.host.empty? ? parsed.host : "localhost"
      @port = parsed.port || ENGINE_DEFAULT_PORT[engine]
      # The path is the graph/database name (one leading slash stripped).
      graph = (parsed.path || "").sub(%r{\A/}, "")
      @graph = graph.empty? ? nil : graph
      @username = parsed.user ? URI.decode_www_form_component(parsed.user) : nil
      @password = parsed.password ? URI.decode_www_form_component(parsed.password) : nil
      @params = URI.decode_www_form(parsed.query || "").to_h
      # TLS if the scheme says so (…s) or ?tls=1.
      @use_tls = scheme.end_with?("s") || %w[1 true].include?(@params["tls"])
    end

    # host:port/graph — for messages, never carrying credentials.
    def dsn
      target = @port ? "#{@host}:#{@port}" : @host
      @graph ? "#{target}/#{@graph}" : target
    end

    # Parse the configured URL, or +nil+ when the variable is not set.
    def self.from_env(env_key = "TINA4_GRAPH_URL")
      url = (ENV[env_key] || "").strip
      url.empty? ? nil : new(url)
    end
  end

  # An engine-neutral vertex: id, labels, properties.
  class GraphNode
    attr_reader :id, :labels, :properties

    def initialize(id:, labels: nil, properties: nil)
      @id = id
      @labels = Array(labels)
      @properties = properties || {}
    end

    def to_h
      { "id" => @id, "labels" => @labels, "properties" => @properties }
    end

    def inspect
      "#<Tina4::GraphNode id=#{@id.inspect} labels=#{@labels.inspect}>"
    end
  end

  # An engine-neutral edge: id, type, from/to node ids, properties.
  class GraphEdge
    attr_reader :id, :type, :from, :to, :properties

    def initialize(id:, type:, from:, to:, properties: nil)
      @id = id
      @type = type
      @from = from
      @to = to
      @properties = properties || {}
    end

    def to_h
      { "id" => @id, "type" => @type, "from" => @from, "to" => @to,
        "properties" => @properties }
    end

    def inspect
      "#<Tina4::GraphEdge id=#{@id.inspect} type=#{@type.inspect} " \
        "#{@from.inspect}->#{@to.inspect}>"
    end
  end

  # A raw-query result — records + columns, same shape as DatabaseResult.
  class GraphResult
    include Enumerable

    attr_reader :records, :columns

    def initialize(records: nil, columns: nil)
      @records = records || []
      @columns = columns || []
    end

    def to_a
      @records
    end

    def scalar
      return nil if @records.empty?

      first = @records[0]
      if first.is_a?(Hash)
        first.values.first
      elsif first.is_a?(Array)
        first.empty? ? nil : first[0]
      else
        first
      end
    end

    def each(&block)
      @records.each(&block)
    end

    def length
      @records.length
    end
    alias size length
  end

  # The one surface every graph engine implements. Raising stubs — a driver that
  # does not override a method fails LOUDLY, naming itself and the method.
  class GraphAdapter
    # -- portable node/edge/traverse core ---------------------------------
    def add_node(_label, _properties = nil)
      not_implemented(__method__)
    end

    def add_edge(_from_id, _to_id, _type, _properties = nil)
      not_implemented(__method__)
    end

    def get_node(_node_id)
      not_implemented(__method__)
    end

    def update_node(_node_id, _properties)
      not_implemented(__method__)
    end

    def delete_node(_node_id)
      not_implemented(__method__)
    end

    def neighbors(_node_id, direction: "both", edge_type: nil, limit: 100)
      not_implemented(__method__)
    end

    def traverse(_start_id, depth: 1, direction: "both", edge_type: nil, limit: 1000)
      not_implemented(__method__)
    end

    # -- raw pass-through (engine-native dialect) -------------------------
    def query(_text, _params = nil)
      not_implemented(__method__)
    end

    def execute(_text, _params = nil)
      not_implemented(__method__)
    end

    # -- lifecycle --------------------------------------------------------
    def close
      not_implemented(__method__)
    end

    # Cause of the last failed operation, or +nil+.
    def get_error
      @last_error
    end

    private

    def not_implemented(method_name)
      raise NotImplementedError, "#{self.class.name} does not implement #{method_name}"
    end
  end

  # The URL-selected graph factory — the GraphDatabase sibling of Database.
  class GraphDatabase
    # engine -> { require:, class:, package:, install: }. Selected lazily so
    # requiring +tina4/graph+ pulls in NO engine driver. bolt (Neo4j/Memgraph)
    # and arango land later — declared so the factory gives a "coming soon"
    # message rather than a bare KeyError.
    ENGINE_ADAPTERS = {
      "ultipa" => {
        require: "tina4/drivers/ultipa_graph_driver",
        class: "Tina4::Drivers::UltipaGraphDriver",
        package: "tina4-ultipa",
        install: "gem install tina4-ultipa   # or add gem \"tina4-ultipa\" to your Gemfile",
      },
    }

    # Parse the URL, pick the engine adapter, connect lazily.
    #
    # The engine driver is required only here (first use of that engine); if it
    # is absent the error names the package and the install command.
    def self.create(url, username: "", password: "")
      graph_url = GraphUrl.new(url)
      registration = ENGINE_ADAPTERS[graph_url.engine]
      if registration.nil?
        raise GraphError,
              "No graph adapter for engine '#{graph_url.engine}' yet " \
              "(scheme '#{graph_url.scheme}'). Available: " \
              "#{ENGINE_ADAPTERS.keys.sort.join(', ')}."
      end

      begin
        require registration[:require]
      rescue LoadError => e
        # The adapter file requires its driver gem at the top; a missing gem
        # surfaces here as an actionable install error, never a bare LoadError.
        raise GraphError,
              "The graph driver for '#{graph_url.engine}' is not installed " \
              "(#{registration[:package]}). Install it with:\n    #{registration[:install]}",
          cause: e
      end

      adapter_class = Object.const_get(registration[:class])
      adapter_class.new(graph_url, username: username, password: password)
    end

    # Build from TINA4_GRAPH_URL (+ TINA4_GRAPH_USERNAME/_PASSWORD).
    def self.from_env(env_key: "TINA4_GRAPH_URL")
      url = ENV[env_key]
      return nil if url.nil? || url.strip.empty?

      create(url,
             username: ENV["TINA4_GRAPH_USERNAME"].to_s,
             password: ENV["TINA4_GRAPH_PASSWORD"].to_s)
    end
  end
end
