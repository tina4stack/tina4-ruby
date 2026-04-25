# frozen_string_literal: true

# Tina4::Docs — Live API RAG.
#
# Walks the running framework (`lib/tina4/`) and the user's project surface
# (`<root>/src/orm`, `routes`, `app`, `services`) and exposes them via a
# ranked search, class/method specs, a flat index, MCP-style mirrors and
# a Markdown drift / sync helper.
#
# Stdlib only — no new gems. Class introspection where safe, regex parsing
# of `.rb` source for unloaded user code (so user files with unresolved
# requires never blow up the indexer).
#
# Spec: plan/v3/22-LIVE-API-RAG.md

require "json"
require "set"

module Tina4
  class Docs
    # ── Constants ────────────────────────────────────────────────────

    USER_DIRS = %w[orm routes app services].freeze

    # Method names commonly referenced in markdown that must NOT be flagged
    # as drift even when not present in the live index.
    STDLIB_ALLOWLIST = %w[
      puts print p pp inspect to_s to_a to_h to_i to_f to_sym
      keys values each map select reject reduce inject filter
      length size count first last empty? include? has_key?
      push pop shift unshift slice splice
      get set put patch post delete head options
      json html xml render redirect text file stream call
      strip lstrip rstrip chomp chop split join replace gsub sub
      upcase downcase capitalize to_str
      new initialize freeze dup clone tap then yield_self
      raise rescue retry begin ensure end
      require require_relative load
      assert assert_equal assert_nil assert_not_nil expect should
    ].freeze

    # Module-level cache keyed by absolute project_root.
    @_mcp_instances = {}
    @_mcp_mutex = Mutex.new

    # ── Construction ─────────────────────────────────────────────────

    def initialize(project_root)
      @project_root = File.expand_path(project_root.to_s)
      @framework_root = File.expand_path(File.dirname(__FILE__))
      @gem_root = File.expand_path(File.join(@framework_root, ".."))
      @version = detect_version
      @framework_entries = nil
      @user_entries = nil
      @user_mtime = 0
    end

    attr_reader :project_root

    # ── Public API ───────────────────────────────────────────────────

    # Search the merged framework + user index for ranked hits.
    #
    # @param query [String]            Free-text query
    # @param k [Integer]               Top-K to return
    # @param source [String]           "all" (default), "framework", "user", "vendor"
    # @param include_private [Boolean] Include private/protected/_underscore methods
    # @return [Array<Hash>]
    def search(query, k: 5, source: "all", include_private: false)
      ensure_index
      tokens = tokenise(query.to_s)
      return [] if tokens.empty?

      joined = query.to_s.downcase.gsub(/\s+/, "")
      results = []
      all_entries.each do |entry|
        src = entry[:source]
        next if source == "all" && src == "vendor"
        next if source != "all" && src != source
        next if !include_private && entry[:_private]

        score = score_entry(entry, tokens, joined)
        next if score <= 0
        score *= 1.2 if src == "user"
        hit = entry.dup
        hit.delete(:_private)
        hit.delete(:docstring)
        hit[:score] = score.round(4)
        results << hit
      end
      results.sort! do |a, b|
        cmp = b[:score] <=> a[:score]
        cmp.nonzero? || (a[:fqn] <=> b[:fqn])
      end
      results.first([k, 1].max)
    end

    # Full reflection of a single class — `nil` for unknown.
    def class_spec(fqn)
      ensure_index
      key = normalise_fqn(fqn)
      class_entry = all_entries.find { |e| e[:kind] == "class" && e[:fqn] == key }
      return nil if class_entry.nil?

      methods = all_entries.select do |m|
        m[:kind] == "method" && m[:class_fqn] == class_entry[:fqn] && m[:visibility] == "public"
      end.map { |m| method_payload(m) }

      {
        fqn:        class_entry[:fqn],
        kind:       "class",
        name:       class_entry[:name],
        file:       class_entry[:file],
        line:       class_entry[:line],
        summary:    class_entry[:summary],
        source:     class_entry[:source],
        version:    class_entry[:version],
        methods:    methods,
        properties: [],
      }
    end

    # Single method spec — `nil` for unknown.
    def method_spec(class_fqn, method_name)
      ensure_index
      key = normalise_fqn(class_fqn)
      entry = all_entries.find do |e|
        e[:kind] == "method" && e[:class_fqn] == key && e[:name] == method_name.to_s
      end
      entry && method_payload(entry)
    end

    # Flat list of every entity (classes + methods).
    def index
      ensure_index
      all_entries.map do |e|
        clean = e.dup
        clean.delete(:_private)
        clean
      end
    end

    # ── MCP-style mirrors ────────────────────────────────────────────

    def self.mcp_search(query, k: 5, project_root: nil, source: "all", include_private: false)
      cached(project_root).search(query, k: k, source: source, include_private: include_private)
    end

    def self.mcp_method(class_fqn, name, project_root: nil)
      cached(project_root).method_spec(class_fqn, name)
    end

    def self.mcp_class(fqn, project_root: nil)
      cached(project_root).class_spec(fqn)
    end

    # ── Drift detector ───────────────────────────────────────────────

    # Scan a markdown file for method-call references that don't exist in
    # the live index. Returns `{drift: [...]}`.
    def self.check_docs(md_file_path, project_root: nil)
      return { drift: [], error: "file not found: #{md_file_path}" } unless File.file?(md_file_path)

      project_root ||= File.dirname(File.expand_path(md_file_path))
      docs = cached(project_root)
      idx = docs.index
      known = idx.each_with_object({}) do |e, acc|
        acc[e[:name].to_s.downcase] = true if e[:kind] == "method"
      end
      allow = STDLIB_ALLOWLIST.map(&:downcase).to_set

      text = File.read(md_file_path, encoding: "utf-8", invalid: :replace, undef: :replace)
      drift = []

      # Patterns: var.method(, Class::method(, Class#method(, var->method(
      patterns = [
        /(?:\b[a-z_][\w]*|\$\w+)\s*[.](\w+)\s*\(/,
        /\b[A-Z]\w*::(\w+)\s*\(/,
        /\b[A-Z]\w*#(\w+)\s*\(/,
        /\$\w+->(\w+)\s*\(/,
      ]

      in_block = false
      text.lines.each_with_index do |line, i|
        if line.lstrip.start_with?("```")
          in_block = !in_block
          next
        end
        next unless in_block

        patterns.each do |pat|
          line.scan(pat) do |captures|
            name = captures.first
            name_lc = name.to_s.downcase
            next if allow.include?(name_lc)
            next if known[name_lc]
            drift << {
              method: name,
              line:   i + 1,
              block:  line.strip,
            }
          end
        end
      end

      { drift: drift }
    end

    # Overwrite the `<!-- BEGIN GENERATED API -->` block in the markdown
    # file. Append a fresh block if the markers are absent.
    def self.sync_docs(md_file_path, project_root: nil)
      project_root ||= (File.file?(md_file_path) ? File.dirname(File.expand_path(md_file_path)) : Dir.pwd)
      docs = cached(project_root)
      generated = docs.send(:render_generated_block)
      begin_marker = "<!-- BEGIN GENERATED API -->"
      end_marker   = "<!-- END GENERATED API -->"
      existing = File.file?(md_file_path) ? File.read(md_file_path, encoding: "utf-8") : ""

      if existing.include?(begin_marker) && existing.include?(end_marker)
        b = existing.index(begin_marker)
        e = existing.index(end_marker)
        if b && e && e > b
          before = existing[0, b + begin_marker.length]
          after  = existing[e..-1]
          File.write(md_file_path, "#{before}\n#{generated}\n#{after}")
          return
        end
      end

      block = "\n\n#{begin_marker}\n#{generated}\n#{end_marker}\n"
      File.write(md_file_path, existing.rstrip + block)
    end

    # ── Internal: cached MCP instance ────────────────────────────────

    def self.cached(project_root)
      key = File.expand_path((project_root || Dir.pwd).to_s)
      @_mcp_mutex.synchronize do
        @_mcp_instances ||= {}
        @_mcp_instances[key] ||= new(key)
      end
    end

    def self.reset_cache!
      @_mcp_mutex ||= Mutex.new
      @_mcp_mutex.synchronize do
        @_mcp_instances = {}
      end
    end

    # ── Internal: index lifecycle ────────────────────────────────────

    private

    def all_entries
      (@framework_entries || []) + (@user_entries || [])
    end

    def ensure_index
      @framework_entries ||= build_framework_index
      current = current_user_mtime
      if @user_entries.nil? || current != @user_mtime
        @user_entries = build_user_index
        @user_mtime = current
      end
    end

    def current_user_mtime
      max = 0
      USER_DIRS.each do |sub|
        root = File.join(@project_root, "src", sub)
        next unless File.directory?(root)
        Dir.glob(File.join(root, "**", "*.rb")).each do |f|
          mt = File.mtime(f).to_f rescue 0
          max = mt if mt > max
        end
      end
      max
    end

    # ── Internal: framework reflection ───────────────────────────────

    def build_framework_index
      entries = []
      Dir.glob(File.join(@framework_root, "**", "*.rb")).each do |path|
        parse_ruby_file(path, "framework", entries)
      end
      entries
    end

    # ── Internal: user reflection ────────────────────────────────────

    def build_user_index
      entries = []
      USER_DIRS.each do |sub|
        root = File.join(@project_root, "src", sub)
        next unless File.directory?(root)
        Dir.glob(File.join(root, "**", "*.rb")).each do |path|
          parse_ruby_file(path, "user", entries)
        end
      end
      entries
    end

    # ── Parsing — regex-based AST-lite ───────────────────────────────

    # Parse a Ruby source file into class + method entries. Tracks nested
    # `module`/`class` declarations to assemble `Foo::Bar` FQNs and pairs
    # each `def` with the leading comment block.
    def parse_ruby_file(abs_path, source, entries)
      text = File.read(abs_path, encoding: "utf-8", invalid: :replace, undef: :replace)
      return if text.bytesize > 1024 * 1024 # 1MB sanity cap

      rel_file = relative_path(abs_path, source)
      stack = []         # [{ kind:, name:, line:, doc:, fqn: }]
      pending_doc = []
      pending_visibility = nil
      visibility_scope = {} # fqn => current visibility

      text.each_line.with_index(1) do |raw_line, lineno|
        line = raw_line.rstrip
        stripped = line.lstrip

        if stripped.start_with?("#")
          # Skip shebang and frozen-string magic comments.
          unless stripped.start_with?("#!") || stripped.start_with?("# frozen_string_literal")
            pending_doc << stripped.sub(/\A#\s?/, "")
          end
          next
        end

        # Track scope-changing visibility modifiers on their own line.
        if stack.last && %w[private protected public].include?(stripped.split(/\s/).first)
          # `private` alone on a line — switches default for the class.
          first_word = stripped.split(/\s/).first
          if stripped.match?(/\A(private|protected|public)\s*\z/)
            current_class = stack.reverse.find { |s| s[:kind] == "class" }
            visibility_scope[current_class[:fqn]] = first_word if current_class
            pending_doc.clear
            next
          end
          # `private :foo` symbol form — apply to that one method
          if (m = stripped.match(/\A(private|protected|public)\s+:(\w+)/))
            mname = m[2]
            target = entries.reverse.find { |e| e[:kind] == "method" && e[:name] == mname }
            target[:visibility] = m[1] if target
            target[:_private] = (m[1] != "public") if target
            pending_doc.clear
            next
          end
          if (m = stripped.match(/\A(private|protected|public)\s+def\s+/))
            pending_visibility = m[1]
            stripped = stripped.sub(/\A(private|protected|public)\s+/, "")
          end
        end

        # Module / class declarations
        if (m = stripped.match(/\Amodule\s+([A-Z]\w*(?:::[A-Z]\w*)*)/))
          name = m[1]
          fqn = qualify(stack, name)
          stack << { kind: "module", name: name, line: lineno, doc: pending_doc.dup, fqn: fqn,
                     indent: leading_indent(line) }
          pending_doc.clear
          next
        end

        if (m = stripped.match(/\Aclass\s+([A-Z]\w*(?:::[A-Z]\w*)*)(?:\s*<\s*[\w:]+)?/))
          name = m[1]
          fqn = qualify(stack, name)
          stack << { kind: "class", name: name, line: lineno, doc: pending_doc.dup, fqn: fqn,
                     indent: leading_indent(line) }
          summary, doc = split_doc(pending_doc)
          entries << {
            fqn:       fqn,
            kind:      "class",
            name:      name.split("::").last,
            signature: "class #{name}",
            summary:   summary,
            docstring: doc,
            file:      rel_file,
            line:      lineno,
            version:   @version,
            source:    source,
            visibility: "public",
          }
          visibility_scope[fqn] = "public"
          pending_doc.clear
          next
        end

        # `end` — pop matching module/class. Match by indent so we don't
        # confuse method-end with class-end.
        if stripped == "end" || stripped.start_with?("end ") || stripped.start_with?("end\t")
          if stack.last && leading_indent(line) == stack.last[:indent]
            stack.pop
            next
          end
        end

        # Method definition.
        if (m = stripped.match(/\Adef\s+(self\.)?([A-Za-z_][\w]*[!?=]?)(.*?)(?:\z|\s*#|;)/))
          is_static = !m[1].nil?
          mname = m[2]
          rest = m[3].to_s.strip
          # Capture args until the matching close paren or end-of-line.
          if rest.start_with?("(")
            args = balanced_paren(rest)
            sig_args = args
          elsif rest.empty?
            sig_args = "()"
          else
            sig_args = "(#{rest})"
          end

          current_class = stack.reverse.find { |s| s[:kind] == "class" }
          if current_class.nil?
            pending_doc.clear
            pending_visibility = nil
            next
          end

          base_visibility = visibility_scope[current_class[:fqn]] || "public"
          visibility = pending_visibility || base_visibility
          # Names starting with `_` are treated as private for search filtering.
          underscored = mname.start_with?("_")
          private_flag = visibility != "public" || underscored

          summary, doc = split_doc(pending_doc)
          method_fqn = if is_static
            "#{current_class[:fqn]}.#{mname}"
          else
            "#{current_class[:fqn]}##{mname}"
          end
          signature = is_static ? "self.#{mname}#{sig_args}" : "#{mname}#{sig_args}"

          entries << {
            fqn:         method_fqn,
            kind:        "method",
            name:        mname,
            class_fqn:   current_class[:fqn],
            class:       current_class[:fqn],
            signature:   signature,
            summary:     summary,
            docstring:   doc,
            file:        rel_file,
            line:        lineno,
            version:     @version,
            source:      source,
            visibility:  visibility,
            static:      is_static,
            _private:    private_flag,
          }
          pending_doc.clear
          pending_visibility = nil
          next
        end

        # Anything else clears the pending docblock.
        pending_doc.clear unless stripped.empty?
      end
    end

    def qualify(stack, name)
      return name if name.start_with?("::")
      parts = stack.map { |s| s[:name] } + [name]
      parts.join("::")
    end

    def leading_indent(line)
      line[/\A[ \t]*/].length
    end

    # Read a balanced parenthesised string starting at `s[0] == "("`.
    def balanced_paren(s)
      depth = 0
      out = +""
      s.each_char do |ch|
        out << ch
        if ch == "("
          depth += 1
        elsif ch == ")"
          depth -= 1
          break if depth.zero?
        end
      end
      out
    end

    def split_doc(lines)
      cleaned = lines.map(&:strip).reject { |l| l.empty? || l.start_with?("@") }
      summary = cleaned.first.to_s
      [summary[0, 240], cleaned.join(" ")]
    end

    # ── Relative path ────────────────────────────────────────────────

    def relative_path(abs_path, source)
      abs = File.expand_path(abs_path)
      if source == "framework"
        # Framework-relative — strip the gem root so files appear as
        # "lib/tina4/response.rb".
        if abs.start_with?(@gem_root + File::SEPARATOR)
          return abs.sub(@gem_root + File::SEPARATOR, "")
        end
      end
      project = @project_root + File::SEPARATOR
      return abs.sub(project, "") if abs.start_with?(project)
      abs
    end

    # ── Ranking ──────────────────────────────────────────────────────

    CAMEL_RE = /(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/.freeze

    SPLIT_RE = /[\s_\-.\/:,;()\[\]{}\\]+/.freeze

    def tokenise(text)
      return [] if text.nil? || text.empty?
      t = text.gsub(CAMEL_RE, " ").downcase
      t.split(SPLIT_RE).reject(&:empty?)
    end

    def score_entry(entry, tokens, joined)
      name = entry[:name].to_s.downcase
      stripped = name.sub(/\A_+/, "")
      summary = entry[:summary].to_s.downcase
      doc = entry[:docstring].to_s.downcase
      score = 0.0

      # 5: exact name match (case-insensitive) on the joined query.
      if name == joined || stripped == joined
        score += 5
      end

      name_tokens = tokenise(entry[:name].to_s)
      tokens.each do |tk|
        next if tk.empty?
        if name.start_with?(tk) || stripped.start_with?(tk)
          score += 3
          next
        end
        name_tokens.each do |nt|
          if nt == tk
            score += 3
            break
          elsif nt.start_with?(tk)
            score += 2
            break
          end
        end
      end

      # 2: per token in summary.
      tokens.each do |tk|
        score += 2 if !tk.empty? && summary.include?(tk)
      end
      # 1: per token in docstring body.
      tokens.each do |tk|
        score += 1 if !tk.empty? && doc.include?(tk)
      end
      # Substring fallback — full joined query inside the name.
      if !joined.empty? && score.zero? && name.include?(joined)
        score += 2
      end
      score
    end

    # ── Spec helpers ─────────────────────────────────────────────────

    def method_payload(entry)
      {
        name:       entry[:name],
        fqn:        entry[:fqn],
        class:      entry[:class_fqn],
        kind:       "method",
        signature:  entry[:signature],
        summary:    entry[:summary],
        docblock:   entry[:docstring],
        file:       entry[:file],
        line:       entry[:line],
        visibility: entry[:visibility],
        static:     entry[:static] || false,
        source:     entry[:source],
        version:    entry[:version],
        params:     [],
        return:     "",
      }
    end

    # ── Sync writer ──────────────────────────────────────────────────

    def render_generated_block
      ensure_index
      lines = []
      lines << "_Generated by `Tina4::Docs` — version #{@version}._"
      lines << ""
      lines << "## Framework classes"
      lines << ""
      fw_classes = (@framework_entries || []).select { |e| e[:kind] == "class" }.sort_by { |e| e[:fqn] }
      method_counts = Hash.new(0)
      (@framework_entries || []).each do |e|
        method_counts[e[:class_fqn]] += 1 if e[:kind] == "method"
      end
      fw_classes.each do |c|
        summary = c[:summary].to_s.empty? ? "" : " — #{c[:summary]}"
        lines << "- `#{c[:fqn]}` (#{method_counts[c[:fqn]]} methods)#{summary}"
      end

      user_classes = (@user_entries || []).select { |e| e[:kind] == "class" }.sort_by { |e| e[:fqn] }
      unless user_classes.empty?
        lines << ""
        lines << "## User code"
        lines << ""
        user_classes.each do |c|
          summary = c[:summary].to_s.empty? ? "" : " — #{c[:summary]}"
          lines << "- `#{c[:fqn]}`#{summary}"
        end
      end

      lines.join("\n")
    end

    # ── Bootstrap helpers ────────────────────────────────────────────

    def detect_version
      if defined?(Tina4::VERSION) && !Tina4::VERSION.to_s.empty?
        return Tina4::VERSION.to_s
      end
      "0.0.0"
    end

    def normalise_fqn(fqn)
      fqn.to_s.sub(/\A::/, "")
    end
  end
end
