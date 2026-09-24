# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# The browser-open gate itself (ADR-0070), called in-process with the
# environment set for real. spec/run_no_browser_spec.rb proves the same gate
# end to end through a booted Tina4.run!.
#
# A CI variable vetoes when it is set to a non-empty value (after trimming)
# that is not one of false / 0 / no / off, case-insensitively. The list of CI
# variables is the ADR-0070 union: CI, CONTINUOUS_INTEGRATION, GITHUB_ACTIONS,
# GITLAB_CI, BUILDKITE, JENKINS_URL, TF_BUILD, TEAMCITY_VERSION.

require "spec_helper"

RSpec.describe "browser-open gate (ADR-0070)" do
  let(:ci_vars) { %w[CI CONTINUOUS_INTEGRATION GITHUB_ACTIONS GITLAB_CI BUILDKITE JENKINS_URL TF_BUILD TEAMCITY_VERSION] }

  around do |example|
    keys = ci_vars + %w[TINA4_DEBUG TINA4_NO_BROWSER]
    saved = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    ENV["TINA4_DEBUG"] = "true"
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def allowed?(argv: []) = Tina4.browser_launch_allowed?(argv: argv)

  it "opens in development with nothing set" do
    expect(allowed?).to be(true)
  end

  it "the CI list is the ADR-0070 union of eight" do
    expect(Tina4::CI_ENV_VARS).to match_array(ci_vars)
  end

  it "every CI variable vetoes when set to a real value" do
    ci_vars.each do |name|
      ENV[name] = "True"
      expect(allowed?).to be(false), "#{name}=True did not veto"
      ENV.delete(name)
    end
  end

  it "a CI value of false, 0, no or off, or a blank one, does not veto" do
    ["false", "0", "no", "off", "FALSE", " Off ", "", "  "].each do |value|
      ENV["CI"] = value
      expect(allowed?).to be(true), "CI=#{value.inspect} vetoed"
    end
  end

  it "any other CI value vetoes" do
    %w[true 1 yes woodpecker].each do |value|
      ENV["CI"] = value
      expect(allowed?).to be(false), "CI=#{value.inspect} did not veto"
    end
  end

  it "a truthy TINA4_NO_BROWSER vetoes, a falsy one does not" do
    ["true", "1", "yes", "on", " ON "].each do |value|
      ENV["TINA4_NO_BROWSER"] = value
      expect(allowed?).to be(false), "TINA4_NO_BROWSER=#{value.inspect} did not veto"
    end
    %w[false 0 maybe y].each do |value|
      ENV["TINA4_NO_BROWSER"] = value
      expect(allowed?).to be(true), "TINA4_NO_BROWSER=#{value.inspect} vetoed"
    end
  end

  it "--no-browser vetoes even with a falsy TINA4_NO_BROWSER" do
    ENV["TINA4_NO_BROWSER"] = "false"
    expect(allowed?(argv: ["--no-browser"])).to be(false)
  end

  it "production never opens, whatever TINA4_NO_BROWSER says" do
    ENV["TINA4_DEBUG"] = "false"
    ENV["TINA4_NO_BROWSER"] = "false"
    expect(allowed?).to be(false)
  end
end
