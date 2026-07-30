# frozen_string_literal: true

require "json"
require "spec_helper"

# The shared DATABASE_URL corpus (feature 5 of the feature audit).
#
# spec/fixtures/database_url_corpus.json is byte-identical in all four
# frameworks. One answer key, four suites: a case that passes here and fails in
# Node is a parity bug with a name, not a difference somebody has to notice.
#
# Core Principle 6 says a connection string means literally the same thing in
# every framework. Nothing could check that before this fixture, because Ruby
# and Python parsed URLs inline inside the Database constructor and could not be
# asked what a URL means without opening a connection.
#
# Pure string-to-value. No database, no socket, no driver load.
# LOCALS, not constants. A constant defined inside an RSpec.describe block leaks
# to the global namespace, and spec/frond_expression_parity_spec.rb already
# defines CORPUS - so whichever file loaded second silently replaced the other's
# fixture, and these examples read the FROND corpus. The per-case examples still
# passed because they are generated at load time, before the collision; only the
# ones that iterate at RUN time failed, and only in a full-suite run. Locals are
# captured by the blocks and cannot collide.
url_corpus = JSON.parse(File.read(File.join(__dir__, "fixtures", "database_url_corpus.json"))).freeze
url_fields = %w[engine host port database username password].freeze

RSpec.describe Tina4::DatabaseUrl do

  describe "every corpus case" do
    url_corpus["cases"].each do |c|
      it "parses #{c['name']} to the agreed struct" do
        url = described_class.new(c["url"])
        got = url_fields.to_h { |f| [f, url.public_send(f)] }
        want = url_fields.to_h { |f| [f, c[f]] }
        expect(got).to eq(want)
      end

      it "round-trips #{c['name']} through to_safe_string" do
        expect(described_class.new(c["url"]).to_safe_string).to eq(c["safe"])
      end
    end
  end

  # A connection URL in a log is a credential leak, so the redacted form is the
  # only shape allowed in a log line or an error message - which is why inspect
  # uses it too.
  describe "redaction" do
    url_corpus["cases"].reject { |c| c["password"].nil? }.each do |c|
      it "never leaks the password for #{c['name']}" do
        url = described_class.new(c["url"])
        expect(url.to_safe_string).not_to include(c["password"])
        expect(url.inspect).not_to include(c["password"])
      end
    end
  end

  describe "an unparseable URL" do
    url_corpus["errors"].each do |c|
      # A silent fallback to sqlite is the dangerous outcome: the app boots,
      # writes to a local file, and nobody learns the real database was never
      # reached. That is exactly what detect_driver's `else "sqlite"` did.
      it "raises for #{c['name']} instead of guessing" do
        expect { described_class.new(c["url"]) }
          .to raise_error(ArgumentError, /DatabaseUrl/)
      end
    end
  end

  describe "aliases" do
    it "resolves every alias to its canonical engine, once, at parse" do
      url_corpus["aliases"].each do |alias_name, canonical|
        sample = alias_name == "sqlite3" ? "#{alias_name}:///app.db" : "#{alias_name}://localhost/db"
        expect(described_class.new(sample).engine).to eq(canonical), alias_name
      end
    end
  end

  describe "default ports" do
    # The port is part of our contract, not the driver's business. A URL with no
    # port used to yield a different struct per framework, and the thing hiding
    # it was a third-party default rather than agreement.
    it "applies the engine default when the URL carries no port" do
      url_corpus["default_ports"].each do |engine, port|
        next if engine == "firebird" # needs a path segment; covered by the cases

        expect(described_class.new("#{engine}://localhost/db").port).to eq(port), engine
      end
    end
  end

  describe "the engine field" do
    it "never holds an adapter class name" do
      canonical = %w[sqlite postgres mysql mssql firebird mongodb odbc]
      url_corpus["cases"].each do |c|
        expect(canonical).to include(described_class.new(c["url"]).engine), c["name"]
      end
    end
  end

  describe "parsing without a database" do
    # The whole point of the value type. Before this, tina4 doctor, the setup
    # wizard, and anything else wanting to validate a URL had nothing to call.
    it "parses a URL without opening a connection" do
      url = described_class.new("postgres://u:p@db.internal:5432/app")
      expect(url.engine).to eq("postgres")
      expect(url.dsn).to eq("db.internal:5432/app")
    end
  end
end
