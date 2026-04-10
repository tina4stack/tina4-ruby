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
        @inline_registry = []
        @results = { passed: 0, failed: 0, errors: 0, tests: [] }
      end

      def describe(name, &block)
        suite = TestSuite.new(name)
        suite.instance_eval(&block)
        suites << suite
      end

      def run_all(quiet: false, failfast: false)
        reset_results
        suites.each do |suite|
          run_suite(suite, quiet: quiet, failfast: failfast)
          break if failfast && results[:failed] > 0
        end
        # Run inline-registered tests
        inline_registry.each do |entry|
          run_inline_entry(entry, quiet: quiet)
          break if failfast && results[:failed] > 0
        end
        print_results unless quiet
        results
      end

      # ── Inline testing (parity with Python/PHP/Node decorator pattern) ──

      # Assertion builder: assert_equal(args, expected)
      def assert_equal(args, expected)
        { type: :equal, args: args, expected: expected }
      end

      # Assertion builder: assert_raises(exception_class, args)
      def assert_raises(exception_class, args)
        { type: :raises, exception: exception_class, args: args }
      end

      # Assertion builder: assert_true(args)
      def assert_true(args)
        { type: :true, args: args }
      end

      # Assertion builder: assert_false(args)
      def assert_false(args)
        { type: :false, args: args }
      end

      # Register a callable with inline assertions (mirrors Python's @tests decorator).
      #
      #   Tina4::Testing.tests(
      #     Tina4::Testing.assert_equal([5, 3], 8),
      #     Tina4::Testing.assert_raises(ArgumentError, [nil]),
      #   ) { |a, b| raise ArgumentError, "b required" if b.nil?; a + b }
      #
      def tests(*assertions, name: nil, &block)
        raise ArgumentError, "tests requires a block" unless block_given?
        inline_registry << {
          fn: block,
          name: name || "anonymous",
          assertions: assertions
        }
        block
      end

      def inline_registry
        @inline_registry ||= []
      end

      private

      def run_inline_entry(entry, quiet: false)
        fn = entry[:fn]
        name = entry[:name]
        puts "\n  #{name}" unless entry[:assertions].empty? || quiet

        entry[:assertions].each do |assertion|
          args = assertion[:args]
          case assertion[:type]
          when :equal
            begin
              result = fn.call(*args)
              if result == assertion[:expected]
                results[:passed] += 1
                puts "    \e[32m✓\e[0m #{name}(#{args.inspect}) == #{assertion[:expected].inspect}" unless quiet
              else
                results[:failed] += 1
                puts "    \e[31m✗\e[0m #{name}(#{args.inspect}) expected #{assertion[:expected].inspect}, got #{result.inspect}" unless quiet
              end
            rescue => e
              results[:errors] += 1
              puts "    \e[33m!\e[0m #{name}(#{args.inspect}) raised #{e.class}: #{e.message}" unless quiet
            end
          when :raises
            begin
              fn.call(*args)
              results[:failed] += 1
              puts "    \e[31m✗\e[0m #{name}(#{args.inspect}) expected #{assertion[:exception]} but none raised" unless quiet
            rescue assertion[:exception]
              results[:passed] += 1
              puts "    \e[32m✓\e[0m #{name}(#{args.inspect}) raises #{assertion[:exception]}" unless quiet
            rescue => e
              results[:failed] += 1
              puts "    \e[31m✗\e[0m #{name}(#{args.inspect}) expected #{assertion[:exception]}, got #{e.class}" unless quiet
            end
          when :true
            begin
              result = fn.call(*args)
              if result
                results[:passed] += 1
                puts "    \e[32m✓\e[0m #{name}(#{args.inspect}) is truthy" unless quiet
              else
                results[:failed] += 1
                puts "    \e[31m✗\e[0m #{name}(#{args.inspect}) expected truthy, got #{result.inspect}" unless quiet
              end
            rescue => e
              results[:errors] += 1
              puts "    \e[33m!\e[0m #{name}(#{args.inspect}) raised #{e.class}: #{e.message}" unless quiet
            end
          when :false
            begin
              result = fn.call(*args)
              if !result
                results[:passed] += 1
                puts "    \e[32m✓\e[0m #{name}(#{args.inspect}) is falsy" unless quiet
              else
                results[:failed] += 1
                puts "    \e[31m✗\e[0m #{name}(#{args.inspect}) expected falsy, got #{result.inspect}" unless quiet
              end
            rescue => e
              results[:errors] += 1
              puts "    \e[33m!\e[0m #{name}(#{args.inspect}) raised #{e.class}: #{e.message}" unless quiet
            end
          end
        end
      end

      def reset_results
        @results = { passed: 0, failed: 0, errors: 0, tests: [] }
      end

      def run_suite(suite, quiet: false, failfast: false)
        puts "\n  #{suite.name}" unless quiet
        suite.tests.each do |test|
          run_test(suite, test, quiet: quiet)
          break if failfast && results[:failed] > 0
        end
      end

      def run_test(suite, test, quiet: false)
        suite.run_before_each
        context = TestContext.new
        context.instance_eval(&test[:block])
        results[:passed] += 1
        results[:tests] << { name: test[:name], status: :passed, suite: suite.name }
        puts "    \e[32m✓\e[0m #{test[:name]}" unless quiet
      rescue TestFailure => e
        results[:failed] += 1
        results[:tests] << { name: test[:name], status: :failed, suite: suite.name, message: e.message }
        puts "    \e[31m✗\e[0m #{test[:name]}: #{e.message}" unless quiet
      rescue => e
        results[:errors] += 1
        results[:tests] << { name: test[:name], status: :error, suite: suite.name, message: e.message }
        puts "    \e[33m!\e[0m #{test[:name]}: #{e.message}" unless quiet
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

      def assert_true(value, message = nil)
        msg = message || "Expected truthy, got #{value.inspect}"
        raise TestFailure, msg unless value
      end

      def assert_false(value, message = nil)
        msg = message || "Expected falsy, got #{value.inspect}"
        raise TestFailure, msg if value
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
