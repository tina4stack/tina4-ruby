# frozen_string_literal: true

require "spec_helper"

# Sandbox contract: a sandbox denies by revoking capability, not by skipping a step.
#
# Audit feature 38 (plan/v3/features/038-sandboxing.md), P1. Mirrors
# tina4-python/tests/test_frond_sandbox_contract.py and
# tina4-php/tests/FrondSandboxContractTest.php.
#
# Two ways an untrusted template could defeat the sandbox:
#
# P1  `{{ x|raw }}` / `{{ x|safe }}` with raw/safe DENIED by the filter
#     allow-list still produced UNESCAPED output. The escape decision read the
#     filter NAME out of the source (frond.rb:913) instead of asking whether the
#     filter was permitted to RUN, so skipping the filter left the value marked
#     safe anyway. Denying raw produced byte-identical output to allowing it.
#
# P1b `{% autoescape false %}` bypassed the TAG allow-list, because the tag gate
#     was a per-name conditional at ONE call site (include) rather than one check
#     where a tag is dispatched.
#
# Ruby reaches outcome parity by a different MECHANISM than Python/PHP, and that
# is deliberate: they walk an AST and can drop a node, while `render_tokens`
# walks a token stream whose handlers consume their own body. A denied tag here
# is CONSUMED WITHOUT RUNNING (`skip_block`) -- skipping only the opening token
# would leave the body to render at the top level and leak exactly what was
# denied. Outcome parity is the contract; mechanism parity is not.
#
# Pure string rendering. No I/O, no dependency, no doubles.
RSpec.describe "Frond sandbox contract" do
  xss     = "<script>alert(1)</script>"
  escaped = "&lt;script&gt;alert(1)&lt;/script&gt;"

  # A sandbox whose filter allow-list does NOT include raw or safe.
  let(:denied) do
    Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: ["x"])
  end

  # The same sandbox, but raw and safe ARE on the allow-list.
  let(:allowed) do
    Tina4::Frond.new.sandbox(filters: %w[upper raw safe], tags: ["if"], vars: ["x"])
  end

  # --- pair 1: raw is revocable ------------------------------------------

  it "escapes the value when raw is denied" do
    expect(denied.render_string("{{ x|raw }}", { "x" => xss })).to eq(escaped)
  end

  it "negative: a denied raw filter never produces unescaped output" do
    out = denied.render_string("{{ x|raw }}", { "x" => xss })
    expect(out).not_to include("<script>"),
                       "a DENIED raw filter produced live markup: #{out.inspect}"
  end

  # --- pair 2: safe is revocable ----------------------------------------

  it "escapes the value when safe is denied" do
    expect(denied.render_string("{{ x|safe }}", { "x" => xss })).to eq(escaped)
  end

  it "negative: a denied safe filter never produces unescaped output" do
    out = denied.render_string("{{ x|safe }}", { "x" => xss })
    expect(out).not_to include("<script>"),
                       "a DENIED safe filter produced live markup: #{out.inspect}"
  end

  # --- pair 3: deny must differ from allow ------------------------------

  it "renders verbatim when raw is allowed and escaped when denied" do
    expect(allowed.render_string("{{ x|raw }}", { "x" => xss })).to eq(xss)
    expect(denied.render_string("{{ x|raw }}", { "x" => xss })).to eq(escaped)
  end

  it "negative: denying a filter never produces the same output as allowing it" do
    expect(denied.render_string("{{ x|raw }}", { "x" => xss }))
      .not_to eq(allowed.render_string("{{ x|raw }}", { "x" => xss })),
              "denying raw and allowing raw produced identical output - the gate is inert"
  end

  # --- pair 4: the tag gate cannot be bypassed (P1b) --------------------

  it "does not let a denied autoescape tag disable escaping" do
    out = denied.render_string(
      "{% autoescape false %}{{ x }}{% endautoescape %}", { "x" => xss }
    )
    expect(out).not_to include("<script>"),
                       "{% autoescape false %} disabled escaping despite not being " \
                       "on the tag allow-list: #{out.inspect}"
  end

  it "negative: no tag can disable escaping inside a sandbox" do
    [
      "{% autoescape false %}{{ x }}{% endautoescape %}",
      "{% autoescape off %}{{ x }}{% endautoescape %}"
    ].each do |tpl|
      out = denied.render_string(tpl, { "x" => xss })
      expect(out).not_to include("<script>"), "#{tpl} disabled escaping: #{out.inspect}"
    end
  end

  # --- pair 5: escape is revocable too ----------------------------------
  # Ruby is immune to this BY CONSTRUCTION and these examples keep it that way.
  # The escape filter returns a Tina4::SafeString (frond.rb), so escaping is marked
  # by a value the filter produces only when it actually RUNS -- deny it and no
  # SafeString exists, so the value is still auto-escaped. Python does the same;
  # PHP prepends a RAW_MARKER. Node instead set a flag from the filter NAME and
  # therefore DID emit live markup for a denied escape (fixed in 1eb1c4a). Anyone
  # who later "simplifies" escape to return a plain String reopens that hole here.

  it "negative: a denied escape filter never produces unescaped output" do
    out = denied.render_string("{{ x|escape }}", { "x" => xss })
    expect(out).not_to include("<script>"),
                       "a DENIED escape filter produced live markup: #{out.inspect}. " \
                       "Escaping must be conferred by RUNNING the filter, never by its name."
  end

  it "negative: a denied e filter never produces unescaped output" do
    out = denied.render_string("{{ x|e }}", { "x" => xss })
    expect(out).not_to include("<script>"),
                       "a DENIED e filter produced live markup: #{out.inspect}"
  end

  it "escapes exactly once when escape is allowed" do
    engine = Tina4::Frond.new.sandbox(filters: ["escape"], tags: ["if"], vars: ["x"])
    expect(engine.render_string("{{ x|escape }}", { "x" => xss })).to eq(escaped)
  end

  # --- pair 6: a denied tag consumes its body ---------------------------
  # The Ruby-specific hazard. `for` is denied here; if the gate skips only the
  # opening token, the body tokens render at the top level and LEAK.

  it "consumes the body of a denied block tag instead of leaking it" do
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: %w[x items])
    out = engine.render_string("{% for i in items %}LEAK{% endfor %}", { "items" => [1, 2] })
    expect(out).not_to include("LEAK"),
                       "a DENIED block tag leaked its body: #{out.inspect}"
  end

  it "keeps a denied tag from binding a variable (no side effects)" do
    # `set` is denied. If the handler runs before being discarded, it still
    # mutates the context and `{{ y }}` would render the bound value.
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: %w[x y])
    out = engine.render_string("{% set y = 'LEAK' %}{{ y }}", {})
    expect(out).not_to include("LEAK"),
                       "a DENIED set tag bound its variable anyway: #{out.inspect}"
  end

  it "gates a nested denied tag" do
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: %w[x items])
    out = engine.render_string(
      "{% if x %}{% for i in items %}LEAK{% endfor %}{% endif %}",
      { "x" => true, "items" => [1, 2] }
    )
    expect(out).not_to include("LEAK"), "a nested DENIED tag ran: #{out.inspect}"
  end

  it "still runs an allowed nested tag" do
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: %w[if for], vars: %w[x items])
    out = engine.render_string(
      "{% if x %}{% for i in items %}Y{% endfor %}{% endif %}",
      { "x" => true, "items" => [1, 2] }
    )
    expect(out).to eq("YY"), "an ALLOWED nested tag was blocked"
  end

  # --- pair 6: what must NOT change -------------------------------------

  it "never gates output on the tag allow-list" do
    # A `{{ }}` is not a tag. A tag allow-list of ["if"] must not blank every
    # expression in the template.
    engine = Tina4::Frond.new.sandbox(filters: nil, tags: ["if"], vars: nil)
    expect(engine.render_string("{{ greeting }}", { "greeting" => "hello" })).to eq("hello")
  end

  it "runs an allowed filter and skips a denied one" do
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: ["v"])
    expect(engine.render_string("{{ v|upper }}", { "v" => "MiXeD" })).to eq("MIXED")
    expect(engine.render_string("{{ v|lower }}", { "v" => "MiXeD" })).to eq("MiXeD")
  end

  it "still renders a denied variable as empty" do
    engine = Tina4::Frond.new.sandbox(filters: ["upper"], tags: ["if"], vars: ["ok"])
    expect(engine.render_string("{{ secret }}", { "ok" => "y", "secret" => "LEAKED" })).to eq("")
  end

  it "leaves escaping outside a sandbox unchanged" do
    plain = Tina4::Frond.new
    expect(plain.render_string("{{ x }}", { "x" => xss })).to eq(escaped)
    expect(plain.render_string("{{ x|raw }}", { "x" => xss })).to eq(xss)
    expect(plain.render_string("{{ x|safe }}", { "x" => xss })).to eq(xss)
  end

  it "restores raw on unsandbox" do
    engine = denied
    expect(engine.render_string("{{ x|raw }}", { "x" => xss })).to eq(escaped)
    engine.unsandbox
    expect(engine.render_string("{{ x|raw }}", { "x" => xss })).to eq(xss)
  end

  # --- empty vs nil allow-list -----------------------------------------
  # nil means "allow everything". An EMPTY list must not silently mean the same,
  # or a caller who computes an allow-list and gets nothing back opens the sandbox.

  it "permits everything on a nil allow-list" do
    engine = Tina4::Frond.new.sandbox(filters: nil, tags: nil, vars: nil)
    expect(engine.render_string("{{ x|raw }}", { "x" => xss })).to eq(xss)
  end

  it "negative: an empty allow-list does not permit everything" do
    engine = Tina4::Frond.new.sandbox(filters: [], tags: [], vars: ["x"])
    out = engine.render_string("{{ x|raw }}", { "x" => xss })
    expect(out).not_to include("<script>"),
                       "an EMPTY filter allow-list behaved like nil (allow all): #{out.inspect}"
  end
end
