# frozen_string_literal: true

require_relative "lib/tina4/version"

Gem::Specification.new do |spec|
  spec.name = "tina4ruby"
  spec.version = Tina4::VERSION
  spec.authors = ["Tina4 Team"]
  spec.email = ["info@tina4.com"]
  spec.summary = "Tina4 for Ruby — native Ruby conventions and shared Tina4 contracts"
  spec.description = "TINA4: The Intelligent Native Application 4ramework for Ruby. A Rack-based backend with native Ruby conventions and shared cross-language contracts."
  spec.homepage = "https://tina4.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.bindir = "exe"
  spec.executables = ["tina4ruby"]
  spec.require_paths = ["lib"]
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "rackup", "~> 2.1"
  spec.add_dependency "puma", "~> 6.0"
  # NO jwt gem. Tina4 signs and verifies every JWT with stdlib OpenSSL:
  # OpenSSL::HMAC for the standard HS256/HS384/HS512 family, and
  # OpenSSL::PKey::RSA#sign/#verify for the opt-in RS256. The gem was declared
  # only to wrap the base64url header.payload.signature envelope lib/tina4/auth.rb
  # already builds for the HMAC path, so it bought nothing. (Measured: a token
  # minted by the stdlib path verifies under PHP openssl_verify AND Node
  # crypto.createVerify, with a tampered payload INVALID in both.)

  spec.add_dependency "net-smtp", "~> 0.5"
  spec.add_dependency "net-imap", "~> 0.5"
  spec.add_dependency "json", "~> 2.7"
  spec.add_dependency "rexml", "~> 3.2"
  spec.add_dependency "webrick", "~> 1.8"
  # logger and base64 were DEFAULT gems until Ruby 3.4/4.0 demoted them to
  # BUNDLED gems, and a bundled gem that nothing declares is NOT on the load
  # path under Bundler. The two are NOT the same severity:
  #
  # logger is REQUIRED. Nothing in the transitive runtime closure of the
  # dependencies above provides it, so `require "logger"` (lib/tina4/log.rb)
  # raised LoadError on Ruby 4 and `tina4 serve` could not boot at all.
  #
  # base64 is now LOAD-BEARING. It used to resolve transitively through jwt, so
  # the declaration was belt-and-braces; dropping jwt removed that transitive
  # path, and eight files require base64 DIRECTLY (auth, api, websocket,
  # messenger, mcp, frond, realtime, dev_mailbox). Removing this line now breaks
  # `require "base64"` on Ruby 3.4+, where base64 is a BUNDLED gem and a bundled
  # gem nothing declares is not on the load path under Bundler.
  #
  # ostruct is deliberately NOT declared: tina4 never requires it. (A scaffold
  # may still need it if the app pulls in oj, which does declare it.)
  spec.add_dependency "logger", "~> 1.6"
  spec.add_dependency "base64", "~> 0.2"
  # sqlite3 is a runtime dependency because Tina4 Ruby promises "SQLite
  # works out of the box with zero configuration" (see Chapter 5 of the
  # book). Without this, `tina4 init ruby && tina4 serve` crashes on
  # first run with LoadError — see tina4-book#100.
  spec.add_dependency "sqlite3", "~> 2.0"

  # Graph databases (Feature 139) — NO runtime gem is added for them:
  #   * Ultipa uses the OPTIONAL, separately-published `tina4-ultipa` gem,
  #     required lazily by lib/tina4/drivers/ultipa_graph_driver.rb (a missing
  #     gem surfaces as an actionable install error, never a bare LoadError).
  #   * Neo4j + Memgraph (engine `bolt`) use a self-contained Bolt 4.4 /
  #     PackStream client built on stdlib `socket`
  #     (lib/tina4/drivers/bolt_graph_driver.rb). The maintained community gems
  #     were both rejected on the lab: `neo4j-ruby-driver` cannot negotiate with
  #     Memgraph (its handshake offers Bolt 4.4 only inside a range entry
  #     Memgraph declines, dropping to v3 where its strict version-string parser
  #     throws) and drags in ActiveSupport; the pure-Ruby `neo4j_bolt` gem
  #     hardcodes `scheme => 'none'` and cannot authenticate to Neo4j.
  #   * ArangoDB (engine `arango`) uses stdlib `Net::HTTP` over the AQL cursor
  #     REST endpoint (lib/tina4/drivers/arango_graph_driver.rb).
  # All three are REAL drivers proven live (no mocks); bolt + arango add zero
  # third-party dependencies, keeping the framework core zero-dependency.

  spec.add_development_dependency "listen", "~> 3.8"
  # mongo is OPTIONAL — the MongoDB cache backend (and session handler) require
  # it lazily, exactly like pg. It is a development/optional dependency only so
  # it is never force-installed; the backend degrades gracefully if it is absent.
  spec.add_development_dependency "mongo", "~> 2.19"
  # bigdecimal is REQUIRED for mongo to load at all on Ruby >= 3.4. It stopped
  # being a default gem there, and bson/decimal128.rb requires it unconditionally,
  # so without this every MongoDB spec fails at `require "mongo"` with
  # "cannot load such file -- bigdecimal" and NO Mongo code is ever exercised.
  # A real-service test that cannot load its client is not verification.
  spec.add_development_dependency "bigdecimal", "~> 4.0"
  spec.add_development_dependency "pg", "~> 1.5"
  # rdkafka (librdkafka binding) — optional, for the live Kafka queue backend +
  # its integration spec. Like mongo/pg it is a dev-only dependency so it is
  # never force-installed; the backend requires it lazily and the spec skips
  # when it is absent. Lets CI exercise the real Kafka enqueue/dequeue cycle.
  spec.add_development_dependency "rdkafka", "~> 0.20"
  # bunny — optional, for the live RabbitMQ queue backend + its integration spec.
  # Dev-only (like mongo/pg/rdkafka) so production installs stay lean; the backend
  # requires it lazily and the live RabbitMQ spec skips when it is absent (without
  # it the spec was perpetually skipped even with a broker reachable).
  spec.add_development_dependency "bunny", "~> 2.22"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.50"
  # openapi3_parser — TEST-ONLY OpenAPI 3.0 validator for the Swagger contract
  # suite (spec/swagger_contract_spec.rb). It implements the OpenAPI 3.0
  # validation rules and exposes document.valid? / document.errors, so the suite
  # checks the REAL generated /swagger/openapi.json against a real validator
  # instead of hand-rolling structural checks (the invariant that would have
  # caught the two frameworks that shipped a structurally invalid document). A
  # development dependency ONLY — like rspec/pg/mongo above it is never a runtime
  # dependency of the published gem, so the framework core stays zero-dependency.
  spec.add_development_dependency "openapi3_parser", "~> 0.10"
end
