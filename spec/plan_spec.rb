# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "tina4/plan"

RSpec.describe Tina4::Plan do
  around(:each) do |ex|
    Dir.mktmpdir("tina4plan") do |tmp|
      Dir.chdir(tmp) { ex.run }
    end
  end

  describe "parse + render round-trip" do
    it "preserves title, goal, steps, and notes" do
      src = "# Build ducks\n\nGoal: track duck sightings\n\n## Steps\n\n- [x] Create model\n- [ ] Add routes\n\n## Notes\n\n- Remember to index sighted_at\n"
      parsed = described_class.parse(src)
      expect(parsed["title"]).to eq("Build ducks")
      expect(parsed["goal"]).to eq("track duck sightings")
      expect(parsed["steps"].size).to eq(2)
      expect(parsed["steps"][0]).to eq({ "text" => "Create model", "done" => true })
      expect(parsed["steps"][1]).to eq({ "text" => "Add routes", "done" => false })
      expect(parsed["notes"]).to include("Remember to index sighted_at")

      rendered = described_class.render(parsed)
      reparsed = described_class.parse(rendered)
      expect(reparsed).to eq(parsed)
    end
  end

  describe ".create" do
    it "writes a plan file, makes it current, lists it" do
      res = described_class.create("Add ducks", goal: "track sightings", steps: ["one", "two"])
      expect(res["ok"]).to be true
      expect(res["is_current"]).to be true
      expect(File).to exist(File.join("plan", res["name"]))
      expect(described_class.current_name).to eq(res["name"])
      plans = described_class.list_plans
      expect(plans.size).to eq(1)
      expect(plans.first["steps_total"]).to eq(2)
      expect(plans.first["steps_done"]).to eq(0)
      expect(plans.first["is_current"]).to be true
    end

    it "refuses duplicate titles" do
      described_class.create("Dup")
      res = described_class.create("Dup")
      expect(res["ok"]).to be false
      expect(res["error"]).to include("already exists")
    end

    it "rejects empty titles" do
      expect(described_class.create("")["ok"]).to be false
    end
  end

  describe ".complete_step / .uncomplete_step / .add_step" do
    before do
      described_class.create("P", steps: ["a", "b"])
    end

    it "ticks a step and reports next_step" do
      r = described_class.complete_step(0)
      expect(r["ok"]).to be true
      expect(r["completed"]).to eq("a")
      expect(r["next_step"]).to eq("b")
      expect(r["remaining"]).to eq(1)
    end

    it "guards out-of-range indexes" do
      expect(described_class.complete_step(99)["ok"]).to be false
    end

    it "unchecks a step" do
      described_class.complete_step(0)
      expect(described_class.uncomplete_step(0)["ok"]).to be true
      expect(described_class.current["steps"][0]["done"]).to be false
    end

    it "adds a new unchecked step" do
      r = described_class.add_step("c")
      expect(r["ok"]).to be true
      expect(r["index"]).to eq(2)
      expect(described_class.current["steps"].size).to eq(3)
    end
  end

  describe ".append_note" do
    it "appends a timestamped note" do
      described_class.create("Q")
      described_class.append_note("hello")
      expect(described_class.current["notes"]).to include("hello")
    end
  end

  describe ".record_action + .summarise_execution" do
    it "groups created/patched/migrations and dedupes" do
      described_class.create("Ledger")
      described_class.record_action("created", "src/orm/A.rb")
      described_class.record_action("patched", "src/orm/A.rb")
      described_class.record_action("patched", "src/orm/A.rb")
      described_class.record_action("migration", "migrations/001_add.sql", note: "add")
      summary = described_class.summarise_execution
      expect(summary["created"]).to eq(["src/orm/A.rb"])
      expect(summary["patched"]).to eq(["src/orm/A.rb"])
      expect(summary["migrations"]).to eq(["migrations/001_add.sql"])
      expect(summary["total"]).to eq(4)
    end

    it "is a no-op when no plan is current" do
      described_class.record_action("created", "whatever")
      expect(described_class.summarise_execution["total"]).to eq(0)
    end
  end

  describe ".archive" do
    it "moves plan to done/ and clears current" do
      described_class.create("X")
      name = described_class.current_name
      r = described_class.archive
      expect(r["ok"]).to be true
      expect(described_class.current_name).to eq("")
      expect(File).to exist(File.join("plan", "done", name))
    end
  end

  describe ".set_current / .clear_current" do
    it "errors on unknown plan" do
      res = described_class.set_current("missing")
      expect(res["ok"]).to be false
    end

    it "clears current pointer" do
      described_class.create("Y")
      described_class.clear_current
      expect(described_class.current).to eq({ "current" => nil })
    end
  end
end
