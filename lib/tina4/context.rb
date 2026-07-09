# frozen_string_literal: true

# Tina4 Ruby
#
# Context — a native, zero-dependency code/doc grounding index.
#
# Lets a Tina4 app ground its own AI assistant on its own source, offline: it
# walks the project, chunks code on def/class/module boundaries and docs as
# prose, and answers keyword/fuzzy queries over a SQLite FTS5 index. The
# sqlite3 gem is already a Tina4-Ruby runtime dependency and modern SQLite ships
# FTS5 + bm25() built in, so this adds NO new dependency.
#
# The retrieval core is a thin port of tina4-python's tina4_python/context
# (itself the proven slice of neemee: SqliteFTS + the stable
# source-over-tests / definition-first reorderings). It COMPLEMENTS the api_*
# reflection tools: api_* is exact structural lookup, Context is fuzzy/semantic
# FTS over source + docs.
#
#   ctx = Tina4::Context.new(".tina4/context.db")
#   ctx.index_root("src")
#   ctx.search("where is the auth token issued?", k: 5)
#   #  -> [{ path: "auth.rb", score: 2.31, snippet: "..." }, ...]
#
# On-disk index defaults to ".tina4/context.db" (gitignored). Guards a sqlite
# build without FTS5: if absent, the Context degrades to safe no-ops rather than
# crashing the app.

require "pathname"
require "fileutils"
require "set"
require_relative "context/chunker"

