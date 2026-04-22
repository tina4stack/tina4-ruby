# frozen_string_literal: true

# Tina4::Plan — project plan storage + manipulation, ported from
# tina4_python/dev_admin/plan.py. Plan files are canonical markdown
# under plan/ at the project root; exactly one plan is "current"
# (filename stored in plan/.current).
#
# File format is byte-for-byte identical to the Python reference —
# title (# Title), optional "Goal: ...", "## Steps" with "- [ ]" /
# "- [x]" checkboxes, and optional "## Notes" trailer.

require "json"
require "fileutils"
require "net/http"
require "uri"

module Tina4
  module Plan
    PLAN_DIR       = "plan"
    CURRENT_FILE   = ".current"
    ARCHIVE_SUBDIR = "done"

    STEP_RE = /\A\s*[-*]\s*\[(?<box>[ xX])\]\s*(?<text>.+?)\s*\z/.freeze

    class << self
      # ── Paths ──────────────────────────────────────────────────

      def project_root
        File.expand_path(Dir.pwd)
      end

      def plan_dir
        p = File.join(project_root, PLAN_DIR)
        FileUtils.mkdir_p(p)
        p
      end

      def current_pointer
        File.join(plan_dir, CURRENT_FILE)
      end

      def archive_dir
        p = File.join(plan_dir, ARCHIVE_SUBDIR)
        FileUtils.mkdir_p(p)
        p
      end

      def slugify(title)
        slug = title.to_s.strip.downcase.gsub(/[^a-z0-9_\-]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = slug[0, 80]
        slug.empty? ? "plan-#{Time.now.to_i}" : slug
      end

      # ── Parse / render ─────────────────────────────────────────

      def parse(text)
        lines = text.to_s.split("\n", -1)
        title = ""
        goal  = ""
        steps = []
        notes_lines = []
        section = nil # :steps | :notes | :other | nil

        lines.each do |raw|
          line = raw.sub(/[[:space:]]+\z/, "")
          if title.empty? && line.start_with?("# ")
            title = line[2..].to_s.strip
            next
          end
          low = line.strip.downcase
          if low.start_with?("goal:") && goal.empty?
            goal = line.split(":", 2)[1].to_s.strip
            next
          end
          if low == "## steps"
            section = :steps
            next
          end
          if low == "## notes"
            section = :notes
            next
          end
          if line.start_with?("## ")
            section = :other
            next
          end
          if section == :steps
            m = STEP_RE.match(line)
            steps << { "text" => m[:text].strip, "done" => m[:box].downcase == "x" } if m
          elsif section == :notes && !line.strip.empty?
            notes_lines << line
          end
        end

        {
          "title" => title,
          "goal"  => goal,
          "steps" => steps,
          "notes" => notes_lines.join("\n").strip
        }
      end

      def render(plan)
        parts = ["# #{plan["title"] || "Untitled plan"}", ""]
        goal = plan["goal"]
        if goal && !goal.to_s.empty?
          parts << "Goal: #{goal}"
          parts << ""
        end
        parts << "## Steps"
        parts << ""
        (plan["steps"] || []).each do |s|
          box = s["done"] ? "x" : " "
          parts << "- [#{box}] #{(s["text"] || "").to_s.strip}"
        end
        notes = (plan["notes"] || "").strip
        if !notes.empty?
          parts << ""
          parts << "## Notes"
          parts << ""
          parts << notes
        end
        parts.join("\n") + "\n"
      end

      # ── Public API ─────────────────────────────────────────────

      def list_plans
        d = plan_dir
        cur = current_name || ""
        out = []
        Dir.glob(File.join(d, "*.md")).sort.each do |path|
          name = File.basename(path)
          parsed = parse(File.read(path, encoding: "utf-8"))
          total = parsed["steps"].size
          done  = parsed["steps"].count { |s| s["done"] }
          out << {
            "name"        => name,
            "title"       => parsed["title"].to_s.empty? ? File.basename(name, ".md") : parsed["title"],
            "steps_total" => total,
            "steps_done"  => done,
            "is_current"  => name == cur
          }
        end
        out
      end

      def current_name
        ptr = current_pointer
        return "" unless File.exist?(ptr)
        File.read(ptr, encoding: "utf-8").strip
      end

      def set_current(name)
        name = name.to_s.strip
        name += ".md" unless name.end_with?(".md")
        path = File.join(plan_dir, name)
        return { "ok" => false, "error" => "No such plan: #{name}" } unless File.exist?(path)
        File.write(current_pointer, name, encoding: "utf-8")
        { "ok" => true, "current" => name }
      end

      def clear_current
        File.delete(current_pointer) if File.exist?(current_pointer)
        { "ok" => true }
      end

      def current
        name = current_name
        return { "current" => nil } if name.empty?
        path = File.join(plan_dir, name)
        unless File.exist?(path)
          clear_current
          return { "current" => nil, "warning" => "Current pointer referenced missing file: #{name}" }
        end
        parsed = parse(File.read(path, encoding: "utf-8"))
        indexed = parsed["steps"].each_with_index.map do |s, i|
          { "index" => i, "text" => s["text"], "done" => s["done"] }
        end
        next_step = indexed.find { |s| !s["done"] }
        {
          "current"   => name,
          "title"     => parsed["title"],
          "goal"      => parsed["goal"],
          "steps"     => indexed,
          "next_step" => next_step,
          "notes"     => parsed["notes"],
          "progress"  => {
            "done"  => indexed.count { |s| s["done"] },
            "total" => indexed.size
          },
          "execution" => summarise_execution(name)
        }
      end

      def read(name)
        name = name.to_s
        name += ".md" unless name.end_with?(".md")
        path = File.join(plan_dir, name)
        return { "error" => "No such plan: #{name}" } unless File.exist?(path)
        parse(File.read(path, encoding: "utf-8")).merge("name" => name)
      end

      def create(title, goal: "", steps: nil, make_current: true)
        title = title.to_s.strip
        return { "ok" => false, "error" => "title is required" } if title.empty?
        name = "#{slugify(title)}.md"
        path = File.join(plan_dir, name)
        if File.exist?(path)
          return {
            "ok"    => false,
            "error" => "Plan already exists: #{name}. Pick a different title or edit the existing one."
          }
        end
        plan = {
          "title" => title,
          "goal"  => goal.to_s.strip,
          "steps" => (steps || []).map { |s| s.to_s.strip }.reject(&:empty?).map { |s| { "text" => s, "done" => false } },
          "notes" => ""
        }
        File.write(path, render(plan), encoding: "utf-8")
        File.write(current_pointer, name, encoding: "utf-8") if make_current
        { "ok" => true, "name" => name, "title" => title, "is_current" => make_current }
      end

      def complete_step(index, name = "")
        target = load_for_mutation(name)
        return target if target.is_a?(Hash) && target["ok"] == false
        path, plan = target
        steps = plan["steps"]
        if index.negative? || index >= steps.size
          return { "ok" => false, "error" => "Step index #{index} out of range (0..#{steps.size - 1})" }
        end
        steps[index]["done"] = true
        File.write(path, render(plan), encoding: "utf-8")
        remaining = steps.each_with_index.reject { |s, _| s["done"] }.map { |_, i| i }
        {
          "ok"        => true,
          "completed" => steps[index]["text"],
          "remaining" => remaining.size,
          "next_step" => remaining.empty? ? nil : steps[remaining.first]["text"]
        }
      end

      def uncomplete_step(index, name = "")
        target = load_for_mutation(name)
        return target if target.is_a?(Hash) && target["ok"] == false
        path, plan = target
        steps = plan["steps"]
        if index.negative? || index >= steps.size
          return { "ok" => false, "error" => "Step index #{index} out of range" }
        end
        steps[index]["done"] = false
        File.write(path, render(plan), encoding: "utf-8")
        { "ok" => true, "step" => steps[index]["text"] }
      end

      def add_step(text, name = "")
        text = text.to_s.strip
        return { "ok" => false, "error" => "text is required" } if text.empty?
        target = load_for_mutation(name)
        return target if target.is_a?(Hash) && target["ok"] == false
        path, plan = target
        plan["steps"] << { "text" => text, "done" => false }
        File.write(path, render(plan), encoding: "utf-8")
        { "ok" => true, "step" => text, "index" => plan["steps"].size - 1 }
      end

      def append_note(text, name = "")
        text = text.to_s.strip
        return { "ok" => false, "error" => "text is required" } if text.empty?
        target = load_for_mutation(name)
        return target if target.is_a?(Hash) && target["ok"] == false
        path, plan = target
        existing = (plan["notes"] || "").strip
        stamp = Time.now.strftime("%Y-%m-%d %H:%M")
        plan["notes"] = (existing + "\n- [#{stamp}] #{text}").strip
        File.write(path, render(plan), encoding: "utf-8")
        { "ok" => true, "appended" => text }
      end

      # ── Execution ledger ───────────────────────────────────────

      def ledger_path(name = "")
        name = name.to_s
        name = current_name if name.empty?
        return nil if name.empty?
        name += ".md" unless name.end_with?(".md")
        File.join(plan_dir, "#{name[0..-4]}.log.json")
      end

      def record_action(action, path, note: "")
        lp = ledger_path
        return nil if lp.nil?
        entries = []
        if File.exist?(lp)
          begin
            entries = JSON.parse(File.read(lp, encoding: "utf-8"))
          rescue StandardError
            entries = []
          end
        end
        entries << {
          "t"      => Time.now.to_i,
          "action" => action,
          "path"   => path,
          "note"   => note
        }
        entries = entries.last(500) if entries.size > 500
        begin
          File.write(lp, JSON.pretty_generate(entries), encoding: "utf-8")
        rescue StandardError
          # best-effort
        end
        nil
      end

      def summarise_execution(name = "")
        lp = ledger_path(name)
        empty = { "created" => [], "patched" => [], "migrations" => [], "total" => 0 }
        return empty if lp.nil? || !File.exist?(lp)
        begin
          entries = JSON.parse(File.read(lp, encoding: "utf-8"))
        rescue StandardError
          return empty
        end
        created = []
        patched = []
        migrations = []
        entries.each do |e|
          p = e["path"]
          next if p.nil?
          bucket = case e["action"]
                   when "migration" then migrations
                   when "created"   then created
                   when "patched"   then patched
                   end
          bucket << p if bucket && !bucket.include?(p)
        end
        {
          "created"    => created.last(20),
          "patched"    => patched.last(20),
          "migrations" => migrations.last(20),
          "total"      => entries.size
        }
      end

      # ── AI flesh-out ──────────────────────────────────────────

      def flesh(name = "", prompt = "")
        target = (name.to_s.strip.empty? ? current_name : name.to_s.strip)
        return { "ok" => false, "error" => "No current plan and no name given" } if target.empty?
        current_plan = read(target)
        return { "ok" => false, "error" => current_plan["error"] } if current_plan["error"]

        existing = (current_plan["steps"] || []).map { |s| s["text"].to_s }
        title = current_plan["title"].to_s.empty? ? target : current_plan["title"]
        goal = current_plan["goal"].to_s

        system_prompt = (
          "You are Tina4, a coding planner embedded in the Tina4 dev " \
          "admin. Return ONLY a JSON array of short imperative step " \
          "strings (no prose, no code-fences, no numbering). 3-8 steps, " \
          "each referencing concrete files/routes/migrations. Example: " \
          '["Create src/orm/Duck.rb with id/name/sighted_at", ' \
          '"Add migration 001_create_ducks.sql", ' \
          '"Add GET/POST/PUT/DELETE /api/ducks routes in src/routes/ducks.rb"]'
        )
        user_parts = ["Plan title: #{title}"]
        user_parts << "Goal: #{goal}" unless goal.empty?
        user_parts << "Existing steps (don't repeat):\n- " + existing.join("\n- ") unless existing.empty?
        user_parts << "Extra context from caller: #{prompt}" unless prompt.to_s.empty?
        user_parts << "Reply with ONLY the JSON array — no explanation, no markdown fences."

        ai_url = ENV.fetch("TINA4_AI_URL", "http://localhost:11437/api/chat")
        ai_model = ENV.fetch("TINA4_AI_MODEL", "qwen2.5-coder:14b")

        reply = begin
          uri = URI.parse(ai_url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 10
          http.read_timeout = 120
          req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
          req.body = JSON.generate({
            "model"    => ai_model,
            "stream"   => false,
            "messages" => [
              { "role" => "system", "content" => system_prompt },
              { "role" => "user",   "content" => user_parts.join("\n\n") }
            ]
          })
          resp = http.request(req)
          body = JSON.parse(resp.body)
          (body["message"].is_a?(Hash) ? body["message"]["content"] : nil) || body["response"] || ""
        rescue StandardError => e
          return { "ok" => false, "error" => "AI backend unreachable: #{e.message}" }
        end

        body = reply.to_s.strip
        if body.start_with?("```")
          body = body.gsub(/\A`+|`+\z/, "")
          body = body[4..].to_s.strip if body.downcase.start_with?("json")
          body = body.strip
        end

        proposed = []
        begin
          parsed = JSON.parse(body)
          proposed = parsed.map { |x| x.to_s.strip }.reject(&:empty?) if parsed.is_a?(Array)
        rescue StandardError
          reply.split("\n").each do |line|
            m = line.match(/\A\s*(?:[-*]|\d+[.)])\s+(.+?)\s*\z/)
            proposed << m[1].strip if m
          end
        end

        if proposed.empty?
          return { "ok" => false, "error" => "AI returned no usable steps", "raw_reply" => reply.to_s[0, 400] }
        end

        existing_lc = existing.map(&:downcase).to_set rescue existing.map(&:downcase)
        existing_lc = Set.new(existing_lc) if existing_lc.is_a?(Array)
        added = []
        proposed.each do |step|
          next if existing_lc.include?(step.downcase)
          res = add_step(step, target)
          if res["ok"]
            added << step
            existing_lc << step.downcase
          end
        end

        {
          "ok"              => true,
          "plan"            => target,
          "added"           => added,
          "added_count"     => added.size,
          "proposed_count"  => proposed.size,
          "plan_after"      => read(target)
        }
      end

      def archive(name = "")
        target = name.to_s.strip.empty? ? current_name : name.to_s.strip
        return { "ok" => false, "error" => "No current plan and no name given" } if target.empty?
        target += ".md" unless target.end_with?(".md")
        src = File.join(plan_dir, target)
        return { "ok" => false, "error" => "No such plan: #{target}" } unless File.exist?(src)
        dest = File.join(archive_dir, target)
        dest = File.join(archive_dir, "#{Time.now.to_i}-#{target}") if File.exist?(dest)
        File.rename(src, dest)
        clear_current if current_name == target
        { "ok" => true, "archived_to" => dest.sub("#{project_root}/", "") }
      end

      private

      def load_for_mutation(name)
        name = current_name if name.to_s.empty?
        return { "ok" => false, "error" => "No current plan and no name given" } if name.empty?
        name += ".md" unless name.end_with?(".md")
        path = File.join(plan_dir, name)
        return { "ok" => false, "error" => "No such plan: #{name}" } unless File.exist?(path)
        [path, parse(File.read(path, encoding: "utf-8"))]
      end
    end
  end
end

require "set"
