# frozen_string_literal: true
source "https://rubygems.org"
gemspec name: "tina4ruby"

gem "net-smtp", "~> 0.5.1"

gem "net-imap", "~> 0.6.3"
gem "net-pop", "~> 0.1.2"

# MySQL + MSSQL drivers for the live cross-engine test suite (issue #262).
# Both compile native extensions against system client libraries
# (libmysqlclient for mysql2, FreeTDS for tiny_tds). They live in an OPTIONAL
# group so a plain `bundle install` on a machine without those libs stays green
# and the rest of the suite (SQLite/PostgreSQL) still runs. Opt in where the
# libs exist: CI sets BUNDLE_WITH=databases (and apt-installs the libs); local
# dev runs `bundle config set --local with databases`. The MySQL/MSSQL specs
# gate on the driver being loadable AND the service reachable, so they exercise
# the REAL engine when enabled and skip cleanly when the group is absent.
group :databases, optional: true do
  gem "mysql2", "~> 0.5"
  gem "tiny_tds", "~> 3.4"
end
