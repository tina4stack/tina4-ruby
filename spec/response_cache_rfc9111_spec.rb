# frozen_string_literal: true

require "spec_helper"

# RFC 9111 conformance for the SHARED response cache.
#
# The cache key is method + URL only, with no header input. Two normative rules
# stop that from replaying one caller's response to another:
#
#   s3   -- "if the cache is shared: the Authorization header field is not
#           present in the request ... or a response directive is present that
#           explicitly allows shared caching"
#   s4.1 -- "the cache MUST NOT use that stored response without revalidation
#           unless all the presented request header fields nominated by that
#           Vary field value match those fields in the original request"
#
# These drive the REAL Tina4::Request and Tina4::Response through the REAL
# middleware hooks. Test names match tina4-python, tina4-php and tina4-nodejs
# one-for-one.
RSpec.describe "ResponseCache RFC 9111 conformance" do
  let(:cache) { Tina4::ResponseCache.new(ttl: 60) }

  # A real Rack-env-backed request. HTTP_* keys are how Rack carries headers.
  def get_request(path, headers = {})
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => path }
    headers.each { |k, v| env["HTTP_#{k.to_s.upcase.tr('-', '_')}"] = v }
    Tina4::Request.new(env)
  end

  # Run one full request through the hook pair. Returns the response the caller
  # would receive. A HIT short-circuits by returning the Response OBJECT.
  def round_trip(request, body:, response_headers: {})
    response = Tina4::Response.new
    out = cache.before_cache(request, response)
    return [out, :hit] unless out.is_a?(Array)

    request, response = out
    response_headers.each { |k, v| response.headers[k] = v }
    response.json(body)
    _req, response = cache.after_cache(request, response)
    [response, :miss]
  end

  it "response_cache_does_not_store_a_response_to_an_authorized_request" do
    alice = get_request("/api/me", "Authorization" => "Bearer alice")
    round_trip(alice, body: { "secret_for" => "alice" })

    # A different bearer on the same URL must NOT get alice's body.
    bob, bob_state = round_trip(get_request("/api/me", "Authorization" => "Bearer bob"),
                                body: { "secret_for" => "bob" })
    expect(bob_state).to eq(:miss)
    expect(bob.body.to_s).not_to include("alice")

    # Nor may an unauthenticated caller, where the cache sits ahead of the gate.
    anon, anon_state = round_trip(get_request("/api/me"), body: { "secret_for" => "anon" })
    expect(anon_state).to eq(:miss)
    expect(anon.body.to_s).not_to include("alice")
  end

  it "response_cache_stores_an_authorized_response_when_cache_control_public" do
    first = get_request("/api/rates", "Authorization" => "Bearer any")
    round_trip(first, body: { "usd" => "shared-rates" },
                      response_headers: { "Cache-Control" => "public, max-age=60" })

    second, state = round_trip(get_request("/api/rates", "Authorization" => "Bearer other"),
                               body: { "usd" => "recomputed" })
    expect(state).to eq(:hit)
    expect(second.body.to_s).to include("shared-rates")
  end

  it "response_cache_serves_an_unauthenticated_get" do
    # Negative control: the fix must not simply disable caching everywhere.
    round_trip(get_request("/api/public"), body: { "v" => "public-body" })

    out, state = round_trip(get_request("/api/public"), body: { "v" => "recomputed" })
    expect(state).to eq(:hit)
    expect(out.body.to_s).to include("public-body")
    expect(out.headers["X-Cache"]).to eq("HIT")
  end

  it "response_cache_honours_vary_on_a_nominated_request_header" do
    round_trip(get_request("/api/greeting", "Accept-Language" => "en"),
               body: { "greeting" => "english" },
               response_headers: { "Vary" => "Accept-Language" })

    # Same nominated value -> HIT.
    same, same_state = round_trip(get_request("/api/greeting", "Accept-Language" => "en"),
                                  body: { "greeting" => "recomputed" },
                                  response_headers: { "Vary" => "Accept-Language" })
    expect(same_state).to eq(:hit)
    expect(same.body.to_s).to include("english")

    # Different value -> MISS, the handler runs again.
    fr, fr_state = round_trip(get_request("/api/greeting", "Accept-Language" => "fr"),
                              body: { "greeting" => "french" },
                              response_headers: { "Vary" => "Accept-Language" })
    expect(fr_state).to eq(:miss)
    expect(fr.body.to_s).to include("french")

    # Absent only matches absent.
    none, none_state = round_trip(get_request("/api/greeting"),
                                  body: { "greeting" => "default" },
                                  response_headers: { "Vary" => "Accept-Language" })
    expect(none_state).to eq(:miss)
    expect(none.body.to_s).to include("default")
  end

  it "response_cache_never_stores_vary_asterisk" do
    round_trip(get_request("/api/anything"),
               body: { "v" => "never-reusable" },
               response_headers: { "Vary" => "*" })

    out, state = round_trip(get_request("/api/anything"), body: { "v" => "recomputed" })
    expect(state).to eq(:miss)
    expect(out.body.to_s).to include("recomputed")
  end
end

RSpec.describe "Cache backend name validation" do
  it "cache_backend_unknown_name_raises" do
    # An unrecognised TINA4_CACHE_BACKEND raises, naming the valid set. It used
    # to fall through to memory, so a typo (redsi) produced a running app with a
    # per-process cache while the operator believed it was Redis.
    expect { Tina4::CacheBackends.create_backend(backend: "redsi") }
      .to raise_error(ArgumentError, /redsi.*memory, file, redis, valkey, memcached, mongodb, database/m)
  end

  it "cache_backend_known_names_do_not_raise" do
    # Negative control: every documented spelling still builds.
    %w[memory MEMORY].each do |name|
      expect(Tina4::CacheBackends.create_backend(backend: name).name).to eq("memory")
    end
    expect(Tina4::CacheBackends.create_backend(backend: " memory ").name).to eq("memory")
  end
end
