# frozen_string_literal: true

# Tina4 — The Intelligent Native Application 4ramework
# Copyright 2007 - current Tina4
# License: MIT https://opensource.org/licenses/MIT

module Tina4
  # Tina4 xUnit-style test base class — class-based test suites with HTTP
  # helpers and positional assertions. Zero external dependencies.
  #
  # Documentation chapter 18 has long described:
  #
  #     class UserApiTest < Tina4::Test
  #       def test_health
  #         resp = get("/health")
  #         assert_equal_value(resp.status, 200)
  #       end
  #     end
  #
  # Until 3.13.0 this class did not exist — examples crashed with
  # "uninitialized constant Tina4::Test". Ruby parity of the
  # Python `tina4_python.test.Test` and PHP `Tina4\Test` classes.
  #
  # The class has a built-in runner (no Minitest/RSpec required):
  #
  #     results = Tina4::Test.run_all          # discovers all subclasses
  #     # => { passed: 12, failed: 0, errors: 0, details: [...] }
  #
  # Or run a single suite class:
  #
  #     UserApiTest.run!
  #
  # HTTP helpers (get/post/put/patch/delete) delegate to TestClient.
  # Positional assertions match the Python (actual, expected, message)
  # shape used throughout the cross-framework docs.
  class Test
    # Class-level registry so run_all can discover every subclass without
    # filesystem scanning.
    @subclasses = []

    class << self
      attr_reader :subclasses

      def inherited(subclass)
        super
        Test.subclasses << subclass
      end

      # Run every test method (`test_*`) on the calling subclass. Returns
      # a hash with passed/failed/errors counts and per-test details.
      def run!
        instance_methods(false).grep(/\Atest_/).sort.each_with_object(
          { passed: 0, failed: 0, errors: 0, details: [] }
        ) do |method, results|
          suite = new
          begin
            suite.send(:set_up)
            suite.send(method)
            suite.send(:tear_down)
            results[:passed] += 1
            results[:details] << { suite: name, test: method, status: "passed" }
          rescue AssertionError => e
            results[:failed] += 1
            results[:details] << { suite: name, test: method, status: "failed", message: e.message }
          rescue StandardError => e
            results[:errors] += 1
            results[:details] << { suite: name, test: method, status: "error", message: "#{e.class}: #{e.message}" }
          end
        end
      end

      # Discover and run every Tina4::Test subclass.
      def run_all(quiet: false)
        results = { passed: 0, failed: 0, errors: 0, details: [] }
        Test.subclasses.each do |klass|
          out = klass.run!
          results[:passed] += out[:passed]
          results[:failed] += out[:failed]
          results[:errors] += out[:errors]
          results[:details].concat(out[:details])
        end
        unless quiet
          puts "Tina4 Test results: #{results[:passed]} passed, #{results[:failed]} failed, #{results[:errors]} errors"
        end
        results
      end
    end

    # ── Lifecycle hooks ──────────────────────────────────────────────
    # snake_case Tina4 idiom; override in subclasses.

    def set_up
    end

    def tear_down
    end

    # ── HTTP test client (lazy) ───────────────────────────────────────

    def test_client
      @test_client ||= Tina4::TestClient.new
    end

    def get(path, headers: nil)
      test_client.get(path, headers: headers)
    end

    def post(path, json: nil, body: nil, headers: nil)
      test_client.post(path, json: json, body: body, headers: headers)
    end

    def put(path, json: nil, body: nil, headers: nil)
      test_client.put(path, json: json, body: body, headers: headers)
    end

    def patch(path, json: nil, body: nil, headers: nil)
      test_client.patch(path, json: json, body: body, headers: headers)
    end

    def delete(path, headers: nil)
      test_client.delete(path, headers: headers)
    end

    # ── Positional assertions — (actual, expected, message) shape ─────

    def assert_equal_value(actual, expected, message = nil)
      return if actual == expected

      raise AssertionError, message || "Expected #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_not_equal_value(actual, expected, message = nil)
      return unless actual == expected

      raise AssertionError, message || "Expected #{actual.inspect} != #{expected.inspect}, but they are equal"
    end

    def assert_true(value, message = nil)
      return if value

      raise AssertionError, message || "Expected truthy, got #{value.inspect}"
    end

    def assert_false(value, message = nil)
      return unless value

      raise AssertionError, message || "Expected falsy, got #{value.inspect}"
    end

    def assert_nil_value(value, message = nil)
      return if value.nil?

      raise AssertionError, message || "Expected nil, got #{value.inspect}"
    end

    def assert_not_nil_value(value, message = nil)
      return unless value.nil?

      raise AssertionError, message || "Expected non-nil, got nil"
    end

    def assert_raises(expected_class, message = nil)
      raise ArgumentError, "Block required" unless block_given?

      begin
        yield
      rescue StandardError => e
        return if e.is_a?(expected_class)

        raise AssertionError,
              message || "Expected #{expected_class}, got #{e.class}: #{e.message}"
      end
      raise AssertionError, message || "Expected #{expected_class} to be raised, but nothing was"
    end
  end

  # AssertionError raised by Tina4::Test assertion helpers on failure.
  class AssertionError < StandardError; end
end
