# migration_contract :: create_migration validates its kind
#
# MEASURED 2026-08-06 across all four frameworks: the accepted value for a CODE
# migration differed in every one, and NOT ONE validated it.
#
#   python "python"   php "php"   ruby "ruby" or "python"   node "class"
#
# So create_migration("add users", kind: "python") produced a code migration in
# Python and Ruby and a SILENT .sql file in PHP and Node - the same call, four
# artefacts, no error. The caller finds out when the migration does nothing they
# wrote.
#
# "code" is now canonical in all four; each keeps its language name as a legacy
# alias; anything else raises. Ruby's extra "python" alias is DROPPED - it was a
# copy-paste from the master and a Ruby project never wants a .py migration.
#
# Pure filesystem work - no service, no double.

require "spec_helper"
require "tmpdir"

RSpec.describe "migration kind contract" do
  around { |ex| Dir.mktmpdir("tina4-migkind-") { |d| @dir = d; ex.run } }

  def create(description, kind: nil)
    if kind.nil?
      Tina4::Migration.create_migration(description, migrations_dir: @dir)
    else
      Tina4::Migration.create_migration(description, migrations_dir: @dir, kind: kind)
    end
  end

  it "accepts code as the canonical kind" do
    expect(File.extname(create("add users", kind: "code"))).to eq(".rb")
  end

  it "still accepts the language name as a legacy alias" do
    expect(File.extname(create("add users", kind: "ruby"))).to eq(".rb")
  end

  it "defaults to sql and leaves it unchanged" do
    expect(File.extname(create("a"))).to eq(".sql")
    expect(File.extname(create("b", kind: "sql"))).to eq(".sql")
  end

  it "raises on an unknown kind instead of silently writing sql" do
    # Another framework's spelling is the most likely typo, and "python" was
    # accepted here by mistake - a Ruby project never wants a .py migration.
    %w[python php class typo].each do |bogus|
      expect { create("add users", kind: bogus) }
        .to raise_error(ArgumentError, /Unknown migration kind/),
            "kind #{bogus.inspect} did not raise - it silently produced a file"
    end
  end
end
