# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tina4::VERSION" do
  it "has a version number" do
    expect(Tina4::VERSION).not_to be_nil
  end

  it "follows semver format" do
    expect(Tina4::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
