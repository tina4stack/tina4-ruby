# frozen_string_literal: true
#
# ADR-0063 (3.13.121): twig-scanner parity for `tina4ruby generate` — the
# EDIT_MARKER_RE now matches THREE comment styles (Ruby `#`, SQL `--`, and
# Twig `{# ... #}`), so the `form` and `view` generators — which have baked
# `{# tina4:edit ... #}` markers into their Twig templates since 3.13.119 —
# join model / migration / middleware / route in populating
# `resolution.edit_hints[]` under the `generate_v1_1` envelope.
#
# Contract stays generate_v1_1: this is ADDITIVE scanner coverage (a wider
# regex + form/view joining the resolution-aware set), not a new envelope
# version. `commands --json` still reports resolution_contract = { version:
# "1.1", envelope: "generate_v1_1" } (verified in generate_envelope_v1_1_spec.rb).
#
# Every case runs the REAL `exe/tina4ruby` in a fresh temp cwd via
# `Open3.capture3`. NO mocks: real generator, real markers, real filesystem
# scan, real subprocess. Mirrors the tina4-php parity behavior — its
# collectEditHintsFromContent already covers `//` / `--` / `{# ... #}`.
#
# The mutation gate (example 4) is the proof the scanner LINE ITSELF gates
# the hint: strip a twig marker from a generated file and re-scan; the
# corresponding edit_hint disappears. Restore the marker and it returns.
# A test that would pass on either version of the file is not proof — it
# must go red when the guarded behaviour is removed.

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "json"

# Load the CLI in-process so example 4's mutation gate can call
# scan_edit_hints_from_files directly (that IS the scanner under test).
require "tina4/cli"

