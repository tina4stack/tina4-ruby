# frozen_string_literal: true

# Real, no-mock tests for the native Context code/doc grounding subsystem.
#
# Parity port of tina4-python's tests/test_context.py. Every test uses a REAL
# temp SQLite file (Dir.mktmpdir) and REAL temp source files — there is nothing
# to mock. They pin the behaviours the subsystem promises:
#
#   1. ranking: a definition out-ranks a test that merely mentions the symbol
#      (source-over-tests + definition-first reorder over bm25());
#   2. reindex-on-change: index_path is an UPSERT — new content is found and the
#      file's old chunks are gone, with no row duplication;
#   3. reindex_file against a subdir index root: relabel + upsert, skip
#      outside-root / ineligible / skip-dir, drop-on-delete;
#   4. FTS5 availability guard: detected for real, and a Context that finds FTS5
#      absent degrades to safe no-ops instead of crashing;
#   5. result shape + score ordering + doc-as-prose + vendor-dir skipping;
#   6. the process-wide shared singleton;
#   7. the dev-reload trigger reindexes the changed file end-to-end;
#   8. the dev-MCP code_search tool over a real temp project.
#
# Symbol names are deliberately NON-OVERLAPPING (wombat/giraffe, whirligig/…)
# so they never cross-match on the FTS index and false-pass/false-fail.

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

