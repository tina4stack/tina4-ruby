# frozen_string_literal: true
require "json"
require "stringio"

module Tina4
  module Testing
    class << self
      def suites
        @suites ||= []
      end

      def results
        @results ||= { passed: 0, failed: 0, errors: 0, tests: [] }
      end

      def reset!
        @suites = []
        @results = { passed: 0, failed: 0, errors: 0, tests: [] }
      end

      def describe(name, &block)
        suite = TestSuite.new(name)
        suite.instance_eval(&block)
        suites << suite
      end

      def run_all
        reset_results
        suites.each do |suite|
          run_suite(suite)
        end
        print_results
        results
      end

      private

      def reset_results
        @results = { passed: 0, failed: 0, errors: 0, tests: [] }
      end

      def run_suite(suite)
        puts "\n  #{suite.name}"
        suite.tests.each do |test|
          run_test(suite, test)
        end
      end

      def run_test(suite, test)
        suite.run_before_each
        context = TestContext.new
        context.instance_eval(&test[:block])
        results[:passed] += 1
        results[:tests] << { name: test[:name], status: :passed, suite: suite.name }
        puts "    \e[32m✓\e[0m #{test[:name]}"
      rescue TestFailure => e
        results[:failed] += 1
        results[:tests] << { name: test[:name], status: :failed, suite: suite.name, message: e.message }
        puts "    \e[31m✗\e[0m #{test[:name]}: #{e.message}"
      rescue => e
        results[:errors] += 1
        results[:tests] << { name: test[:name], status: :error, suite: suite.name, message: e.message }
        puts "    \e[33m!\e[0m #{test[:name]}: #{e.message}"
      ensure
        suite.run_after_each
      end

      def print_results
        total = results[:passed] + results[:failed] + results[:errors]
        puts "\n  #{total} tests: \e[32m#{results[:passed]} passed\e[0m, " \
             "\e[31m#{results[:failed]} failed\e[0m, " \
             "\e[33m#{results[:errors]} errors\e[0m\n"
      end
    end

    class TestFailure < StandardError; end

    class TestSuite
      attr_reader :name, :tests

      def initialize(name)
        @name = name
        @tests = []
        @before_each = nil
        @after_each = nil
      end

      def it(description, &block)
        @tests << { name: description, block: block }
      end

      def before_each(&block)
        @before_each = block
      end

      def after_each(&block)
        @after_each = block
      end

      def run_before_each
        @before_each&.call
      end

      def run_after_each
        @after_each&.call
      end
    end

    class TestContext
      def assert(condition, message = "Assertion failed")
        raise TestFailure, message unless condition
      end

      def assert_equal(expected, actual, message = nil)
        msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
        raise TestFailure, msg unless expected == actual
      end

      def assert_not_equal(expected, actual, message = nil)
        msg = message || "Expected #{actual.inspect} to not equal #{expected.inspect}"
        raise TestFailure, msg if expected == actual
      end

      def assert_nil(value, message = nil)
        msg = message || "Expected nil, got #{value.inspect}"
        raise TestFailure, msg unless value.nil?
      end

      def assert_not_nil(value, message = nil)
        msg = message || "Expected non-nil value"
        raise TestFailure, msg if value.nil?
      end

      def assert_includes(collection, item, message = nil)
        msg = message || "Expected #{collection.inspect} to include #{item.inspect}"
        raise TestFailure, msg unless collection.include?(item)
      end

      def assert_raises(exception_class, message = nil)
        yield
        raise TestFailure, message || "Expected #{exception_class} to be raised"
      rescue exception_class
        true
      end

      def assert_match(pattern, string, message = nil)
        msg = message || "Expected #{string.inspect} to match #{pattern.inspect}"
        raise TestFailure, msg unless pattern.match?(string)
      end

      def assert_json(response_body)
        JSON.parse(response_body)
      rescue JSON::ParserError => e
        raise TestFailure, "Invalid JSON: #{e.message}"
      end

      def assert_status(response, expected_status)
        actual = response.is_a?(Array) ? response[0] : response.status
        assert_equal(expected_status, actual, "Expected status #{expected_status}, got #{actual}")
      end

      # HTTP test helpers
      def simulate_request(method, path, body: nil, headers: {}, params: {})
        env = build_test_env(method, path, body: body, headers: headers, params: params)
        app = Tina4::RackApp.new
        app.call(env)
      end

      def get(path, headers: {}, params: {})
        simulate_request("GET", path, headers: headers, params: params)
      end

      def post(path, body: nil, headers: {})
        simulate_request("POST", path, body: body, headers: headers)
      end

      def put(path, body: nil, headers: {})
        simulate_request("PUT", path, body: body, headers: headers)
      end

      def delete(path, headers: {})
        simulate_request("DELETE", path, headers: headers)
      end

      private

      def build_test_env(method, path, body: nil, headers: {}, params: {})
        query_string = params.empty? ? "" : URI.encode_www_form(params)
        body_str = body.is_a?(Hash) ? JSON.generate(body) : (body || "")
        input = StringIO.new(body_str)

        env = {
          "REQUEST_METHOD" => method.upcase,
          "PATH_INFO" => path,
          "QUERY_STRING" => query_string,
          "CONTENT_TYPE" => body.is_a?(Hash) ? "application/json" : "text/plain",
          "CONTENT_LENGTH" => body_str.length.to_s,
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.input" => input,
          "rack.errors" => StringIO.new,
          "rack.url_scheme" => "http"
        }

        headers.each do |key, value|
          env_key = "HTTP_#{key.upcase.gsub('-', '_')}"
          env[env_key] = value
        end

        env
      end
    end
  end
end