RSpec.describe "tina4ruby generate — twig edit-hint scanner (ADR-0063, 3.13.121)" do
  def run_generate(*args)
    Open3.capture3(RUBY_BIN, EXE, "generate", *args, chdir: @project_root)
  end

  around(:each) do |ex|
    Dir.mktmpdir("tina4_twig_edit_hints") do |dir|
      @project_root = dir
      ex.run
    end
  end

  # ── 1. Positive twig scan: generate form → edit_hints[] carries the twig marker ──

  describe "1. `generate form MyForm --json --dry-run` surfaces the baked twig marker" do
    it "envelope's resolution.edit_hints[] is NON-EMPTY and the label comes from the twig comment" do
      stdout, stderr, status = run_generate("form", "MyForm", "--json", "--dry-run")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      expect(envelope["command"]).to eq("generate")
      expect(envelope["target"]).to eq("form")
      expect(envelope["dry_run"]).to be true
      expect(envelope["actions_taken"]).to eq([])

      resolution = envelope["resolution"]
      expect(resolution).to include(
        "class_name", "table_name", "file_path", "migration_path",
        "transformations", "routes", "test_paths", "next", "edit_hints"
      )
      expect(resolution["class_name"]).to eq("MyForm")
      expect(resolution["file_path"]).to eq("src/templates/forms/my_form.twig")

      # Shape check on every edit_hint entry.
      expect(resolution["edit_hints"]).to be_an(Array)
      expect(resolution["edit_hints"]).not_to be_empty
      resolution["edit_hints"].each do |hint|
        expect(hint).to include("file", "line", "label")
        expect(hint["file"]).to be_a(String).and end_with(".twig")
        expect(hint["line"]).to be_an(Integer).and be > 0
        expect(hint["label"]).to be_a(String)
        expect(hint["label"]).not_to be_empty
        # The label must NOT carry the twig closing marker — proves the
        # scanner's optional-tail (?:\s*#\})? cleaned it before capture.
        expect(hint["label"]).not_to match(/#\}\s*$/),
                                    "twig closer bled into label: #{hint['label'].inspect}"
      end

      # The twig-comment label from the form template appears verbatim.
      labels = resolution["edit_hints"].map { |h| h["label"] }
      expect(labels).to include("restyle the form beyond the scaffolded defaults")

      # Files listed name the twig template — not a Ruby file (proves the
      # scanner picked twig markers, not Ruby `#`).
      files = resolution["edit_hints"].map { |h| h["file"] }
      expect(files).to all(end_with(".twig"))
      expect(files).to include("src/templates/forms/my_form.twig")

      # --dry-run really writes nothing.
      expect(Dir.exist?(File.join(@project_root, "src"))).to be false
    end
  end

  # ── 1b. Same contract for `generate view MyView` — TWO twig files ──

  describe "1b. `generate view MyView --json --dry-run` surfaces markers from BOTH twig templates" do
    it "envelope carries edit_hints from BOTH the list and detail twig templates" do
      stdout, stderr, status = run_generate("view", "MyView", "--json", "--dry-run")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      expect(envelope["target"]).to eq("view")

      resolution = envelope["resolution"]
      expect(resolution["class_name"]).to eq("MyView")
      # List view = plural (route name); detail view = singular (class snake).
      expect(resolution["file_path"]).to eq("src/templates/pages/my_views.twig")

      expect(resolution["edit_hints"]).to be_an(Array)
      expect(resolution["edit_hints"].size).to be >= 2

      # Every file cited is a .twig file — no Ruby leakage.
      files = resolution["edit_hints"].map { |h| h["file"] }
      expect(files).to include("src/templates/pages/my_views.twig")
      expect(files).to include("src/templates/pages/my_view.twig")
      expect(files).to all(end_with(".twig"))

      # Both twig-comment labels surface verbatim.
      labels = resolution["edit_hints"].map { |h| h["label"] }
      expect(labels).to include("add sort / filter / pagination controls to the list")
      expect(labels).to include("extend the detail view with related records or actions")

      # No twig closer bled through on any label.
      labels.each do |lbl|
        expect(lbl).not_to match(/#\}\s*$/), "twig closer bled into label: #{lbl.inspect}"
      end
    end
  end

  # ── 2. Mutation gate: strip the twig marker → edit_hint disappears ──

  describe "2. mutation gate — stripping the twig marker removes the hint; restoring returns it" do
    # The scanner is `Tina4::CLI#scan_edit_hints_from_files`. We generate a
    # real form file (no dry-run) so we have a concrete twig template on
    # disk, then scan that file directly. Strip the marker line, re-scan,
    # assert the entry disappears. Restore, re-scan, assert it returns.
    # This is a real end-to-end proof the regex line drives the hint —
    # a test that would pass on either version of the file is not proof.
    # scan_edit_hints_from_files is a private instance method of Tina4::CLI
    # (nothing under `private` since line 175 in lib/tina4/cli.rb is a public
    # helper). The mutation gate reaches it via #send — we are proving the
    # regex covers the twig line, not the visibility contract.
    it "scan_edit_hints_from_files goes red when the twig marker line is stripped, green when restored" do
      _stdout, stderr, status = run_generate("form", "MyForm")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"

      form_path = File.join(@project_root, "src", "templates", "forms", "my_form.twig")
      expect(File.file?(form_path)).to be(true), "generate form did not write the twig file"

      original_content = File.read(form_path)
      expect(original_content).to include("{# tina4:edit"),
                                  "form template did not bake a twig marker (test premise dead)"

      cli = Tina4::CLI.new

      # Baseline scan on the real file — the twig marker fires.
      baseline_hints = cli.send(:scan_edit_hints_from_files, [form_path])
      expect(baseline_hints).not_to be_empty
      expect(baseline_hints.first["file"]).to eq(form_path)
      expect(baseline_hints.first["label"])
        .to eq("restyle the form beyond the scaffolded defaults")
      original_hint_count = baseline_hints.size

      # MUTATE: strip the twig marker line (replace with an empty line so
      # subsequent line numbers stay stable in case we ever assert on them).
      lines = original_content.each_line.to_a
      marker_idx = lines.index { |l| l =~ /\{#\s*tina4:edit/ }
      expect(marker_idx).not_to be_nil, "no twig marker line found in the generated template"
      mutated_lines = lines.dup
      mutated_lines[marker_idx] = "\n"
      File.write(form_path, mutated_lines.join)

      mutated_hints = cli.send(:scan_edit_hints_from_files, [form_path])
      expect(mutated_hints.size).to eq(original_hint_count - 1),
                                    "stripping the twig marker did not remove exactly one edit_hint " \
                                    "(baseline=#{original_hint_count}, mutated=#{mutated_hints.size})"
      mutated_labels = mutated_hints.map { |h| h["label"] }
      expect(mutated_labels).not_to include("restyle the form beyond the scaffolded defaults")

      # RESTORE and prove the hint returns — a green mutation with no red
      # restore would mean the regex never fires either way (a ghost test).
      File.write(form_path, original_content)
      restored_hints = cli.send(:scan_edit_hints_from_files, [form_path])
      expect(restored_hints.size).to eq(original_hint_count)
      restored_labels = restored_hints.map { |h| h["label"] }
      expect(restored_labels).to include("restyle the form beyond the scaffolded defaults")
    end
  end

  # ── 3. Regression: model + migration edit_hints still populate ──

  describe "3. regression — model + migration scanners still populate edit_hints[]" do
    # The change is additive (widen the regex + form/view join resolution-aware).
    # Ruby `# tina4:edit` and SQL `-- tina4:edit` markers must keep firing.
    it "generate model Foo still emits Ruby + SQL edit_hints under generate_v1_1" do
      stdout, stderr, status = run_generate("model", "Foo", "--json", "--dry-run")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      resolution = envelope["resolution"]

      files = resolution["edit_hints"].map { |h| h["file"] }
      # Ruby model file surfaces via a `#`-style marker.
      expect(files).to include("src/orm/foo.rb")
      # SQL migration file surfaces via a `--`-style marker.
      expect(files.any? { |f| f =~ %r{migrations/\d+_create_foo\.sql} }).to be(true),
                                                                            "no create-migration edit_hint: #{files.inspect}"

      # None of these should be twig files.
      expect(files.none? { |f| f.end_with?(".twig") }).to be(true)

      # Ruby-style label from the model template surfaces intact.
      labels = resolution["edit_hints"].map { |h| h["label"] }
      expect(labels).to include("add fields beyond the default 'name'")
      # SQL-style label from the migration surfaces intact.
      expect(labels).to include("add columns beyond id + created_at")
    end

    it "generate migration alter_foo still emits SQL edit_hints (--- style)" do
      stdout, stderr, status = run_generate("migration", "alter_foo", "--json", "--dry-run")

      expect(status.exitstatus).to eq(0), "stderr: #{stderr}"
      envelope = JSON.parse(stdout)
      resolution = envelope["resolution"]

      files = resolution["edit_hints"].map { |h| h["file"] }
      expect(files.any? { |f| f =~ %r{migrations/\d+_alter_foo\.sql} }).to be(true),
                                                                          "no alter migration hint: #{files.inspect}"

      # Every migration hint file is .sql, not .twig.
      expect(files.all? { |f| f.end_with?(".sql") }).to be(true)
    end
  end
end
