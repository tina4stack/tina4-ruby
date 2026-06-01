# frozen_string_literal: true

require "spec_helper"

# Verify the new Tina4::Test class shipped in 3.13.0 for parity with
# Python's tina4_python.test.Test and PHP's Tina4\Test. Chapter 18 of
# the Ruby documentation has long shown `class FooTest < Tina4::Test`
# integration tests with HTTP helpers mixed onto the test class. Until
# 3.13.0 the constant didn't exist.
RSpec.describe Tina4::Test do
  describe "class definition" do
    it "exists" do
      expect(defined?(Tina4::Test)).to eq("constant")
    end

    it "auto-registers subclasses for run_all discovery" do
      before_count = Tina4::Test.subclasses.size
      Class.new(Tina4::Test) do
        def test_x
          assert_true(true)
        end
      end
      expect(Tina4::Test.subclasses.size).to eq(before_count + 1)
    end
  end

  describe "HTTP helpers" do
    let(:fixture_class) do
      Class.new(Tina4::Test) do
        def test_noop
          assert_true(true)
        end
      end
    end

    let(:suite) { fixture_class.new }

    it "exposes get/post/put/patch/delete" do
      expect(suite).to respond_to(:get)
      expect(suite).to respond_to(:post)
      expect(suite).to respond_to(:put)
      expect(suite).to respond_to(:patch)
      expect(suite).to respond_to(:delete)
    end

    it "lazily creates a single TestClient" do
      client1 = suite.test_client
      client2 = suite.test_client
      expect(client1).to be(client2)
    end
  end

  describe "positional assertions" do
    let(:fixture_class) do
      Class.new(Tina4::Test) do
        def test_noop
          assert_true(true)
        end
      end
    end

    let(:suite) { fixture_class.new }

    it "assert_equal_value passes on match" do
      expect { suite.assert_equal_value(2 + 2, 4, "basic add") }.not_to raise_error
    end

    it "assert_equal_value fails on mismatch" do
      expect { suite.assert_equal_value(2 + 2, 5) }.to raise_error(Tina4::AssertionError)
    end

    it "assert_not_equal_value works" do
      expect { suite.assert_not_equal_value("hi", "bye") }.not_to raise_error
      expect { suite.assert_not_equal_value("hi", "hi") }.to raise_error(Tina4::AssertionError)
    end

    it "assert_true / assert_false work" do
      expect { suite.assert_true(1) }.not_to raise_error
      expect { suite.assert_true(nil) }.to raise_error(Tina4::AssertionError)
      expect { suite.assert_false(false) }.not_to raise_error
      expect { suite.assert_false(true) }.to raise_error(Tina4::AssertionError)
    end

    it "assert_nil_value / assert_not_nil_value work" do
      expect { suite.assert_nil_value(nil) }.not_to raise_error
      expect { suite.assert_nil_value(0) }.to raise_error(Tina4::AssertionError)
      expect { suite.assert_not_nil_value(0) }.not_to raise_error
      expect { suite.assert_not_nil_value(nil) }.to raise_error(Tina4::AssertionError)
    end

    it "assert_raises catches the documented exception" do
      expect do
        suite.assert_raises(ArgumentError) { raise ArgumentError, "bad" }
      end.not_to raise_error
    end

    it "assert_raises fails when wrong exception" do
      expect do
        suite.assert_raises(ArgumentError) { raise TypeError, "wrong" }
      end.to raise_error(Tina4::AssertionError)
    end

    it "assert_raises fails when no exception" do
      expect do
        suite.assert_raises(ArgumentError) { 42 }
      end.to raise_error(Tina4::AssertionError)
    end
  end

  describe "built-in runner" do
    it "run! returns passed/failed/errors counts" do
      log = []
      fixture = Class.new(Tina4::Test) do
        define_method(:set_up) { log << "set_up" }
        define_method(:tear_down) { log << "tear_down" }
        define_method(:test_passes) { assert_true(true) }
        define_method(:test_fails) { assert_true(false) }
        define_method(:test_errors) { raise "boom" }
      end
      results = fixture.run!
      expect(results[:passed]).to eq(1)
      expect(results[:failed]).to eq(1)
      expect(results[:errors]).to eq(1)
      # set_up / tear_down ran for the passing test; for failing/erroring they
      # may not complete — what matters is set_up fires for each test bracket.
      expect(log.count("set_up")).to be >= 1
    end
  end
end

# Parity for Auth.valid_token return-type change in 3.13.0
RSpec.describe Tina4::Auth, "valid_token return type (3.13.0)" do
  before(:all) do
    require "tmpdir"
    Tina4::Auth.setup(Dir.mktmpdir)
  end

  it "returns the payload Hash on success (not a bare bool)" do
    token = Tina4::Auth.get_token({ "user_id" => 42, "role" => "admin" })
    result = Tina4::Auth.valid_token(token)
    expect(result).to be_a(Hash)
    expect(result["user_id"]).to eq(42)
    expect(result["role"]).to eq("admin")
  end

  it "returns nil on invalid token" do
    expect(Tina4::Auth.valid_token("not.a.jwt")).to be_nil
    expect(Tina4::Auth.valid_token("")).to be_nil
  end

  it "preserves the truthy/falsy contract for `if valid_token(t)`" do
    valid_token = Tina4::Auth.get_token({ "x" => 1 })
    expect(!!Tina4::Auth.valid_token(valid_token)).to be true
    expect(!!Tina4::Auth.valid_token("bogus")).to be false
  end
end
