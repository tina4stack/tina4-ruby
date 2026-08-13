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

# Competitor template engines for the Frond throughput comparison
# (benchmarks/bench_templates.rb). Erubi is the ERB implementation Rails uses, so
# it is the engine Frond is actually measured against; plain ERB needs nothing
# because it is stdlib. OPTIONAL on purpose: a benchmark dependency must never be
# something a plain `bundle install` or the gemspec drags in -- the framework core
# stays zero-dependency.
#
# Opt in by APPENDING to the groups you already have, colon-separated -- do not pass
# `benchmarks` alone, because `bundle config set --local with` REPLACES the value and
# would silently drop :databases (which is how the mysql2/tiny_tds/redis specs go quiet):
#   bundle config set --local with "databases:benchmarks"
# BUNDLE_WITH in the environment does NOT help here: a local .bundle/config `with`
# setting outranks it, so an existing local value must be replaced, not overridden.
group :benchmarks, optional: true do
  gem "erubi", "~> 1.13"
end

# The `fb` gem (native Firebird driver) lives in its OWN optional group, kept
# SEPARATE from :databases on purpose: the main `test` job installs :databases
# but does NOT apt-install libfbclient/firebird-dev, so folding fb into
# :databases would break that job's `bundle install` when fb's C extension tries
# to link. The dedicated live-Firebird CI job (see .github/workflows/test.yml)
# apt-installs firebird-dev and sets BUNDLE_WITH=firebird, so fb compiles and the
# firebird specs run against a REAL Firebird 5.0.2. Everywhere else this group is
# absent and the firebird specs skip cleanly.
group :firebird, optional: true do
  gem "fb", "~> 0.10.0"
end

# The `ruby-odbc` gem (native ODBC driver) lives in its OWN optional group, kept
# SEPARATE like :firebird: its C extension links against unixODBC (libodbc), which
# the main `test` job does NOT apt-install, so folding it into :databases would
# break that job's `bundle install`. A machine with unixODBC + a driver opts in
# (`bundle config set --local with odbc`; the lab sets BUNDLE_WITH=odbc), and the
# ODBC-provider spec runs against a REAL ODBC source. Everywhere else this group
# is absent and the spec skips cleanly.
group :odbc, optional: true do
  gem "ruby-odbc", "~> 0.9"
end
