# frozen_string_literal: true
#
# Feature 19 - Input and request validation: the shared conformance contract.
# Parity with tina4-nodejs/test/validationContract.test.ts,
# tina4-python/tests/test_validation_contract.py,
# tina4-php/tests/ValidationContractTest.php.
#
# Two validators, both REAL-tested (no mocks, no doubles):
#   1. the chainable request-body Validator (advisory) - every rule pos + neg
#      (Ruby's max_length/max/in_list/regex were UNTESTED before this);
#   2. ORM field validation ENFORCED on save() (VALID-RUBY-NULLONLY - Ruby's
#      validate used to be NULL-ONLY, so an over-length/wrong-format value was
#      written silently): a constraint-violating model returns false from save
#      AND writes NOTHING - proven by a real COUNT(*) against real SQLite;
#   3. both validators emit ONE canonical message per rule (VALID-TWO-MESSAGES).
#
# Case names are shared verbatim across the four frameworks and gated by
# tina4-documentation/scripts/audit-contract-fixtures.py.

require "spec_helper"
require "tmpdir"

class ValidationPerson < Tina4::ORM
  table_name "validation_person"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :name, required: true, min_length: 2, max_length: 5
  integer_field :age, min: 0, max: 65
  string_field :code, pattern: /^[0-9]+$/
end

