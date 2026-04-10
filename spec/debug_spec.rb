# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tina4::Debug backward compatibility" do
  it "Tina4::Debug is aliased to Tina4::Log" do
    expect(Tina4::Debug).to eq(Tina4::Log)
  end

  it "responds to all Log methods via Debug" do
    expect(Tina4::Debug).to respond_to(:info)
    expect(Tina4::Debug).to respond_to(:debug)
    expect(Tina4::Debug).to respond_to(:warning)
    expect(Tina4::Debug).to respond_to(:error)
    expect(Tina4::Debug).to respond_to(:configure)
  end
end
