# frozen_string_literal: true

require "spec_helper"

# Non-overlapping models for the public/secure-by-default parity check.
# (Distinct table + class names so they never collide with auto_crud_spec.rb.)
class SecureNote < Tina4::ORM
  table_name "securenotes"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title, nullable: false
end

class PublicNote < Tina4::ORM
  table_name "publicnotes"
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title, nullable: false
end

# Parity with tina4-python / tina4-php: AutoCrud write routes are
# secure-by-default (the router gates POST/PUT/PATCH/DELETE unless a route
# explicitly opts out via .no_auth). `public: true` is the explicit escape
# hatch that opens the write routes consistently across all backends.
#
# Ruby's Route exposes the gate via `route.auth_required` (attr_accessor):
#   true  => gated (bearer token required)
#   false => open (no_auth)  — see lib/tina4/router.rb:24 / :40
RSpec.describe "Tina4::AutoCrud public: opt-in (secure-by-default parity)" do
  # Write methods that the framework gates by default.
  WRITE_ROUTE_TEMPLATES = [
    ["POST",   "/api/%s"],
    ["PUT",    "/api/%s/1"],
    ["DELETE", "/api/%s/1"],
  ].freeze

  before(:each) do
    Tina4::Router.clear!
    Tina4::AutoCrud.clear!
  end

  describe "default register(Model) — secure by default" do
    before(:each) do
      Tina4::AutoCrud.register(SecureNote)
      Tina4::AutoCrud.generate_routes
    end

    it "gates POST/PUT/DELETE (auth_required = true) — never opts out" do
      WRITE_ROUTE_TEMPLATES.each do |method, tmpl|
        route, = Tina4::Router.match(method, format(tmpl, "securenotes"))
        expect(route).not_to be_nil, "expected #{method} route to be registered"
        expect(route.auth_required).to eq(true),
          "#{method} /api/securenotes should stay gated (secure by default)"
      end
    end

    it "leaves GET (read) routes ungated" do
      route, = Tina4::Router.match("GET", "/api/securenotes")
      expect(route).not_to be_nil
      expect(route.auth_required).to eq(false)
    end
  end

  describe "register(Model, public: true) — explicit opt-out" do
    before(:each) do
      Tina4::AutoCrud.register(PublicNote, public: true)
      Tina4::AutoCrud.generate_routes
    end

    it "marks POST/PUT/DELETE noauth (auth_required = false)" do
      WRITE_ROUTE_TEMPLATES.each do |method, tmpl|
        route, = Tina4::Router.match(method, format(tmpl, "publicnotes"))
        expect(route).not_to be_nil, "expected #{method} route to be registered"
        expect(route.auth_required).to eq(false),
          "#{method} /api/publicnotes should be noauth when public: true"
      end
    end
  end

  describe "generate_routes_for(Model, public:) — direct path" do
    it "opens writes only when public: true, keeps them gated otherwise" do
      Tina4::AutoCrud.generate_routes_for(SecureNote)               # default secure
      Tina4::AutoCrud.generate_routes_for(PublicNote, public: true) # opt-in public

      secure_post, = Tina4::Router.match("POST", "/api/securenotes")
      public_post, = Tina4::Router.match("POST", "/api/publicnotes")

      expect(secure_post.auth_required).to eq(true)
      expect(public_post.auth_required).to eq(false)
    end
  end
end
