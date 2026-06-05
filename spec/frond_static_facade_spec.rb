# frozen_string_literal: true

require_relative "../lib/tina4/frond"

# Parity test suite for the Frond static-facade pattern (cross-framework).
#
# tina4-python registers filters/globals/tests on a class-level registry so
# that ``Frond.add_filter("money", fn)`` at app startup is inherited by every
# subsequent ``Frond()`` instance, including those reborn by hot-reload. This
# spec exercises the equivalent Ruby surface:
#
#   * Class-level call (``Tina4::Frond.add_filter(...)``) — populates the
#     class registry only; later ``Frond.new`` instances drain it on
#     construction.
#   * Instance-level call (``frond.add_filter(...)``) — populates both the
#     class registry AND the instance's live map.
#   * ``Tina4::Frond.clear_registry`` — wipes user-registered state without
#     touching the built-in filters baked in by ``default_filters``.
RSpec.describe Tina4::Frond do
  describe "static facade for filters/globals/tests" do
    # Each test starts with a clean class registry so we don't poison the
    # rest of the suite (built-in filters survive — only user state is wiped).
    before(:each) { Tina4::Frond.clear_registry }
    after(:all)   { Tina4::Frond.clear_registry }

    describe ".add_filter (class-level)" do
      it "registers a filter at class level visible to a NEW instance" do
        Tina4::Frond.add_filter("money") { |v| format("$%.2f", v.to_f) }
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ 100 | money }}", {})).to eq("$100.00")
      end

      it "works in conjunction with chained filters" do
        Tina4::Frond.add_filter("double") { |v| v.to_i * 2 }
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ 5 | double | double }}", {})).to eq("20")
      end

      it "returns the filter for late-constructed instances even after intermediate work" do
        Tina4::Frond.add_filter("shout") { |v| "#{v.to_s.upcase}!" }
        first  = Tina4::Frond.new
        # Do some unrelated work on the first instance.
        expect(first.render_string("{{ x }}", { "x" => "hi" })).to eq("hi")
        # A brand-new instance still inherits the filter.
        second = Tina4::Frond.new
        expect(second.render_string("{{ name | shout }}", { "name" => "andre" })).to eq("ANDRE!")
      end
    end

    describe "#add_filter (instance-level)" do
      it "still works as it always did — updates the instance" do
        engine = Tina4::Frond.new
        engine.add_filter("exclaim") { |v| "#{v}!" }
        expect(engine.render_string("{{ msg | exclaim }}", { "msg" => "hi" })).to eq("hi!")
      end

      it "also propagates the filter to future instances via the class registry" do
        engine = Tina4::Frond.new
        engine.add_filter("yell") { |v| "#{v.to_s.upcase}!" }
        future = Tina4::Frond.new
        expect(future.render_string("{{ s | yell }}", { "s" => "yo" })).to eq("YO!")
      end

      it "returns self so calls can chain" do
        engine = Tina4::Frond.new
        result = engine.add_filter("identity") { |v| v }
        expect(result).to equal(engine)
      end
    end

    describe ".add_global (class-level)" do
      it "registers a global available in NEW instances" do
        Tina4::Frond.add_global("APP", "MyApp")
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ APP }}", {})).to eq("MyApp")
      end

      it "supports non-string values" do
        Tina4::Frond.add_global("MAX", 42)
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ MAX }}", {})).to eq("42")
      end

      it "allows render-time data to override the global" do
        Tina4::Frond.add_global("APP", "Default")
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ APP }}", { "APP" => "Override" })).to eq("Override")
      end
    end

    describe "#add_global (instance-level)" do
      it "updates the current instance immediately" do
        engine = Tina4::Frond.new
        engine.add_global("VERSION", "3.13.4")
        expect(engine.render_string("{{ VERSION }}", {})).to eq("3.13.4")
      end

      it "propagates to future instances" do
        engine = Tina4::Frond.new
        engine.add_global("NAME", "Tina4")
        future = Tina4::Frond.new
        expect(future.render_string("{{ NAME }}", {})).to eq("Tina4")
      end
    end

    describe ".add_test (class-level)" do
      it "registers a test usable in {% if x is ... %} from a NEW instance" do
        Tina4::Frond.add_test("positive") { |v| v.to_f > 0 }
        engine = Tina4::Frond.new
        expect(engine.render_string("{% if x is positive %}yes{% else %}no{% endif %}", { "x" => 5 })).to eq("yes")
        expect(engine.render_string("{% if x is positive %}yes{% else %}no{% endif %}", { "x" => -1 })).to eq("no")
      end

      it "supports 'is not' negation" do
        Tina4::Frond.add_test("big") { |v| v.to_i > 100 }
        engine = Tina4::Frond.new
        expect(engine.render_string("{% if v is not big %}small{% endif %}", { "v" => 10 })).to eq("small")
      end
    end

    describe "#add_test (instance-level)" do
      it "registers a test on the current instance" do
        engine = Tina4::Frond.new
        engine.add_test("zero") { |v| v.to_i == 0 }
        expect(engine.render_string("{% if x is zero %}Z{% else %}NZ{% endif %}", { "x" => 0 })).to eq("Z")
      end

      it "propagates the test to later instances" do
        engine = Tina4::Frond.new
        engine.add_test("even_test") { |v| v.to_i.even? }
        future = Tina4::Frond.new
        expect(future.render_string("{% if x is even_test %}E{% else %}O{% endif %}", { "x" => 4 })).to eq("E")
      end
    end

    describe ".clear_registry" do
      it "wipes user-registered filters" do
        Tina4::Frond.add_filter("shout") { |v| "#{v}!!!" }
        Tina4::Frond.clear_registry
        engine = Tina4::Frond.new
        # No user filter — the value passes through unchanged.
        expect(engine.render_string("{{ x | shout }}", { "x" => "hi" })).to eq("hi")
      end

      it "wipes user-registered globals" do
        Tina4::Frond.add_global("APP", "Cleared")
        Tina4::Frond.clear_registry
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ APP }}", {})).to eq("")
      end

      it "wipes user-registered tests" do
        Tina4::Frond.add_test("custom_truthy") { |v| !!v }
        Tina4::Frond.clear_registry
        engine = Tina4::Frond.new
        # custom_truthy is gone — eval_test returns false for unknown tests.
        expect(engine.render_string("{% if x is custom_truthy %}Y{% else %}N{% endif %}", { "x" => 1 })).to eq("N")
      end

      it "leaves built-in filters intact (upper, lower, length, etc.)" do
        Tina4::Frond.add_filter("shout") { |v| "#{v}!" }
        Tina4::Frond.clear_registry
        engine = Tina4::Frond.new
        expect(engine.render_string("{{ x | upper }}", { "x" => "hi" })).to eq("HI")
        expect(engine.render_string("{{ x | length }}", { "x" => "hello" })).to eq("5")
        expect(engine.render_string("{{ x | lower }}", { "x" => "HI" })).to eq("hi")
      end

      it "leaves built-in tests intact (defined, empty, even, odd, etc.)" do
        Tina4::Frond.add_test("foo") { |v| v == "foo" }
        Tina4::Frond.clear_registry
        engine = Tina4::Frond.new
        expect(engine.render_string("{% if x is defined %}D{% endif %}", { "x" => 1 })).to eq("D")
        expect(engine.render_string("{% if x is even %}E{% endif %}", { "x" => 2 })).to eq("E")
      end
    end

    describe "ordering — registration BEFORE construction (the key use case)" do
      it "registers filter at class level, then constructs first instance — filter is present" do
        # Mimic the app.rb flow: register at module-load, construct engine later.
        Tina4::Frond.add_filter("money") { |v| format("R%.2f", v.to_f) }
        Tina4::Frond.add_global("APP", "Cowork")
        Tina4::Frond.add_test("over_nine_thousand") { |v| v.to_i > 9000 }

        engine = Tina4::Frond.new
        out = engine.render_string(
          "{{ amount | money }} for {{ APP }} — {% if score is over_nine_thousand %}LEGEND{% endif %}",
          { "amount" => 100.5, "score" => 9500 }
        )
        expect(out).to eq("R100.50 for Cowork — LEGEND")
      end
    end
  end
end
