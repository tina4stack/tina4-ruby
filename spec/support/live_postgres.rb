# frozen_string_literal: true

require "socket"

# ── The live PostgreSQL the credential specs connect to ───────────────────────
#
# A credential claim ("the password does not reach this message") is only worth
# anything against a REAL server, so these specs connect to one. This module
# exists so they do not each hand-roll the endpoint - and, more importantly, so
# they stop SKIPPING.
#
# spec/database_url_credentials_spec.rb used to gate on an unset
# TINA4_TEST_PG_URL and skip with "live PostgreSQL not configured". That skip
# reads as green, and it slips past the TINA4_REQUIRE_SERVICES gate too: the
# gate matches "postgres" plus an unavailability hint ("not reachable", "not
# set", ...) and "not configured" is not one of them. So the one end-to-end
# proof that a percent-encoded password reaches the driver has been silently not
# running. Picking a reachable endpoint instead of demanding an env var makes it
# run everywhere it can.
module LivePostgres
  module_function

  # Preference order: whatever the operator configured, then the endpoint the
  # security batch names, then the local container the other PG specs use.
  def host
    @host ||= begin
      candidates = [ENV["TINA4_TEST_PG_HOST"], "192.168.88.99", "localhost"].compact
      candidates.find { |candidate| port_open?(candidate, port) } || candidates.last
    end
  end

  def port
    ENV.fetch("TINA4_TEST_PG_PORT", "55432").to_i
  end

  def username
    ENV.fetch("TINA4_TEST_PG_USERNAME", "tina4")
  end

  def password
    ENV.fetch("TINA4_TEST_PG_PASSWORD", "tina4")
  end

  def database
    ENV.fetch("TINA4_TEST_PG_DB", "tina4_py")
  end

  def reachable?
    port_open?(host, port)
  end

  def url(user: username, pass: password, db: database)
    "postgres://#{user}:#{pass}@#{host}:#{port}/#{db}"
  end

  def port_open?(target_host, target_port)
    Socket.tcp(target_host, target_port, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end
end
