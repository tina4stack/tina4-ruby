# frozen_string_literal: true

# Tina4 Frond Engine -- Lexer, parser, and runtime.
# Zero-dependency twig-like template engine.
# Supports: variables, filters, if/elseif/else/endif, for/else/endfor,
# extends/block, include, macro, set, comments, whitespace control, tests,
# fragment caching, sandboxing, auto-escaping, custom filters/tests/globals.

require "json"
require "digest"
require "base64"
require "cgi"
require "erb"
require "uri"
require "date"
require "time"
require "securerandom"

module Tina4
  # Marker class for strings that should not be auto-escaped in Frond.
  class SafeString < String
  end

  class Frond
    # -- Class-level registries ------------------------------------------------
    # Persist globals, filters, and tests across hot-reloads and across module
    # boundaries. When app.rb does ``Tina4::Frond.add_filter("money") { ... }``
    # at startup before any instance exists, the registration sits here. Every
    # subsequent ``Tina4::Frond.new`` drains these into its instance-local
    # registries — so hot-reloads (which re-execute ``frond = Frond.new``) and
    # late-constructed engines automatically inherit prior registrations.
    #
    # The same-name dual-callable (class + instance) methods below let callers
    # write either ``Tina4::Frond.add_filter(...)`` (class-level only) or
    # ``frond.add_filter(...)`` (updates both the class registry and the
    # instance's live filter map). Parity with tina4-python's
    # ``_ClassOrInstanceMethod`` descriptor.
    @@class_filters = {}
    @@class_globals = {}
    @@class_tests   = {}

    # -- Live-block registries (server-rendered {% live %} regions) -----------
    # A {% live %} block registers three things when its page first renders:
    #   * class_live_fragments[name]  -> the raw body source, re-rendered on
    #                                    every refresh by the /__frond/live/<name>
    #                                    endpoint or push_live
    #   * class_live_sources[name]    -> an optional data provider (live_source)
    #                                    that re-runs with the LIVE request each
    #                                    refresh, so auth re-applies (IDOR guard)
    #   * class_live_ws_paths[name]   -> the ws path a `ws "path"` block declared,
    #                                    used as the push_live broadcast target
    # These persist across requests in the long-lived server (parity with the
    # Python master's class-level dicts and PHP's static registries).
    @@class_live_fragments = {}
    @@class_live_sources   = {}
    @@class_live_ws_paths  = {}

    # Clear the class-level globals/filters/tests/live registries.
    #
    # Useful in test fixtures to prevent leaking state between tests. Does
    # NOT affect built-in filters or globals — only user-registered ones.
    def self.clear_registry
      @@class_filters = {}
      @@class_globals = {}
      @@class_tests   = {}
      @@class_live_fragments = {}
      @@class_live_sources   = {}
      @@class_live_ws_paths  = {}
    end

    # -- Token types ----------------------------------------------------------
    TEXT    = :text
    VAR     = :var      # {{ ... }}
    BLOCK   = :block    # {% ... %}
    COMMENT = :comment  # {# ... #}

    # Regex to split template source into tokens
    TOKEN_RE = /(\{%-?\s*.*?\s*-?%\})|(\{\{-?\s*.*?\s*-?\}\})|(\{#.*?#\})/m

    # HTML escape table
    HTML_ESCAPE_MAP = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;",
                        '"' => "&quot;", "'" => "&#39;" }.freeze
    HTML_ESCAPE_RE  = /[&<>"']/

    # -- Compiled regex constants (optimization: avoid re-compiling in methods) --
    EXTENDS_RE      = /\{%-?\s*extends\s+["'](.+?)["']\s*-?%\}/
    BLOCK_RE        = /\{%-?\s*block\s+(\w+)\s*-?%\}(.*?)\{%-?\s*endblock\s*-?%\}/m
    # Open/close halves of BLOCK_RE, used standalone by extract_blocks' depth
    # counter -- a single non-greedy BLOCK_RE match cannot tell a NESTED
    # endblock from the outer block's own, so it needs its own two-piece scan.
    BLOCK_OPEN_RE   = /\{%-?\s*block\s+(\w+)\s*-?%\}/
    BLOCK_CLOSE_RE  = /\{%-?\s*endblock\s*-?%\}/
    STRING_LIT_RE   = /\A["'](.*)["']\z/
    INTEGER_RE      = /\A-?\d+\z/
    FLOAT_RE        = /\A-?\d+\.\d+\z/
    ARRAY_LIT_RE    = /\A\[(.+)\]\z/m
    HASH_LIT_RE     = /\A\{(.+)\}\z/m
    HASH_PAIR_RE    = /\A\s*(?:["']([^"']+)["']|(\w+))\s*:\s*(.+)\z/
    RANGE_LIT_RE    = /\A(\d+)\.\.(\d+)\z/
    ARITHMETIC_OPS  = [" + ", " - ", " * ", " // ", " / ", " % ", " ** "].freeze
    # Operators Twig binds LOOSER than the filter pipe `|`. When one of these
    # sits at the top level alongside a pipe (e.g. `amount|number_format(2) ~
    # ' EUR'`), the whole expression must go through eval_expr (which resolves
    # the pipe at its correct, tighter precedence) instead of being split on
    # the pipe as a plain filter chain. Detection is quote/paren-aware
    # (find_outside_quotes) so operator-like text inside a string or filter
    # args never false-triggers.
    LOOSER_THAN_PIPE_OPS = [
      "~", "??", " if ",
      " not in ", " in ", " is not ", " is ", "!=", "==", ">=", "<=", ">", "<",
      " and ", " or ", " not ",
      " + ", " - ", " * ", " // ", " / ", " % ", " ** "
    ].freeze
    # A dot is allowed in the callee so {% import "f" as m %} can register its macros
    # under the literal key "m.greet" and {{ m.greet("Andre") }} resolves as a call.
    # Without the dot the whole expression was not recognised as a function call at
    # all, so an aliased macro rendered as SILENTLY EMPTY.
    FUNC_CALL_RE    = /\A([\w.]+)\s*\((.*)\)\z/m
    FILTER_WITH_ARGS_RE = /\A(\w+)\s*\((.*)\)\z/m
    FILTER_CMP_RE   = /\A(\w+)\s*(!=|==|>=|<=|>|<)\s*(.+)\z/
    OR_SPLIT_RE     = /\s+or\s+/
    AND_SPLIT_RE    = /\s+and\s+/
    IS_NOT_RE       = /\A(.+?)\s+is\s+not\s+(\w+)(.*)\z/
    IS_RE           = /\A(.+?)\s+is\s+(\w+)(.*)\z/
    NOT_IN_RE       = /\A(.+?)\s+not\s+in\s+(.+)\z/
    IN_RE           = /\A(.+?)\s+in\s+(.+)\z/
    DIVISIBLE_BY_RE = /\s*by\s*\(\s*(\d+)\s*\)/
    RESOLVE_SPLIT_RE = /\.|\[([^\]]+)\]/
    RESOLVE_STRIP_RE = /\A["']|["']\z/
    DIGIT_RE        = /\A\d+\z/
    FOR_RE          = /\Afor\s+(\w+)(?:\s*,\s*(\w+))?\s+in\s+(.+)\z/
    SET_RE          = /\Aset\s+(\w+)\s*=\s*(.+)\z/m
    INCLUDE_RE      = /\Ainclude\s+["'](.+?)["'](?:\s+with\s+(.+))?\z/
    MACRO_RE        = /\Amacro\s+(\w+)\s*\(([^)]*)\)/
    # {% live "name" poll N | sse | ws "path" [src "url"] %}
    LIVE_RE         = /\Alive\s+["']([^"']+)["'](.*)\z/m
    LIVE_WS_RE      = /ws\s+["']([^"']+)["']/
    LIVE_SRC_RE     = /src\s+["']([^"']+)["']/

    # Escape a value for use inside an HTML attribute on a live marker.
    # Byte-identical order to the Python master / PHP liveAttr so the emitted
    # marker element matches across all four frameworks.
    def self.live_attr(value)
      value.to_s.gsub("&", "&amp;").gsub('"', "&quot;")
           .gsub("<", "&lt;").gsub(">", "&gt;")
    end
    FROM_IMPORT_RE  = /\Afrom\s+["'](.+?)["']\s+import\s+(.+)/
    IMPORT_AS_RE    = /\Aimport\s+["'](.+?)["']\s+as\s+(\w+)/
    CACHE_RE        = /\Acache\s+["'](.+?)["']\s*(\d+)?/
    SPACELESS_RE    = />\s+</

    # Every tag that OPENS a construct. An unknown tag is a typo, and 3.13.89
    # makes it raise rather than render its body: a mistyped guard --
    # {% iff is_admin %} instead of {% if is_admin %} -- used to render the gated
    # content UNCONDITIONALLY, so a reviewer saw a guard that was not there. Twig
    # and Jinja2 both raise on an unknown tag; Frond now does too. There is no
    # user-extension point for tags in any of the four frameworks, so an unknown
    # name is always a mistake, never a plugin.
    KNOWN_TAGS = %w[
      autoescape block cache extends for from if import include live macro raw set
      spaceless
    ].freeze

    # Terminators and branch keywords. These reach the tag dispatch only when
    # stray (their own collector consumes them in the normal case), and a stray
    # one keeps the old render-nothing behaviour -- see the comment at the raise.
    TERMINATOR_TAGS = %w[
      elif else elseif endautoescape endblock endcache endfor endif endlive
      endmacro endraw endset endspaceless
    ].freeze

    # Author-written tags the sandbox allow-list governs. Mirrors Python's
    # _GATEABLE_TAGS and PHP's GATEABLE_TAGS. A tag absent from this list is
    # structural, not an author capability, and is never gated -- `block` and
    # `extends` are template inheritance, and `raw` is consumed by the tokenizer.
    # Both spellings of set ({% set x = 1 %} and {% set x %}...{% endset %})
    # dispatch under "set", so one entry covers the pair.
    GATEABLE_TAGS = %w[
      autoescape cache for from if import include live macro set spaceless
    ].freeze

    # Gateable tags that OWN A BODY, mapped to the terminator closing it. A
    # denied tag has to consume its body -- see skip_block.
    BLOCK_TAG_ENDS = {
      "autoescape" => "endautoescape",
      "cache" => "endcache",
      "for" => "endfor",
      "if" => "endif",
      "live" => "endlive",
      "macro" => "endmacro",
      "set" => "endset",
      "spaceless" => "endspaceless"
    }.freeze
    AUTOESCAPE_RE   = /\Aautoescape\s+(false|true)/
    STRIPTAGS_RE    = /<[^>]+>/
    THOUSANDS_RE    = /(\d)(?=(\d{3})+(?!\d))/
    SLUG_CLEAN_RE   = /[^a-z0-9]+/
    SLUG_TRIM_RE    = /\A-|-\z/

    # Set of common no-arg filter names that can be inlined for speed
    INLINE_FILTERS = %w[upper lower length trim capitalize title string int escape e].each_with_object({}) { |f, h| h[f] = true }.freeze

    # Hard cap on the template caches — @compiled and @compiled_strings
    # (ADR-0004, parity with PHP/Python/Node TEMPLATE_CACHE_MAX).
    #
    # An entry here is a whole token list, so the cap sits well below what a
    # per-expression memo would justify. 256 is far above any real
    # application's template count, so a normal app never evicts. The cap
    # exists for the workload that genuinely grows without limit for the life
    # of a worker: +render_string+ keys on md5(source), so an app that builds
    # template strings dynamically adds an entry per distinct string.
    TEMPLATE_CACHE_MAX = 256

    # -- Lazy context overlay for for-loops (avoids full Hash#dup) --
    class LoopContext
      def initialize(parent)
        @parent = parent
        @local = {}
      end

      def [](key)
        @local.key?(key) ? @local[key] : @parent[key]
      end

      def []=(key, value)
        @local[key] = value
      end

      def key?(key)
        @local.key?(key) || @parent.key?(key)
      end
      alias include? key?
      alias has_key? key?

      def fetch(key, *args, &block)
        if @local.key?(key)
          @local[key]
        elsif @parent.key?(key)
          @parent[key]
        elsif block
          yield key
        elsif !args.empty?
          args[0]
        else
          raise KeyError, "key not found: #{key.inspect}"
        end
      end

      def merge(other)
        dup_hash = to_h
        dup_hash.merge!(other)
        dup_hash
      end

      def merge!(other)
        other.each { |k, v| @local[k] = v }
        self
      end

      def dup
        copy = LoopContext.new(@parent)
        @local.each { |k, v| copy[k] = v }
        copy
      end

      def to_h
        h = @parent.is_a?(LoopContext) ? @parent.to_h : @parent.dup
        @local.each { |k, v| h[k] = v }
        h
      end

      def each(&block)
        to_h.each(&block)
      end

      def respond_to_missing?(name, include_private = false)
        @parent.respond_to?(name, include_private) || super
      end

      def is_a?(klass)
        klass == Hash || super
      end

      def keys
        (@parent.is_a?(LoopContext) ? @parent.keys : @parent.keys) | @local.keys
      end
    end

    # -----------------------------------------------------------------------
    # Public API
    # -----------------------------------------------------------------------

    attr_reader :template_dir

    def initialize(template_dir: "src/templates")
      @template_dir    = template_dir
      @filters         = default_filters
      @globals         = {}
      @tests           = default_tests
      @auto_escape     = true

      # Sandboxing
      @sandbox         = false
      @allowed_filters = nil
      @allowed_tags    = nil
      @allowed_vars    = nil

      # Fragment cache: key => [html, expires_at]
      @fragment_cache  = {}

      # Token pre-compilation cache
      @compiled         = {}  # {template_name => [tokens, mtime]}
      @compiled_strings = {}  # {md5_hash => tokens}

      # Parsed filter chain cache: expr_string => [variable, filters]
      @filter_chain_cache = {}

      # Resolved dotted-path split cache: expr_string => parts_array
      @resolve_cache = {}

      # Sandbox root-var split cache: var_name => root_var_string
      @dotted_split_cache = {}

      # Built-in global functions
      register_builtin_globals

      # Drain class-level registries into this instance. Filters and tests
      # registered via ``Tina4::Frond.add_filter`` BEFORE this instance was
      # constructed flow in here. Globals likewise. This is the key to the
      # static-facade: ``app.rb`` registers once at startup, and every
      # Frond instance created later (including those born from hot-reloads)
      # automatically inherits the registration. Parity with tina4-python.
      @filters.merge!(@@class_filters)
      @globals.merge!(@@class_globals)
      @tests.merge!(@@class_tests)
    end

    # Render a template file with data. Uses token caching for performance.
    #
    # Caching strategy:
    #   * TINA4_DEBUG=true        — never cache (always re-read + re-tokenize).
    #   * TINA4_TEMPLATE_CACHE_TTL > 0 — cache entries expire after N seconds.
    #   * TINA4_TEMPLATE_CACHE_TTL == 0 (default in production) — permanent cache.
    def render(template, data = {})
      context = @globals.merge(stringify_keys(data))

      path = File.join(@template_dir, template)
      raise "Template not found: #{path}" unless File.exist?(path)

      debug_mode = ENV.fetch("TINA4_DEBUG", "").downcase == "true"
      ttl = (ENV["TINA4_TEMPLATE_CACHE_TTL"] || "0").to_i

      unless debug_mode
        cached = @compiled[template]
        if cached
          # cached layout: [tokens, mtime, cached_at]
          tokens, _mtime, cached_at = cached
          fresh = ttl <= 0 || (Time.now.to_i - cached_at.to_i) < ttl
          return execute_cached(tokens, context) if fresh
        end
      end
      # Dev mode: skip cache entirely — always re-read and re-tokenize
      # so edits to partials and extended base templates are detected

      # Cache miss — load, tokenize, cache
      source = File.read(path, encoding: "utf-8")
      mtime = File.mtime(path)
      tokens = tokenize(source)
      cap_cache(@compiled, TEMPLATE_CACHE_MAX)
      @compiled[template] = [tokens, mtime, Time.now.to_i]
      execute_with_tokens(source, tokens, context)
    end

    # Render a template string directly. Uses token caching for performance.
    def render_string(source, data = {})
      context = @globals.merge(stringify_keys(data))

      key = Digest::MD5.hexdigest(source)
      cached_tokens = @compiled_strings[key]

      if cached_tokens
        return execute_cached(cached_tokens, context)
      end

      tokens = tokenize(source)
      cap_cache(@compiled_strings, TEMPLATE_CACHE_MAX)
      @compiled_strings[key] = tokens
      execute_cached(tokens, context)
    end

    # Clear all compiled template caches.
    def clear_cache
      @compiled.clear
      @compiled_strings.clear
      @filter_chain_cache.clear
      @resolve_cache.clear
      @dotted_split_cache.clear
    end

    # Register a custom filter on the class registry only.
    #
    # Callable as ``Tina4::Frond.add_filter("money") { |v| ... }`` at app
    # startup BEFORE any instance exists. The registration is remembered at
    # class level so every later ``Tina4::Frond.new`` inherits it. To also
    # update a live instance's filter map, use the instance method form.
    def self.add_filter(name, &blk)
      @@class_filters[name.to_s] = blk
    end

    # Register a custom test on the class registry only.
    #
    # Same dual-callable semantics as ``add_filter`` — see that method for
    # the static-facade pattern.
    def self.add_test(name, &blk)
      @@class_tests[name.to_s] = blk
    end

    # Register a global variable on the class registry only.
    #
    # Same dual-callable semantics as ``add_filter`` — see that method for
    # the static-facade pattern.
    def self.add_global(name, value)
      @@class_globals[name.to_s] = value
    end

    # Register a custom filter.
    #
    # Updates BOTH the class registry (so future ``Tina4::Frond.new`` picks
    # the filter up) AND this instance's live filter map (so the change is
    # visible to subsequent renders on the current engine).
    def add_filter(name, &blk)
      self.class.add_filter(name, &blk)
      @filters[name.to_s] = blk
      self
    end

    # Register a custom test.
    #
    # Updates BOTH the class registry and this instance's live tests map.
    # See ``add_filter`` for the dual-write semantics.
    def add_test(name, &blk)
      self.class.add_test(name, &blk)
      @tests[name.to_s] = blk
      self
    end

    # Register a global variable available in all templates.
    #
    # Updates BOTH the class registry and this instance's live globals map.
    # See ``add_filter`` for the dual-write semantics.
    def add_global(name, value)
      self.class.add_global(name, value)
      @globals[name.to_s] = value
      self
    end

    # Enable sandbox mode.
    def sandbox(filters: nil, tags: nil, vars: nil)
      @sandbox         = true
      @allowed_filters = filters ? filters.map(&:to_s) : nil
      @allowed_tags    = tags    ? tags.map(&:to_s)    : nil
      @allowed_vars    = vars    ? vars.map(&:to_s)    : nil
      self
    end

    # Disable sandbox mode.
    def unsandbox
      @sandbox         = false
      @allowed_filters = nil
      @allowed_tags    = nil
      @allowed_vars    = nil
      self
    end

    # May this filter RUN under the current sandbox?
    #
    # The escaping decision has to ask this rather than read the filter name out
    # of the source: a denied `raw` that still marked its value safe made the
    # allow-list entry governing XSS escaping inert.
    def filter_permitted?(name)
      return true unless @sandbox && @allowed_filters

      @allowed_filters.include?(name.to_s)
    end

    # May this tag run under the current sandbox?
    #
    # One gate for every tag, so the allow-list governs the whole tag vocabulary
    # instead of whichever names somebody remembered to check individually.
    def tag_permitted?(tag)
      return true unless @sandbox && @allowed_tags
      return true unless GATEABLE_TAGS.include?(tag)

      @allowed_tags.include?(tag)
    end

    # Utility: HTML escape
    def self.escape_html(str)
      str.to_s.gsub(HTML_ESCAPE_RE, HTML_ESCAPE_MAP)
    end

    # Serializes a value to compact JSON text that is always valid JSON.
    #
    # Never raises and never returns an empty string: a non-finite float becomes
    # null (the JSON spec has no Infinity or NaN) and malformed UTF-8 is scrubbed,
    # so a payload always arrives, in the worst case as null.
    def self.json_text(value)
      JSON.generate(value)
    rescue StandardError
      # Only reached when the happy path raised, so a well-formed payload never
      # pays for the walk.
      begin
        JSON.generate(json_sanitize(value))
      rescue StandardError
        "null"
      end
    end

    # Replaces anything JSON.generate refuses with a JSON-representable stand-in.
    def self.json_sanitize(value)
      case value
      when Float   then value.finite? ? value : nil
      when Hash    then value.transform_values { |item| json_sanitize(item) }
      when Array   then value.map { |item| json_sanitize(item) }
      when String  then value.valid_encoding? ? value : value.scrub
      else value
      end
    end

    # Serializes to JSON that is valid JSON, valid JavaScript, and safe in HTML.
    #
    # THE cross-framework contract for json_encode / to_json / tojson. Keep the
    # four implementations byte-identical; frond_expression_corpus.txt locks it.
    #
    # Three things this must never do, each of which was a real bug:
    #
    # 1. Never emit a non-finite literal. JSON.generate raises on Infinity, and
    #    the old `rescue v.to_s` turned that raise into Ruby inspect output --
    #    `{"a" => 1.0}` -- which no JSON.parse will read. Reported as
    #    tina4-php#184 by justin-k-bruce, who hit the same class of bug in PHP.
    # 2. Never emit nothing, and never emit something that still parses and means
    #    something else. "var ROWS = ;" is at least a loud SyntaxError.
    # 3. Never HTML-escape it. Entity-encoding JSON produces {&quot;a&quot;:1},
    #    a SyntaxError inside <script>, which is the filter's whole point. Escape
    #    only the dangerous characters, as JSON \uXXXX escapes: the result stays
    #    valid JSON AND valid JavaScript, </script> cannot terminate the block,
    #    and it is safe inside a single-quoted attribute. This is what Jinja2's
    #    tojson does, and it is why the result is a SafeString.
    #
    # U+2028 and U+2029 join that escape set. Both are legal inside a JSON string
    # and both were illegal inside a JavaScript string literal before ES2019.
    def self.json_safe(value)
      Tina4::SafeString.new(json_text(value).gsub(JSON_ESCAPE_RE, JSON_ESCAPE_MAP))
    end

    JSON_ESCAPE_MAP = {
      "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026", "'" => "\\u0027",
      "\u2028" => "\\u2028", "\u2029" => "\\u2029"
    }.freeze
    JSON_ESCAPE_RE = /[<>&'\u2028\u2029]/

    private

    # Keep a memo cache bounded (ADR-0004). Call immediately before inserting
    # a new entry.
    #
    # Eviction is insertion-ordered (oldest first), not true LRU: a Ruby Hash
    # preserves insertion order, so dropping from the front is cheap, whereas
    # refreshing recency on every cache HIT would add writes to the hottest
    # path in a render and cost more than it saves. Half the cache is dropped
    # at once so the sweep amortises to O(1) per insert.
    #
    # Evicting can never change what a render produces: every read site treats
    # a miss as "recompute", so a swept entry is rebuilt on next use.
    #
    # @param cache [Hash] memo cache to bound, mutated in place
    # @param max_entries [Integer] cap for this cache
    # @return [void]
    def cap_cache(cache, max_entries)
      return if cache.size < max_entries

      cache.keys.first(max_entries / 2).each { |key| cache.delete(key) }
    end

    # -----------------------------------------------------------------------
    # Tokenizer
    # -----------------------------------------------------------------------

    # Regex to extract {% raw %}...{% endraw %} blocks before tokenizing
    RAW_BLOCK_RE = /\{%-?\s*raw\s*-?%\}(.*?)\{%-?\s*endraw\s*-?%\}/m

    def tokenize(source)
      # 1. Extract raw blocks and replace with placeholders
      raw_blocks = []
      source = source.gsub(RAW_BLOCK_RE) do
        idx = raw_blocks.length
        raw_blocks << Regexp.last_match(1)
        "\x00RAW_#{idx}\x00"
      end

      # 2. Normal tokenization
      tokens = []
      pos = 0
      source.scan(TOKEN_RE) do
        m = Regexp.last_match
        start = m.begin(0)
        tokens << [TEXT, source[pos...start]] if start > pos

        raw = m[0]
        if raw.start_with?("{#")
          tokens << [COMMENT, raw]
        elsif raw.start_with?("{{")
          tokens << [VAR, raw]
        elsif raw.start_with?("{%")
          tokens << [BLOCK, raw]
        end
        pos = m.end(0)
      end
      tokens << [TEXT, source[pos..]] if pos < source.length

      # 3. Restore raw block placeholders as literal TEXT
      unless raw_blocks.empty?
        tokens = tokens.map do |ttype, value|
          if ttype == TEXT && value.include?("\x00RAW_")
            raw_blocks.each_with_index do |content, idx|
              value = value.gsub("\x00RAW_#{idx}\x00", content)
            end
          end
          [ttype, value]
        end
      end

      tokens
    end

    # Strip delimiters from a tag and detect whitespace control markers.
    # Returns [content, strip_before, strip_after].
    def strip_tag(raw)
      inner = raw[2..-3] # remove {{ }} or {% %} or {# #}
      strip_before = false
      strip_after  = false

      if inner.start_with?("-")
        strip_before = true
        inner = inner[1..]
      end
      if inner.end_with?("-")
        strip_after = true
        inner = inner[0..-2]
      end

      [inner.strip, strip_before, strip_after]
    end

    # -----------------------------------------------------------------------
    # Template loading
    # -----------------------------------------------------------------------

    # Load a template's source, CONFINED under the templates directory.
    #
    # Every path-taking tag ({% include %}, {% extends %}, {% import %},
    # {% from ... import %}) funnels through this one loader, so this single guard
    # confines them all (TAG-DEC-01): a name that is absolute, climbs out with a
    # +..+ up-level segment, or resolves through a symlink to a location OUTSIDE
    # the templates root is REFUSED -- the outside file is never read. Template
    # -side analogue of the static-asset confinement (feature 41 / ADR-0050).
    def load_template(name)
      # Lexical belt: refuse an absolute path or a `..` up-level segment before
      # touching the filesystem (defense in depth in front of the realpath check).
      if name.start_with?("/", "\\") || name =~ %r{\A[A-Za-z]:} ||
         name.split(%r{[\\/]}).include?("..")
        raise "Template path escapes the templates directory: #{name}"
      end
      path = File.join(@template_dir, name)
      raise "Template not found: #{path}" unless File.file?(path)

      # Realpath containment: a symlink INSIDE the templates dir whose target
      # resolves OUTSIDE it is refused (the lexical belt cannot see a symlink).
      root = File.realpath(@template_dir)
      real = File.realpath(path)
      unless real == root || real.start_with?(root + File::SEPARATOR)
        raise "Template path escapes the templates directory: #{name}"
      end

      File.read(real, encoding: "utf-8")
    end

    # -----------------------------------------------------------------------
    # Execution
    # -----------------------------------------------------------------------

    def execute_cached(tokens, context)
      # Check if first non-text token is an extends block
      tokens.each do |ttype, raw|
        next if ttype == TEXT && raw.strip.empty?
        if ttype == BLOCK
          content, _, _ = strip_tag(raw)
          if content.start_with?("extends ")
            # Extends requires source-based execution for block extraction
            source = tokens.map { |_, v| v }.join
            return execute(source, context)
          end
        end
        break
      end
      render_tokens(tokens, context)
    end

    # Return this template's OWN {% extends %} parent name, or nil.
    #
    # A template may extend at most one parent. Before 3.13.100 a SECOND
    # {% extends %} tag anywhere in the source was silently invisible: only
    # the first occurrence was ever matched, and the rest of the child's
    # non-block content -- including the second extends tag -- was already
    # discarded the same way ordinary non-block child content always is
    # during inheritance. That hid what is almost always a mistake (a
    # copy-paste, a bad merge) with zero signal. Raise clearly instead, the
    # same policy 3.13.89 applied to an unknown tag.
    def extends_target(source)
      matches = source.scan(EXTENDS_RE)
      if matches.length > 1
        raise "Frond: template has #{matches.length} \"{% extends %}\" tags -- " \
              "a template can extend only one parent"
      end
      source =~ EXTENDS_RE ? Regexp.last_match(1) : nil
    end

    def execute_with_tokens(source, tokens, context)
      # Handle extends first
      parent_name = extends_target(source)
      if parent_name
        parent_source = load_template(parent_name)
        child_blocks = extract_blocks(source)
        return render_with_blocks(parent_source, context, child_blocks)
      end

      render_tokens(tokens, context)
    end

    def execute(source, context)
      # Handle extends first
      parent_name = extends_target(source)
      if parent_name
        parent_source = load_template(parent_name)
        child_blocks = extract_blocks(source)
        return render_with_blocks(parent_source, context, child_blocks)
      end

      render_tokens(tokenize(source), context)
    end

    # Extract {% block name %}...{% endblock %} from source, TOP-LEVEL only.
    #
    # Counts depth rather than relying on a single non-greedy BLOCK_RE scan:
    # a plain scan cannot tell a NESTED block's own {% endblock %} from the
    # outer block's real one, so it pairs the outer open with whichever
    # {% endblock %} happens to come first -- silently truncating the outer
    # block's captured content at the wrong tag. A nested block's own markup
    # stays embedded, VERBATIM, inside its outer block's captured content
    # here; resolving it is render_with_blocks' fixed-point substitution
    # loop's job, not this method's. Matches the Python master's
    # _extract_blocks.
    def extract_blocks(source)
      blocks = {}
      pos = 0
      len = source.length

      while pos < len
        m_open = BLOCK_OPEN_RE.match(source, pos)
        break unless m_open

        name = m_open[1]
        content_start = m_open.end(0)
        depth = 1
        scan = content_start
        matched = false

        while depth.positive? && scan < len
          next_open = BLOCK_OPEN_RE.match(source, scan)
          next_close = BLOCK_CLOSE_RE.match(source, scan)
          break if next_close.nil? # malformed -- no matching endblock

          if next_open && next_open.begin(0) < next_close.begin(0)
            depth += 1
            scan = next_open.end(0)
          else
            depth -= 1
            if depth.zero?
              blocks[name] = source[content_start...next_close.begin(0)]
              pos = next_close.end(0)
              matched = true
              break
            end
            scan = next_close.end(0)
          end
        end

        pos = content_start unless matched # malformed -- skip forward
      end

      blocks
    end

    def render_with_blocks(parent_source, context, child_blocks)
      # Multi-level extends: when this parent ITSELF has its own {% extends %},
      # merge its own block defaults under the child's overrides (the nearer
      # descendant always wins) and recurse until a root template with no
      # {% extends %} is reached. Before 3.13.100 this recursion never
      # happened: a mid-level parent's own {% extends %} tag reached
      # render_tokens' "block/endblock/extends" case, which is a silent
      # no-op, so a 3+ level chain lost the root's wrapping entirely and any
      # of the mid template's own non-block text leaked through unwrapped
      # instead. Matches the Python/PHP/Node masters, which already recurse
      # the parent -> grandparent chain the same way.
      grandparent_name = extends_target(parent_source)
      if grandparent_name
        parent_blocks = extract_blocks(parent_source)
        merged_blocks = parent_blocks.merge(child_blocks)

        # Resolve NESTED blocks: a block value that itself contains a
        # {% block inner %}...{% endblock %} tag (this level's own markup,
        # not yet substituted) has that inner tag replaced with the merged
        # dict's value for that name, or the inner tag's own default when
        # nothing overrides it. Fixed-point because resolving one level can
        # reveal another (a block three levels deep). Matches Python/Node's
        # multi-level extends, and is what lets a grandchild override a
        # block nested INSIDE a block the middle template redeclares.
        changed = true
        while changed
          changed = false
          merged_blocks.keys.each do |name|
            resolved = merged_blocks[name].gsub(BLOCK_RE) do
              inner_name = Regexp.last_match(1)
              inner_default = Regexp.last_match(2)
              merged_blocks.fetch(inner_name, inner_default)
            end
            if resolved != merged_blocks[name]
              merged_blocks[name] = resolved
              changed = true
            end
          end
        end

        grandparent_source = load_template(grandparent_name)
        return render_with_blocks(grandparent_source, context, merged_blocks)
      end

      engine = self
      result = parent_source.gsub(BLOCK_RE) do
        name = Regexp.last_match(1)
        parent_content = Regexp.last_match(2)
        block_source = child_blocks.fetch(name, parent_content)

        # Make parent() and super() available inside child blocks
        rendered_parent = nil
        get_parent = lambda do
          rendered_parent ||= Tina4::SafeString.new(
            engine.send(:render_tokens, tokenize(parent_content), context)
          )
          rendered_parent
        end

        block_ctx = context.merge("parent" => get_parent, "super" => get_parent)
        render_tokens(tokenize(block_source), block_ctx)
      end
      render_tokens(tokenize(result), context)
    end

    # -----------------------------------------------------------------------
    # Token renderer
    # -----------------------------------------------------------------------

    # Consume a denied tag WITHOUT running it, returning the index past its body.
    #
    # Ruby walks a token stream, so a denied tag cannot simply be dropped the way
    # an AST node can. Advancing by one token would leave the body's tokens to
    # render at the TOP level, leaking exactly the content the sandbox denied.
    # Running the handler and discarding its output is no better: handle_set binds
    # its variable before it returns. Consuming the block gives all three
    # properties at once -- no output, no side effects, correct index.
    def skip_block(tokens, i, tag, content)
      terminator = BLOCK_TAG_ENDS[tag]
      # {% set x = 1 %} is an assignment and owns no body; {% set x %}...{% endset %}
      # captures one. Same exact-"=" test the dispatch uses.
      terminator = nil if tag == "set" && content.include?("=")
      return i + 1 if terminator.nil?

      depth = 1
      j = i + 1
      while j < tokens.length
        if tokens[j][0] == BLOCK
          inner = strip_tag(tokens[j][1])[0]
          case inner.split[0]
          when tag
            # A nested assignment-form set opens no body, so it must not nest.
            depth += 1 unless tag == "set" && inner.include?("=")
          when terminator
            depth -= 1
            return j + 1 if depth.zero?
          end
        end
        j += 1
      end

      # Unterminated block: consume to the end. Nothing renders, which is the
      # safe answer -- the alternative leaks the body of a denied tag.
      tokens.length
    end

    def render_tokens(tokens, context)
      output = []
      i = 0

      while i < tokens.length
        ttype, raw = tokens[i]

        case ttype
        when TEXT
          output << raw
          i += 1

        when COMMENT
          i += 1

        when VAR
          content, strip_b, strip_a = strip_tag(raw)
          output[-1] = output[-1].rstrip if strip_b && !output.empty?

          result = eval_var(content, context)
          output << (result.nil? ? "" : result.to_s)

          if strip_a && i + 1 < tokens.length && tokens[i + 1][0] == TEXT
            tokens[i + 1] = [TEXT, tokens[i + 1][1].lstrip]
          end
          i += 1

        when BLOCK
          content, strip_b, strip_a = strip_tag(raw)
          output[-1] = output[-1].rstrip if strip_b && !output.empty?

          tag = content.split[0] || ""

          # ONE sandbox gate for the whole tag vocabulary. Previously only
          # `include` was checked, so every other tag ignored the allow-list --
          # {% autoescape false %} could switch escaping off from inside a
          # sandbox whose tags were restricted to something else entirely.
          unless tag_permitted?(tag)
            i = skip_block(tokens, i, tag, content)
            if strip_a && i < tokens.length && tokens[i][0] == TEXT
              tokens[i] = [TEXT, tokens[i][1].lstrip]
            end
            next
          end

          case tag
          when "if"
            result, i = handle_if(tokens, i, context)
            output << result
          when "for"
            result, i = handle_for(tokens, i, context)
            output << result
          when "set"
            # An assignment has an "="; without one this is the BLOCK form,
            # {% set name %}...{% endset %}, which captures its rendered body.
            # A bare include? is exact here, not a shortcut: the block form's tag
            # content is only ever "set <name>", so an "=" anywhere -- even inside
            # a quoted value like {% set m = "a = b" %} -- means assignment.
            if content.include?("=")
              handle_set(content, context)
              i += 1
            else
              i = handle_set_block(tokens, i, context)
            end
          when "include"
            output << handle_include(content, context)
            i += 1
          when "macro"
            i = handle_macro(tokens, i, context)
          when "import"
            handle_import_as(content, context)
            i += 1
          when "from"
            handle_from_import(content, context)
            i += 1
          when "cache"
            result, i = handle_cache(tokens, i, context)
            output << result
          when "live"
            result, i = handle_live(tokens, i, context)
            output << result
          when "spaceless"
            result, i = handle_spaceless(tokens, i, context)
            output << result
          when "autoescape"
            result, i = handle_autoescape(tokens, i, context)
            output << result
          when "block", "endblock", "extends"
            i += 1
          else
            i += 1
            unless tag.empty? || TERMINATOR_TAGS.include?(tag)
              raise ArgumentError,
                    %(Frond: unknown tag "#{tag}" -- known tags are: #{KNOWN_TAGS.sort.join(", ")})
            end
            # An empty tag ({%  %}) or a stray terminator (an {% endif %} with
            # no {% if %}): no output.
            # Malformed, but it has always rendered nothing, and nothing is the
            # safe answer -- unlike an unknown tag it cannot expose content that
            # was meant to be gated.
          end

          if strip_a && i < tokens.length && tokens[i][0] == TEXT
            tokens[i] = [TEXT, tokens[i][1].lstrip]
          end
        else
          i += 1
        end
      end

      output.join
    end

    # -----------------------------------------------------------------------
    # Variable evaluation
    # -----------------------------------------------------------------------

    def eval_var(expr, context)
      # Check for top-level ternary BEFORE splitting filters so that
      # expressions like ``products|length != 1 ? "s" : ""`` work correctly.
      ternary_pos = find_ternary(expr)
      if ternary_pos != -1
        cond_part = expr[0...ternary_pos].strip
        rest = expr[(ternary_pos + 1)..]
        colon_pos = find_colon(rest)
        if colon_pos != -1
          true_part = rest[0...colon_pos].strip
          false_part = rest[(colon_pos + 1)..].strip
          cond = eval_var_raw(cond_part, context)
          return truthy?(cond) ? eval_var(true_part, context) : eval_var(false_part, context)
        end
      end

      eval_var_inner(expr, context)
    end

    def eval_var_raw(expr, context)
      var_name, filters = parse_filter_chain(expr)
      value = eval_expr(var_name, context)
      filters.each do |fname, args|
        next if fname == "raw" || fname == "safe"

        # Sandbox: a blocked filter is silently skipped (value passes through
        # unchanged) — same gate as eval_var_inner. Without this, a filter pipe
        # reached via eval_filter_pipe (`x|f ~ y`, #171) or a ternary condition
        # (`x|f ? a : b`) would run a non-allow-listed filter in sandbox mode.
        next if @sandbox && @allowed_filters && !@allowed_filters.include?(fname)

        # Filter + property-access chain: `first.groupSummary` — apply
        # the filter, then traverse the path on the result using a
        # synthetic context so eval_expr's dotted resolution does the
        # work. Parity with tina4-python + tina4-php.
        real_fname, tail_path = split_filter_name_and_path(fname)
        if !tail_path.empty? && @filters[real_fname]
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = @filters[real_fname].call(value, *evaluated_args)
          value = eval_expr("__frond_filter_tmp.#{tail_path}",
                            { "__frond_filter_tmp" => value })
          next
        end

        fn = @filters[fname]
        if fn
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = fn.call(value, *evaluated_args)
        else
          # The filter name may include a trailing comparison operator,
          # e.g. "length != 1".  Extract the real filter name and the
          # comparison suffix, apply the filter, then evaluate the comparison.
          m = fname.match(FILTER_CMP_RE)
          if m
            real_filter = m[1]
            op = m[2]
            right_expr = m[3].strip
            fn2 = @filters[real_filter]
            if fn2
              evaluated_args = args.map { |a| eval_filter_arg(a, context) }
              value = fn2.call(value, *evaluated_args)
            end
            right = eval_expr(right_expr, context)
            value = case op
                    when "!=" then value != right
                    when "==" then value == right
                    when ">=" then value >= right
                    when "<=" then value <= right
                    when ">"  then value > right
                    when "<"  then value < right
                    else false
                    end rescue false
          else
            value = eval_expr(fname, context)
          end
        end
      end
      value
    end

    def eval_var_inner(expr, context)
      # Twig binds the filter pipe `|` TIGHTER than ~, comparison, and
      # arithmetic. When a looser operator sits at the top level alongside a
      # pipe (e.g. `amount|number_format(2) ~ ' EUR'`), splitting on the pipe
      # here would swallow the tail (`~ ' EUR'`) into the filter args and drop
      # it. Hand the whole expression to eval_expr — which resolves the pipe at
      # the correct precedence (eval_filter_pipe) — then apply output escaping.
      if find_outside_quotes(expr, "|") >= 0 && has_looser_than_pipe_operator?(expr)
        value = eval_expr(expr, context)
        if @auto_escape && value.is_a?(String) && !value.is_a?(SafeString)
          value = Frond.escape_html(value)
        end
        return value
      end

      var_name, filters = parse_filter_chain(expr)

      # Sandbox: check variable access
      if @sandbox && @allowed_vars
        root_var = @dotted_split_cache[var_name]
        unless root_var
          root_var = var_name.split(".")[0].split("[")[0].strip
          @dotted_split_cache[var_name] = root_var
        end
        return "" if !root_var.empty? && !@allowed_vars.include?(root_var) && root_var != "loop"
      end

      value = eval_expr(var_name, context)

      is_safe = false
      filters.each do |fname, args|
        if fname == "raw" || fname == "safe"
          # Decide from what was permitted to RUN, not from what the source
          # asked for. Marking the value safe here regardless meant a DENIED
          # raw produced byte-identical output to an allowed one -- the
          # allow-list entry that governs XSS escaping did nothing at all.
          is_safe = true if filter_permitted?(fname)
          next
        end

        # Sandbox: check filter access
        next if @sandbox && @allowed_filters && !@allowed_filters.include?(fname)

        # Filter + property-access chain: `first.groupSummary` — apply
        # the filter, then traverse the path on the result. Done BEFORE
        # the inline fast-path so cases like `items|first.name` work
        # regardless of whether `first` is an inline filter too.
        real_fname, tail_path = split_filter_name_and_path(fname)
        if !tail_path.empty? && @filters[real_fname]
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = @filters[real_fname].call(value, *evaluated_args)
          value = eval_expr("__frond_filter_tmp.#{tail_path}",
                            { "__frond_filter_tmp" => value })
          next
        end

        # Inline common no-arg filters for speed (skip generic dispatch)
        if args.empty? && INLINE_FILTERS.include?(fname)
          value = case fname
                  when "upper"      then value.to_s.upcase
                  when "lower"      then value.to_s.downcase
                  when "length"     then value.respond_to?(:length) ? value.length : value.to_s.length
                  when "trim"       then value.to_s.strip
                  when "capitalize" then value.to_s.capitalize
                  when "title"      then value.to_s.split.map(&:capitalize).join(" ")
                  when "string"     then value.to_s
                  when "int"        then value.to_i
                  when "escape", "e" then Tina4::SafeString.new(Frond.escape_html(value.to_s))
                  else value
                  end
          next
        end

        fn = @filters[fname]
        if fn
          evaluated_args = args.map { |a| eval_filter_arg(a, context) }
          value = fn.call(value, *evaluated_args)
        end
      end

      # Auto-escape HTML unless marked safe or SafeString
      if @auto_escape && !is_safe && value.is_a?(String) && !value.is_a?(SafeString)
        value = Frond.escape_html(value)
      end

      value
    end

    def eval_filter_arg(arg, context)
      return Regexp.last_match(1) if arg =~ STRING_LIT_RE
      return arg.to_i if arg =~ INTEGER_RE
      return arg.to_f if arg =~ FLOAT_RE
      eval_expr(arg, context)
    end

    # Find the first occurrence of +needle+ that is not inside quotes or
    # parentheses.  Returns the index, or -1 if not found.
    def find_outside_quotes(expr, needle)
      # Fast path. This is the hottest method in a render -- profiling the Python
      # twin showed 415,200 calls and 53% of render time for a single 20-row loop
      # template, and the overwhelming majority return -1 because the needle
      # simply is not in the expression. include? is a C-level scan, so bailing
      # here skips the whole Ruby character loop. Exact, not a heuristic: a
      # needle absent from the string cannot be present outside quotes either.
      return -1 unless expr.include?(needle)

      in_q = nil
      depth = 0
      bracket_depth = 0
      i = 0
      nlen = needle.length
      # Hoisted: expr.length was recomputed on every iteration of the condition.
      last_start = expr.length - nlen
      while i <= last_start
        ch = expr[i]
        if (ch == '"' || ch == "'") && depth == 0
          if in_q.nil?
            in_q = ch
          elsif ch == in_q
            in_q = nil
          end
          i += 1
          next
        end
        if in_q
          i += 1
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        elsif ch == "["
          bracket_depth += 1
        elsif ch == "]"
          bracket_depth -= 1
        end
        if depth == 0 && bracket_depth == 0 && expr[i, nlen] == needle
          return i
        end
        i += 1
      end
      -1
    end

    # Find the index of a top-level ``?`` that is part of a ternary operator.
    # Respects quoted strings, parentheses, and skips ``??`` (null coalesce).
    # Returns -1 if not found.
    def find_ternary(expr)
      depth = 0
      in_quote = nil
      i = 0
      len = expr.length
      while i < len
        ch = expr[i]
        if in_quote
          in_quote = nil if ch == in_quote
          i += 1
          next
        end
        if ch == '"' || ch == "'"
          in_quote = ch
          i += 1
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        elsif ch == "?" && depth == 0
          # Skip ``??`` (null coalesce)
          if i + 1 < len && expr[i + 1] == "?"
            i += 2
            next
          end
          return i
        end
        i += 1
      end
      -1
    end

    # Find the index of the top-level ``:`` that separates the true/false
    # branches of a ternary.  Respects quotes and parentheses.
    def find_colon(expr)
      depth = 0
      in_quote = nil
      expr.each_char.with_index do |ch, i|
        if in_quote
          in_quote = nil if ch == in_quote
          next
        end
        if ch == '"' || ch == "'"
          in_quote = ch
          next
        end
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
        elsif ch == ":" && depth == 0
          return i
        end
      end
      -1
    end

    # -----------------------------------------------------------------------
    # Filter chain parser
    # -----------------------------------------------------------------------

    # Split "first.groupSummary" into ["first", "groupSummary"] so a
    # filter segment followed by property access — `{{ x | first.name }}`
    # — applies the filter then traverses the path on the result.
    # Returns [fname, ""] when no structural dot is present.
    #
    # The split point must sit outside parens/brackets/braces and quotes
    # so filter args like `round(1.5)` or `date("Y.m.d")` don't false-
    # trigger. Parity with tina4-python and tina4-php.
    def split_filter_name_and_path(fname)
      depth = 0
      in_q  = nil
      i     = 0
      n     = fname.length
      while i < n
        ch = fname[i]
        if in_q
          in_q = nil if ch == in_q && (i.zero? || fname[i - 1] != "\\")
          i += 1
          next
        end
        case ch
        when '"', "'"
          in_q = ch
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1
        when "."
          return [fname[0...i], fname[(i + 1)..]] if depth.zero?
        end
        i += 1
      end
      [fname, ""]
    end

    def parse_filter_chain(expr)
      cached = @filter_chain_cache[expr]
      return cached if cached

      parts = split_on_pipe(expr)
      variable = parts[0].strip
      filters = []

      parts[1..].each do |f|
        f = f.strip
        if f =~ FILTER_WITH_ARGS_RE
          name = Regexp.last_match(1)
          raw_args = Regexp.last_match(2).strip
          args = raw_args.empty? ? [] : parse_args(raw_args)
          filters << [name, args]
        else
          filters << [f.strip, []]
        end
      end

      result = [variable, filters].freeze
      @filter_chain_cache[expr] = result
      result
    end

    # Split expression on | but not inside quotes or parens.
    def split_on_pipe(expr)
      parts = []
      current = +""
      in_quote = nil
      depth = 0

      expr.each_char do |ch|
        if in_quote
          current << ch
          in_quote = nil if ch == in_quote
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "("
          depth += 1
          current << ch
        elsif ch == ")"
          depth -= 1
          current << ch
        elsif ch == "|" && depth == 0
          parts << current
          current = +""
        else
          current << ch
        end
      end
      parts << current unless current.empty?
      parts
    end

    def parse_args(raw)
      args = []
      current = +""
      in_quote = nil
      depth = 0

      raw.each_char do |ch|
        if in_quote
          if ch == in_quote
            in_quote = nil
          end
          current << ch
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "(" || ch == "{" || ch == "["
          depth += 1
          current << ch
        elsif ch == ")" || ch == "}" || ch == "]"
          depth -= 1
          current << ch
        elsif ch == "," && depth == 0
          args << current.strip
          current = +""
        else
          current << ch
        end
      end
      args << current.strip unless current.strip.empty?
      args
    end

    # -----------------------------------------------------------------------
    # Expression evaluator
    # -----------------------------------------------------------------------

    # ── Expression evaluator (dispatcher) ──────────────────────────────
    # Each expression type is handled by a focused helper method.
    # Helpers return :not_matched when the expression doesn't match their
    # type, so the dispatcher falls through to the next handler.

    # Bound for the expression-form cache. Python bounds its expression caches
    # (lru_cache 1024) and PHP's were unbounded instance arrays until ADR-0004;
    # a template with generated expression strings must not grow this forever.
    # FIFO drop-oldest-half, deliberately not LRU (no per-hit bookkeeping on the
    # hot path).
    EXPR_FORM_CACHE_MAX = 2048

    # ── Expression evaluation: a cascade, with the branch memoised ──
    #
    # eval_expr tries 12 structural forms in Twig precedence order. The catch is
    # that the LAST one, `resolve`, is by far the most common (a plain `i.name`),
    # so every ordinary variable used to walk all 11 detectors ahead of it on
    # EVERY render. Measured: ~6-7 microseconds and ~38 Frond method calls per
    # expression evaluation, linear in expression count.
    #
    # So: on first sight run the real cascade and RECORD which branch fired; on
    # later renders jump straight to that branch. The cache key is the expression
    # string, and a form is a pure property of that string.
    #
    # Correctness is owned by the existing evaluators, not by a second copy of the
    # detection logic (which is what would drift). The fast path calls exactly one
    # evaluator; if it declines -- returns its own :not_* sentinel -- we fall
    # through to the full cascade and re-record. A wrong cache entry therefore
    # costs one wasted call, never a wrong render.
    def eval_expr(expr, context)
      expr = expr.strip
      return nil if expr.empty?

      form = (@expr_form ||= {})[expr]
      if form
        result = eval_expr_as(form, expr, context)
        return result unless result == :form_declined
      end

      result = eval_literal(expr)
      return remember_form(expr, :literal, result) unless result == :not_literal

      result = eval_collection_literal(expr, context)
      return remember_form(expr, :collection, result) unless result == :not_collection

      if matched_parens?(expr)
        remember_form(expr, :parens, nil)
        return eval_expr(expr[1..-2], context)
      end

      result = eval_ternary(expr, context)
      return remember_form(expr, :ternary, result) unless result == :not_ternary

      result = eval_inline_if(expr, context)
      return remember_form(expr, :inline_if, result) unless result == :not_inline_if

      result = eval_null_coalesce(expr, context)
      return remember_form(expr, :coalesce, result) unless result == :not_coalesce

      result = eval_concat(expr, context)
      return remember_form(expr, :concat, result) unless result == :not_concat

      if has_comparison?(expr)
        remember_form(expr, :comparison, nil)
        return eval_comparison(expr, context)
      end

      result = eval_arithmetic(expr, context)
      return remember_form(expr, :arithmetic, result) unless result == :not_arithmetic

      result = eval_filter_pipe(expr, context)
      return remember_form(expr, :pipe, result) unless result == :not_filter_pipe

      result = eval_function_call(expr, context)
      return remember_form(expr, :function, result) unless result == :not_function

      remember_form(expr, :resolve, nil)
      resolve(expr, context)
    end

    # Record the branch an expression took, then hand back its value unchanged.
    def remember_form(expr, form, result)
      cache = (@expr_form ||= {})
      if cache.length >= EXPR_FORM_CACHE_MAX
        cache.keys.first(EXPR_FORM_CACHE_MAX / 2).each { |k| cache.delete(k) }
      end
      cache[expr] = form
      result
    end

    # Evaluate via the one remembered branch. Returns :form_declined when that
    # branch no longer applies, so the caller re-runs the full cascade.
    def eval_expr_as(form, expr, context)
      case form
      when :resolve     then resolve(expr, context)
      when :pipe        then (r = eval_filter_pipe(expr, context)) == :not_filter_pipe ? :form_declined : r
      when :literal     then (r = eval_literal(expr)) == :not_literal ? :form_declined : r
      when :function    then (r = eval_function_call(expr, context)) == :not_function ? :form_declined : r
      when :concat      then (r = eval_concat(expr, context)) == :not_concat ? :form_declined : r
      when :comparison  then has_comparison?(expr) ? eval_comparison(expr, context) : :form_declined
      when :arithmetic  then (r = eval_arithmetic(expr, context)) == :not_arithmetic ? :form_declined : r
      when :ternary     then (r = eval_ternary(expr, context)) == :not_ternary ? :form_declined : r
      when :inline_if   then (r = eval_inline_if(expr, context)) == :not_inline_if ? :form_declined : r
      when :coalesce    then (r = eval_null_coalesce(expr, context)) == :not_coalesce ? :form_declined : r
      when :collection  then (r = eval_collection_literal(expr, context)) == :not_collection ? :form_declined : r
      when :parens      then matched_parens?(expr) ? eval_expr(expr[1..-2], context) : :form_declined
      else :form_declined
      end
    end

    # ── Filter pipe: value|filter(args) ──
    # Reached only after every looser-binding operator (concat ~, comparison,
    # arithmetic, ternary, ...) has been ruled out at this level, so the pipe
    # binds tighter than all of them — matching Twig. This is what makes
    # `amount|number_format(2) ~ ' EUR'` resolve as `(amount|number_format(2))
    # ~ ' EUR'`, and it lets a pipe inside parens / a sub-expression resolve
    # (previously such a pipe fell through to `resolve` and returned empty).
    # Delegates to eval_var_raw, which applies the filter chain WITHOUT output
    # escaping (escaping happens once, at the output layer, on the final value).
    def eval_filter_pipe(expr, context)
      return :not_filter_pipe unless find_outside_quotes(expr, "|") >= 0

      eval_var_raw(expr, context)
    end

    # True when the expression carries a top-level operator that Twig binds
    # looser than the filter pipe. Quote/paren-aware via find_outside_quotes so
    # operator-like text inside a string literal or filter args never matches.
    def has_looser_than_pipe_operator?(expr)
      # Leading unary `not` -- see has_comparison? for why a space-delimited
      # match cannot see it. `not x|upper` must be `not (x|upper)`.
      return true if expr.start_with?("not ")

      LOOSER_THAN_PIPE_OPS.any? { |op| find_outside_quotes(expr, op) >= 0 }
    end

    # ── Literal values: strings, numbers, booleans, null ──

    def eval_literal(expr)
      if expr.length >= 2 && (expr[0] == '"' || expr[0] == "'") && expr[-1] == expr[0]
        # Only a SINGLE complete string literal — i.e. the opening quote's
        # match is the final char. Without this check, `'a' ~ 'b'` and
        # `'Y' if x else 'N'` (which merely start and end with a quote) get
        # their outer quotes stripped here before concat / inline-if run.
        q = expr[0]
        i = 1
        single = false
        while i < expr.length
          if expr[i] == "\\"
            i += 2
            next
          end
          if expr[i] == q
            single = (i == expr.length - 1)
            break
          end
          i += 1
        end
        return expr[1..-2] if single
      end
      return expr.to_i if expr =~ INTEGER_RE
      return expr.to_f if expr =~ FLOAT_RE
      return true  if expr == "true"
      return false if expr == "false"
      return nil   if expr == "null" || expr == "none" || expr == "nil"
      :not_literal
    end

    # ── Collection literals: arrays, hashes, ranges ──

    def eval_collection_literal(expr, context)
      if expr =~ ARRAY_LIT_RE
        inner = Regexp.last_match(1)
        return split_args_toplevel(inner).map { |item| eval_expr(item.strip, context) }
      end
      if expr =~ HASH_LIT_RE
        inner = Regexp.last_match(1)
        hash = {}
        split_args_toplevel(inner).each do |pair|
          if pair =~ HASH_PAIR_RE
            key = Regexp.last_match(1) || Regexp.last_match(2)
            hash[key] = eval_expr(Regexp.last_match(3).strip, context)
          end
        end
        return hash
      end
      if expr =~ RANGE_LIT_RE
        return (Regexp.last_match(1).to_i..Regexp.last_match(2).to_i).to_a
      end
      :not_collection
    end

    # ── Parenthesized sub-expression check ──

    def matched_parens?(expr)
      return false unless expr.start_with?("(") && expr.end_with?(")")
      depth = 0
      expr.each_char.with_index do |ch, pi|
        depth += 1 if ch == "("
        depth -= 1 if ch == ")"
        return false if depth == 0 && pi < expr.length - 1
      end
      true
    end

    # ── Ternary: condition ? "yes" : "no" ──

    def eval_ternary(expr, context)
      q_pos = find_outside_quotes(expr, "?")
      return :not_ternary unless q_pos && q_pos > 0
      cond_part = expr[0...q_pos].strip
      rest = expr[(q_pos + 1)..]
      c_pos = find_outside_quotes(rest, ":")
      return :not_ternary unless c_pos && c_pos >= 0
      true_part = rest[0...c_pos].strip
      false_part = rest[(c_pos + 1)..].strip
      cond = eval_expr(cond_part, context)
      truthy?(cond) ? eval_expr(true_part, context) : eval_expr(false_part, context)
    end

    # ── Inline if: value if condition else other_value ──

    def eval_inline_if(expr, context)
      if_pos = find_outside_quotes(expr, " if ")
      return :not_inline_if unless if_pos && if_pos >= 0
      else_pos = find_outside_quotes(expr, " else ")
      return :not_inline_if unless else_pos && else_pos > if_pos
      value_part = expr[0...if_pos].strip
      cond_part = expr[(if_pos + 4)...else_pos].strip
      else_part = expr[(else_pos + 6)..].strip
      cond = eval_expr(cond_part, context)
      truthy?(cond) ? eval_expr(value_part, context) : eval_expr(else_part, context)
    end

    # ── Null coalescing: value ?? "default" ──

    def eval_null_coalesce(expr, context)
      return :not_coalesce unless expr.include?("??")
      left, _, right = expr.partition("??")
      val = eval_expr(left.strip, context)
      val.nil? ? eval_expr(right.strip, context) : val
    end

    # ── String concatenation: a ~ b ──

    def eval_concat(expr, context)
      return :not_concat unless expr.include?("~")
      parts = expr.split("~")
      # `|| ""` would swallow a legitimate `false`: in Ruby only nil and false are
      # falsy, so `false || ""` is "" and a boolean rendered as EMPTY. Guard on nil
      # only -- false must render as "false", matching the other three frameworks
      # (and line 635, which already got this right, which is why a comparison
      # rendered "false" while a bare false variable rendered "").
      parts.map { |p| v = eval_expr(p.strip, context); v.nil? ? "" : v.to_s }.join
    end

    # ── Arithmetic: +, -, *, //, /, %, ** ──

    def eval_arithmetic(expr, context)
      ARITHMETIC_OPS.each do |op|
        pos = find_outside_quotes(expr, op)
        next unless pos && pos >= 0
        l_val = eval_expr(expr[0...pos].strip, context)
        r_val = eval_expr(expr[(pos + op.length)..].strip, context)
        return apply_math(l_val, op.strip, r_val)
      end
      :not_arithmetic
    end

    # ── Function call: name(arg1, arg2) ──

    def eval_function_call(expr, context)
      return :not_function unless expr =~ FUNC_CALL_RE
      fn_name = Regexp.last_match(1)
      raw_args = Regexp.last_match(2).strip
      fn = context[fn_name]
      return :not_function unless fn.respond_to?(:call)
      args = raw_args.empty? ? [] : split_args_toplevel(raw_args).map { |a| eval_expr(a.strip, context) }
      fn.call(*args)
    end

    # True when the expression carries a comparison/logical operator, so it is
    # routed to eval_comparison -- the SAME evaluator {% if %} uses. A condition
    # therefore means the same thing in a condition and in an output expression.
    #
    # The LEADING unary `not` needs its own check: every operator in the list is
    # matched WITH surrounding spaces, so `not x` (nothing to its left) matched
    # none of them and fell through to the variable-resolution tail, which
    # looked up a variable literally named "not x", found nothing, and rendered
    # EMPTY. `{% if not x %}` and `x and not y` always worked; only the
    # standalone `{{ not x }}` was dropped, and before booleans rendered
    # lowercase a dropped expression and `false -> ''` looked identical.
    # Fixed in 3.13.87 alongside the boolean contract.
    def has_comparison?(expr)
      return true if expr.start_with?("not ")

      [" not in ", " in ", " is not ", " is ", "!=", "==", ">=", "<=", ">", "<",
       " and ", " or ", " not "].any? { |op| expr.include?(op) }
    end

    # Split comma-separated args at top level (not inside quotes/parens/brackets).
    def split_args_toplevel(str)
      parts = []
      current = +""
      in_quote = nil
      depth = 0

      str.each_char do |ch|
        if in_quote
          current << ch
          in_quote = nil if ch == in_quote
        elsif ch == '"' || ch == "'"
          in_quote = ch
          current << ch
        elsif ch == "(" || ch == "[" || ch == "{"
          depth += 1
          current << ch
        elsif ch == ")" || ch == "]" || ch == "}"
          depth -= 1
          current << ch
        elsif ch == "," && depth == 0
          parts << current.strip
          current = +""
        else
          current << ch
        end
      end
      parts << current.strip unless current.strip.empty?
      parts
    end

    # -----------------------------------------------------------------------
    # Comparison / logical evaluator
    # -----------------------------------------------------------------------

    def eval_comparison(expr, context, eval_fn = nil)
      eval_fn ||= method(:eval_expr)
      expr = expr.strip

      # Handle 'not' prefix
      if expr.start_with?("not ")
        return !eval_comparison(expr[4..], context, eval_fn)
      end

      # 'or' (lowest precedence)
      or_parts = expr.split(OR_SPLIT_RE)
      if or_parts.length > 1
        return or_parts.any? { |p| eval_comparison(p, context, eval_fn) }
      end

      # 'and'
      and_parts = expr.split(AND_SPLIT_RE)
      if and_parts.length > 1
        return and_parts.all? { |p| eval_comparison(p, context, eval_fn) }
      end

      # 'is not' test
      if expr =~ IS_NOT_RE
        return !eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                          Regexp.last_match(3).strip, context, eval_fn)
      end

      # 'is' test
      if expr =~ IS_RE
        return eval_test(Regexp.last_match(1).strip, Regexp.last_match(2),
                         Regexp.last_match(3).strip, context, eval_fn)
      end

      # 'not in'
      if expr =~ NOT_IN_RE
        val = eval_fn.call(Regexp.last_match(1).strip, context)
        collection = eval_fn.call(Regexp.last_match(2).strip, context)
        return !(collection.respond_to?(:include?) && collection.include?(val))
      end

      # 'in'
      if expr =~ IN_RE
        val = eval_fn.call(Regexp.last_match(1).strip, context)
        collection = eval_fn.call(Regexp.last_match(2).strip, context)
        return collection.respond_to?(:include?) ? collection.include?(val) : false
      end

      # Binary comparison operators
      [["!=", ->(a, b) { a != b }],
       ["==", ->(a, b) { a == b }],
       [">=", ->(a, b) { a.to_f >= b.to_f }],
       ["<=", ->(a, b) { a.to_f <= b.to_f }],
       [">",  ->(a, b) { a.to_f > b.to_f }],
       ["<",  ->(a, b) { a.to_f < b.to_f }]].each do |op, fn|
        if expr.include?(op)
          left, _, right = expr.partition(op)
          l = eval_fn.call(left.strip, context)
          r = eval_fn.call(right.strip, context)
          begin
            return fn.call(l, r)
          rescue
            return false
          end
        end
      end

      # Fall through to simple eval
      val = eval_fn.call(expr, context)
      truthy?(val)
    end

    # -----------------------------------------------------------------------
    # Tests ('is' expressions)
    # -----------------------------------------------------------------------

    def eval_test(value_expr, test_name, args_str, context, eval_fn = nil)
      eval_fn ||= method(:eval_expr)
      val = eval_fn.call(value_expr, context)

      # 'divisible by(n)'
      if test_name == "divisible"
        if args_str =~ DIVISIBLE_BY_RE
          n = Regexp.last_match(1).to_i
          return val.is_a?(Integer) && (val % n).zero?
        end
        return false
      end

      # Check custom tests first
      custom = @tests[test_name]
      return custom.call(val) if custom

      false
    end

    def default_tests
      {
        "defined"  => ->(v) { !v.nil? },
        "empty"    => ->(v) { v.nil? || (v.respond_to?(:empty?) && v.empty?) || v == 0 || v == false },
        "null"     => ->(v) { v.nil? },
        "none"     => ->(v) { v.nil? },
        "even"     => ->(v) { v.is_a?(Integer) && v.even? },
        "odd"      => ->(v) { v.is_a?(Integer) && v.odd? },
        "iterable" => ->(v) { v.respond_to?(:each) && !v.is_a?(String) },
        "string"   => ->(v) { v.is_a?(String) },
        "number"   => ->(v) { v.is_a?(Numeric) },
        "boolean"  => ->(v) { v.is_a?(TrueClass) || v.is_a?(FalseClass) },
      }
    end

    # -----------------------------------------------------------------------
    # Variable resolver
    # -----------------------------------------------------------------------

    def resolve(expr, context)
      parts = @resolve_cache[expr]
      unless parts
        parts = expr.split(RESOLVE_SPLIT_RE).reject(&:empty?)
        @resolve_cache[expr] = parts
      end

      value = context

      parts.each do |part|
        part = part.strip.gsub(RESOLVE_STRIP_RE, "") # strip quotes from bracket access
        if value.is_a?(Hash) || value.is_a?(LoopContext)
          # `a[k] || a[k.to_sym]` LOSES a stored `false`: only nil and false are
          # falsy in Ruby, so a legitimate false fell through to the symbol lookup,
          # missed, and became nil -- rendering as EMPTY. That is why
          # `{{ flag }}` printed nothing while `{{ n < 3 }}` printed "false".
          # Probe the string key by presence, not truthiness.
          value = if value.is_a?(Hash) && value.key?(part)
                    value[part]
                  elsif value.is_a?(Hash) && value.key?(part.to_sym)
                    value[part.to_sym]
                  else
                    sv = value[part]
                    sv.nil? ? value[part.to_sym] : sv
                  end
        elsif value.is_a?(Array)
          # Slice syntax: value[1:5], value[:10], value[start:end]
          if part.include?(":") && !(part.start_with?('"') || part.start_with?("'"))
            slice_parts = part.split(":", 2)
            s_start = slice_parts[0].strip.empty? ? nil : eval_expr(slice_parts[0].strip, context).to_i
            s_end = slice_parts[1].strip.empty? ? nil : eval_expr(slice_parts[1].strip, context).to_i
            if s_start && s_end
              value = value[s_start...s_end]
            elsif s_start
              value = value[s_start..]
            elsif s_end
              value = value[0...s_end]
            else
              value = value.dup
            end
            next
          end
          idx = if part =~ DIGIT_RE
                  part.to_i
                else
                  eval_expr(part, context)
                end
          idx = idx.to_i if idx.is_a?(Numeric)
          value = idx.is_a?(Integer) ? value[idx] : nil
        elsif value.respond_to?(part.to_sym)
          value = value.send(part.to_sym)
        else
          return nil
        end
        return nil if value.nil?
      end

      value
    end

    # -----------------------------------------------------------------------
    # Math
    # -----------------------------------------------------------------------

    def apply_math(left, op, right)
      l = (left || 0).to_f
      r = (right || 0).to_f
      # Preserve int type when both operands are int-like (except for / which returns float)
      both_int = l == l.to_i && r == r.to_i && op != "/"
      result = case op
               when "+"  then l + r
               when "-"  then l - r
               when "*"  then l * r
               when "/"  then r != 0 ? l / r : 0
               when "//" then r != 0 ? (l / r).floor : 0
               when "%"  then r != 0 ? l % r : 0
               when "**" then l ** r
               else 0
               end
      both_int && result == result.to_i ? result.to_i : result.to_f == result.to_i ? result.to_i : result
    end

    # -----------------------------------------------------------------------
    # Block handlers
    # -----------------------------------------------------------------------

    # {% if %}...{% elseif %}...{% else %}...{% endif %}
    def handle_if(tokens, start, context)
      content, _, strip_a_open = strip_tag(tokens[start][1])
      condition_expr = content.sub(/\Aif\s+/, "").strip

      branches = []
      current_tokens = []
      current_cond = condition_expr
      depth = 0
      i = start + 1

      # If the opening {%- if -%} has strip_after, lstrip the first body text
      pending_lstrip = strip_a_open

      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, strip_b_tag, strip_a_tag = strip_tag(raw)
          tag = tag_content.split[0] || ""

          if tag == "if"
            depth += 1
            current_tokens << tokens[i]
          elsif tag == "endif" && depth > 0
            depth -= 1
            current_tokens << tokens[i]
          elsif tag == "endif" && depth == 0
            # Apply strip_before from endif to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            i += 1
            break
          elsif (tag == "elseif" || tag == "elif") && depth == 0
            # Apply strip_before from elseif to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            current_cond = tag_content.sub(/\A(?:elseif|elif)\s+/, "").strip
            current_tokens = []
            pending_lstrip = strip_a_tag
          elsif tag == "else" && depth == 0
            # Apply strip_before from else to last body token
            if strip_b_tag && !current_tokens.empty? && current_tokens[-1][0] == TEXT
              current_tokens[-1] = [TEXT, current_tokens[-1][1].rstrip]
            end
            branches << [current_cond, current_tokens]
            current_cond = nil
            current_tokens = []
            pending_lstrip = strip_a_tag
          else
            current_tokens << tokens[i]
          end
        else
          tok = tokens[i]
          if pending_lstrip && ttype == TEXT
            tok = [TEXT, tok[1].lstrip]
            pending_lstrip = false
          end
          current_tokens << tok
        end
        i += 1
      end

      branches.each do |cond, branch_tokens|
        if cond.nil? || eval_comparison(cond, context, method(:eval_var_raw))
          return [render_tokens(branch_tokens.dup, context), i]
        end
      end

      ["", i]
    end

    # {% for item in items %}...{% else %}...{% endfor %}
    def handle_for(tokens, start, context)
      content, _, strip_a_open = strip_tag(tokens[start][1])
      m = content.match(FOR_RE)
      return ["", start + 1] unless m

      var1 = m[1]
      var2 = m[2]
      iterable_expr = m[3].strip

      body_tokens = []
      else_tokens = []
      in_else = false
      for_depth = 0
      if_depth = 0
      i = start + 1
      pending_lstrip = strip_a_open

      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, strip_b_tag, strip_a_tag = strip_tag(raw)
          tag = tag_content.split[0] || ""

          if tag == "for"
            for_depth += 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endfor" && for_depth > 0
            for_depth -= 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endfor" && for_depth == 0
            target = in_else ? else_tokens : body_tokens
            if strip_b_tag && !target.empty? && target[-1][0] == TEXT
              target[-1] = [TEXT, target[-1][1].rstrip]
            end
            i += 1
            break
          elsif tag == "if"
            if_depth += 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "endif"
            if_depth -= 1
            (in_else ? else_tokens : body_tokens) << tokens[i]
          elsif tag == "else" && for_depth == 0 && if_depth == 0
            if strip_b_tag && !body_tokens.empty? && body_tokens[-1][0] == TEXT
              body_tokens[-1] = [TEXT, body_tokens[-1][1].rstrip]
            end
            in_else = true
            pending_lstrip = strip_a_tag
          else
            (in_else ? else_tokens : body_tokens) << tokens[i]
          end
        else
          tok = tokens[i]
          if pending_lstrip && ttype == TEXT
            tok = [TEXT, tok[1].lstrip]
            pending_lstrip = false
          end
          (in_else ? else_tokens : body_tokens) << tok
        end
        i += 1
      end

      iterable = eval_expr(iterable_expr, context)

      if iterable.nil? || (iterable.respond_to?(:empty?) && iterable.empty?)
        if else_tokens.any?
          return [render_tokens(else_tokens.dup, context), i]
        end
        return ["", i]
      end

      output = []
      items = iterable.is_a?(Hash) ? iterable.to_a : Array(iterable)
      total = items.length

      items.each_with_index do |item, idx|
        loop_ctx = LoopContext.new(context)
        loop_ctx["loop"] = {
          "index"     => idx + 1,
          "index0"    => idx,
          "first"     => idx == 0,
          "last"      => idx == total - 1,
          "length"    => total,
          "revindex"  => total - idx,
          "revindex0" => total - idx - 1,
          "even"      => ((idx + 1) % 2).zero?,
          "odd"       => ((idx + 1) % 2) != 0,
        }

        if iterable.is_a?(Hash)
          key, value = item
          if var2
            loop_ctx[var1] = key
            loop_ctx[var2] = value
          else
            loop_ctx[var1] = key
          end
        else
          if var2
            loop_ctx[var1] = idx
            loop_ctx[var2] = item
          else
            loop_ctx[var1] = item
          end
        end

        output << render_tokens(body_tokens.dup, loop_ctx)
      end

      [output.join, i]
    end

    # {% set name = expr %}
    def handle_set(content, context)
      if content =~ SET_RE
        name = Regexp.last_match(1)
        expr = Regexp.last_match(2).strip
        context[name] = eval_var_raw(expr, context)
      end
    end

    # {% include "file.html" %}
    def handle_include(content, context)
      ignore_missing = content.include?("ignore missing")
      content = content.gsub("ignore missing", "").strip

      m = content.match(INCLUDE_RE)
      return "" unless m

      filename = m[1]
      with_expr = m[2]

      begin
        source = load_template(filename)
      rescue
        return "" if ignore_missing
        raise
      end

      inc_context = context.dup
      if with_expr
        extra = eval_expr(with_expr, context)
        inc_context.merge!(stringify_keys(extra)) if extra.is_a?(Hash)
      end

      execute(source, inc_context)
    end

    # {% macro name(args) %}...{% endmacro %}
    def handle_macro(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = content.match(MACRO_RE)
      unless m
        i = start + 1
        while i < tokens.length
          if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
            return i + 1
          end
          i += 1
        end
        return i
      end

      macro_name = m[1]
      params = parse_macro_params(m[2])

      body_tokens = []
      i = start + 1
      while i < tokens.length
        if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
          i += 1
          break
        end
        body_tokens << tokens[i]
        i += 1
      end

      engine = self
      captured_body = body_tokens.dup
      captured_context = context

      context[macro_name] = lambda { |*args|
        macro_ctx = captured_context.dup
        params.each_with_index do |(pname, pdefault), pi|
          macro_ctx[pname] = pi < args.length ? args[pi] : pdefault
        end
        Tina4::SafeString.new(engine.send(:render_tokens, captured_body.dup, macro_ctx))
      }

      i
    end

    # {% import "file" as alias %} — load EVERY macro in a file under one namespace.
    #
    # Macros are registered in the context under the dotted key "alias.name", so
    # {{ alias.greet("Andre") }} resolves through the ordinary function-call path
    # (FUNC_CALL_RE now admits a dot) and reuses _make_macro_fn — identical argument
    # binding, default handling and SafeString output as every other macro. Both
    # import forms therefore render identically, the contract Python locks too.
    def handle_import_as(content, context)
      m = content.match(IMPORT_AS_RE)
      return unless m

      filename = m[1]
      alias_name = m[2]
      source = load_template(filename)
      tokens = tokenize(source)

      i = 0
      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, = strip_tag(raw)
          if tag_content.split(/\s+/).first == "macro"
            macro_m = tag_content.match(MACRO_RE)
            if macro_m
              macro_name = macro_m[1]
              params = parse_macro_params(macro_m[2])

              body_tokens = []
              i += 1
              while i < tokens.length
                if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
                  i += 1
                  break
                end
                body_tokens << tokens[i]
                i += 1
              end

              context["#{alias_name}.#{macro_name}"] =
                _make_macro_fn(body_tokens.dup, params.dup, context.dup)
              next
            end
          end
        end
        i += 1
      end
    end

    # {% from "file" import macro1, macro2 %}
    def handle_from_import(content, context)
      m = content.match(FROM_IMPORT_RE)
      return unless m

      filename = m[1]
      names = m[2].split(",").map(&:strip).reject(&:empty?)

      source = load_template(filename)
      tokens = tokenize(source)

      i = 0
      while i < tokens.length
        ttype, raw = tokens[i]
        if ttype == BLOCK
          tag_content, _, _ = strip_tag(raw)
          tag = (tag_content.split[0] || "")
          if tag == "macro"
            macro_m = tag_content.match(MACRO_RE)
            if macro_m && names.include?(macro_m[1])
              macro_name = macro_m[1]
              param_names = parse_macro_params(macro_m[2])

              body_tokens = []
              i += 1
              while i < tokens.length
                if tokens[i][0] == BLOCK && tokens[i][1].include?("endmacro")
                  i += 1
                  break
                end
                body_tokens << tokens[i]
                i += 1
              end

              context[macro_name] = _make_macro_fn(body_tokens.dup, param_names.dup, context.dup)
              next
            end
          end
        end
        i += 1
      end
    end

    # Parse a macro parameter list into [name, default] pairs.
    #
    # Handles: name, name="default", name='default'. Splitting on "," alone left
    # a defaulted parameter NAMED "greeting='Hello'", so the body's {{ greeting }}
    # matched nothing (rendered empty) AND the caller's positional argument was
    # stored under that junk key and lost. Mirrors the Python master's
    # _parse_macro_params. `default` is nil when none is declared.
    def parse_macro_params(raw_params)
      raw_params.split(",").map(&:strip).reject(&:empty?).map do |p|
        name, default = p.split("=", 2)
        default = default.strip if default
        if default && default.length >= 2 &&
           ((default.start_with?('"') && default.end_with?('"')) ||
            (default.start_with?("'") && default.end_with?("'")))
          default = default[1..-2]
        end
        [name.strip, default]
      end
    end

    # Build an isolated lambda for a macro — avoids closure-in-loop variable sharing.
    # `params` is the [name, default] list from parse_macro_params.
    def _make_macro_fn(body_tokens, params, ctx)
      engine = self
      lambda { |*args|
        macro_ctx = ctx.dup
        params.each_with_index do |(pname, pdefault), pi|
          macro_ctx[pname] = pi < args.length ? args[pi] : pdefault
        end
        Tina4::SafeString.new(engine.send(:render_tokens, body_tokens.dup, macro_ctx))
      }
    end

    # {% cache "key" ttl %}...{% endcache %}
    def handle_cache(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = content.match(CACHE_RE)
      cache_key = m ? m[1] : "default"
      ttl = m && m[2] ? m[2].to_i : 60

      # Check cache
      cached = @fragment_cache[cache_key]
      if cached
        html_content, expires_at = cached
        if Time.now.to_f < expires_at
          # Skip to endcache
          i = start + 1
          depth = 0
          while i < tokens.length
            if tokens[i][0] == BLOCK
              tc, _, _ = strip_tag(tokens[i][1])
              tag = tc.split[0] || ""
              if tag == "cache"
                depth += 1
              elsif tag == "endcache"
                return [html_content, i + 1] if depth == 0
                depth -= 1
              end
            end
            i += 1
          end
          return [html_content, i]
        end
      end

      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "cache"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endcache"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      rendered = render_tokens(body_tokens.dup, context)
      @fragment_cache[cache_key] = [rendered, Time.now.to_f + ttl]
      [rendered, i]
    end

    # Handle {% live "name" poll N | sse | ws "path" [src "url"] %}...{% endlive %}.
    #
    # Server-rendered live region. The body renders once for first paint, is
    # registered under <name> so the /__frond/live/<name> endpoint (or a
    # live_source provider) can re-render it, and is wrapped in a marker element
    # that frond.js wires to the chosen transport (poll / sse / ws). Mirrors the
    # Python master's _handle_live and PHP's handleLive.
    def handle_live(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      m = LIVE_RE.match(content)
      raise 'live: expected {% live "name" poll N | sse | ws "path" %}' unless m

      name = m[1]
      rest = (m[2] || "").strip
      parts = rest.split
      mode = parts[0] || ""

      src = nil
      if (sm = LIVE_SRC_RE.match(rest))
        src = sm[1]
      end
      if src && (src.start_with?("http://") || src.start_with?("https://") || src.start_with?("//"))
        raise "live: src must be a same-origin path, not an absolute URL"
      end

      interval = nil
      ws_path  = nil
      case mode
      when "poll"
        raise 'live: poll requires seconds, e.g. {% live "x" poll 5 %}' unless parts[1]&.match?(/\A\d+\z/)
        interval = parts[1].to_i
      when "sse"
        # no extra config
      when "ws"
        wm = LIVE_WS_RE.match(rest)
        raise 'live: ws requires a path, e.g. {% live "x" ws "/ws/x" %}' unless wm
        ws_path = wm[1]
      else
        raise %(live: unknown transport "#{mode}" (use poll N, sse, or ws "path"))
      end

      # Collect body tokens up to {% endlive %}. Nested live is unsupported.
      body_tokens = []
      i = start + 1
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          raise "live: nested live blocks are not supported" if tag == "live"
          if tag == "endlive"
            i += 1
            break
          end
          body_tokens << tokens[i]
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      # Register the raw body source so the auto endpoint can re-render it.
      @@class_live_fragments[name] = body_tokens.map { |t| t[1] }.join

      endpoint = src || ("/__frond/live/" + name)
      attrs = [%(data-frond-live="#{Frond.live_attr(name)}"), %(id="live-#{Frond.live_attr(name)}")]
      case mode
      when "poll"
        attrs << 'data-mode="poll"' << %(data-interval="#{interval}") << %(data-src="#{Frond.live_attr(endpoint)}")
      when "sse"
        attrs << 'data-mode="sse"' << %(data-src="#{Frond.live_attr(endpoint)}")
      when "ws"
        @@class_live_ws_paths[name] = ws_path
        attrs << 'data-mode="ws"' << %(data-ws="#{Frond.live_attr(ws_path)}")
      end

      first_paint = render_tokens(body_tokens.dup, context)
      [%(<div #{attrs.join(' ')}>#{first_paint}</div>), i]
    end

    # -- Live-block class API (mirrors Python master + PHP static facade) -----

    # Re-render a registered {% live %} fragment by name with fresh data.
    # Returns the rendered HTML, or nil if no fragment is registered under that
    # name yet (its page has not rendered). The /__frond/live/<name> endpoint
    # calls this after resolving the provider data.
    def self.render_live(name, data = {})
      source = @@class_live_fragments[name]
      return nil if source.nil?

      new.render_string(source, data || {})
    end

    # Register a data provider for a {% live %} block. Accepts a block OR a
    # callable (proc/lambda); it is invoked with the live request on every
    # refresh so auth re-applies (IDOR guard). Mirrors Python's @live_source.
    def self.live_source(name, callable = nil, &blk)
      @@class_live_sources[name] = callable || blk
    end

    # The provider registered for a live block, or nil.
    def self.get_live_source(name)
      @@class_live_sources[name]
    end

    # Whether a live fragment has been registered (its page rendered).
    def self.has_live_fragment?(name)
      @@class_live_fragments.key?(name)
    end

    # The ws path a live block declared (data-ws), or nil.
    def self.get_live_ws_path(name)
      @@class_live_ws_paths[name]
    end

    # Handle GET /__frond/live/{name}: resolve the provider, run it with the
    # live request (auth re-applies), re-render the fragment, return via the
    # response callable. 404 for unknown name / unrendered fragment. Mirrors
    # Python's live_endpoint and PHP's respondLive.
    def self.respond_live(request, response, name)
      provider = @@class_live_sources[name]
      if !@@class_live_fragments.key?(name) && provider.nil?
        return response.call("live block not found: #{name}", 404)
      end

      context = {}
      unless provider.nil?
        result = provider.call(request)
        context = result.is_a?(Hash) ? result : {}
      end

      html = render_live(name, context)
      return response.call("live fragment not registered yet: #{name}", 404) if html.nil?

      response.call(html)
    end

    # Re-render the '<name>' live fragment and push it to connected clients.
    # Broadcasts a {type,name,html} envelope over WebSocket to the block's
    # declared data-ws path (else a room named <name>). Returns the rendered
    # HTML, or nil if the fragment is not registered. Mirrors Python push_live
    # / PHP pushLive. The broadcast is best-effort — a missing/failed WS engine
    # never raises into the caller.
    def self.push_live(name, data = {})
      html = render_live(name, data)
      return nil if html.nil?

      envelope = { "type" => "live", "name" => name, "html" => html }.to_json
      engine = (Tina4::WebSocket.current if defined?(Tina4::WebSocket))
      if engine
        begin
          ws_path = get_live_ws_path(name)
          if ws_path
            engine.broadcast(envelope, path: ws_path)
          else
            engine.broadcast_to_room(name, envelope)
          end
        rescue StandardError => e
          Tina4::Log.error("push_live(#{name}) broadcast failed: #{e.message}") if defined?(Tina4::Log)
        end
      end
      html
    end

    # Register the always-on GET /__frond/live/{name} endpoint that re-renders
    # a live block on demand. Idempotent — guarded against a re-register after a
    # Router.clear! (specs / hot-reload rescans). Mirrors PHP App::registerLiveEndpoint.
    def self.register_live_endpoint!
      return if Tina4::Router.find_route("GET", "/__frond/live/live-probe")

      Tina4::Router.add(
        "GET", "/__frond/live/{name}",
        lambda { |request, response, name| Tina4::Frond.respond_live(request, response, name) }
      )
    end

    # {% set name %}...{% endset %} -- render the body and bind it.
    #
    # Emits nothing itself. The captured value is a SafeString because it is
    # template output that has already been escaped on the way in; re-escaping it
    # at {{ name }} would double-encode every entity. Twig and Jinja2 both mark
    # the capture safe. Returns the index just past {% endset %}.
    def handle_set_block(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      name = (content.split[1] || "").strip

      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "set" && !tc.include?("=")
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endset"
            if depth.zero?
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      unless name.empty?
        context[name] = Tina4::SafeString.new(render_tokens(body_tokens.dup, context))
      end
      i
    end

    def handle_spaceless(tokens, start, context)
      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "spaceless"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endspaceless"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      rendered = render_tokens(body_tokens.dup, context)
      rendered = rendered.gsub(SPACELESS_RE, "><")
      [rendered, i]
    end

    def handle_autoescape(tokens, start, context)
      content, _, _ = strip_tag(tokens[start][1])
      mode_match = content.match(AUTOESCAPE_RE)
      auto_escape_on = !(mode_match && mode_match[1] == "false")

      body_tokens = []
      i = start + 1
      depth = 0
      while i < tokens.length
        if tokens[i][0] == BLOCK
          tc, _, _ = strip_tag(tokens[i][1])
          tag = tc.split[0] || ""
          if tag == "autoescape"
            depth += 1
            body_tokens << tokens[i]
          elsif tag == "endautoescape"
            if depth == 0
              i += 1
              break
            end
            depth -= 1
            body_tokens << tokens[i]
          else
            body_tokens << tokens[i]
          end
        else
          body_tokens << tokens[i]
        end
        i += 1
      end

      if !auto_escape_on
        old_auto_escape = @auto_escape
        @auto_escape = false
        rendered = render_tokens(body_tokens.dup, context)
        @auto_escape = old_auto_escape
      else
        rendered = render_tokens(body_tokens.dup, context)
      end

      [rendered, i]
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def truthy?(val)
      return false if val.nil? || val == false || val == 0 || val == ""
      return false if val.respond_to?(:empty?) && val.empty?
      true
    end

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    # -----------------------------------------------------------------------
    # Built-in filters (53 total)
    # -----------------------------------------------------------------------

    def default_filters
      {
        # -- Text --
        "upper"      => ->(v, *_a) { v.to_s.upcase },
        "lower"      => ->(v, *_a) { v.to_s.downcase },
        "capitalize" => ->(v, *_a) { v.to_s.capitalize },
        "title"      => ->(v, *_a) { v.to_s.split.map(&:capitalize).join(" ") },
        "trim"       => ->(v, *_a) { v.to_s.strip },
        "ltrim"      => ->(v, *_a) { v.to_s.lstrip },
        "rtrim"      => ->(v, *_a) { v.to_s.rstrip },
        "replace"    => ->(v, *a) {
          if a.length == 1 && a[0].is_a?(Hash)
            result = v.to_s
            a[0].each { |old, new_val| result = result.gsub(old.to_s, new_val.to_s) }
            result
          elsif a.length >= 2
            v.to_s.gsub(a[0].to_s, a[1].to_s)
          else
            v.to_s
          end
        },
        "striptags"  => ->(v, *_a) { v.to_s.gsub(STRIPTAGS_RE, "") },

        # -- Encoding --
        "escape"        => ->(v, *_a) { Tina4::SafeString.new(Frond.escape_html(v.to_s)) },
        "e"             => ->(v, *_a) { Tina4::SafeString.new(Frond.escape_html(v.to_s)) },
        "raw"           => ->(v, *_a) { v },
        "safe"          => ->(v, *_a) { v },
        # Frond.json_safe, never a bare JSON.generate: generate RAISES on an
        # Infinity/NaN float, and the old `rescue v.to_s` answered that raise with
        # Ruby inspect output that no JSON.parse will read. See Frond.json_safe.
        "json_encode"   => ->(v, *_a) { Frond.json_safe(v) },
        "json_decode"   => ->(v, *_a) { v.is_a?(String) ? (JSON.parse(v) rescue v) : v },
        "base64_encode" => ->(v, *_a) { Base64.strict_encode64(v.is_a?(String) ? v : v.to_s) },
        "base64encode"  => ->(v, *_a) { Base64.strict_encode64(v.is_a?(String) ? v : v.to_s) },
        "base64_decode" => ->(v, *_a) { Base64.decode64(v.to_s) },
        "base64decode"  => ->(v, *_a) { Base64.decode64(v.to_s) },
        "data_uri" => ->(v, *_a) {
          if v.is_a?(Hash)
            ct = v[:type] || v["type"] || "application/octet-stream"
            raw = v[:content] || v["content"] || ""
            raw = raw.respond_to?(:read) ? raw.read : raw
            "data:#{ct};base64,#{Base64.strict_encode64(raw.to_s)}"
          else
            v.to_s
          end
        },
        "url_encode"    => ->(v, *_a) { ERB::Util.url_encode(v.to_s) },

        # -- JSON / JS --
        # Same serializer as json_encode -- the three names are one behaviour.
        # The old indent argument is gone: PHP cannot honour an arbitrary indent
        # (JSON_PRETTY_PRINT is fixed at four spaces), so honouring it here alone
        # broke byte-parity for the one filter whose whole job is a wire format.
        "to_json" => ->(v, *_a) { Frond.json_safe(v) },
        "tojson"  => ->(v, *_a) { Frond.json_safe(v) },
        "js_escape" => ->(v, *_a) {
          Tina4::SafeString.new(
            v.to_s.gsub("\\", "\\\\").gsub("'", "\\'").gsub('"', '\\"')
                  .gsub("\n", "\\n").gsub("\r", "\\r").gsub("\t", "\\t")
          )
        },

        # -- Hashing --
        "md5"    => ->(v, *_a) { Digest::MD5.hexdigest(v.to_s) },
        "sha256" => ->(v, *_a) { Digest::SHA256.hexdigest(v.to_s) },

        # -- Numbers --
        "abs"           => ->(v, *_a) { v.is_a?(Numeric) ? v.abs : v.to_f.abs },
        "round"         => ->(v, *a)  { v.to_f.round(a[0] ? a[0].to_i : 0) },
        "int"           => ->(v, *_a) { v.to_i },
        "float"         => ->(v, *_a) { v.to_f },
        "number_format" => ->(v, *a) {
          # Twig signature: number_format(decimals, decimalPoint, thousandsSep).
          # The defaults reproduce the historical output ("1,234.50") so a
          # 1-arg call is unchanged; args 2 and 3 apply the localized
          # separators (e.g. number_format(2, ',', '.') -> "1.234,50").
          decimals      = a[0] ? a[0].to_i : 0
          decimal_point = a[1].nil? ? "." : a[1].to_s
          thousands_sep = a[2].nil? ? "," : a[2].to_s
          formatted = format("%.#{decimals}f", v.to_f)
          int_part, frac_part = formatted.split(".")
          int_part = int_part.gsub(THOUSANDS_RE) { |digit| "#{digit}#{thousands_sep}" }
          frac_part ? "#{int_part}#{decimal_point}#{frac_part}" : int_part
        },

        # -- Date --
        "date" => ->(v, *a) {
          fmt = a[0] || "%Y-%m-%d"
          begin
            if v.is_a?(String)
              dt = DateTime.parse(v)
              dt.strftime(fmt)
            elsif v.respond_to?(:strftime)
              v.strftime(fmt)
            else
              v.to_s
            end
          rescue
            v.to_s
          end
        },

        # -- Arrays --
        "length"  => ->(v, *_a) { v.respond_to?(:length) ? v.length : v.to_s.length },
        "first"   => ->(v, *_a) { v.respond_to?(:first) ? v.first : (v.to_s[0] rescue nil) },
        "last"    => ->(v, *_a) { v.respond_to?(:last) ? v.last : (v.to_s[-1] rescue nil) },
        "reverse" => ->(v, *_a) { v.respond_to?(:reverse) ? v.reverse : v.to_s.reverse },
        "sort"    => ->(v, *_a) { v.respond_to?(:sort) ? v.sort : v },
        "shuffle" => ->(v, *_a) { v.respond_to?(:shuffle) ? v.shuffle : v },
        "unique"  => ->(v, *_a) { v.is_a?(Array) ? v.uniq : v },
        "join"    => ->(v, *a)  { v.respond_to?(:join) ? v.join(a[0] || ", ") : v.to_s },
        "split"   => ->(v, *a)  { v.to_s.split(a[0] || " ") },
        "slice"   => ->(v, *a) {
          if a.length >= 2
            s = a[0].to_i
            e = a[1].to_i
            if v.is_a?(Array)
              v[s...e]
            else
              v.to_s[s...e]
            end
          else
            v
          end
        },
        "batch"   => ->(v, *a) {
          if a[0] && v.respond_to?(:each_slice)
            v.each_slice(a[0].to_i).to_a
          else
            [v]
          end
        },
        "map"     => ->(v, *a) {
          if a[0] && v.is_a?(Array)
            v.map { |item| item.is_a?(Hash) ? (item[a[0]] || item[a[0].to_sym]) : nil }
          else
            v
          end
        },
        "filter"  => ->(v, *_a) { v.is_a?(Array) ? v.select { |item| item } : v },
        "column"  => ->(v, *a) {
          if a[0] && v.is_a?(Array)
            v.map { |row| row.is_a?(Hash) ? (row[a[0]] || row[a[0].to_sym]) : nil }
          else
            v
          end
        },

        # -- Dict --
        "keys"   => ->(v, *_a) { v.respond_to?(:keys) ? v.keys : [] },
        "values" => ->(v, *_a) { v.respond_to?(:values) ? v.values : [v] },
        "merge"  => ->(v, *a) {
          if v.respond_to?(:merge) && a[0].is_a?(Hash)
            v.merge(a[0])
          elsif v.is_a?(Array) && a[0].is_a?(Array)
            v + a[0]
          else
            v
          end
        },

        # -- Utility --
        "default"  => ->(v, *a) { (v.nil? || v.to_s.empty?) ? (a[0] || "") : v },
        # dump filter — gated on TINA4_DEBUG=true via Frond.render_dump.
        # Both the |dump filter and the dump() global delegate to the same
        # helper so they produce identical output and obey the same gating.
        "dump"     => ->(v, *_a) { Frond.render_dump(v) },
        "string"   => ->(v, *_a) { v.to_s },
        "truncate" => ->(v, *a) {
          len = a[0] ? a[0].to_i : 50
          str = v.to_s
          str.length > len ? str[0...len] + "..." : str
        },
        "wordwrap" => ->(v, *a) {
          width = a[0] ? a[0].to_i : 75
          words = v.to_s.split
          lines = []
          current = +""
          words.each do |word|
            if !current.empty? && current.length + 1 + word.length > width
              lines << current
              current = word
            else
              current = current.empty? ? word : "#{current} #{word}"
            end
          end
          lines << current unless current.empty?
          lines.join("\n")
        },
        "slug"   => ->(v, *_a) { v.to_s.downcase.gsub(SLUG_CLEAN_RE, "-").gsub(SLUG_TRIM_RE, "") },
        "nl2br"  => ->(v, *_a) { Tina4::SafeString.new(Frond.escape_html(v.to_s).gsub("\n", "<br />\n")) },
        "format" => ->(v, *a) {
          if a.any?
            v.to_s % a
          else
            v.to_s
          end
        },
        "form_token" => ->(_v, *_a) { Frond.generate_form_token(_v.to_s) },
      }
    end

    # -----------------------------------------------------------------------
    # Built-in globals
    # -----------------------------------------------------------------------

    def register_builtin_globals
      @globals["form_token"] = ->(descriptor = "") { Frond.generate_form_token(descriptor.to_s) }
      @globals["formTokenValue"] = ->(descriptor = "") { Frond.generate_form_token_value(descriptor.to_s) }
      @globals["form_token_value"] = ->(descriptor = "") { Frond.generate_form_token_value(descriptor.to_s) }

      # Debug helper: {{ dump(x) }} — gated on TINA4_DEBUG=true.
      # Both this global and the |dump filter call Frond.render_dump which
      # returns an empty SafeString in production so dump never leaks state.
      @globals["dump"] = ->(value = nil) { Frond.render_dump(value) }
    end

    # Render a value as a pre-formatted inspect() wrapped in <pre> tags.
    #
    # Gated on TINA4_DEBUG=true. In production (TINA4_DEBUG unset or false)
    # this returns an empty SafeString to avoid leaking internal state,
    # object shapes, or sensitive values into rendered HTML.
    #
    # Shared by the {{ value|dump }} filter and the {{ dump(value) }}
    # global function so both produce identical output and obey the same
    # gating.
    def self.render_dump(value)
      return SafeString.new("") unless ENV.fetch("TINA4_DEBUG", "").downcase == "true"

      dumped = value.inspect
      escaped = dumped
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub('"', "&quot;")
      SafeString.new("<pre>#{escaped}</pre>")
    end

    # Generate a JWT form token and return a hidden input element.
    #
    # @param descriptor [String] Optional string to enrich the token payload.
    #   - Empty: payload is {"type" => "form"}
    #   - "admin_panel": payload is {"type" => "form", "context" => "admin_panel"}
    #   - "checkout|order_123": payload is {"type" => "form", "context" => "checkout", "ref" => "order_123"}
    #
    # @return [String] <input type="hidden" name="formToken" value="TOKEN">
    # Session ID used by generate_form_token for CSRF session binding.
    # Set this before rendering templates to bind tokens to the current session.
    @form_token_session_id = ""

    class << self
      attr_accessor :form_token_session_id

      # Set the session ID used for CSRF form token binding.
      # Parity with Python/PHP/Node: Frond.set_form_token_session_id(id)
      #
      # @param session_id [String] The session ID to bind form tokens to
      def set_form_token_session_id(session_id)
        self.form_token_session_id = session_id
      end
    end

    # Generate a raw JWT form token string.
    #
    # @param descriptor [String] Optional string to enrich the token payload.
    #   - Empty: payload is {"type" => "form"}
    #   - "admin_panel": payload is {"type" => "form", "context" => "admin_panel"}
    #   - "checkout|order_123": payload is {"type" => "form", "context" => "checkout", "ref" => "order_123"}
    #
    # @return [String] The raw JWT token string.
    def self.generate_form_jwt(descriptor = "")
      require_relative "log"
      require_relative "auth"

      payload = { "type" => "form", "nonce" => SecureRandom.hex(8) }
      if descriptor && !descriptor.empty?
        if descriptor.include?("|")
          parts = descriptor.split("|", 2)
          payload["context"] = parts[0]
          payload["ref"] = parts[1]
        else
          payload["context"] = descriptor
        end
      end

      # Include session_id for CSRF session binding
      sid = form_token_session_id.to_s
      payload["session_id"] = sid unless sid.empty?

      ttl_minutes = (ENV["TINA4_TOKEN_LIMIT"] || "60").to_i
      expires_in = ttl_minutes * 60
      Tina4::Auth.create_token(payload, expires_in: expires_in)
    end

    def self.generate_form_token(descriptor = "")
      token = generate_form_jwt(descriptor)
      Tina4::SafeString.new(%(<input type="hidden" name="formToken" value="#{CGI.escapeHTML(token)}">))
    end

    # Return just the raw JWT form token string (no <input> wrapper).
    # Registered as both formTokenValue and form_token_value template globals.
    def self.generate_form_token_value(descriptor = "")
      Tina4::SafeString.new(generate_form_jwt(descriptor))
    end
  end
end
