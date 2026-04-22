# frozen_string_literal: true

# Tina4::ProjectIndex — lightweight "where is what" map of a project.
# Ported from tina4_python/dev_admin/project_index.py.
#
# Storage: .tina4/project_index.json at the project root. Incremental,
# mtime-based refresh on every read. Per-language extractors (Ruby,
# ERB/Twig, SQL, JS/TS, Markdown) produce symbol/route/import summaries
# used by index_search and index_overview.

require "json"
require "digest"
require "fileutils"

module Tina4
  module ProjectIndex
    INDEX_DIRNAME  = ".tina4"
    INDEX_FILENAME = "project_index.json"

    SKIP_DIRS = %w[
      .git .hg .svn node_modules __pycache__ .venv venv .mypy_cache
      .ruff_cache .pytest_cache dist build .tina4 logs .idea .vscode
      vendor coverage tmp .bundle
    ].freeze

    INDEX_EXT = %w[
      .rb .erb .twig .html .sql .scss .css .js .ts .mjs .md .json .yml
      .yaml .toml .env .rake
    ].freeze

    MAX_FILE_BYTES = 256 * 1024

    ROUTE_METHODS = %w[get post put patch delete any any_method secure_get secure_post].freeze

    class << self
      def project_root
        File.expand_path(Dir.pwd)
      end

      def index_path
        dir = File.join(project_root, INDEX_DIRNAME)
        FileUtils.mkdir_p(dir)
        File.join(dir, INDEX_FILENAME)
      end

      # ── Extractors ────────────────────────────────────────────

      def extract_ruby(text)
        out = { "symbols" => [], "imports" => [], "routes" => [], "docstring" => "" }
        # Pick up first non-blank comment block as pseudo-docstring.
        first_comment = nil
        text.each_line do |ln|
          s = ln.strip
          next if s.empty? || s.start_with?("#!") || s == "# frozen_string_literal: true"
          if s.start_with?("#")
            first_comment = s.sub(/\A#\s*/, "")[0, 200]
            break
          else
            break
          end
        end
        out["docstring"] = first_comment if first_comment

        text.scan(/^\s*(?:class|module)\s+([A-Z][\w:]*)/) { |m| out["symbols"] << m[0] }
        text.scan(/^\s*def\s+(self\.)?([A-Za-z_][\w!?=]*)/) { |m| out["symbols"] << m[1] }
        text.scan(/^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/) { |m| out["imports"] << m[0] }
        # Tina4.get "/path"  OR  Tina4::Router.get("/path")  OR  get "/path" do
        route_re = /(?:Tina4(?:::Router)?\.|^\s*)(get|post|put|patch|delete|any|any_method|secure_get|secure_post)\s*\(?\s*['"]([^'"]+)['"]/
        text.scan(route_re) do |meth, path|
          next unless ROUTE_METHODS.include?(meth)
          out["routes"] << { "method" => meth.upcase, "path" => path, "handler" => "" }
        end
        out["symbols"].uniq!
        out["imports"].uniq!
        out
      end

      TWIG_EXTENDS = /\{%\s*extends\s+['"]([^'"]+)['"]\s*%\}/.freeze
      TWIG_BLOCK   = /\{%\s*block\s+([A-Za-z_][\w-]*)/.freeze
      TWIG_INCLUDE = /\{%\s*include\s+['"]([^'"]+)['"]/.freeze

      def extract_twig(text)
        {
          "extends"  => text.scan(TWIG_EXTENDS).flatten,
          "blocks"   => text.scan(TWIG_BLOCK).flatten.uniq.sort,
          "includes" => text.scan(TWIG_INCLUDE).flatten.uniq.sort
        }
      end

      def extract_erb(text)
        # ERB acts a lot like Twig here — extract partial renders.
        renders = text.scan(/render\s+['"]([^'"]+)['"]/).flatten.uniq
        { "renders" => renders }
      end

      SQL_CREATE = /create\s+(?:unique\s+)?(table|index|view|trigger|sequence|procedure|function)\s+(?:if\s+not\s+exists\s+)?([A-Za-z_][\w.]*)/i.freeze
      SQL_ALTER  = /alter\s+(table|index|view)\s+([A-Za-z_][\w.]*)/i.freeze

      def extract_sql(text)
        out = { "creates" => [], "alters" => [] }
        text.scan(SQL_CREATE) { |kind, name| out["creates"] << "#{kind.upcase} #{name}" }
        text.scan(SQL_ALTER)  { |kind, name| out["alters"]  << "#{kind.upcase} #{name}" }
        out
      end

      JS_EXPORT = /^\s*export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z_$][\w$]*)/.freeze
      JS_IMPORT = /^\s*import\s+[^'"]+?['"]([^'"]+)['"]/.freeze

      def extract_js_ts(text)
        {
          "exports" => text.scan(JS_EXPORT).flatten.uniq.sort,
          "imports" => text.scan(JS_IMPORT).flatten.uniq.sort
        }
      end

      MD_H1 = /^#\s+(.+)$/.freeze
      MD_H2 = /^##\s+(.+)$/.freeze

      def extract_md(text)
        {
          "title"    => (text[MD_H1, 1] || "").strip,
          "sections" => text.scan(MD_H2).flatten.first(30)
        }
      end

      def extract_generic(text)
        text.each_line do |line|
          s = line.strip
          next if s.empty? || s.start_with?("<!--")
          return { "first_line" => s[0, 200] }
        end
        {}
      end

      EXTRACTORS = {
        ".rb"   => :extract_ruby,
        ".rake" => :extract_ruby,
        ".erb"  => :extract_erb,
        ".twig" => :extract_twig,
        ".html" => :extract_twig,
        ".sql"  => :extract_sql,
        ".js"   => :extract_js_ts,
        ".mjs"  => :extract_js_ts,
        ".ts"   => :extract_js_ts,
        ".md"   => :extract_md
      }.freeze

      LANGUAGES = {
        ".rb" => "ruby", ".rake" => "ruby",
        ".erb" => "erb", ".twig" => "twig", ".html" => "html",
        ".sql" => "sql", ".scss" => "scss", ".css" => "css",
        ".js" => "javascript", ".mjs" => "javascript", ".ts" => "typescript",
        ".md" => "markdown", ".json" => "json", ".yml" => "yaml",
        ".yaml" => "yaml", ".toml" => "toml", ".env" => "env"
      }.freeze

      def language_for(path)
        LANGUAGES[File.extname(path)] || "text"
      end

      # ── Index core ───────────────────────────────────────────

      def extract(path)
        stat = File.stat(path)
        rel  = path.sub("#{project_root}/", "")
        entry = {
          "path"     => rel,
          "size"     => stat.size,
          "mtime"    => stat.mtime.to_i,
          "language" => language_for(path)
        }
        return entry.merge("skipped" => "too large (#{stat.size} bytes)") if stat.size > MAX_FILE_BYTES

        text = begin
          File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
        rescue StandardError
          return entry
        end
        entry["sha256"] = Digest::SHA256.hexdigest(text)[0, 16]
        ext = File.extname(path)
        extractor = EXTRACTORS[ext]
        begin
          data = extractor ? send(extractor, text) : extract_generic(text)
          entry.merge!(data) if data.is_a?(Hash)
        rescue StandardError => e
          entry["extraction_error"] = e.message[0, 200]
        end
        entry["summary"] = summarise(entry)
        entry
      rescue Errno::ENOENT, Errno::EACCES
        {}
      end

      def summarise(entry)
        return entry["skipped"] if entry["skipped"]
        return entry["docstring"] if entry["docstring"] && !entry["docstring"].to_s.empty?
        return entry["title"]     if entry["title"] && !entry["title"].to_s.empty?
        if entry["routes"] && !entry["routes"].empty?
          r = entry["routes"][0]
          extra = entry["routes"].size > 1 ? " (+#{entry["routes"].size - 1} more)" : ""
          return "#{r["method"]} #{r["path"]}#{extra}"
        end
        return "defines " + entry["symbols"].first(4).join(", ") if entry["symbols"] && !entry["symbols"].empty?
        return "exports " + entry["exports"].first(4).join(", ") if entry["exports"] && !entry["exports"].empty?
        return "schema: " + entry["creates"].first(3).join(", ") if entry["creates"] && !entry["creates"].empty?
        return "template, extends #{entry["extends"][0]}" if entry["extends"] && !entry["extends"].empty?
        return entry["first_line"] if entry["first_line"]
        ""
      end

      def walk_project
        root = project_root
        found = []
        prefix_len = root.length + 1
        walker = lambda do |dir|
          Dir.each_child(dir) do |name|
            next if name == "." || name == ".."
            # Skip hidden dirs (allow .env as a file below)
            full = File.join(dir, name)
            if File.directory?(full)
              next if SKIP_DIRS.include?(name)
              next if name.start_with?(".")
              walker.call(full)
            elsif File.file?(full)
              if name.start_with?(".")
                next unless name == ".env"
              end
              ext = File.extname(name)
              next unless INDEX_EXT.include?(ext) || name == ".env"
              found << full
            end
          end
        rescue Errno::EACCES, Errno::ENOENT
          # skip
        end
        walker.call(root)
        found
      end

      def load_raw
        p = index_path
        return { "version" => 1, "files" => {}, "generated_at" => 0 } unless File.exist?(p)
        JSON.parse(File.read(p, encoding: "utf-8"))
      rescue StandardError
        { "version" => 1, "files" => {}, "generated_at" => 0 }
      end

      def save_raw(data)
        data["generated_at"] = Time.now.to_i
        File.write(index_path, JSON.pretty_generate(data), encoding: "utf-8")
      end

      def refresh
        data = load_raw
        files = data["files"] || {}
        added = 0
        updated = 0
        seen = {}
        root = project_root

        walk_project.each do |p|
          rel = p.sub("#{root}/", "")
          seen[rel] = true
          begin
            mtime = File.mtime(p).to_i
          rescue Errno::ENOENT
            next
          end
          existing = files[rel]
          if existing && existing["mtime"] == mtime
            next
          end
          files[rel] = extract(p)
          if existing
            updated += 1
          else
            added += 1
          end
        end

        removed_paths = files.keys - seen.keys
        removed_paths.each { |k| files.delete(k) }
        data["files"] = files
        save_raw(data)
        {
          "added"   => added,
          "updated" => updated,
          "removed" => removed_paths.size,
          "total"   => files.size,
          "path"    => index_path.sub("#{root}/", "")
        }
      end

      def search(query, limit = 20)
        refresh
        data = load_raw
        q = query.to_s.downcase.strip
        return [] if q.empty?
        hits = []
        data["files"].each do |rel, entry|
          score = 0
          score += 10 if rel.downcase.include?(q)
          (entry["symbols"] || []).each do |s|
            sl = s.downcase
            if sl == q
              score += 8
            elsif sl.include?(q)
              score += 4
            end
          end
          (entry["routes"] || []).each do |r|
            combined = "#{r["path"]} #{r["handler"]}".downcase
            score += 5 if combined.include?(q)
          end
          score += 3 if (entry["summary"] || "").downcase.include?(q)
          (entry["imports"] || []).each { |imp| score += 1 if imp.downcase.include?(q) }
          if score.positive?
            hits << [score, {
              "path"     => rel,
              "summary"  => entry["summary"] || "",
              "score"    => score,
              "language" => entry["language"] || ""
            }]
          end
        end
        hits.sort_by! { |h| -h[0] }
        hits.first([1, limit].max).map { |_, info| info }
      end

      def file_entry(rel_path)
        refresh
        data = load_raw
        entry = data["files"][rel_path]
        entry || { "error" => "Not in index: #{rel_path}" }
      end

      def overview
        refresh
        data = load_raw
        files = data["files"]
        langs = Hash.new(0)
        route_count = 0
        model_count = 0
        files.each_value do |e|
          langs[e["language"] || "other"] += 1
          route_count += (e["routes"] || []).size
          path = e["path"].to_s
          if (path.start_with?("src/orm/") || path.start_with?("orm/") || path.start_with?("app/models/")) && (e["symbols"] && !e["symbols"].empty?)
            model_count += 1
          end
        end
        recent = files.values.map do |e|
          { "path" => e["path"], "summary" => e["summary"] || "", "mtime" => e["mtime"] || 0 }
        end.sort_by { |e| -(e["mtime"] || 0) }.first(10)
        {
          "total_files"        => files.size,
          "by_language"        => langs,
          "routes_declared"    => route_count,
          "orm_models"         => model_count,
          "recently_changed"   => recent,
          "index_generated_at" => data["generated_at"] || 0
        }
      end
    end
  end
end
