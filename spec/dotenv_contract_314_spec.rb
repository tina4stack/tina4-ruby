# frozen_string_literal: true

require "json"
require_relative "spec_helper"

# Fail-closed runner for the audited Tina4 3.14 DotEnv contract. Every fixture
# case requires exactly one real behavioural executor. Missing executors fail;
# they are never pending or skipped.
RSpec.describe "DotEnv 3.14 contract" do
  fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "dotenv_corpus.json")))
  cases = fixture.fetch("contract_3_14").fetch("cases").freeze

  # Implementation work registers one real-filesystem/process-environment
  # executor per case. Empty now means the completed audit turns the suite red
  # until Feature 1 is implemented.
  executors = {}.freeze

  it "has exactly 46 unique case IDs and mutation witnesses" do
    ids = cases.map { |item| item.fetch("id") }
    witnesses = cases.map { |item| item.fetch("witness") }
    expect(ids.length).to eq(46)
    expect(ids.uniq.length).to eq(ids.length)
    expect(witnesses.uniq.length).to eq(witnesses.length)
  end

  it "has no executor for an unknown fixture case" do
    ids = cases.map { |item| item.fetch("id") }
    expect(executors.keys - ids).to be_empty
  end

  cases.each do |contract_case|
    id = contract_case.fetch("id")
    witness = contract_case.fetch("witness")

    it "executes #{id}" do
      executor = executors[id]
      expect(executor).to be_a(Proc),
        "#{id}: contract_3_14 executor not implemented; witness=#{witness}"
      executor.call(contract_case)
    end
  end
end
