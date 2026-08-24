# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# Parity with tina4-nodejs #58 / tina4-python #118 (ead390c76).
#
# Before the fix, ServiceRunner.stop(name) only flipped ctx.running = false
# on the ServiceContext; it never called entry[:instance].stop, so a
# subclass whose #run loops on `until should_stop?` never exited
# cooperatively -- the thread was killed by the thread.join(5) timeout
# instead. `register_service` even stored the instance under
# @registry[name][:instance] and the docstring promised the wiring, so this
# was a broken promise, not a design gap.
RSpec.describe "ServiceRunner.stop cooperates with class-based Service instances" do
  # Anonymous subclass so no global constant leaks between specs (parity with
  # spec/parity_graphql_service_spec.rb's fixture_class pattern; Ruby 4.0
  # rejects underscore-prefixed constant names anyway).
  let(:fixture_class) do
    Class.new(Tina4::Service) do
      attr_accessor :run_calls

      def initialize
        super
        @run_calls = 0
      end

      def run
        # Real cooperative loop -- the exact shape the docs teach.
        until should_stop?
          @run_calls += 1
          sleep 0.001
          break if @run_calls > 10_000 # fixture safety
        end
      end
    end
  end

  it "flips the registered instance's should_stop? via the runner (positive gate)" do
    name = "parity-stop-#{SecureRandom.hex(3)}"
    svc = fixture_class.new

    Tina4::ServiceRunner.register_service(name, svc)

    expect(svc.should_stop?).to be(false), "sanity: fresh Service is not stopped"

    Tina4::ServiceRunner.stop(name)

    expect(svc.should_stop?).to be(true),
      "ServiceRunner.stop(name) must call the registered Service instance's stop " \
      "(parity with tina4-python #118 / tina4-nodejs #58 / ead390c76)."
  end

  it "is a safe no-op when the target name was never registered (negative gate)" do
    missing = "never-registered-#{SecureRandom.hex(3)}"
    expect { Tina4::ServiceRunner.stop(missing) }.not_to raise_error
  end
end