RSpec.describe Tina4::Context do
  def write(root, rel, body)
    p = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, body)
    p
  end

  # ── 1. ranking — definition above a test that mentions the symbol ──────────
  describe "ranking" do
    it "ranks a definition above a test that merely mentions the symbol" do
      Dir.mktmpdir do |tmp|
        src_root = File.join(tmp, "app")
        write(src_root, "src/auth.rb",
              "def issue_token(user)\n" \
              "  # issue an auth token for a user\n" \
              "  sign(user)\nend\n")
        # a test file that MENTIONS issue_token many times (BM25 loves this) but
        # does not DEFINE it — it must not out-rank the definition.
        write(src_root, "tests/test_auth.rb",
              "def test_issue_token\n" \
              "  assert issue_token(1)\n" \
              "  assert issue_token(2)\n" \
              "  assert issue_token(3)\n" \
              "  assert issue_token(4)\nend\n")

        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        n = ctx.index_root(src_root)
        expect(n).to be > 0

        res = ctx.search("issue_token", k: 5)
        paths = res.map { |r| r[:path] }
        # both files surface
        expect(paths).to(satisfy { |ps| ps.any? { |p| p.end_with?("auth.rb") && !p.include?("test") } })
        expect(paths).to(satisfy { |ps| ps.any? { |p| p.include?("test_auth") } })
        # the definition (non-test source) ranks ABOVE the test file
        src_idx  = res.index { |r| r[:path].end_with?("auth.rb") && !r[:path].include?("test") }
        test_idx = res.index { |r| r[:path].include?("test_auth") }
        expect(src_idx).to be < test_idx
        # and the very top hit is the definition, not the test
        expect(res.first[:path]).not_to include("test")
        ctx.close
      end
    end

    it "ranks a definition above a non-test file that only calls the symbol" do
      Dir.mktmpdir do |tmp|
        src_root = File.join(tmp, "app")
        write(src_root, "src/animals.rb", "def wombat\n  :marsupial\nend\n")
        write(src_root, "src/caller.rb",
              "def elsewhere\n  wombat\n  wombat\n  wombat\n  wombat\nend\n")

        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(src_root)
        res = ctx.search("wombat", k: 5)
        expect(res.first[:path]).to end_with("animals.rb")
        ctx.close
      end
    end
  end

  # ── 2. reindex-on-change — UPSERT: new found, old gone, no duplication ─────
  describe "index_path UPSERT" do
    it "finds new content, drops old, and never duplicates rows" do
      Dir.mktmpdir do |tmp|
        f = write(tmp, "app/src/mod.rb", "def wombat\n  1\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_path(f, label: "src/mod.rb")

        expect(ctx.search("wombat").any? { |r| r[:path] == "src/mod.rb" }).to be true
        rows_before = ctx.count

        File.write(f, "def giraffe\n  2\nend\n")
        ctx.index_path(f, label: "src/mod.rb")

        expect(ctx.search("giraffe").any? { |r| r[:path] == "src/mod.rb" }).to be true
        expect(ctx.search("wombat").any? { |r| r[:path] == "src/mod.rb" }).to be false
        expect(ctx.count).to eq(rows_before) # delete-then-insert, not append
        ctx.close
      end
    end

    it "re-indexing an unchanged file does not append duplicates" do
      Dir.mktmpdir do |tmp|
        f = write(tmp, "app/src/dup.rb", "def only_one\n  42\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_path(f, label: "src/dup.rb")
        n1 = ctx.count
        ctx.index_path(f, label: "src/dup.rb")
        expect(ctx.count).to eq(n1)
        ctx.close
      end
    end
  end

  # ── 3. FTS5 availability guard ─────────────────────────────────────────────
  describe "FTS5 availability" do
    it "reports FTS5 as available on this Ruby's sqlite3 build" do
      expect(described_class.fts5_available?).to be true
    end

    it "degrades to safe no-ops when FTS5 is absent" do
      Dir.mktmpdir do |tmp|
        write(tmp, "app/src/x.rb", "def y\n  1\nend\n")
        # inject a predicate that reports FTS5 as ABSENT — exercises the real
        # graceful-degradation branch (no mocking of sqlite or files).
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"), fts5_check: -> { false })
        expect(ctx.available).to be false
        expect(ctx.index_root(File.join(tmp, "app"))).to eq(0)
        expect(ctx.index_path(File.join(tmp, "app", "src", "x.rb"), label: "src/x.rb")).to eq(0)
        expect(ctx.search("anything")).to eq([])
        ctx.close

        ok = described_class.new(File.join(tmp, ".tina4", "ok.db"))
        expect(ok.available).to be true
        ok.close
      end
    end
  end

  # ── 4. result shape, score ordering, doc chunking, dir skipping ────────────
  describe "search result shape + ordering" do
    it "returns {path,score,snippet} sorted by descending score" do
      Dir.mktmpdir do |tmp|
        src_root = File.join(tmp, "app")
        write(src_root, "src/widget.rb",
              "def build_widget(spec)\n  Widget.new(spec)\nend\n\n" \
              "class Widget\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(src_root)

        res = ctx.search("build_widget", k: 5)
        expect(res).not_to be_empty
        res.each do |r|
          expect(r.keys).to include(:path, :score, :snippet)
          expect(r[:score]).to be_a(Float)
          expect(r[:snippet]).to be_a(String)
          expect(r[:snippet]).not_to be_empty
        end
        scores = res.map { |r| r[:score] }
        expect(scores).to eq(scores.sort.reverse) # higher = better, descending
        ctx.close
      end
    end

    it "indexes docs as prose and skips vendor/runtime dirs" do
      Dir.mktmpdir do |tmp|
        src_root = File.join(tmp, "app")
        write(src_root, "docs/guide.md",
              "# Overview\n\nThe whirligig subsystem manages the flux capacitor " \
              "and its temporal bindings.\n")
        # these live under dirs the walk skips — they must NOT be indexed
        write(src_root, "__pycache__/junk.rb", "def whirligig_flux_capacitor; end\n")
        write(src_root, "node_modules/lib.js", "function whirligigFluxCapacitor(){}\n")

        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(src_root)

        res = ctx.search("whirligig flux capacitor", k: 5)
        paths = res.map { |r| r[:path] }
        expect(paths.any? { |p| p.end_with?("guide.md") }).to be true
        expect(paths.any? { |p| p.include?("__pycache__") }).to be false
        expect(paths.any? { |p| p.include?("node_modules") }).to be false
        ctx.close
      end
    end

    it "returns empty for an empty or stopword-only query" do
      Dir.mktmpdir do |tmp|
        write(tmp, "app/src/a.rb", "def a\n  1\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(File.join(tmp, "app"))
        expect(ctx.search("")).to eq([])
        expect(ctx.search("   ")).to eq([])
        ctx.close
      end
    end
  end

  # ── 5. reindex_file — UPSERT against a subdir index root ───────────────────
  describe "#reindex_file" do
    it "relabels and upserts a project-root-relative path against a subdir root" do
      Dir.mktmpdir do |tmp|
        write(tmp, "src/mod.rb", "def wombat\n  1\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(File.join(tmp, "src")) # root = src/, label = "mod.rb"
        expect(ctx.search("wombat").any? { |r| r[:path] == "mod.rb" }).to be true

        File.write(File.join(tmp, "src", "mod.rb"), "def giraffe\n  2\nend\n")
        Dir.chdir(tmp) do
          expect(ctx.reindex_file("src/mod.rb")).to be >= 1 # project-root-relative
        end
        expect(ctx.search("giraffe").any? { |r| r[:path] == "mod.rb" }).to be true
        expect(ctx.search("wombat").any? { |r| r[:path] == "mod.rb" }).to be false
        ctx.close
      end
    end

    it "skips files outside the root, ineligible files, and skip-dirs" do
      Dir.mktmpdir do |tmp|
        write(tmp, "src/a.rb", "def a\n  1\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(File.join(tmp, "src"))
        Dir.chdir(tmp) do
          write(tmp, "README.md", "# top-level, outside src/\n")
          expect(ctx.reindex_file("README.md")).to eq(-1) # outside the index root
          write(tmp, "src/data.bin", "x")
          expect(ctx.reindex_file("src/data.bin")).to eq(-1) # ineligible extension
          write(tmp, "src/__pycache__/j.rb", "def j; end\n")
          expect(ctx.reindex_file("src/__pycache__/j.rb")).to eq(-1) # skip-dir
        end
        ctx.close
      end
    end

    it "drops the chunks of a deleted file" do
      Dir.mktmpdir do |tmp|
        f = write(tmp, "src/gone.rb", "def unique_gone_sym\n  1\nend\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        ctx.index_root(File.join(tmp, "src"))
        expect(ctx.search("unique_gone_sym").any? { |r| r[:path] == "gone.rb" }).to be true
        File.unlink(f)
        Dir.chdir(tmp) do
          expect(ctx.reindex_file("src/gone.rb")).to eq(0) # delete → drop rows
        end
        expect(ctx.search("unique_gone_sym")).to eq([])
        ctx.close
      end
    end

    it "no-ops (-1) before index_root has run" do
      Dir.mktmpdir do |tmp|
        write(tmp, "src/a.rb", "def a; end\n")
        ctx = described_class.new(File.join(tmp, ".tina4", "context.db"))
        Dir.chdir(tmp) { expect(ctx.reindex_file("src/a.rb")).to eq(-1) }
        ctx.close
      end
    end
  end

  # ── 6. process-wide shared singleton ───────────────────────────────────────
  describe ".default_context / .existing_context" do
    it "is a shared singleton keyed by resolved db path" do
      described_class.clear_shared_contexts!
      Dir.mktmpdir do |tmp|
        db = File.join(tmp, ".tina4", "ctx.db")
        write(tmp, "src/x.rb", "def findme_sym\n  1\nend\n")
        a = described_class.default_context(root: File.join(tmp, "src"), db: db)
        expect(described_class.default_context(db: db)).to equal(a) # same db → same instance
        expect(described_class.existing_context(db: db)).to equal(a)
        expect(described_class.existing_context(db: File.join(tmp, "nope.db"))).to be_nil
        expect(a.search("findme_sym").any? { |r| r[:path].include?("x.rb") }).to be true
      end
      described_class.clear_shared_contexts!
    end
  end

  # ── 7. the dev-reload TRIGGER reindexes the changed file end-to-end ────────
  describe "dev-reload trigger integration" do
    it "reindexes the changed file into the shared Context on POST /__dev/api/reload" do
      described_class.clear_shared_contexts!
      old_debug = ENV["TINA4_DEBUG"]
      ENV["TINA4_DEBUG"] = "true"
      Dir.mktmpdir do |tmp|
        src = File.join(tmp, "src")
        FileUtils.mkdir_p(src)
        File.write(File.join(src, "mod.rb"), "def wombat\n  1\nend\n")

        Dir.chdir(tmp) do
          # build the shared index the way code_search does (cwd/.tina4/context.db)
          ctx = described_class.default_context(root: src)
          expect(ctx.search("wombat").any? { |r| r[:path] == "mod.rb" }).to be true

          # edit, then FIRE the reload trigger with the changed file (real request)
          File.write(File.join(src, "mod.rb"), "def giraffe\n  2\nend\n")
          env = {
            "PATH_INFO" => "/__dev/api/reload",
            "REQUEST_METHOD" => "POST",
            "rack.input" => StringIO.new(JSON.generate({ "file" => "src/mod.rb", "type" => "reload" }))
          }
          status, = Tina4::DevAdmin.handle_request(env)
          expect(status).to eq(200)

          expect(ctx.search("giraffe").any? { |r| r[:path] == "mod.rb" }).to be true
          expect(ctx.search("wombat").any? { |r| r[:path] == "mod.rb" }).to be false
        end
      end
    ensure
      old_debug.nil? ? ENV.delete("TINA4_DEBUG") : (ENV["TINA4_DEBUG"] = old_debug)
      described_class.clear_shared_contexts!
    end
  end

  # ── 8. dev-MCP code_search tool — real registration over a temp project ────
  describe "dev-MCP code_search tool" do
    def call(server, name, arguments = {})
      JSON.parse(server.handle_message({
        "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => name, "arguments" => arguments }
      }))
    end

    it "is registered as a sibling of api_search and finds a symbol" do
      described_class.clear_shared_contexts!
      Dir.mktmpdir do |tmp|
        FileUtils.mkdir_p(File.join(tmp, "src"))
        File.write(File.join(tmp, "src", "service.rb"),
                   "def widget_factory(name)\n" \
                   "  # create a configured widget\n" \
                   "  { name: name }\nend\n")
        old_cwd = Dir.pwd
        Dir.chdir(tmp)
        begin
          server = Tina4::McpServer.new("/test-code-search", name: "code_search test")
          Tina4::McpDevTools.register(server)

          listed = JSON.parse(server.handle_message({
            "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => {}
          }))
          names = listed["result"]["tools"].map { |t| t["name"] }
          expect(names).to include("code_search")

          resp = call(server, "code_search", { "query" => "widget_factory" })
          expect(resp).to have_key("result")
          payload = JSON.parse(resp["result"]["content"].first["text"])
          expect(payload).to be_an(Array)
          expect(payload.map { |r| r["path"] }.any? { |p| p.end_with?("service.rb") }).to be true
        ensure
          Dir.chdir(old_cwd)
          described_class.clear_shared_contexts!
        end
      end
    end
  end
end
