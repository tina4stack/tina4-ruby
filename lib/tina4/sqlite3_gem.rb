# frozen_string_literal: true

module Tina4
  # The sqlite3 gem is an APPLICATION dependency, not a framework one
  # (ADR-0067): `tina4 init ruby` writes gem "sqlite3" into the project's
  # Gemfile, and tina4ruby itself never declares it, exactly like pg, mysql2 and
  # the other drivers. Everything that opens SQLite goes through here so a
  # project without the gem gets one actionable message instead of a bare
  # "cannot load such file -- sqlite3".
  SQLITE3_MISSING_MESSAGE =
    "The 'sqlite3' gem is required for SQLite connections. Add gem \"sqlite3\" " \
    "to your Gemfile (tina4 init ruby does this for you), or install one of:\n" \
    "    bundle add sqlite3     # if your project uses Bundler\n" \
    "    gem install sqlite3    # bare driver"

  def self.require_sqlite3!
    require "sqlite3"
  rescue LoadError
    raise LoadError, SQLITE3_MISSING_MESSAGE
  end
end
