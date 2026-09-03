# frozen_string_literal: true

# The dev-admin version check must not report "up to date" for a check it never
# made.
#
# It used to answer HTTP 200 with latest == current whenever the call to
# RubyGems failed, and the toolbar renders that as a green
# "Latest: vX — You are up to date!". A developer several releases behind, on a
# machine with no route out, was told the opposite of the truth — and the
# toolbar's own "Could not check for updates" branch could never fire, because
# the failure arrived as a success.

require "spec_helper"
require "json"

RSpec.describe "dev-admin version check" do
  # Stands in for rubygems.org. The real object is never reached, so the three
  # outcomes below are decided here rather than by the network on the day.
  def stub_registry(response: nil, raising: nil)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    if raising
      allow(http).to receive(:request).and_raise(raising)
    else
      allow(http).to receive(:request).and_return(response)
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  def ok_response(body)
    resp = instance_double(Net::HTTPOK, body: body)
    allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    resp
  end

  def payload
    Tina4::DevAdmin.send(:version_check_payload)
  end

  it "does not answer with the current version when the registry is unreachable" do
    stub_registry(raising: SocketError.new("getaddrinfo: Name or service not known"))

    result = payload

    expect(result[:latest]).to be_nil,
      "a check that did not happen must not answer with a version"
    expect(result[:latest]).not_to eq(result[:current]),
      "the toolbar reads latest == current as 'you are up to date'"
    expect(result[:error].to_s).not_to be_empty, "the reason has to reach the client"
    expect(result[:current]).to eq(Tina4::VERSION)
  end

  it "does not treat a non-success response as up to date" do
    resp = instance_double(Net::HTTPServiceUnavailable, code: "503")
    allow(resp).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    stub_registry(response: resp)

    result = payload

    expect(result[:latest]).to be_nil
    expect(result[:error].to_s).to include("503")
  end

  it "does not invent a version from an answer that carries none" do
    # Reaching RubyGems is not the same as learning the version.
    stub_registry(response: ok_response(JSON.generate({})))

    result = payload

    expect(result[:latest]).to be_nil
    expect(result[:error].to_s).not_to be_empty
  end

  it "reports the published version when the registry answers" do
    stub_registry(response: ok_response(JSON.generate({ "version" => "9.9.9" })))

    result = payload

    expect(result[:latest]).to eq("9.9.9")
    expect(result).not_to have_key(:error)
  end

  it "has a toolbar that acts on a missing latest before comparing versions" do
    js = Tina4::RackApp.toolbar_js

    expect(js).to include("couldNotCheck"),
      "no branch for a check that did not happen"
    expect(js).to include("if (!latest) { couldNotCheck")
    expect(js.index("if (!latest)")).to be < js.index("if (latest === current)"),
      "the up-to-date branch must not run first — a null would fall into it"
  end
end
