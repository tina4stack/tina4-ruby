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
    Tina4::Auth.instance_variable_set(:@private_key, nil)
    Tina4::Auth.instance_variable_set(:@public_key, nil)
    Tina4::Auth.instance_variable_set(:@keys_dir, nil)
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

  describe ".create_token / .validate_token" do
    it "creates a valid JWT token" do
      token = Tina4::Auth.create_token({ "user_id" => 42 })
      expect(token).to be_a(String)
      expect(token.split(".").length).to eq(3)
    end

    it "validates a valid token" do
      token = Tina4::Auth.create_token({ "user_id" => 42 })
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      expect(result[:payload]["user_id"]).to eq(42)
    end

    it "includes iat, exp, nbf claims" do
      token = Tina4::Auth.create_token({ "role" => "admin" })
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      expect(result[:payload]).to have_key("iat")
      expect(result[:payload]).to have_key("exp")
      expect(result[:payload]).to have_key("nbf")
    end

    it "rejects an invalid token" do
      result = Tina4::Auth.validate_token("invalid.token.here")
      expect(result[:valid]).to be false
    end

    it "respects custom expiry" do
      token = Tina4::Auth.create_token({ "user_id" => 1 }, expires_in: 60)
      result = Tina4::Auth.validate_token(token)
      expect(result[:valid]).to be true
      expect(result[:payload]["exp"] - result[:payload]["iat"]).to eq(60)
    end
  end

  describe ".hash_password / .check_password" do
    it "hashes a password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(hash.to_s).to be_a(String)
      expect(hash.to_s).to start_with("$2a$")
    end

    it "verifies correct password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(Tina4::Auth.check_password("secret123", hash)).to be true
    end

    it "rejects incorrect password" do
      hash = Tina4::Auth.hash_password("secret123")
      expect(Tina4::Auth.check_password("wrong", hash)).to be false
    end

    it "handles invalid hash gracefully" do
      expect(Tina4::Auth.check_password("test", "not-a-hash")).to be false
    end
  end

  describe ".get_payload" do
    it "decodes payload without verification" do
      token = Tina4::Auth.create_token({ "user_id" => 99 })
      payload = Tina4::Auth.get_payload(token)
      expect(payload["user_id"]).to eq(99)
    end

    it "returns nil for invalid token" do
      expect(Tina4::Auth.get_payload("not-a-token")).to be_nil
    end
  end

  describe ".refresh_token" do
    it "returns a new token with fresh expiry" do
      token = Tina4::Auth.create_token({ "user_id" => 1 }, expires_in: 60)
      new_token = Tina4::Auth.refresh_token(token, expires_in: 7200)
      expect(new_token).to be_a(String)
      expect(new_token).not_to eq(token)
      result = Tina4::Auth.validate_token(new_token)
      expect(result[:valid]).to be true
      expect(result[:payload]["user_id"]).to eq(1)
      expect(result[:payload]["exp"] - result[:payload]["iat"]).to eq(7200)
    end

    it "returns nil for invalid token" do
      expect(Tina4::Auth.refresh_token("invalid.token")).to be_nil
    end
  end

  describe ".authenticate_request" do
    it "validates bearer token from headers" do
      token = Tina4::Auth.create_token({ "user_id" => 5 })
      payload = Tina4::Auth.authenticate_request({ "HTTP_AUTHORIZATION" => "Bearer #{token}" })
      expect(payload).not_to be_nil
      expect(payload["user_id"]).to eq(5)
    end

    it "returns nil for missing header" do
      result = Tina4::Auth.authenticate_request({})
      expect(result).to be_nil
    end
  end

  describe ".validate_api_key" do
    it "validates matching key" do
      expect(Tina4::Auth.validate_api_key("my-key", expected: "my-key")).to be true
    end

    it "rejects mismatched key" do
      expect(Tina4::Auth.validate_api_key("wrong", expected: "my-key")).to be false
    end

    it "rejects nil or empty" do
      expect(Tina4::Auth.validate_api_key(nil, expected: "key")).to be false
      expect(Tina4::Auth.validate_api_key("", expected: "key")).to be false
    end
  end

  describe ".bearer_auth" do
    it "returns a lambda" do
      expect(Tina4::Auth.bearer_auth).to respond_to(:call)
    end

    it "authenticates valid bearer token" do
      token = Tina4::Auth.create_token({ "user_id" => 1 })
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
