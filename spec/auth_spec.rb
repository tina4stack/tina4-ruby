# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Auth do
  let(:tmp_dir) { Dir.mktmpdir("tina4_auth_test") }

  before(:each) do
    # Reset cached keys
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
    Tina4::Auth.setup(tmp_dir)
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".setup" do
    it "creates .keys directory" do
      expect(Dir.exist?(File.join(tmp_dir, ".keys"))).to be true
    end

    it "generates RSA key pair" do
      keys_dir = File.join(tmp_dir, ".keys")
      expect(File.exist?(File.join(keys_dir, "private.pem"))).to be true
      expect(File.exist?(File.join(keys_dir, "public.pem"))).to be true
    end
  end

  describe ".generate_token / .validate_token" do
    it "creates a valid JWT token" do
      token = Tina4::Auth.generate_token({ "user_id" => 42 })
      expect(token).to be_a(String)
      expect(token.split(".").length).to eq(3)
    end

    it "validates a valid token" do
      token = Tina4::Auth.generate_token({ "user_id" => 42 })
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      expect(result[:payload]["user_id"]).to eq(42)
    end

    it "includes iat, exp, nbf claims" do
      token = Tina4::Auth.generate_token({ "role" => "admin" })
      result = Tina4::Auth.validate_token(token)
      payload = result[:payload]
      expect(payload).to have_key("iat")
      expect(payload).to have_key("exp")
      expect(payload).to have_key("nbf")
    end

    it "rejects an invalid token" do
      result = Tina4::Auth.validate_token("invalid.token.here")
      expect(result[:valid]).to be false
      expect(result[:error]).to be_a(String)
    end

    it "respects custom expiry" do
      token = Tina4::Auth.generate_token({ "user_id" => 1 }, expires_in: 60)
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      payload = result[:payload]
      expect(payload["exp"] - payload["iat"]).to eq(60)
    end
  end

  describe ".hash_password / .verify_password" do
    it "hashes a password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(hash.to_s).to be_a(String)
      expect(hash.to_s).to start_with("$2a$")
    end

    it "verifies correct password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(Tina4::Auth.verify_password("secret123", hash)).to be true
    end

    it "rejects incorrect password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(Tina4::Auth.verify_password("wrong", hash)).to be false
    end

    it "handles invalid hash gracefully" do
      expect(Tina4::Auth.verify_password("test", "not-a-hash")).to be false
    end
  end

  describe ".bearer_auth" do
    it "returns a lambda" do
      expect(Tina4::Auth.bearer_auth).to respond_to(:call)
    end

    it "authenticates valid bearer token" do
      token = Tina4::Auth.generate_token({ "user_id" => 1 })
      env = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
      result = Tina4::Auth.bearer_auth.call(env)
      expect(result).to be true
      expect(env["tina4.auth"]["user_id"]).to eq(1)
    end

    it "rejects missing authorization header" do
      env = {}
      result = Tina4::Auth.bearer_auth.call(env)
      expect(result).to be false
    end

    it "rejects invalid token" do
      env = { "HTTP_AUTHORIZATION" => "Bearer invalid.token" }
      result = Tina4::Auth.bearer_auth.call(env)
      expect(result).to be false
    end
  end
end
