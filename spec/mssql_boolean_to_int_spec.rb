# frozen_string_literal: true

require "spec_helper"

# The mssql driver (and firebird) wire boolean_to_int into translate_sql, so a
# bare TRUE/FALSE reaches a BIT-backed engine as 1/0. A TRUE/FALSE inside a
# string literal is data and must survive untouched.
#
# No mocks: translate_sql is a pure function over its input, and the driver
# constructor opens no connection (connect is a separate call that lazy-loads the
# native gem). Regression guard for the wiring gap where the drivers translated
# AUTOINCREMENT and the DDL types but never the boolean literal.
#
# Mirrors the Python master's tests/test_mssql_boolean_to_int_wiring.py.
RSpec.describe "boolean_to_int adapter wiring" do
  describe Tina4::Drivers::MssqlDriver do
    let(:driver) { described_class.new }

    it "turns a bare TRUE into 1 and FALSE into 0" do
      insert = driver.translate_sql("INSERT INTO flags (active) VALUES (TRUE)")
      expect(insert).to include("(1)")
      expect(insert).not_to match(/TRUE/i)
      expect(driver.translate_sql("UPDATE flags SET active = FALSE")).to match(/=\s*0/)
    end

    it "preserves a TRUE inside a string literal" do
      expect(driver.translate_sql("SELECT id FROM flags WHERE label = 'TRUE'")).to include("'TRUE'")
    end
  end

  describe Tina4::Drivers::FirebirdDriver do
    let(:driver) { described_class.new }

    it "turns a bare TRUE into 1 (parity guard)" do
      insert = driver.translate_sql("INSERT INTO flags (active) VALUES (TRUE)")
      expect(insert).to include("(1)")
      expect(insert).not_to match(/TRUE/i)
    end

    it "preserves a TRUE inside a string literal" do
      expect(driver.translate_sql("SELECT id FROM flags WHERE label = 'TRUE'")).to include("'TRUE'")
    end
  end
end
