# frozen_string_literal: true

# Lock-in specs for 3.13.100's remaining Frond cache bounds (ADR-0004).
#
# @compiled / @compiled_strings were already capped (see
# frond_template_cache_spec.rb). This file covers the three per-expression
# memos that were still plain unbounded Hashes -- @filter_chain_cache,
# @resolve_cache, @dotted_split_cache -- plus the {% cache %} fragment store
# (@fragment_cache), which was BOTH unbounded AND never swept a TTL-expired
# entry: a key that expired and was never read again sat in memory for the
# life of the worker.
#
# Reproduced for real below: real renders through the real engine, and the
# real instance caches read directly. No mocks: nothing here stands in for
# the engine, the clock, or the filesystem.

require_relative "spec_helper"
require_relative "../lib/tina4/frond"

RSpec.describe Tina4::Frond do
  let(:engine) { Tina4::Frond.new }

  describe "per-expression memo cache bound (ADR-0004)" do
    let(:memo_cap) { Tina4::Frond::MEMO_CACHE_MAX }

    it "caps at a positive number of entries" do
      expect(memo_cap).to be > 0
    end

    it "does not grow @filter_chain_cache without limit for distinct filter-chain expressions" do
      distinct = (memo_cap * 2) + 17

      distinct.times do |index|
        result = engine.render_string("{{ n | default(#{index}) }}", {})
        expect(result).to eq(index.to_s)
      end

      size = engine.instance_variable_get(:@filter_chain_cache).size
      expect(size).to be <= memo_cap,
                      "filter_chain_cache grew to #{size} entries for #{distinct} distinct expressions; cap is #{memo_cap}"
    end

    it "does not grow @resolve_cache without limit for distinct dotted-path expressions" do
      distinct = (memo_cap * 2) + 17

      distinct.times do |index|
        result = engine.render_string("{{ v#{index}.name }}", { "v#{index}" => { "name" => index.to_s } })
        expect(result).to eq(index.to_s)
      end

      size = engine.instance_variable_get(:@resolve_cache).size
      expect(size).to be <= memo_cap,
                      "resolve_cache grew to #{size} entries for #{distinct} distinct expressions; cap is #{memo_cap}"
    end

    it "does not grow @dotted_split_cache without limit for distinct sandboxed variable roots" do
      distinct = (memo_cap * 2) + 17
      allowed = Array.new(distinct) { |i| "v#{i}" }
      sandboxed = Tina4::Frond.new
      sandboxed.sandbox(vars: allowed)

      distinct.times do |index|
        result = sandboxed.render_string("{{ v#{index} }}", { "v#{index}" => index.to_s })
        expect(result).to eq(index.to_s)
      end

      size = sandboxed.instance_variable_get(:@dotted_split_cache).size
      expect(size).to be <= memo_cap,
                      "dotted_split_cache grew to #{size} entries for #{distinct} distinct roots; cap is #{memo_cap}"
    end

    # Negative control (shared across the three -- same cap_cache mechanism):
    # the cap must not fire EARLY.
    it "evicts nothing while a memo cache is under the cap" do
      below_cap = memo_cap - 1
      below_cap.times { |index| engine.render_string("{{ n | default(#{index}) }}", {}) }

      expect(engine.instance_variable_get(:@filter_chain_cache).size).to eq(below_cap)
    end

    it "still empties every memo cache on clear_cache" do
      engine.render_string("{{ n | default(1) }}", {})
      engine.render_string("{{ v.name }}", { "v" => { "name" => "x" } })

      expect(engine.instance_variable_get(:@filter_chain_cache)).not_to be_empty
      expect(engine.instance_variable_get(:@resolve_cache)).not_to be_empty

      engine.clear_cache

      expect(engine.instance_variable_get(:@filter_chain_cache)).to be_empty
      expect(engine.instance_variable_get(:@resolve_cache)).to be_empty
      expect(engine.instance_variable_get(:@dotted_split_cache)).to be_empty

      # Still renders correctly from cold after a clear.
      expect(engine.render_string("{{ n | default(1) }}", {})).to eq("1")
    end
  end

  describe "fragment cache bound and TTL sweep (ADR-0004)" do
    let(:frag_cap) { Tina4::Frond::TEMPLATE_CACHE_MAX }

    it "does not grow @fragment_cache without limit for many distinct cache keys" do
      distinct = (frag_cap * 2) + 13

      distinct.times do |index|
        result = engine.render_string(%({% cache "frag#{index}" 300 %}{{ n }}{% endcache %}), { "n" => index })
        expect(result).to eq(index.to_s)
      end

      size = engine.instance_variable_get(:@fragment_cache).size
      expect(size).to be <= frag_cap,
                      "fragment_cache grew to #{size} entries for #{distinct} distinct keys; cap is #{frag_cap}"
    end

    it "evicts nothing while the fragment cache is under the cap" do
      below_cap = frag_cap - 1
      below_cap.times do |index|
        engine.render_string(%({% cache "under#{index}" 300 %}{{ n }}{% endcache %}), { "n" => index })
      end

      expect(engine.instance_variable_get(:@fragment_cache).size).to eq(below_cap)
    end

    # The bound must not cost correctness: a key evicted while still
    # unexpired simply recomputes on next use instead of erroring or
    # serving another key's content.
    it "recomputes a fragment evicted by the size cap and stays correct" do
      first_key_result = engine.render_string('{% cache "first_evictable" 300 %}{{ n }}{% endcache %}', { "n" => "one" })
      expect(first_key_result).to eq("one")

      (frag_cap * 2).times do |index|
        engine.render_string(%({% cache "filler#{index}" 300 %}{{ n }}{% endcache %}), { "n" => index })
      end

      keys = engine.instance_variable_get(:@fragment_cache).keys
      expect(keys).not_to include("first_evictable"), "the first fragment should have been evicted by the size cap"

      # Recomputes from cold with fresh data -- the cache slate was wiped,
      # not left pointing at stale/wrong content.
      recomputed = engine.render_string('{% cache "first_evictable" 300 %}{{ n }}{% endcache %}', { "n" => "two" })
      expect(recomputed).to eq("two")
    end

    it "sweeps a TTL-expired fragment instead of leaving it stale in memory forever" do
      short_lived = engine.render_string('{% cache "short_lived" 1 %}{{ n }}{% endcache %}', { "n" => "first" })
      expect(short_lived).to eq("first")
      engine.render_string('{% cache "control" 300 %}{{ n }}{% endcache %}', { "n" => "control" })

      sleep 1.1

      # Touch a DIFFERENT cache key -- proving the sweep runs as a side
      # effect of any fragment-cache render, not only on a re-read of the
      # SAME key (which the old code already handled by silent overwrite).
      engine.render_string('{% cache "trigger" 300 %}{{ n }}{% endcache %}', { "n" => "trigger" })

      keys = engine.instance_variable_get(:@fragment_cache).keys
      expect(keys).not_to include("short_lived"), "the expired entry should have been swept, not merely left stale"
      expect(keys).to include("control"), "a still-live entry must not be swept early"

      # A fresh render recomputes rather than ever reading stale content.
      refreshed = engine.render_string('{% cache "short_lived" 1 %}{{ n }}{% endcache %}', { "n" => "second" })
      expect(refreshed).to eq("second")
    end
  end
end
