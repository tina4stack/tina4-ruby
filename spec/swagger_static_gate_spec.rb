# frozen_string_literal: true

# Lock-in: the BUNDLED Swagger UI static assets must honour the swagger gate.
#
# Regression this pins down
# -------------------------
# The framework ships the Swagger UI as static files under
# lib/tina4/public/swagger/ (index.html + oauth2-redirect.html). Static files
# are resolved by try_static INDEPENDENTLY of the gated /swagger handler, so
# before the fix a production server still served the Swagger UI on:
#
#   /swagger/index.html            -> 200 (direct file)
#   /swagger/oauth2-redirect.html  -> 200 (direct file)
#
# even with swagger disabled -- silently bypassing the documented
# TINA4_SWAGGER_ENABLED / TINA4_DEBUG switch. A bare /swagger (and /swagger/)
# was already intercepted by the gated handler, which is exactly why the leak
# stayed hidden: testing only /swagger looked clean.
#
# Real files on disk, the real try_static, real env vars. No doubles.

require "spec_helper"

RSpec.describe "Swagger bundled-asset gate" do
  FRAMEWORK_PUBLIC = File.expand_path("../lib/tina4/public", __dir__)

  # The shipped assets that made up the leak surface.
  SWAGGER_ASSETS = %w[swagger/index.html swagger/oauth2-redirect.html].freeze

  # Request paths that MUST be gated.
  GATED_PATHS = %w[/swagger /swagger/ /swagger/index.html /swagger/oauth2-redirect.html].freeze

  # A bundled asset that is NOT swagger, to prove the gate is surgical.
  CONTROL_PATH = "/favicon.ico"

  let(:app) { Tina4::RackApp.new }

  def with_env(pairs)
    previous = {}
    pairs.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # GUARD: without the real files on disk the negative example below could pass
  # vacuously (nothing to serve means nothing to leak) and would keep passing
  # even if the gate were deleted.
  it "actually ships the swagger assets (else the negative example proves nothing)" do
    SWAGGER_ASSETS.each do |asset|
      expect(File.file?(File.join(FRAMEWORK_PUBLIC, asset)))
        .to be(true), "#{asset} missing from #{FRAMEWORK_PUBLIC}"
    end
    expect(File.file?(File.join(FRAMEWORK_PUBLIC, "favicon.ico"))).to be(true)
  end

  it "NEGATIVE: blocks every bundled swagger asset path when swagger is disabled" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "false") do
      GATED_PATHS.each do |path|
        expect(app.send(:try_static, path))
          .to be_nil, "#{path} served the bundled Swagger UI with swagger disabled"
      end
    end
  end

  it "POSITIVE: still serves the bundled swagger assets when swagger is enabled" do
    with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "true") do
      %w[/swagger/index.html /swagger/oauth2-redirect.html].each do |path|
        expect(app.send(:try_static, path))
          .not_to be_nil, "#{path} did not serve with swagger enabled"
      end
    end
  end

  it "falls back to TINA4_DEBUG when TINA4_SWAGGER_ENABLED is unset" do
    with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, "/swagger/index.html")).to be_nil
    end
    with_env("TINA4_SWAGGER_ENABLED" => nil, "TINA4_DEBUG" => "true") do
      expect(app.send(:try_static, "/swagger/index.html")).not_to be_nil
    end
  end

  it "honours an explicit TINA4_SWAGGER_ENABLED over TINA4_DEBUG in both directions" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "true") do
      expect(app.send(:try_static, "/swagger/index.html")).to be_nil
    end
    with_env("TINA4_SWAGGER_ENABLED" => "true", "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, "/swagger/index.html")).not_to be_nil
    end
  end

  it "does not affect non-swagger bundled assets" do
    with_env("TINA4_SWAGGER_ENABLED" => "false", "TINA4_DEBUG" => "false") do
      expect(app.send(:try_static, CONTROL_PATH))
        .not_to be_nil, "the swagger gate must not block ordinary static assets"
    end
  end
end
