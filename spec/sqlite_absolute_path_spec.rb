# frozen_string_literal: true

require "spec_helper"

# Regression guard for cross-framework SQLite absolute-path parity.
#
# The "naive" absolute form is `sqlite:` + an absolute filesystem path with a
# SINGLE leading slash, e.g. `sqlite:/var/data/app.db`. tina4-ruby ALREADY
# handles this correctly: SqliteDriver.resolve_path strips the scheme
# sequentially (sqlite:/// → sqlite:// → sqlite:) so `sqlite:/abs` collapses to
# `/abs` and is treated as absolute (no cwd join, no mkdir outside cwd).
# tina4-python / tina4-php / tina4-nodejs were fixed to MATCH this behaviour, so
# this spec LOCKS IN the Ruby side as the reference — if a future refactor of the
# scheme-stripping regressed the naive form back to a cwd-relative join, this
# fails loudly.
#
# No mocks — real SQLite files on disk via the actual sqlite3 gem.
RSpec.describe "SQLite absolute-path parity (real DB)" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_sqlite_abs") }
  let(:abs)     { File.join(tmp_dir, "app.db") }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  describe ".resolve_path — naive absolute form (regression guard)" do
    it "returns the absolute path unchanged for `sqlite:` + one-leading-slash abs" do
      # tmp_dir from Dir.mktmpdir is already absolute (one leading slash).
      expect(abs).to start_with("/")

      resolved = Tina4::Drivers::SqliteDriver.resolve_path("sqlite:" + abs)

      # Absolute in, absolute out — NOT joined under cwd.
      expect(resolved).to start_with("/")
      expect(resolved).to eq(abs)
      expect(resolved).not_to start_with(Dir.pwd + "/") unless abs.start_with?(Dir.pwd + "/")
    end
  end

  describe "real connect via naive absolute form" do
    it "creates the DB file at the ABSOLUTE path (not cwd-relative) and round-trips" do
      # Drive it from an UNRELATED cwd so a stray cwd-join would put the file in
      # the wrong place and this assertion would catch it.
      Dir.mktmpdir("tina4_other_cwd") do |other_cwd|
        Dir.chdir(other_cwd) do
          driver = Tina4::Drivers::SqliteDriver.new
          driver.connect("sqlite:" + abs)
          driver.execute("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT)")
          driver.execute("INSERT INTO widgets (id, name) VALUES (?, ?)", [1, "gizmo"])
          driver.close

          # The real file must exist at the ABSOLUTE path we asked for...
          expect(File.exist?(abs)).to be true
          # ...and NOT at a cwd-relative location (abs re-rooted under other_cwd).
          expect(File.exist?(File.join(other_cwd, abs.sub(%r{\A/}, "")))).to be false
        end
      end

      # Reopen the SAME absolute file (fresh driver) and read the row back —
      # proves the data persisted to the on-disk file, not an ephemeral one.
      reopened = Tina4::Drivers::SqliteDriver.new
      reopened.connect("sqlite:" + abs)
      rows = reopened.execute_query("SELECT id, name FROM widgets ORDER BY id")
      reopened.close

      expect(rows.length).to eq(1)
      expect(rows.first[:id]).to eq(1)
      expect(rows.first[:name]).to eq("gizmo")
    end
  end

  describe ".resolve_path — documented forms unchanged" do
    it "three-slash URL stays relative to cwd" do
      Dir.mktmpdir("tina4_cwd") do |cwd|
        Dir.chdir(cwd) do
          resolved_cwd = Dir.pwd # macOS symlinks /var -> /private/var
          expected = File.join(resolved_cwd, "data", "app.db")
          expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///data/app.db")).to eq(expected)
        end
      end
    end

    it "four-slash absolute form stays absolute" do
      expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:////#{abs}")).to start_with("/")
    end

    it "canonical four-slash form (sqlite:/// + abs) resolves to the abs path" do
      # sqlite:/// (three slashes) + abs's own leading slash = four slashes total,
      # the documented absolute URL form.
      expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///#{abs}")).to eq(abs)
    end

    it ":memory: short form passes through" do
      expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite::memory:")).to eq(":memory:")
    end

    it ":memory: URL form passes through" do
      expect(Tina4::Drivers::SqliteDriver.resolve_path("sqlite:///:memory:")).to eq(":memory:")
    end
  end
end
