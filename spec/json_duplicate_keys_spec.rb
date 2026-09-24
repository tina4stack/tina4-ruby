# frozen_string_literal: true

require "spec_helper"
require "stringio"

# JSON that repeats a key: the LAST occurrence wins, whatever json gem the app
# resolves. That is what Python (json.loads), PHP (json_decode) and Node
# (JSON.parse) do, and what the Ruby json gem did until 3.0 (September 2026),
# which RAISES on a duplicate key by default. tina4ruby no longer pins json, so
# an app that pulls json 3 through any other gem would otherwise see a request
# body with a repeated key turn into the raw string (or {} from json_body), a
# GraphQL request fail, and a JWT with a doubled "alg" fail to parse.
#
# Tina4.parse_json pins the rule for every JSON that arrives from outside the
# process. These examples mean the same on json 2.x and 3.x; CI resolves json
# 3, where they were red before the fix.
RSpec.describe "JSON with a duplicate key (last one wins, any json gem)" do
  let(:doubled) { '{"name":"first","name":"last","n":1}' }

  it "Tina4.parse_json keeps the last value" do
    expect(Tina4.parse_json(doubled)).to eq("name" => "last", "n" => 1)
  end

  it "Tina4.parse_json still passes options through and still rejects broken JSON" do
    expect(Tina4.parse_json(doubled, symbolize_names: true)).to eq(name: "last", n: 1)
    expect { Tina4.parse_json('{"a":') }.to raise_error(JSON::ParserError)
  end

  describe "a request body" do
    def request_with(body)
      Tina4::Request.new(
        "REQUEST_METHOD" => "POST", "PATH_INFO" => "/", "QUERY_STRING" => "",
        "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new(body),
        "rack.errors" => StringIO.new, "SERVER_NAME" => "localhost",
        "SERVER_PORT" => "7147", "SCRIPT_NAME" => "", "rack.url_scheme" => "http"
      )
    end

    it "parses to a Hash holding the last value, not the raw string" do
      expect(request_with(doubled).body).to eq("name" => "last", "n" => 1)
    end

    it "json_body holds the last value, not {}" do
      expect(request_with(doubled).json_body).to eq("name" => "last", "n" => 1)
    end
  end

  it "a GraphQL request body with a repeated key still executes" do
    schema = Tina4::GraphQLSchema.new
    schema.add_query("hello", {}, "String") { |_root, _args, _ctx| "world" }
    result = Tina4::GraphQL.new(schema).handle_request('{"query":"{ nope }","query":"{ hello }"}')
    expect(result["data"]).to eq("hello" => "world")
  end

  it "a JWT whose payload repeats a claim is read with the last value" do
    secret = "json-dup-secret-0123456789abcdef"
    encode = ->(bytes) { Tina4::Base64.urlsafe_encode64(bytes, padding: false) }
    header = encode.call('{"alg":"HS256","typ":"JWT"}')
    payload = encode.call(%({"role":"user","role":"admin","exp":#{Time.now.to_i + 600}}))
    signature = encode.call(OpenSSL::HMAC.digest("SHA256", secret, "#{header}.#{payload}"))
    expect(Tina4::Auth.hmac_decode("#{header}.#{payload}.#{signature}", secret, algorithm: "HS256"))
      .to include("role" => "admin")
  end
end
