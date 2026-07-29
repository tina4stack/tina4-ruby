# frozen_string_literal: true
#
# Lock-in: column names mirror the DATABASE verbatim, and `auto_map` is INERT here.
#
# Owner rule (2026-07-29): "Keep the column name exactly as it is in the
# DATABASE. A language-specific case mapping may be an OPT-IN later, but the
# default must mirror the DB so nobody guesses wrong."
#
# Ruby is snake_case-native: the attribute a developer declares IS the column
# name, so there is nothing for a case mapping to do. `auto_map` exists only so
# a model ported from PHP (where `autoMap` really does map a camelCase property
# onto a snake_case column) does not blow up on an unknown setter.
#
# It was dead in a worse sense than "does nothing": NOTHING read it, so setting
# `self.auto_map = false` to "turn the conversion off" got silence, and a
# developer could reasonably believe they had changed something. These specs
# make the inertness EXPLICIT and VERIFIED so the flag cannot quietly grow
# behaviour later without a named spec going red -- which a future opt-in would
# have to do deliberately.
#
# Deliberately NOT specced-for, because the owner's rule forbids it as a
# default: camelCase attribute -> snake_case column conversion.
#
# The PHP twin of the read-back spec below caught a REAL bug: with autoMap on,
# PHP re-pointed the column at a camelCase property the model never declared, so
# a model mirroring its DB columns SAVED correctly and READ BACK nil, silently.
# Ruby has no such conversion, so it must simply hold -- and now it is pinned.

require "spec_helper"

class CaseSnake < Tina4::ORM
  table_name "case_probe"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :first_name
end

class CaseAutoMapOff < Tina4::ORM
  table_name "case_probe"
  self.auto_map = false          # must behave IDENTICALLY to CaseSnake
  integer_field :id, primary_key: true, auto_increment: true
  string_field :first_name
end

class CaseExplicitMap < Tina4::ORM
  table_name "case_probe"
  self.field_mapping = { "given_name" => "first_name" }
  integer_field :id, primary_key: true, auto_increment: true
  string_field :given_name
end

RSpec.describe "ORM column-name case handling" do
  let(:tmp_dir) { Dir.mktmpdir("tina4_case") }
  let(:db_path) { File.join(tmp_dir, "case.db") }
  let(:db) { Tina4::Database.new("sqlite:///" + db_path) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute(
      "CREATE TABLE case_probe (id INTEGER PRIMARY KEY AUTOINCREMENT, first_name TEXT)"
    )
    db.commit
  end

  after(:each) do
    db.close
    FileUtils.rm_rf(tmp_dir)
  end

  describe "column names are verbatim" do
    it "writes the value into the declared column name" do
      m = CaseSnake.new(first_name: "Ada")
      expect(m.save).to be_truthy
      expect(db.fetch_one("SELECT first_name FROM case_probe")[:first_name]).to eq("Ada")
    end

    it "populates a verbatim-named attribute on read" do
      CaseSnake.new(first_name: "Ada").save
      back = CaseSnake.find(1)
      expect(back).not_to be_nil
      expect(back.first_name).to eq("Ada")
    end
  end

  describe "auto_map is inert" do
    # THE TRIPWIRE. If either of these goes red, someone gave the flag
    # behaviour, which the owner's rule says must be OPT-IN.

    it "defaults to true for cross-framework parity" do
      expect(CaseSnake.auto_map).to be true
    end

    it "changes nothing when explicitly set to false" do
      m = CaseAutoMapOff.new(first_name: "Grace")
      expect(m.save).to be_truthy
      expect(db.fetch_one("SELECT first_name FROM case_probe")[:first_name]).to eq("Grace")
      expect(CaseAutoMapOff.find(1).first_name).to eq("Grace")
    end

    it "is settable both ways without affecting the column" do
      expect(CaseAutoMapOff.auto_map).to be false
      expect(CaseSnake.auto_map).to be true
    end
  end

  describe "field_mapping is the supported mapping mechanism" do
    it "points an attribute at a differently-named column, both ways" do
      m = CaseExplicitMap.new(given_name: "Hedy")
      expect(m.save).to be_truthy
      expect(db.fetch_one("SELECT first_name FROM case_probe")[:first_name]).to eq("Hedy")
      expect(CaseExplicitMap.find(1).given_name).to eq("Hedy")
    end
  end
end
