# frozen_string_literal: true

require "spec_helper"

# Frond expression parity gate -- the cross-framework output contract.
#
# WHY THIS FILE EXISTS. "Frond expressions behave the same in all four
# frameworks" was an assumption, never a measurement. When it was finally
# measured -- 72 expressions rendered through Python, PHP, Ruby and Node
# against one identical dataset -- 11 of the 72 disagreed. Booleans disagreed
# in ALL FOUR (PHP printed false as an EMPTY STRING; Ruby was inconsistent with
# itself, yielding `false` for a comparison but '' for a bare false variable;
# Python emitted Python's True/False), {{ not x }} was silently dropped in
# three, and PHP's |json_encode skipped HTML escaping. Each implementation
# looked correct in isolation, which is exactly why the drift survived.
#
# So the corpus is no longer a one-off script -- it is a fixture, and it lives
# in all four repos as the SAME BYTES:
#
#   tina4-python/tests/fixtures/frond_expression_{corpus,expected}.txt
#   tina4-php/tests/fixtures/...
#   tina4-ruby/spec/fixtures/...
#   tina4-nodejs/test/fixtures/...
#
# expected.txt is a single agreed answer key, not a per-language snapshot. If
# one framework drifts, ITS suite goes red while the other three stay green,
# and the diff names the expression. Changing the contract on purpose means
# changing the answer key in all four repos in the same change -- the point.
#
# Keep the dataset below byte-identical to the other three runners.
RSpec.describe "Frond expression parity" do
  FIXTURES = File.join(__dir__, "fixtures")

  # The shared dataset. Must stay identical across all four frameworks -- an
  # expression can only be compared if it is fed the same values.
  def context
    {
      "name" => "Andre",
      "lower_name" => "andre van zuydam",
      "padded" => "  pad  ",
      "empty_str" => "",
      "n" => 5,
      "f" => 1234.5678,
      "neg" => -42,
      "t" => true,
      "f_bool" => false,
      "nil_val" => nil,
      "user" => { "name" => "Ann", "addr" => { "city" => "CPT" } },
      "list" => %w[a b c],
      "map" => { "a" => 1, "b" => 2 },
      "html" => "<b>&x</b>",
      # Non-finite floats: the tina4-php#184 payload. JSON has no Infinity or
      # NaN, so both must serialize as null in every framework.
      "inf_val" => Float::INFINITY,
      "nan_map" => { "v" => Float::NAN }
    }
  end

  # Parse a `label<sep>value` fixture into an ordered list of pairs.
  def self.load_fixture(file, separator)
    File.read(File.join(FIXTURES, file)).split("\n").reject { |l| l.strip.empty? }.map do |line|
      label, _, rest = line.partition(separator)
      [label, rest]
    end
  end

  CORPUS   = load_fixture("frond_expression_corpus.txt", "|").freeze
  EXPECTED = load_fixture("frond_expression_expected.txt", "\t").to_h.freeze

  let(:engine) { Tina4::Frond.new }

  # Guard the guard: a corpus entry with no expected value would otherwise pass
  # by never being asserted.
  it "has a corpus and an answer key that line up" do
    expect(CORPUS.length).to eq(84)
    expect(CORPUS.map(&:first).sort).to eq(EXPECTED.keys.sort)
  end

  CORPUS.each do |label, source|
    it "renders #{label} to the cross-framework contract" do
      expect(engine.render_string(source, context)).to eq(EXPECTED[label])
    end
  end

  # -- Named regressions for the bugs the corpus actually caught -------------
  # The generated examples above would catch these too, but only as "some line
  # changed". These name the behaviour, and each carries the NEGATIVE case that
  # was failing before the fix.

  describe "boolean rendering" do
    # 3.13.87 contract: a boolean renders lowercase `true`/`false`.
    #
    # Ruby had TWO falsy guards behind this. `resolve` used
    # `value[part] || value[part.to_sym]` -- and since only nil and false are
    # falsy in Ruby, a STORED false fell through to a missing symbol key,
    # became nil, and rendered EMPTY. The concat path had the same `|| ""`.
    # That is why a comparison yielded "false" but a bare false variable
    # yielded "". Both now probe with `key?` instead of truthiness.
    it "renders lowercase true/false, and a stored false never vanishes" do
      ctx = { "t" => true, "f" => false, "n" => 5 }
      expect(engine.render_string("{{ t }}", ctx)).to eq("true")
      expect(engine.render_string("{{ f }}", ctx)).to eq("false")
      expect(engine.render_string("{{ n > 3 }}", ctx)).to eq("true")
      expect(engine.render_string("{{ n < 3 }}", ctx)).to eq("false")
      # The bare-variable form -- the half that used to render blank.
      expect(engine.render_string("[{{ f }}]", ctx)).to eq("[false]")
      # ...and through the concat path, the second falsy guard.
      expect(engine.render_string("{{ 'v=' ~ f }}", ctx)).to eq("v=false")
      # A symbol-keyed context must behave the same as a string-keyed one.
      expect(engine.render_string("{{ f }}", { f: false })).to eq("false")
      # An integer 1 still renders as 1, not as "true".
      expect(engine.render_string("{{ one }}", { "one" => 1 })).to eq("1")
    end
  end

  describe "the not operator" do
    # `{{ not x }}` renders the boolean instead of being silently dropped.
    #
    # Every logical operator was matched WITH surrounding spaces, so a LEADING
    # `not` (nothing to its left) matched none of them, fell through to the
    # variable-resolution tail, and was looked up as a variable literally named
    # "not x" -- which rendered EMPTY. `{% if not x %}` and `x and not y`
    # always worked, so the operator logic was fine; only the standalone output
    # expression was lost. Before booleans rendered lowercase, a dropped
    # expression and `false -> ''` were indistinguishable, which is why it hid.
    it "evaluates a standalone {{ not x }} output expression" do
      ctx = { "t" => true, "f" => false }
      expect(engine.render_string("{{ not t }}", ctx)).to eq("false")
      expect(engine.render_string("{{ not f }}", ctx)).to eq("true")
      expect(engine.render_string("{{ not missing }}", ctx)).to eq("true")
      # The paths that always worked -- they must not drift from the standalone form.
      expect(engine.render_string("{% if not f %}Y{% else %}N{% endif %}", ctx)).to eq("Y")
      expect(engine.render_string("{{ t and not f }}", ctx)).to eq("true")
      expect(engine.render_string("{{ not t ? 'A' : 'B' }}", ctx)).to eq("B")
    end

    it "treats an identifier merely starting with 'not' as a variable" do
      # NEGATIVE case: no space after "not", so this is never the operator.
      expect(engine.render_string("{{ notes }}", { "notes" => nil })).to eq("")
      expect(engine.render_string("{{ nothing }}", { "nothing" => "x" })).to eq("x")
      expect(engine.render_string('{{ "not a var" }}', {})).to eq("not a var")
    end
  end

  describe "json_encode output contract" do
    # 3.13.88 reverts 3.13.87's HTML-escaping of this filter. Entity-encoding the
    # payload produced {&quot;a&quot;:1}, a SyntaxError inside <script>, which
    # broke the filter's primary use in all four frameworks at once. The safe
    # form escapes only the dangerous characters, as JSON \uXXXX escapes: valid
    # JSON, valid JavaScript, cannot terminate a </script>, safe in a
    # single-quoted attribute. Jinja2's tojson model.
    it "emits JSON that is valid inside a script block" do
      expect(engine.render_string("{{ data|json_encode }}", { "data" => { "a" => 1 } })).to eq('{"a":1}')
      # Negative case: escapes must be \uXXXX, never HTML entities, and
      # </script> must not survive intact.
      out = engine.render_string("{{ data|json_encode }}", { "data" => { "x" => "</script>&'" } })
      expect(out).to eq('{"x":"\\u003c/script\\u003e\\u0026\\u0027"}')
      expect(out).not_to include("&quot;")
      expect(out).not_to include("</script>")
      # raw is now a no-op rather than the required opt-out.
      expect(engine.render_string("{{ data|json_encode|raw }}", { "data" => { "a" => 1 } })).to eq('{"a":1}')
    end

    # tina4-php#184 (justin-k-bruce). JSON.generate RAISES on Infinity, and the
    # old `rescue v.to_s` answered that raise with Ruby inspect output that no
    # JSON.parse will read. null is the only answer the JSON grammar allows.
    it "never emits a non-finite literal" do
      inf = Float::INFINITY
      nan = Float::NAN
      expect(engine.render_string("{{ v|json_encode }}", { "v" => inf })).to eq("null")
      expect(engine.render_string("{{ v|json_encode }}", { "v" => -inf })).to eq("null")
      expect(engine.render_string("{{ v|json_encode }}", { "v" => nan })).to eq("null")
      expect(engine.render_string("{{ v|json_encode }}", { "v" => { "a" => 1, "b" => inf } }))
        .to eq('{"a":1,"b":null}')
      expect(engine.render_string("{{ v|json_encode }}", { "v" => [1, nan] })).to eq("[1,null]")
      # Negative case: none of the old failure outputs, and never empty -- an
      # empty payload is a silent, invisible failure.
      out = engine.render_string("{{ v|json_encode }}", { "v" => { "b" => inf } })
      ["Infinity", "NaN", "false", "=>"].each { |bad| expect(out).not_to include(bad) }
      expect(engine.render_string("{{ v|json_encode }}", { "v" => inf })).not_to eq("")
    end

    # 3.13.89: {% set name %}...{% endset %} binds the rendered body. Core
    # syntax in BOTH reference engines, and broken identically in all four
    # frameworks until now: the body rendered inline where it stood and the
    # variable was never assigned.
    it "captures a block set body instead of printing it" do
      out = engine.render_string("{% set g %}Hi {{ n }}{% endset %}[{{ g }}]", { "n" => "Andre" })
      expect(out).to eq("[Hi Andre]")
      # Negative case: the old bug printed the body first and left the variable
      # empty. Neither may happen.
      expect(out).not_to start_with("Hi")
      expect(out).not_to include("[]")
      expect(engine.render_string("{% set g %}{% for i in [1,2] %}{{ i }}{% endfor %}{% endset %}[{{ g }}]", {}))
        .to eq("[12]")
      # Nesting: the inner endset must not close the outer block.
      expect(engine.render_string("{% set a %}A{% set b %}B{% endset %}{{ b }}{% endset %}[{{ a }}]", {}))
        .to eq("[AB]")
    end

    # The capture is already-escaped output, so it is not escaped again. Twig and
    # Jinja2 both mark a captured block safe. A value interpolated INTO the body
    # is still escaped on the way in -- escaping happens once, in the right place.
    it "marks the capture safe and leaves the inline set form alone" do
      expect(engine.render_string("{% set g %}{{ h }}{% endset %}[{{ g }}]", { "h" => "<b>&x</b>" }))
        .to eq("[&lt;b&gt;&amp;x&lt;/b&gt;]")
      expect(engine.render_string("{% set g %}<b>hi</b>{% endset %}[{{ g }}]", {})).to eq("[<b>hi</b>]")
      # Negative case: the inline assignment form is untouched, including an "="
      # inside a quoted value -- that must NOT be read as the block form.
      expect(engine.render_string(%q({% set g = "x" %}[{{ g }}]), {})).to eq("[x]")
      expect(engine.render_string(%q({% set g = "a = b" %}[{{ g }}]), {})).to eq("[a = b]")
    end

    # THE security-shaped one. {% iff user.is_admin %}...{% endiff %} used to
    # render the admin block UNCONDITIONALLY: the unknown tag emitted nothing and
    # its body was parsed as ordinary content, so a reviewer read a guard that was
    # not there. Twig and Jinja2 both raise on an unknown tag. There is no
    # user-extension point for tags, so an unknown name is always a mistake.
    it "raises on an unknown tag instead of leaking its body" do
      expect { engine.render_string("{% iff admin %}SECRET{% endiff %}", { "admin" => false }) }
        .to raise_error(ArgumentError, /unknown tag "iff"/)
      expect { engine.render_string("{% frobnicate 42 %}", {}) }
        .to raise_error(ArgumentError, /unknown tag "frobnicate"/)
      # Negative case 1: every real tag still parses.
      expect(engine.render_string(
        "{% if 1 %}x{% endif %}{% for i in [1] %}{{ i }}{% endfor %}" \
        "{% raw %}{{ q }}{% endraw %}{% spaceless %} a {% endspaceless %}" \
        "{% autoescape true %}y{% endautoescape %}", {}
      )).to eq("x1{{ q }} a y")
      # Negative case 2: a STRAY terminator is not an unknown tag. It stays a
      # silent no-op -- it was always one, and unlike an unknown tag it cannot
      # expose gated content.
      expect(engine.render_string("A{% endif %}B", {})).to eq("AB")
    end

    it "treats json_encode, to_json and tojson as one behaviour" do
      ctx = { "v" => { "a" => 1, "u" => "a/b", "n" => "caf\u00e9", "bad" => Float::INFINITY } }
      out = engine.render_string("{{ v|json_encode }}", ctx)
      expect(engine.render_string("{{ v|to_json }}", ctx)).to eq(out)
      expect(engine.render_string("{{ v|tojson }}", ctx)).to eq(out)
      # Slashes stay unescaped and non-ASCII stays raw -- PHP alone used to
      # write "a\\/b", and Python alone used to write "caf\\u00e9".
      expect(out).to include('"u":"a/b"')
      expect(out).to include("caf\u00e9")
    end
  end
end
