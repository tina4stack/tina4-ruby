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

  # ── Session-leak regressions (port of Python #117) ────────────────
  #
  # The cache key is method + URL only, and a Tina4 session IS a cookie. Before
  # the fix, may_store? guarded only Vary '*' and Authorization, so a
  # cookie-bearing or Set-Cookie response fell through to `true` and was replayed
  # to the next caller of that URL. These prove it no longer is, and the two
  # controls prove the fix did not simply switch caching off.

  it "a response that sets Set-Cookie is not replayed to another session" do
    # First caller's handler installs a session cookie on the response.
    first, first_state = round_trip(get_request("/api/dashboard"),
                                    body: { "user" => "alice" },
                                    response_headers: { "Set-Cookie" => "tina4session=alice; HttpOnly" })
    expect(first_state).to eq(:miss)
    expect(first.body.to_s).to include("alice")

    # A second, different visitor must NOT be served alice's per-session page:
    # the handler has to run again (MISS), not replay from cache.
    second, second_state = round_trip(get_request("/api/dashboard"),
                                      body: { "user" => "bob" })
    expect(second_state).to eq(:miss)
    expect(second.body.to_s).to include("bob")
    expect(second.body.to_s).not_to include("alice")
  end

  it "a cookie-bearing request without a shared-cache directive is not cached" do
    # A signed-in caller carries a session cookie; with no shared-cache opt-in,
    # storing their response would replay it to the next caller of this URL.
    first, first_state = round_trip(get_request("/api/profile", "Cookie" => "tina4session=alice"),
                                    body: { "user" => "alice" })
    expect(first_state).to eq(:miss)

    second, second_state = round_trip(get_request("/api/profile", "Cookie" => "tina4session=bob"),
                                      body: { "user" => "bob" })
    expect(second_state).to eq(:miss)
    expect(second.body.to_s).to include("bob")
    expect(second.body.to_s).not_to include("alice")
  end

  it "responses marked private / no-store / no-cache are not cached" do
    %w[private no-store no-cache].each_with_index do |directive, i|
      url = "/api/secret-#{i}"
      first, first_state = round_trip(get_request(url),
                                      body: { "v" => "first" },
                                      response_headers: { "Cache-Control" => directive })
      expect(first_state).to eq(:miss), "expected #{directive.inspect} first request to MISS"
      expect(first.body.to_s).to include("first")

      _second, second_state = round_trip(get_request(url), body: { "v" => "recomputed" })
      expect(second_state).to eq(:miss), "expected #{directive.inspect} to keep the response out of the cache"
    end
  end

  # Control: a cookie-bearing caller CAN be cached when the response explicitly
  # opts a shared cache in — otherwise the fix would just disable caching for
  # every browser that holds a cookie.
  it "a cookie-bearing request marked public still hits the cache" do
    round_trip(get_request("/api/rates", "Cookie" => "tina4session=alice"),
               body: { "usd" => "shared-rates" },
               response_headers: { "Cache-Control" => "public, max-age=60" })

    second, state = round_trip(get_request("/api/rates", "Cookie" => "tina4session=bob"),
                               body: { "usd" => "recomputed" })
    expect(state).to eq(:hit)
    expect(second.body.to_s).to include("shared-rates")
  end

  # Control: plain cookieless public traffic is unaffected — the common case
  # still caches and replays.
  it "cookieless public traffic still hits the cache" do
    round_trip(get_request("/api/news"), body: { "v" => "headline" })

    second, state = round_trip(get_request("/api/news"), body: { "v" => "recomputed" })
    expect(state).to eq(:hit)
    expect(second.body.to_s).to include("headline")
    expect(second.headers["X-Cache"]).to eq("HIT")
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
