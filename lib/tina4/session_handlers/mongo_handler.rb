# frozen_string_literal: true
require "json"
require_relative "mongo_wire_client"

module Tina4
  module SessionHandlers
    class MongoHandler
      # Connection is configured from TINA4_SESSION_MONGO_* env vars (parity with
      # Python's MongoDBSessionHandler) so TINA4_SESSION_BACKEND=mongodb can be
      # pointed at a server by env. TINA4_SESSION_MONGO_URI is canonical;
      # TINA4_SESSION_MONGO_URL is a legacy alias. The database default is
      # "tina4" (Python's default — Ruby previously drifted to "tina4_sessions").
      # An explicit constructor option always wins over the environment.
      # NO NETWORK I/O IN A CONSTRUCTOR (ADR-0021, session_contract.json #4).
      # `require "mongo"` is a pure load and costs nothing on the wire;
      # Mongo::Client.new is NOT - it starts SDAM topology monitoring and
      # handshakes the server immediately, and ensure_ttl_index then issues a
      # createIndexes round trip (dropping and recreating the index on an
      # IndexOptionsConflict).
      #
      # MEASURED against a REAL counting TCP listener before this change:
      # constructing this handler accepted THREE connections. That traffic sat
      # OUTSIDE the log-loud-and-degrade policy, so an unreachable MongoDB took
      # the app down at construction instead of degrading per request - the one
      # place the policy cannot protect being the FIRST thing that runs.
      #
      # The client, the collection and the TTL index are all built on FIRST USE.
      #
      # TWO TRANSPORTS, ONE RESOLUTION POINT (session_contract.json #6,
      # ADR-0024). The `mongo` gem is used when it is installed; when it is NOT,
      # this handler speaks the MongoDB wire protocol directly over a socket via
      # MongoWireClient - zero dependencies, exactly as Python, PHP and Node have
      # always done. This line USED to be a bare `require "mongo"` whose
      # `rescue LoadError` re-raised "MongoDB session handler requires the
      # 'mongo' gem", so TINA4_SESSION_BACKEND=mongodb worked in three
      # frameworks and blew up in the fourth on identical configuration.
      # MEASURED at v3 HEAD in a real subprocess with no gems resolvable at all:
      # file, redis, valkey and memcached all round-tripped a session and
      # mongodb raised at Session construction.
      #
      # The probe stays a PURE LOAD - `require` opens no socket - so ADR-0021
      # (no network I/O in a constructor) still holds. Guarding on
      # ::Mongo::VERSION rather than on `require` alone is the same defence
      # RedisHandler#build_gem_client uses: a bare `Mongo` constant defined by
      # something else must not be mistaken for the real driver.
      def initialize(options = {})
        # TINA4_SESSION_TTL reaches every backend (ADR-0024); was a hard-coded
        # 86400. 3600 matches Python (the master), PHP and Node.
        @ttl = (options[:ttl] || ENV["TINA4_SESSION_TTL"] || 3600).to_i
        @uri = options[:uri] || ENV["TINA4_SESSION_MONGO_URI"] || ENV["TINA4_SESSION_MONGO_URL"] || "mongodb://localhost:27017"
        @database = options[:database] || ENV["TINA4_SESSION_MONGO_DB"] || "tina4"
        @collection_name = options[:collection] || ENV["TINA4_SESSION_MONGO_COLLECTION"] || "sessions"
        @gem_available = gem_available?
        @client = nil
        @wire_client = nil
        @collection = nil
        @index_ready = false
      end

      # Release whichever transport was opened.
      #
      # Mongo::Client owns a pool of REAL sockets. Before the client was lazy it
      # was a local variable in #initialize, reachable only through the
      # collection, so every construction leaked a pool and nothing could give it
      # back. Now the handler holds the client, so the handler can close it -
      # parity with the Python master's MongoDBSessionHandler.close() and with
      # Tina4::DocStore.close_doc_store, which already closes its Mongo clients
      # the same way. The zero-dependency transport owns ONE raw socket and is
      # closed the same way, so neither path leaks. Safe to call on a handler
      # that never connected.
      def close
        # Each close is guarded on its own: a failure on one transport must not
        # skip the other, and neither may mask the caller's work.
        [@client, @wire_client].each do |transport|
          transport&.close
        rescue StandardError
          nil
        end
      ensure
        @client = nil
        @wire_client = nil
        @collection = nil
        @index_ready = false
      end

      # Decide whether a stored document has expired, FROM THE DOCUMENT ALONE.
      #
      # THE CONTRACT: an ABSENT or ZERO expiry stamp means "never expires". It is
      # guarded OUT of the comparison, never fed INTO it - so a document written
      # by another framework, an older version, or a direct insert is returned
      # rather than destroyed. Identical to the Python master's _has_expired.
      def self.expired?(doc)
        expires_at = doc["expires_at"].to_f
        expires_at.positive? && expires_at < Time.now.to_f
      end

      def read(session_id)
        doc = collection.find(_id: session_id).first
        return nil unless doc

        # Expiry is checked HERE, at read time, against the document's own
        # absolute deadline. Relying on the TTL index alone (as this handler used
        # to) cannot honour a short TTL at all: mongod's TTL monitor sweeps once
        # every 60 SECONDS, so a 2-second session stayed readable for up to a
        # minute after it expired. The index is still created, but purely as the
        # background reaper that keeps the collection from growing forever.
        if self.class.expired?(doc)
          destroy(session_id)
          return nil
        end

        doc["data"]
      end

      # Write session data. A per-call +ttl+ WINS over the handler default.
      #
      # The ttl is consumed HERE, at write time, and baked into an ABSOLUTE
      # deadline (+expires_at+), so nothing at read time needs to know what the
      # ttl was. That field name and meaning are the shape Python (the master),
      # PHP and Node all store, so a session store SHARED between two frameworks
      # carries one shape instead of four. +updated_at+ is still written to feed
      # the TTL index.
      #
      # @param session_id [String] the session id
      # @param data [Hash] the payload to store
      # @param ttl [Integer] per-call lifetime in seconds; 0 uses the handler default
      def write(session_id, data, ttl = 0)
        effective_ttl = ttl.to_i.positive? ? ttl.to_i : @ttl
        now = Time.now
        expires_at = effective_ttl.positive? ? now.to_f + effective_ttl : 0.0
        collection.update_one(
          { _id: session_id },
          { "$set" => { data: data, expires_at: expires_at,
                        updated_at: now - (@ttl - effective_ttl) } },
          upsert: true
        )
      end

      def destroy(session_id)
        collection.delete_one(_id: session_id)
      end

      def cleanup
        gc
      end

      # Garbage-collect expired sessions. Matches the Python master's
      # MongoDBSessionHandler.gc and the FileHandler interface, and it is what
      # Session#gc calls when a handler responds to it.
      #
      # THE REAPER IS NOT OPTIONAL ON THE ZERO-DEPENDENCY TRANSPORT. The TTL
      # index below is created on the gem path only (creating it needs the gem's
      # own index API), so without this sweep a wire-protocol deployment would
      # keep every expired document forever. Expiry itself is unaffected either
      # way - #read checks the document's own absolute deadline.
      #
      # Same contract as #read: only a stamp that is genuinely PRESENT and in
      # the PAST makes a document a deletion candidate. `$gt: 0` is explicit so
      # a document with a zero stamp is never swept, and one with no stamp at
      # all cannot match the range predicate either.
      #
      # @param max_lifetime [Integer] accepted for interface parity; expiry is
      #   absolute and already baked into expires_at at write time.
      def gc(max_lifetime = nil)
        _ = max_lifetime
        collection.delete_many("expires_at" => { "$gt" => 0, "$lt" => Time.now.to_f })
      end

      private

      # Whether the REAL `mongo` gem is loadable. A pure load - it opens no
      # socket - so this is safe in a constructor (ADR-0021). Returns false when
      # the gem is absent, which selects the zero-dependency wire transport.
      def gem_available?
        require "mongo"
        defined?(::Mongo::VERSION) ? true : false
      rescue LoadError
        false
      end

      # The collection, built on FIRST USE rather than at construction, so every
      # byte this handler puts on the wire happens inside the log-loud-and-degrade
      # policy (see #initialize). Called by read/write/destroy/gc.
      #
      # THIS IS THE ONE PLACE THE TRANSPORT IS CHOSEN. read, write, destroy and
      # gc have no branch of their own: whichever transport this returns answers
      # find/update_one/delete_one/delete_many with the same shape, so the
      # request path cannot take one transport while a directly-constructed
      # handler takes the other. A per-operation branch is a branch that can be
      # wrong on one path only - which is exactly how a fallback ships untested.
      def collection
        return @collection if @collection

        if @gem_available
          @client = Mongo::Client.new(@uri, database: @database)
          @collection = @client[@collection_name]
          ensure_ttl_index
        else
          @wire_client = build_wire_client
          @collection = @wire_client
        end
        @collection
      end

      # The zero-dependency transport, pointed at the host and port parsed out of
      # the configured URI. Opens nothing here - MongoWireClient connects on its
      # first command.
      #
      # mongodb+srv:// is REFUSED here rather than half-supported. That scheme is
      # not a host at all: it is a DNS SRV lookup that yields the real seed list,
      # plus mandatory TLS. Parsing it as a hostname would dial
      # "cluster0.example.mongodb.net:27017" in the clear, which does not exist,
      # and the operator would get a bare connection-refused with nothing
      # pointing at the cause. Before this fallback existed they got a clear
      # "requires the 'mongo' gem"; they still get a clear message. Naming the
      # remedy at the point of use is the framework's rule for a genuinely
      # missing capability.
      def build_wire_client
        if @uri.to_s.start_with?("mongodb+srv://")
          raise "mongodb+srv:// needs a DNS SRV lookup and TLS, which the zero-dependency " \
                "MongoDB transport does not do. Install the 'mongo' gem (gem install mongo), " \
                "or point TINA4_SESSION_MONGO_URI at an explicit mongodb://host:port."
        end

        host, port = parse_host_port(@uri)
        MongoWireClient.new(host: host, port: port, database: @database, collection: @collection_name)
      end

      # Extract host and port from a MongoDB URI, mirroring the Python master's
      # _parse_url: strip the scheme, strip any credentials, strip the path and
      # query, then take the FIRST host of a seed list.
      #
      # URI.parse is deliberately not used: a perfectly ordinary replica-set URI
      # ("mongodb://a:27017,b:27017/db") is not a valid RFC 3986 authority, so it
      # raises - and defaulting to localhost there would silently dial the WRONG
      # server, which is far worse than any parse error.
      def parse_host_port(uri)
        remainder = uri.to_s.sub(%r{\Amongodb://}, "")
        remainder = remainder.split("@", 2).last.to_s   # credentials
        remainder = remainder.split("/", 2).first.to_s  # path + query
        remainder = remainder.split(",", 2).first.to_s  # first seed host
        host, port = remainder.split(":", 2)
        host = "localhost" if host.nil? || host.empty?
        [host, port.nil? || port.empty? ? 27_017 : port.to_i]
      end

      # Create the updated_at TTL index. An existing updated_at index with a
      # DIFFERENT expireAfterSeconds raises IndexOptionsConflict (code 85) — a
      # TTL index cannot be modified in place — so drop and recreate it with the
      # requested TTL. This makes re-init idempotent (no per-run error log) and
      # lets a changed session TTL take effect.
      #
      # GEM PATH ONLY - #collection calls it in that branch and nowhere else.
      # Python, PHP and Node create no TTL index on any transport, so the
      # zero-dependency path reaps with #gc instead and expiry itself is
      # unchanged either way (#read checks the document's own deadline). It also
      # could not run here: the rescues below name Mongo::Error, a constant that
      # does not exist when the gem is absent, so evaluating them would raise
      # NameError rather than the LoadError anyone would expect.
      #
      # Runs ONCE per handler (@index_ready), on the first operation. The flag is
      # set BEFORE the round trip so an unreachable server is not re-probed on
      # every read - the same ordering the Python master uses for _table_ready.
      def ensure_ttl_index
        return if @index_ready

        @index_ready = true
        @collection.indexes.create_one({ updated_at: 1 }, expire_after_seconds: @ttl)
      rescue Mongo::Error::OperationFailure => e
        raise unless e.code == 85 || e.message.include?("IndexOptionsConflict")
        @collection.indexes.drop_one("updated_at_1")
        @collection.indexes.create_one({ updated_at: 1 }, expire_after_seconds: @ttl)
      rescue Mongo::Error => e
        # The index is the background REAPER, not the expiry authority - #read
        # checks expires_at on the document itself - so failing to create it must
        # not break sessions. The constructor swallowed this the same way; the
        # only change is WHERE it is swallowed. A genuinely unreachable server
        # still surfaces on the read/write that follows, inside the policy.
        Tina4::Log.error("MongoDB session setup failed: #{e.message}")
      end
    end
  end
end
