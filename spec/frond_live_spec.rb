# frozen_string_literal: true

# Frond {% live %} blocks — engine, endpoint (respond_live), push (push_live).
# Mirrors the Python test_frond_live* suites and PHP FrondLiveTest. No mocks:
# real Frond, real Request/Response. Parity with the Python master.

require_relative "spec_helper"
require_relative "../lib/tina4/frond"
require_relative "../lib/tina4/request"
require_relative "../lib/tina4/response"

RSpec.describe "Tina4::Frond {% live %} blocks" do
  let(:engine) { Tina4::Frond.new }

  before(:each) { Tina4::Frond.clear_registry }
  after(:each)  { Tina4::Frond.clear_registry }

  # -- engine ----------------------------------------------------------------

  describe "engine" do
    it "renders poll wrapper first paint and registers the fragment" do
      out = engine.render_string(
        '{% live "notifications" poll 5 %}<ul>{% for n in items %}<li>{{ n }}</li>{% endfor %}</ul>{% endlive %}',
        { "items" => %w[a b] }
      )
      expect(out).to include('data-frond-live="notifications"')
      expect(out).to include('id="live-notifications"')
      expect(out).to include('data-mode="poll"')
      expect(out).to include('data-interval="5"')
      expect(out).to include('data-src="/__frond/live/notifications"')
      expect(out).to include("<li>a</li>")
      expect(Tina4::Frond.has_live_fragment?("notifications")).to be true
    end

    it "render_live re-renders with fresh data" do
      engine.render_string('{% live "cart" poll 3 %}<b>{{ count }}</b>{% endlive %}', { "count" => 1 })
      html = Tina4::Frond.render_live("cart", { "count" => 9 })
      expect(html).to include("<b>9</b>")
    end

    it "render_live returns nil for an unknown block" do
      expect(Tina4::Frond.render_live("never-registered", {})).to be_nil
    end

    it "supports sse mode" do
      out = engine.render_string('{% live "feed" sse %}<span>{{ n }}</span>{% endlive %}', { "n" => 12 })
      expect(out).to include('data-mode="sse"')
      expect(out).to include('data-src="/__frond/live/feed"')
    end

    it "ws mode uses data-ws" do
      out = engine.render_string('{% live "chat" ws "/ws/chat" %}hi{% endlive %}', {})
      expect(out).to include('data-mode="ws"')
      expect(out).to include('data-ws="/ws/chat"')
      expect(Tina4::Frond.get_live_ws_path("chat")).to eq("/ws/chat")
    end

    it "honours an explicit src route" do
      out = engine.render_string('{% live "cart" poll 5 src "/fragments/cart" %}0{% endlive %}', {})
      expect(out).to include('data-src="/fragments/cart"')
    end

    it "raises on an unknown transport" do
      expect { engine.render_string('{% live "x" bogus %}y{% endlive %}', {}) }.to raise_error(RuntimeError)
    end

    it "raises when poll has no seconds" do
      expect { engine.render_string('{% live "x" poll %}y{% endlive %}', {}) }.to raise_error(RuntimeError)
    end

    it "rejects a cross-origin src" do
      expect do
        engine.render_string('{% live "x" poll 5 src "http://evil.example/x" %}y{% endlive %}', {})
      end.to raise_error(RuntimeError)
    end

    it "raises on a nested live block" do
      expect do
        engine.render_string('{% live "a" poll 5 %}{% live "b" poll 5 %}z{% endlive %}{% endlive %}', {})
      end.to raise_error(RuntimeError)
    end

    it "live_source registers a provider" do
      fn = ->(_request) { { "n" => 3 } }
      Tina4::Frond.live_source("orders", fn)
      expect(Tina4::Frond.get_live_source("orders")).to eq(fn)
    end
  end

  # -- endpoint (respond_live) ----------------------------------------------

  describe "respond_live endpoint" do
    def request_with(headers = {})
      env = {}
      headers.each { |k, v| env["HTTP_#{k.to_s.upcase.tr('-', '_')}"] = v }
      Tina4::Request.new(env, {})
    end

    it "re-renders with provider data" do
      engine.render_string('{% live "cart" poll 5 %}<b>{{ count }}</b> items{% endlive %}', { "count" => 1 })
      Tina4::Frond.live_source("cart", ->(_r) { { "count" => 7 } })
      resp = Tina4::Frond.respond_live(request_with, Tina4::Response.new, "cart")
      expect(resp.status_code).to eq(200)
      expect(resp.body).to include("<b>7</b> items")
    end

    it "404s for an unknown name" do
      resp = Tina4::Frond.respond_live(request_with, Tina4::Response.new, "nope")
      expect(resp.status_code).to eq(404)
    end

    it "404s when the fragment has not been rendered yet" do
      Tina4::Frond.live_source("later", ->(_r) { { "x" => 1 } })
      resp = Tina4::Frond.respond_live(request_with, Tina4::Response.new, "later")
      expect(resp.status_code).to eq(404)
    end

    it "re-applies auth scoping per request (IDOR guard)" do
      # The provider re-runs with the LIVE request every refresh, so an
      # unauthenticated caller never gets another user's data.
      engine.render_string('{% live "me" poll 5 %}<span>{{ who }}</span>{% endlive %}', { "who" => "" })
      Tina4::Frond.live_source("me", ->(request) { { "who" => (request.headers["x-user"] || "guest") } })

      r1 = Tina4::Frond.respond_live(request_with, Tina4::Response.new, "me")
      expect(r1.body).to include("<span>guest</span>")

      r2 = Tina4::Frond.respond_live(request_with("x-user" => "alice"), Tina4::Response.new, "me")
      expect(r2.body).to include("<span>alice</span>")
      expect(r1.body).not_to include("alice")
    end

    it "renders a fragment with no provider registered" do
      engine.render_string('{% live "static" poll 5 %}<p>hello</p>{% endlive %}', {})
      resp = Tina4::Frond.respond_live(request_with, Tina4::Response.new, "static")
      expect(resp.status_code).to eq(200)
      expect(resp.body).to include("<p>hello</p>")
    end
  end

  # -- push_live -------------------------------------------------------------

  describe "push_live" do
    it "returns the rendered html" do
      engine.render_string('{% live "score" ws "/ws/score" %}<b>{{ n }}</b>{% endlive %}', { "n" => 0 })
      html = Tina4::Frond.push_live("score", { "n" => 5 })
      expect(html).to include("<b>5</b>")
    end

    it "returns nil for an unknown block" do
      expect(Tina4::Frond.push_live("ghost", {})).to be_nil
    end
  end
end
