# frozen_string_literal: true
source "https://rubygems.org"
gemspec name: "tina4ruby"

gem "net-smtp", "~> 0.5.1"

gem "net-imap", "~> 0.6.3"
gem "net-pop", "~> 0.1.2"

# Optional service-client gems for the live cross-engine / cross-service test
# suite (#262). mysql2 + tiny_tds compile native extensions against system
# client libraries (libmysqlclient, FreeTDS); redis is the RESP client the
# Valkey/Redis SESSION handler hard-requires (`require "redis"`). They live in
# an OPTIONAL group so a plain `bundle install` on a machine without those libs
# stays green and the SQLite/PostgreSQL suite still runs. Opt in where the libs
# exist: CI sets BUNDLE_WITH=databases (and apt-installs the native libs); local
# dev runs `bundle config set --local with databases`. The specs gate on the
# client being loadable AND the service reachable — they exercise the REAL
# engine/service when enabled and skip cleanly when the group is absent.
group :databases, optional: true do
  gem "mysql2", "~> 0.5"
  gem "tiny_tds", "~> 3.4"
  gem "redis", "~> 5.0"
end
