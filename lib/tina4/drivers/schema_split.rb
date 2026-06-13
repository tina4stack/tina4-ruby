# frozen_string_literal: true

module Tina4
  module Drivers
    # v3.13.14 (#48): split a possibly-qualified table name into [schema, table].
    #
    # A model whose table name is qualified — PostgreSQL "gift_cards.gift_card",
    # MSSQL "dbo.widget", MySQL "otherdb.table", SQLite "attached.table" — lives
    # in that schema/catalog, not the default. Drivers use this so table_exists?
    # / columns query the right namespace instead of matching the whole dotted
    # string as one flat name. Returns [nil, name] for a bare name. Splits on the
    # first dot. Firebird has no schemas, so its driver ignores this.
    module SchemaSplit
      def split_schema(name)
        str = name.to_s
        idx = str.index(".")
        return [nil, str] if idx.nil?

        [str[0...idx], str[(idx + 1)..]]
      end
    end
  end
end
