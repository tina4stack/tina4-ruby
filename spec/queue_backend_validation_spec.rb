# frozen_string_literal: true

# queue_contract.json :: an-unsupported-operation-raises-naming-itself
#
# A typo in TINA4_QUEUE_BACKEND must not produce a running app writing every job
# to local disk.
#
# MEASURED 2026-08-03: PHP and Node accepted ANY string as a backend name and
# silently fell through to the local file store. Ruby already raised on an
# unknown name - but it normalised ONLY the env var, so an explicit
# Queue.new(backend: "FILE") raised while the identical spelling in
# TINA4_QUEUE_BACKEND resolved. Python, PHP and Node all accepted it, so Ruby
# was the outlier; Python is master on internal API design.
#
# The case names here are shared verbatim with the Python, PHP and Node suites,
# because scripts/audit-contract-fixtures.py resolves ONE fixture case against
# EVERY framework's file.

require "spec_helper"
require "tmpdir"

RSpec.describe "Queue backend validation" do
  around do |example|
    saved = ENV["TINA4_QUEUE_BACKEND"]
    saved_path = ENV["TINA4_QUEUE_PATH"]
    ENV.delete("TINA4_QUEUE_BACKEND")
    ENV["TINA4_QUEUE_PATH"] = Dir.mktmpdir
    example.run
    saved.nil? ? ENV.delete("TINA4_QUEUE_BACKEND") : ENV["TINA4_QUEUE_BACKEND"] = saved
    saved_path.nil? ? ENV.delete("TINA4_QUEUE_PATH") : ENV["TINA4_QUEUE_PATH"] = saved_path
  end

  it "an unknown queue backend raises instead of silently using file" do
    expect { Tina4::Queue.new(topic: "validation", backend: "totally-bogus-backend") }
      .to raise_error(ArgumentError, /Unknown queue backend/)
  end

  it "the unknown backend error names the value and the valid set" do
    Tina4::Queue.new(topic: "validation", backend: "rabbitmqq")
    raise "a bogus backend name must raise"
  rescue ArgumentError => e
    # The message must name the offending value AND the valid set, so the
    # operator can fix it without reading the source.
    expect(e.message).to include("rabbitmqq")
    %w[rabbitmq kafka mongodb].each { |v| expect(e.message).to include(v) }
  end

  it "a queue backend name is normalised before it is resolved" do
    # ' file ' is the same backend as 'file'. Without normalisation a stray space
    # in a .env turns a valid configuration into the raise above.
    [" file ", "FILE", "File", " lite", "DEFAULT"].each do |spelling|
      expect { Tina4::Queue.new(topic: "validation", backend: spelling) }
        .not_to raise_error, "#{spelling.inspect} must resolve"
    end
  end

  it "the guard still accepts every documented backend name" do
    # NEGATIVE: without this, "make everything raise" would pass the test above.
    ENV["TINA4_QUEUE_MONGO_URL"] = "mongodb://127.0.0.1:27017"
    %w[mongodb mongo MongoDB].each do |spelling|
      expect { Tina4::Queue.new(topic: "validation", backend: spelling) }
        .not_to raise_error, "#{spelling.inspect} must resolve"
    end
  end
end
