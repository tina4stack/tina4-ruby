# frozen_string_literal: true

require "spec_helper"

# v3.13.1 parity tests for Ruby — GraphQL.resolve decorator + Service
# base class. Matches the Python @GraphQL.resolve / PHP GraphQL::resolve
# decorator and the cross-framework Service base.
RSpec.describe Tina4::GraphQL, ".resolve (3.13.1 decorator API)" do
  before do
    Tina4::GraphQL._clear_class_resolvers!
  end

  after do
    Tina4::GraphQL._clear_class_resolvers!
  end

  it "registers a Query resolver via class-level decorator" do
    Tina4::GraphQL.resolve("Query", "hello") { |root, args, ctx| "world" }
    expect(Tina4::GraphQL.class_resolvers["Query"]["hello"]).to be_a(Proc)
  end

  it "new GraphQL instance drains class-level registry into its schema" do
    Tina4::GraphQL.resolve("Query", "ping") { |root, args, ctx| "pong" }
    gql = Tina4::GraphQL.new
    expect(gql.schema.queries["ping"]).not_to be_nil
    expect(gql.schema.queries["ping"][:resolve]).to be_a(Proc)
  end

  it "Mutation resolver lands in schema.mutations" do
    Tina4::GraphQL.resolve("Mutation", "createWidget") { |root, args, ctx| { id: 1 } }
    gql = Tina4::GraphQL.new
    expect(gql.schema.mutations["createWidget"]).not_to be_nil
  end

  it "Object-type field resolver is stashed on the instance" do
    Tina4::GraphQL.resolve("Product", "reviews") do |product, args, ctx|
      [{ id: 1, rating: 5 }]
    end
    gql = Tina4::GraphQL.new
    resolver = gql.field_resolver("Product", "reviews")
    expect(resolver).to be_a(Proc)
    expect(resolver.call({ id: 42 }, {}, {})).to eq([{ id: 1, rating: 5 }])
  end

  it "post-instantiation registration wires into default instance" do
    gql = Tina4::GraphQL.new
    Tina4::GraphQL.default_instance = gql
    Tina4::GraphQL.resolve("Query", "lateBound") { |_, _, _| "registered after init" }
    expect(gql.schema.queries["lateBound"]).not_to be_nil
  end
end

RSpec.describe Tina4::Service, "(3.13.1 base class)" do
  let(:fixture_class) do
    Class.new(Tina4::Service) do
      attr_accessor :iterations
      def initialize
        super
        @iterations = 0
      end

      def run
        until should_stop?
          @iterations += 1
          stop if @iterations >= 3
        end
      end
    end
  end

  it "enforces the abstract contract: base #run raises and a fresh instance is not-yet-stopped" do
    base = Tina4::Service.new
    # The abstract base must refuse to run without a subclass override.
    expect { base.run }.to raise_error(NotImplementedError, /run must be implemented/)
    # A freshly-constructed service starts in the running state.
    expect(base.should_stop?).to be false
  end

  it "raises NotImplementedError when run is not overridden" do
    base = Tina4::Service.new
    expect { base.run }.to raise_error(NotImplementedError)
  end

  it "should_stop? flips after stop" do
    svc = fixture_class.new
    expect(svc.should_stop?).to be false
    svc.stop
    expect(svc.should_stop?).to be true
  end

  it "subclass run loop terminates via should_stop?" do
    svc = fixture_class.new
    svc.run
    expect(svc.iterations).to eq(3)
  end

  it "to_proc returns a callable that, when invoked, drives #run to completion" do
    svc = fixture_class.new
    callable = svc.to_proc
    expect(callable).to be_a(Proc)
    # Calling the proc must actually execute #run — observe the side effect.
    expect(svc.iterations).to eq(0)
    callable.call
    expect(svc.iterations).to eq(3)
    expect(svc.should_stop?).to be true
  end

  it "ServiceRunner.register_service accepts a Service instance" do
    svc = fixture_class.new
    Tina4::ServiceRunner.register_service("parity-test-svc", svc)
    # Verify the registry entry exists with a callable handler
    expect(Tina4::ServiceRunner.list).to include(a_hash_including(name: "parity-test-svc"))
  end

  it "ServiceRunner.register_service rejects non-Service instances" do
    expect {
      Tina4::ServiceRunner.register_service("bad", Object.new)
    }.to raise_error(ArgumentError, /Tina4::Service/)
  end
end