RSpec.describe "Feature 19 - input and request validation" do
  # A method, not a bare constant: a constant declared inside an RSpec.describe
  # block lands on Object and can clobber another spec file (a known footgun).
  def roles = %w[admin user guest]

  let(:tmp_dir) { Dir.mktmpdir("tina4_validation") }
  let(:db) { Tina4::Database.new("sqlite:///" + File.join(tmp_dir, "validation.db")) }

  before(:each) do
    Tina4.bind_database(db)
    db.execute(
      "CREATE TABLE validation_person (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER, code TEXT)"
    )
  end

  after(:each) { FileUtils.remove_entry(tmp_dir) if File.exist?(tmp_dir) }

  def row_count
    # fetch_one returns a Hash keyed by the column alias (symbol on SQLite);
    # values.first is the COUNT regardless of key spelling.
    db.fetch_one("SELECT COUNT(*) AS c FROM validation_person").values.first
  end

  # ── 1. request-body Validator: every rule, positive AND negative ───────────

  describe "request Validator rules (pos + neg)" do
    it "required rule passes a present value and reports a missing one" do
      expect(Tina4::Validator.new({ "name" => "Alice" }).required("name").is_valid?).to be true
      bad = Tina4::Validator.new({ "name" => "" }).required("name")
      expect(bad.is_valid?).to be false
      expect(bad.errors.first[:message]).to eq("name is required")
    end

    it "email rule passes a valid address and reports an invalid one" do
      expect(Tina4::Validator.new({ "email" => "a@b.co" }).email("email").is_valid?).to be true
      expect(Tina4::Validator.new({ "email" => "nope" }).email("email").errors.first[:message])
        .to eq("email must be a valid email address")
    end

    it "min length rule passes a long value and reports a short one" do
      expect(Tina4::Validator.new({ "name" => "Alice" }).min_length("name", 2).is_valid?).to be true
      expect(Tina4::Validator.new({ "name" => "A" }).min_length("name", 2).errors.first[:message])
        .to eq("name must be at least 2 characters")
    end

    it "max length rule passes a short value and reports a long one" do
      expect(Tina4::Validator.new({ "name" => "Al" }).max_length("name", 5).is_valid?).to be true
      expect(Tina4::Validator.new({ "name" => "Alexander" }).max_length("name", 5).errors.first[:message])
        .to eq("name must be at most 5 characters")
    end

    it "integer rule passes an integer and reports a non integer" do
      expect(Tina4::Validator.new({ "age" => 30 }).integer("age").is_valid?).to be true
      expect(Tina4::Validator.new({ "age" => "abc" }).integer("age").errors.first[:message])
        .to eq("age must be an integer")
    end

    it "min rule passes a value above the minimum and reports one below" do
      expect(Tina4::Validator.new({ "age" => 5 }).min("age", 0).is_valid?).to be true
      expect(Tina4::Validator.new({ "age" => -5 }).min("age", 0).errors.first[:message])
        .to eq("age must be at least 0")
    end

    it "max rule passes a value below the maximum and reports one above" do
      expect(Tina4::Validator.new({ "age" => 40 }).max("age", 65).is_valid?).to be true
      expect(Tina4::Validator.new({ "age" => 999 }).max("age", 65).errors.first[:message])
        .to eq("age must be at most 65")
    end

    it "in list rule passes an allowed value and reports a disallowed one" do
      expect(Tina4::Validator.new({ "role" => "admin" }).in_list("role", roles).is_valid?).to be true
      expect(Tina4::Validator.new({ "role" => "root" }).in_list("role", roles).errors.first[:message])
        .to eq('role must be one of ["admin","user","guest"]')
    end

    it "regex rule passes a matching value and reports a non matching one" do
      expect(Tina4::Validator.new({ "code" => "123" }).regex("code", /^[0-9]+$/).is_valid?).to be true
      expect(Tina4::Validator.new({ "code" => "abc" }).regex("code", /^[0-9]+$/).errors.first[:message])
        .to eq("code does not match the required format")
    end

    it "is valid reflects whether any rule failed" do
      expect(Tina4::Validator.new({ "name" => "Al", "age" => 30 }).required("name").integer("age").is_valid?)
        .to be true
      bad = Tina4::Validator.new({ "name" => "", "age" => "x" }).required("name").integer("age")
      expect(bad.is_valid?).to be false
      expect(bad.errors.length).to eq(2)
    end
  end

  # ── 2. ORM save() ENFORCES field validation and writes NOTHING ─────────────

  describe "ORM save() enforcement (real SQLite, writes nothing)" do
    it "a required violation makes save return false and writes nothing" do
      person = ValidationPerson.new(age: 30, code: "123") # name omitted -> nil
      expect(person.save).to be false
      expect(row_count).to eq(0)
    end

    it "an over length value makes save return false and writes nothing" do
      person = ValidationPerson.new(name: "Alexander", age: 30, code: "123")
      expect(person.save).to be false
      expect(row_count).to eq(0)
    end

    it "an out of range value makes save return false and writes nothing" do
      person = ValidationPerson.new(name: "Al", age: 999, code: "123")
      expect(person.save).to be false
      expect(row_count).to eq(0)
    end

    it "a pattern violation makes save return false and writes nothing" do
      person = ValidationPerson.new(name: "Al", age: 30, code: "abc")
      expect(person.save).to be false
      expect(row_count).to eq(0)
    end

    it "a valid model saves and writes one row" do
      expect(ValidationPerson.new(name: "Al", age: 30, code: "123").save).not_to be false
      expect(row_count).to eq(1)
    end
  end

  # ── 3. one canonical vocabulary across BOTH validators ─────────────────────

  describe "unified message vocabulary (request == ORM)" do
    it "required emits the same canonical message from both validators" do
      orm = ValidationPerson.new(age: 30, code: "123").validate.first
      req = Tina4::Validator.new({}).required("name").errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("name is required")
    end

    it "min length emits the same canonical message from both validators" do
      orm = ValidationPerson.new(name: "A", age: 30, code: "123").validate.first
      req = Tina4::Validator.new({ "name" => "A" }).min_length("name", 2).errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("name must be at least 2 characters")
    end

    it "max length emits the same canonical message from both validators" do
      orm = ValidationPerson.new(name: "Alexander", age: 30, code: "123").validate.first
      req = Tina4::Validator.new({ "name" => "Alexander" }).max_length("name", 5).errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("name must be at most 5 characters")
    end

    it "min emits the same canonical message from both validators" do
      orm = ValidationPerson.new(name: "Al", age: -5, code: "123").validate.first
      req = Tina4::Validator.new({ "age" => -5 }).min("age", 0).errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("age must be at least 0")
    end

    it "max emits the same canonical message from both validators" do
      orm = ValidationPerson.new(name: "Al", age: 999, code: "123").validate.first
      req = Tina4::Validator.new({ "age" => 999 }).max("age", 65).errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("age must be at most 65")
    end

    it "regex emits the same canonical message from both validators" do
      orm = ValidationPerson.new(name: "Al", age: 30, code: "abc").validate.first
      req = Tina4::Validator.new({ "code" => "abc" }).regex("code", /^[0-9]+$/).errors.first[:message]
      expect(orm).to eq(req)
      expect(orm).to eq("code does not match the required format")
    end
  end
end
