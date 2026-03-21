# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Testing do
  before(:each) do
    Tina4::Testing.reset!
  end

  describe ".reset!" do
    it "clears all suites" do
      Tina4::Testing.describe("Suite") { it("test") { assert(true) } }
      expect(Tina4::Testing.suites.length).to eq(1)
      Tina4::Testing.reset!
      expect(Tina4::Testing.suites).to be_empty
    end

    it "resets results counters" do
      Tina4::Testing.reset!
      results = Tina4::Testing.results
      expect(results[:passed]).to eq(0)
      expect(results[:failed]).to eq(0)
      expect(results[:errors]).to eq(0)
      expect(results[:tests]).to be_empty
    end
  end

  describe ".describe" do
    it "creates a test suite" do
      Tina4::Testing.describe("My Suite") do
        it("does something") { assert(true) }
      end
      expect(Tina4::Testing.suites.length).to eq(1)
      expect(Tina4::Testing.suites.first.name).to eq("My Suite")
    end

    it "creates multiple test suites" do
      Tina4::Testing.describe("Suite A") { it("test") { assert(true) } }
      Tina4::Testing.describe("Suite B") { it("test") { assert(true) } }
      expect(Tina4::Testing.suites.length).to eq(2)
    end

    it "registers tests within a suite" do
      Tina4::Testing.describe("Suite") do
        it("test one") { assert(true) }
        it("test two") { assert(true) }
        it("test three") { assert(true) }
      end
      expect(Tina4::Testing.suites.first.tests.length).to eq(3)
    end
  end

  describe ".run_all" do
    it "runs all suites and returns results" do
      Tina4::Testing.describe("Suite") do
        it("passes") { assert(true) }
      end
      results = capture_output { Tina4::Testing.run_all }
      expect(results[:passed]).to eq(1)
      expect(results[:failed]).to eq(0)
    end

    it "counts failed tests" do
      Tina4::Testing.describe("Suite") do
        it("fails") { assert(false, "expected failure") }
      end
      results = capture_output { Tina4::Testing.run_all }
      expect(results[:failed]).to eq(1)
    end

    it "counts errors separately from failures" do
      Tina4::Testing.describe("Suite") do
        it("errors") { raise "unexpected error" }
      end
      results = capture_output { Tina4::Testing.run_all }
      expect(results[:errors]).to eq(1)
    end

    it "records test names and statuses" do
      Tina4::Testing.describe("Suite") do
        it("good test") { assert(true) }
        it("bad test") { assert(false, "nope") }
      end
      results = capture_output { Tina4::Testing.run_all }
      test_names = results[:tests].map { |t| t[:name] }
      expect(test_names).to include("good test")
      expect(test_names).to include("bad test")
    end

    it "records suite name with each test" do
      Tina4::Testing.describe("My Suite") do
        it("a test") { assert(true) }
      end
      results = capture_output { Tina4::Testing.run_all }
      expect(results[:tests].first[:suite]).to eq("My Suite")
    end
  end

  describe Tina4::Testing::TestSuite do
    it "stores its name" do
      suite = Tina4::Testing::TestSuite.new("Example")
      expect(suite.name).to eq("Example")
    end

    it "starts with empty tests" do
      suite = Tina4::Testing::TestSuite.new("Example")
      expect(suite.tests).to be_empty
    end

    it "registers tests with it()" do
      suite = Tina4::Testing::TestSuite.new("Example")
      suite.it("does stuff") { true }
      expect(suite.tests.length).to eq(1)
      expect(suite.tests.first[:name]).to eq("does stuff")
    end

    it "stores before_each callback" do
      suite = Tina4::Testing::TestSuite.new("Example")
      called = false
      suite.before_each { called = true }
      suite.run_before_each
      expect(called).to be true
    end

    it "stores after_each callback" do
      suite = Tina4::Testing::TestSuite.new("Example")
      called = false
      suite.after_each { called = true }
      suite.run_after_each
      expect(called).to be true
    end

    it "does not error when before_each not set" do
      suite = Tina4::Testing::TestSuite.new("Example")
      expect { suite.run_before_each }.not_to raise_error
    end

    it "does not error when after_each not set" do
      suite = Tina4::Testing::TestSuite.new("Example")
      expect { suite.run_after_each }.not_to raise_error
    end
  end

  describe Tina4::Testing::TestContext do
    let(:ctx) { Tina4::Testing::TestContext.new }

    describe "#assert" do
      it "passes for truthy values" do
        expect { ctx.assert(true) }.not_to raise_error
      end

      it "raises TestFailure for falsy values" do
        expect { ctx.assert(false) }.to raise_error(Tina4::Testing::TestFailure)
      end

      it "uses custom message" do
        expect { ctx.assert(false, "custom msg") }.to raise_error(
          Tina4::Testing::TestFailure, "custom msg"
        )
      end
    end

    describe "#assert_equal" do
      it "passes when values are equal" do
        expect { ctx.assert_equal(42, 42) }.not_to raise_error
      end

      it "raises TestFailure when values differ" do
        expect { ctx.assert_equal(42, 99) }.to raise_error(Tina4::Testing::TestFailure)
      end

      it "includes expected and actual in message" do
        expect { ctx.assert_equal("a", "b") }.to raise_error(
          Tina4::Testing::TestFailure, /Expected "a", got "b"/
        )
      end
    end

    describe "#assert_not_equal" do
      it "passes when values differ" do
        expect { ctx.assert_not_equal(1, 2) }.not_to raise_error
      end

      it "raises TestFailure when values are equal" do
        expect { ctx.assert_not_equal(1, 1) }.to raise_error(Tina4::Testing::TestFailure)
      end
    end

    describe "#assert_nil" do
      it "passes for nil" do
        expect { ctx.assert_nil(nil) }.not_to raise_error
      end

      it "raises TestFailure for non-nil" do
        expect { ctx.assert_nil("not nil") }.to raise_error(Tina4::Testing::TestFailure)
      end
    end

    describe "#assert_not_nil" do
      it "passes for non-nil" do
        expect { ctx.assert_not_nil("value") }.not_to raise_error
      end

      it "raises TestFailure for nil" do
        expect { ctx.assert_not_nil(nil) }.to raise_error(Tina4::Testing::TestFailure)
      end
    end

    describe "#assert_includes" do
      it "passes when collection includes item" do
        expect { ctx.assert_includes([1, 2, 3], 2) }.not_to raise_error
      end

      it "raises TestFailure when collection does not include item" do
        expect { ctx.assert_includes([1, 2, 3], 4) }.to raise_error(Tina4::Testing::TestFailure)
      end

      it "works with strings" do
        expect { ctx.assert_includes("hello world", "world") }.not_to raise_error
      end
    end

    describe "#assert_raises" do
      it "passes when expected exception is raised" do
        expect {
          ctx.assert_raises(RuntimeError) { raise "boom" }
        }.not_to raise_error
      end

      it "fails when no exception is raised" do
        expect {
          ctx.assert_raises(RuntimeError) { "no error" }
        }.to raise_error(Tina4::Testing::TestFailure)
      end
    end

    describe "#assert_match" do
      it "passes when pattern matches string" do
        expect { ctx.assert_match(/hello/, "hello world") }.not_to raise_error
      end

      it "raises TestFailure when pattern does not match" do
        expect { ctx.assert_match(/xyz/, "hello") }.to raise_error(Tina4::Testing::TestFailure)
      end
    end

    describe "#assert_json" do
      it "returns parsed JSON for valid JSON" do
        result = ctx.assert_json('{"key": "value"}')
        expect(result).to eq({ "key" => "value" })
      end

      it "raises TestFailure for invalid JSON" do
        expect { ctx.assert_json("not json{{{") }.to raise_error(Tina4::Testing::TestFailure, /Invalid JSON/)
      end
    end

    describe "#assert_status" do
      it "passes for matching status in array response" do
        response = [200, {}, ["OK"]]
        expect { ctx.assert_status(response, 200) }.not_to raise_error
      end

      it "fails for non-matching status" do
        response = [404, {}, ["Not Found"]]
        expect { ctx.assert_status(response, 200) }.to raise_error(Tina4::Testing::TestFailure)
      end
    end
  end

  describe Tina4::Testing::TestFailure do
    it "is a subclass of StandardError" do
      expect(Tina4::Testing::TestFailure.ancestors).to include(StandardError)
    end

    it "carries a message" do
      error = Tina4::Testing::TestFailure.new("test failed")
      expect(error.message).to eq("test failed")
    end
  end

  # Helper to capture stdout during test runs
  def capture_output
    original_stdout = $stdout
    $stdout = StringIO.new
    result = yield
    $stdout = original_stdout
    result
  end
end