module Tina4
  class Context
    # File classification — mirrors the Python port's repo walk.
    CODE_EXTS = %w[.py .php .js .mjs .ts .rb .pas .dpr .dpk .inc .dfm .fmx].freeze
    DOC_EXTS  = %w[.md .txt .rst .twig .html].freeze
    # deploy/CLI/env answers live in config files, not sources — chunk as code
    # (line windows), since sentence chunking shreds YAML/Dockerfiles.
    CONFIG_EXTS = %w[.toml .yml .yaml].freeze
    SPECIAL_FILES = %w[dockerfile makefile docker-compose.yml package.json
                       composer.json gemfile .env.example .env.sample].freeze
    # Same dirs the Python port skips, plus Tina4 runtime dirs that hold no
    # source of truth (our own index/backups, session blobs, logs).
    SKIP_DIRS = %w[.git __pycache__ node_modules vendor dist build coverage
                   .idea .venv venv .pytest_cache .tina4 sessions logs].freeze

    # Generic question/code vocabulary that never NAMES a symbol — kept small.
    DEF_STOP = %w[the and what how does can which where when who why list all
                  available module class function functions method methods def
                  get set new return import from with that this are is was for
                  into use used].to_set.freeze

    # A chunk that DEFINES a queried symbol ("def get_token", "class Widget",
    # "module Auth") should out-rank one that merely USES it. Matched against
    # the folded body.
    DEF_KW = '(?:async def|def|class|module|function|fn|func|interface|trait)'

    attr_reader :path, :available, :root

    # `path` is the on-disk index file (its parent dir is created). `fts5_check`
    # overrides FTS5 detection (used by tests to exercise the graceful-
    # degradation path); defaults to a real probe of this build.
    def initialize(path = "./.tina4/context.db", fts5_check: nil)
      @path = path.to_s
      @lock = Mutex.new
      @conn = nil
      @root = nil # set by index_root; reindex_file relabels against it
      check = fts5_check || -> { self.class.fts5_available? }
      @available = !!check.call
      return unless @available

      require "sqlite3"
      parent = File.dirname(@path)
      FileUtils.mkdir_p(parent) unless parent.empty? || parent == "." || File.directory?(parent)
      # One connection guarded by a Mutex — the dev-MCP reload hook may run on a
      # Puma worker thread, so access is serialized rather than same-thread-only.
      @conn = SQLite3::Database.new(@path)
      ensure_table
    end

    # ── FTS5 availability ───────────────────────────────────────
    # Whether this Ruby's sqlite3 build supports FTS5 (a real in-memory probe).
    def self.fts5_available?
      require "sqlite3"
      db = SQLite3::Database.new(":memory:")
      begin
        db.execute("CREATE VIRTUAL TABLE _probe USING fts5(x)")
        true
      rescue SQLite3::Exception
        false
      ensure
        db.close
      end
    rescue LoadError, StandardError
      false
    end

    # ── schema ──────────────────────────────────────────────────
    def ensure_table
      # `body` holds fold(text) so query/index tokenization is symmetric; `raw`
      # (UNINDEXED) keeps the original text to return as a snippet; `path`/`cid`
      # (UNINDEXED) are metadata used for upsert + citation.
      @conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS chunks " \
        "USING fts5(cid UNINDEXED, path UNINDEXED, raw UNINDEXED, body)"
      )
    end
    private :ensure_table

    # Drop and recreate the index (full rebuild starting point).
    def reset
      return unless @available

      @lock.synchronize do
        @conn.execute("DROP TABLE IF EXISTS chunks")
        ensure_table
      end
    end

    # ── indexing ────────────────────────────────────────────────
    # [index, chunk_text] pairs — code/config files on def/class boundaries,
    # docs as prose.
    def self.chunks_for(label, text)
      ext = File.extname(label).downcase
      special = SPECIAL_FILES.include?(File.basename(label).downcase)
      if CODE_EXTS.include?(ext) || CONFIG_EXTS.include?(ext) || special
        Chunker.chunk_code(text, path: label)
      else
        Chunker.chunk_text(text)
      end
    end

    # UPSERT one file into the index: delete this path's existing chunks,
    # re-chunk the current contents, insert. A single file save re-indexes just
    # that file. `label` is the stored/citation path (defaults to `file`) and
    # MUST be stable across calls for the same file so the delete targets the
    # right rows. Returns rows inserted.
    def index_path(file, label: nil)
      return 0 unless @available

      stored = as_text(label.nil? ? file : label)
      begin
        text = File.read(file, encoding: "UTF-8", invalid: :replace, undef: :replace, replace: "")
      rescue SystemCallError
        return 0
      end
      rows = self.class.chunks_for(stored, text).map do |i, chunk|
        ["#{stored}:#{i}", stored, chunk, Chunker.fold(chunk)]
      end
      @lock.synchronize do
        @conn.execute("DELETE FROM chunks WHERE path = ?", [stored])
        unless rows.empty?
          stmt = @conn.prepare("INSERT INTO chunks(cid, path, raw, body) VALUES (?, ?, ?, ?)")
          begin
            rows.each { |r| stmt.execute(r) }
          ensure
            stmt.close
          end
        end
      end
      rows.length
    end

    # True if a file should be indexed (the per-file filter used by both
    # index_root and reindex_file). Directory skipping is handled separately.
    def self.eligible?(filename)
      fn = filename.downcase
      return false if fn.end_with?(".min.js")

      ext = File.extname(fn)
      CODE_EXTS.include?(ext) || DOC_EXTS.include?(ext) ||
        CONFIG_EXTS.include?(ext) || SPECIAL_FILES.include?(fn)
    end

    # Walk `root`, indexing every eligible file (skips vendor/build/runtime
    # dirs). Paths are stored RELATIVE to `root` for clean citations. Records
    # `root` so reindex_file can relabel a changed file consistently. Returns
    # the total number of chunks inserted.
    def index_root(root)
      return 0 unless @available

      root = canonical_dir(root)
      @root = root
      total = 0
      walk(root) do |full|
        rel = Pathname.new(full).relative_path_from(Pathname.new(root)).to_s
        total += index_path(full, label: rel)
      end
      total
    end

    # Re-index a single changed file into the LIVE index — the hook the dev
    # reload trigger (POST /__dev/api/reload) calls so code_search tracks edits
    # without a rebuild. Resolves `changed_path` against the indexed root, then:
    # outside root / under a skip-or-dot dir / ineligible -> skip (-1);
    # deleted -> drop its chunks (0); otherwise UPSERT (rows). No-op (-1) until
    # index_root has run (nothing to keep fresh yet).
    def reindex_file(changed_path)
      return -1 unless @available && @root

      p = changed_path.to_s
      # The reload trigger reports paths relative to the project root (cwd during
      # `tina4 serve`); the index root may be a subdir like src/.
      p = File.join(Dir.pwd, p) unless Pathname.new(p).absolute?
      resolved = canonical_path(p)
      begin
        rel_pn = Pathname.new(resolved).relative_path_from(Pathname.new(@root))
      rescue ArgumentError
        return -1 # different mount/drive — outside the indexed root
      end
      parts = rel_pn.each_filename.to_a
      return -1 if parts.first == ".." # outside the indexed root
      return -1 if parts.any? { |pt| SKIP_DIRS.include?(pt) }
      return -1 if parts[0...-1].any? { |pt| pt.start_with?(".") }
      return -1 unless self.class.eligible?(rel_pn.basename.to_s)

      stored = as_text(rel_pn.to_s)
      unless File.exist?(resolved) # deleted → drop its chunks
        @lock.synchronize { @conn.execute("DELETE FROM chunks WHERE path = ?", [stored]) }
        return 0
      end
      index_path(resolved, label: stored)
    end

    # ── query ───────────────────────────────────────────────────
    # Build the FTS5 MATCH string: each folded query token (plus its light stem)
    # as a quoted OR term. Quoting keeps it injection-safe.
    def match_expr(query)
      toks = []
      Chunker.terms(query).each do |t|
        toks << t
        toks << Chunker.light_stem(t)
      end
      toks = toks.uniq.reject(&:empty?)
      return nil if toks.empty?

      toks.sort.map { |t| %("#{t}") }.join(" OR ")
    end
    private :match_expr

    def self.testlike?(path)
      s = (path || "").downcase
      ["/test", "test/", "test_", "_test.", ".test.", "/example", "example/"].any? { |p| s.include?(p) }
    end

    def defines?(folded_body, symbols)
      return false if symbols.empty?

      alt = symbols.map { |s| Regexp.escape(s) }.join("|")
      pat = Regexp.new("#{DEF_KW}\\s+(?:#{alt})(?![a-z0-9])")
      !pat.match(folded_body).nil?
    end
    private :defines?

    # Return the top-`k` chunks as [{ path:, score:, snippet: }], ranked by
    # bm25() then reordered with two stable, proven passes:
    #   - source-over-tests: a test that merely mentions a symbol sinks below the
    #     source that defines it (skipped when the query is about tests);
    #   - definition-first: a chunk that DEFINES a queried symbol rises above
    #     chunks that only use it.
    # Score is a higher-is-better float (sqlite's bm25 sign flipped).
    def search(query, k: 5)
      return [] unless @available

      expr = match_expr(query)
      return [] if expr.nil?

      pool_n = [k * 3, 15].max
      rows = @lock.synchronize do
        @conn.execute(
          "SELECT path, raw, body, bm25(chunks) AS s FROM chunks " \
          "WHERE chunks MATCH ? ORDER BY s LIMIT ?",
          [expr, pool_n]
        )
      end
      return [] if rows.empty?

      # candidate symbol names from the query (drop generic vocab).
      symbols = Chunker.terms(query).select { |t| t.length >= 3 && !DEF_STOP.include?(t) }.uniq
      about_tests = query.downcase.include?("test")

      ordered = rows.each_with_index.sort_by do |row, idx|
        path, _raw, body, = row
        is_test = (!about_tests && self.class.testlike?(path)) ? 1 : 0
        is_def  = defines?(body, symbols) ? 0 : 1
        [is_test, is_def, idx] # bm25 order (idx) breaks ties
      end

      ordered.first(k).map do |row, _idx|
        path, raw, _body, s = row
        { path: path, score: (-s.to_f).round(6), snippet: snippet(raw) }
      end
    end

    def snippet(raw, limit: 280)
      text = (raw || "").strip
      return text if text.length <= limit

      "#{text[0...limit].rstrip} ..."
    end
    private :snippet

    # ── misc ────────────────────────────────────────────────────
    def count
      return 0 unless @available

      @lock.synchronize { @conn.execute("SELECT count(*) FROM chunks").first.first }
    end

    def empty?
      count.zero?
    end

    def close
      return if @conn.nil?

      @lock.synchronize do
        @conn.close
        @conn = nil
      end
    end

    # Tag a string as UTF-8 TEXT for SQLite binding. Path strings from
    # Pathname#relative_path_from / File.realpath arrive as ASCII-8BIT (BINARY),
    # which the sqlite3 gem binds as a BLOB — and in SQLite a BLOB never equals a
    # TEXT column value, so `WHERE path = ?` would silently match nothing and the
    # UPSERT's delete would leave stale rows behind. Re-tagging the same bytes as
    # UTF-8 makes them bind as TEXT; invalid byte sequences are scrubbed so the
    # bind can never raise. Filesystem paths on the supported platforms are UTF-8.
    def as_text(str)
      s = str.to_s.dup.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : s.scrub("?")
    end
    private :as_text

    # ── path canonicalization ───────────────────────────────────
    # Resolve symlinks like Python's Path.resolve() so a root under /var and a
    # changed path reported under /private/var (macOS) compare equal.
    def canonical_dir(dir)
      File.exist?(dir) ? File.realpath(dir) : File.expand_path(dir)
    end
    private :canonical_dir

    def canonical_path(p)
      return File.realpath(p) if File.exist?(p)

      d = File.dirname(p)
      d = File.realpath(d) if File.exist?(d)
      File.join(d, File.basename(p))
    end
    private :canonical_path

    # Top-down walk that prunes skip-dirs and dotdirs, yielding each eligible
    # file's absolute path in sorted order (mirrors the Python os.walk prune).
    def walk(dir, &blk)
      children = Dir.children(dir).sort
      files = children.select { |c| File.file?(File.join(dir, c)) }.sort
      files.each do |fn|
        blk.call(File.join(dir, fn)) if self.class.eligible?(fn)
      end
      subdirs = children.select do |c|
        full = File.join(dir, c)
        File.directory?(full) && !SKIP_DIRS.include?(c) && !c.start_with?(".")
      end
      subdirs.sort.each { |d| walk(File.join(dir, d), &blk) }
    end
    private :walk

    # ── process-wide shared index ─────────────────────────────────
    # code_search (dev MCP) and the dev-reload reindex hook must share ONE index
    # so a saved file is immediately searchable. Keyed by resolved db path.
    @shared_contexts = {}

    class << self
      def db_key(db = nil)
        base = db ? db.to_s : File.join(Dir.pwd, ".tina4", "context.db")
        File.expand_path(base)
      end

      # Get (or create) the process-wide Context at `db` (default
      # <cwd>/.tina4/context.db). If `root` is given and the index is empty,
      # builds it once. This is what code_search uses so the reload hook can keep
      # the SAME index fresh.
      def default_context(root: nil, db: nil)
        key = db_key(db)
        ctx = (@shared_contexts[key] ||= new(key))
        ctx.index_root(root) if !root.nil? && ctx.available && ctx.empty?
        ctx
      end

      # Return the already-created shared Context for `db` (or nil). Used by the
      # reload hook so a file change reindexes an EXISTING index but never
      # creates one on its own (nothing to keep fresh until code_search runs).
      def existing_context(db: nil)
        @shared_contexts[db_key(db)]
      end

      # Test/teardown seam — forget every shared Context.
      def clear_shared_contexts!
        @shared_contexts.each_value { |c| c.close rescue nil }
        @shared_contexts = {}
      end
    end
  end
end
