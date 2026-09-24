# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


require_relative "lib/tina4/version"

Gem::Specification.new do |spec|
  spec.name = "tina4ruby"
  spec.version = Tina4::VERSION
  spec.authors = ["Tina4 Team"]
  spec.email = ["info@tina4.com"]
  spec.summary = "Tina4 for Ruby — native Ruby conventions and shared Tina4 contracts"
  spec.description = "TINA4: The Intelligent Native Application 4ramework for Ruby. A zero-dependency backend with its own HTTP server, native Ruby conventions and shared cross-language contracts."
  spec.homepage = "https://tina4.com"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[README.md LICENSE LICENSE.txt NOTICE COMMERCIAL-LICENSE.md CHANGELOG.md]
  spec.bindir = "exe"
  spec.executables = ["tina4ruby"]
  spec.require_paths = ["lib"]
  # NO web-server gems: no rack, rackup, puma or webrick. Tina4 serves HTTP
  # itself (lib/tina4/http_server.rb, stdlib socket) in development AND
  # production, and parses multipart forms itself (lib/tina4/form_parser.rb).
  # The app is still a Rack-style call(env) object, so an application that
  # WANTS Puma adds `gem "puma"` to its own Gemfile and production uses it
  # (ADR-0067); TINA4_DEFAULT_WEBSERVER=TRUE pins the built-in server anyway.
  # NO jwt gem. Tina4 signs and verifies every JWT with stdlib OpenSSL:
  # OpenSSL::HMAC for the standard HS256/HS384/HS512 family, and
  # OpenSSL::PKey::RSA#sign/#verify for the opt-in RS256. The gem was declared
  # only to wrap the base64url header.payload.signature envelope lib/tina4/auth.rb
  # already builds for the HMAC path, so it bought nothing. (Measured: a token
  # minted by the stdlib path verifies under PHP openssl_verify AND Node
  # crypto.createVerify, with a tampered payload INVALID in both.)

  # NOT declared, and never to come back (spec/zero_dependency_gemspec_spec.rb):
  #   json    a DEFAULT gem on every Ruby this gem supports (3.1 to 4.0), so it is
  #           always loadable, Bundler or not.
  #   base64  a BUNDLED gem since Ruby 3.4, so it would have to be declared.
  #           Instead lib/tina4/base64.rb provides the same six methods on core
  #           Array#pack("m") / String#unpack1("m"), which is all the gem does.
  #   logger  nothing in lib/ or exe/ requires it: Tina4::Log writes and rotates
  #           its own files. (It was declared when log.rb used ::Logger.)
  #   ostruct never required by tina4. (A scaffold may still need it if the app
  #           pulls in oj, which does declare it.)
  #   net-smtp, net-imap  replaced by Tina4's own clients on stdlib socket +
  #           openssl (lib/tina4/smtp_client.rb, imap_client.rb, mail_socket.rb):
  #           plain / STARTTLS / implicit TLS, AUTH PLAIN and LOGIN, and exactly
  #           the IMAP commands Messenger uses. That also drops net-protocol,
  #           timeout and date, which only ever arrived through those two.
  #   rexml   replaced by lib/tina4/xml_parser.rb for SOAP bodies: UTF-8 only and
  #           no DTD support at all, so no entity expansion and no XXE.
  # sqlite3 is an APPLICATION dependency (ADR-0067), exactly like pg and mysql2:
  # tina4ruby requires it lazily through Tina4.require_sqlite3!
  # (lib/tina4/sqlite3_gem.rb), which raises an actionable LoadError naming the
  # fix when it is missing. "SQLite works out of the box" still holds because
  # `tina4 init ruby` writes gem "sqlite3" into the new project's Gemfile
  # (tina4-book#100). It stays a development dependency for this repo's suite.

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

  spec.add_development_dependency "sqlite3", "~> 2.0"
  spec.add_development_dependency "listen", "~> 3.8"
  # puma is a DEVELOPMENT dependency only, so spec/puma_shutdown_spec.rb can
  # boot the opt-in production path for real (ADR-0067). It is never installed
  # for an application unless that application asks for it.
  # Puma 7.2.1 fixes the reported request-framing advisories; upstream requires Ruby >=3.0, preserving the framework Ruby >=3.1 floor.
  spec.add_development_dependency "puma", "~> 7.2", ">= 7.2.1"
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
  # NO rubocop dev-dependency. The framework ships no linter — `tina4ruby lint`
  # installs rubocop on demand into the USER's project (bundle add rubocop
  # --group development), so a Tina4 app stays zero-dependency until the developer
  # asks to lint. Keeping it here would force rubocop into every framework install
  # and contradict that contract.
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
