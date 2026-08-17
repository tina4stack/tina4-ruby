# frozen_string_literal: true

require "spec_helper"
require "cgi"
require "fileutils"
require "net/http"
require "tmpdir"

RSpec.describe "Feature 136 provider-neutral OIDC SSO" do
  def options
    {
      issuer: ENV.fetch("TINA4_TEST_OIDC_ISSUER", "http://127.0.0.1:58080/realms/tina4-contract"),
      client_id: "tina4-app", client_secret: "tina4-secret",
      redirect_uri: "http://127.0.0.1:7147/auth/callback"
    }
  end

  def file_session(directory)
    Tina4::Session.new({}, handler: :file, handler_options: { dir: directory })
  end

  it "exposes the shared surface, fails closed and hides reserved values" do
    contract = JSON.parse(File.read(File.expand_path("fixtures/sso_contract.json", __dir__)))
    expect(contract["adr"]).to eq("ADR-0056")
    expect(contract["invariants"].length).to eq(10)
    value = Tina4::Sso.new(options)
    expect(%i[discover login callback identity refresh logout].all? { |method| value.respond_to?(method) }).to be(true)
    expect(Tina4::Sso.safe_return("/dashboard")).to eq("/dashboard")
    expect(Tina4::Sso.safe_return("https://evil.example")).to eq("/")
    expect { Tina4::Sso.new(options.merge(issuer: "http://identity.example/realm")) }.to raise_error(Tina4::SsoError)
    expect { Tina4::Sso.new(options.merge(verify: "jwks")) }.to raise_error(Tina4::SsoError, /cryptography capability/)
    Dir.mktmpdir("tina4-sso-") do |directory|
      session = file_session(directory)
      session.set("cart", [42])
      session.set(Tina4::Sso::PENDING_KEY, { "state" => "secret" })
      session.set(Tina4::Sso::SESSION_KEY, { "access_token" => "secret" })
      expect(session.all).to eq({ "cart" => [42] })
    end
  end

  def browser_query(login_url, callback)
    uri = URI(login_url)
    page = Net::HTTP.get_response(uri)
    cookies = Array(page.get_fields("set-cookie")).map { |value| value.split(";", 2).first }.join("; ")
    action = CGI.unescapeHTML(page.body.match(/<form[^>]+action="([^"]+)"[^>]*>/)[1])
    action_uri = URI(action)
    request = Net::HTTP::Post.new(action_uri)
    request["Cookie"] = cookies
    request.set_form_data(username: "andre", password: "tina4-pass", credentialId: "")
    response = Net::HTTP.start(action_uri.host, action_uri.port) { |http| http.request(request) }
    expect([302, 303]).to include(response.code.to_i)
    expect(response["location"]).to start_with(callback)
    URI.decode_www_form(URI(response["location"]).query).to_h
  end

  it "completes real PKCE, Session rotation, refresh and local-first logout" do
    skip "real OIDC gate runs on the lab" unless ENV["TINA4_REQUIRE_OIDC"]
    value = Tina4::Sso.from_issuer(options)
    Dir.mktmpdir("tina4-sso-") do |directory|
      session = file_session(directory)
      session.set("cart", [42])
      old_id = session.get_session_id
      login_url = value.login(session, "/dashboard")
      query = URI.decode_www_form(URI(login_url).query).to_h
      expect(query["response_type"]).to eq("code")
      expect(query["code_challenge_method"]).to eq("S256")
      result = value.callback(session, browser_query(login_url, value.redirect_uri))
      expect(session.get_session_id).not_to eq(old_id)
      expect(session.get("cart")).to eq([42])
      expect(result["return_to"]).to eq("/dashboard")
      expect(result.dig("identity", "username")).to eq("andre")
      expect(result.dig("identity", "roles")).to include("admin", "developer")
      expect(result.dig("identity", "groups")).to eq(["/engineering"])
      expect(session.all).not_to have_key(Tina4::Sso::SESSION_KEY)
      expect(value.refresh(session)["subject"]).to eq(result.dig("identity", "subject"))
      expect(value.logout(session)).to include("logout")
      expect(session.get_session_id).to be_nil
    end
  end
end
