#!/usr/bin/env ruby
# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# audit_doc_drift.rb -- fail when this repo's CLAUDE.md documents a Tina4 API the
# code does not have. It is the machine side of the First Principle
# ("Documentation Matches Code Reality") for the AI-context doc AI agents read.
#
# Every claim is checked against the LIVE framework -- required and introspected
# by Ruby reflection (const_get / respond_to? / instance_methods), never a
# hand-kept list -- so the gate cannot itself drift. For each ```ruby fence in
# CLAUDE.md:
#
#   1. Every `Tina4::Something` (nested) constant reference must RESOLVE.
#      (Catches `Tina4::NoSuchClass`.)
#   2. Every `Tina4[::Klass...].method(` / `Tina4.method(` call must name a real
#      method -- a singleton method on the module/class, or an instance method of
#      the class. (Catches `Tina4::Auth.no_such_method`.)
#   3. A local var bound by `var = Tina4::Klass.new(...)` in the SAME fence is
#      followed: `var.method` must be a real instance (or singleton) method of
#      that class. (Catches `db.summon_everything` when `db = Tina4::Database.new`.)
#
# Lowercase receivers with no in-fence `= Tina4::X.new` binding (`session`, `job`,
# `resp`, `request`, `response`, example-model instances) are skipped -- they
# cannot be resolved, exactly as the Python gate skips locals/builtins.
#
# Usage:
#   ruby -Ilib scripts/audit_doc_drift.rb            # report (exit 0)
#   ruby -Ilib scripts/audit_doc_drift.rb --strict   # CI gate (exit 1 on drift)

require "tina4"

module DocDriftAudit
  module_function

  REPO_ROOT = File.expand_path("..", __dir__)

  # A `Tina4::A::B::C` reference (nested allowed). Anchored so a bare `Tina4`
  # module mention or a `Tina4.method` call is not mistaken for a constant.
  CONST_REF = /\bTina4(?:::[A-Z][A-Za-z0-9_]*)+/.freeze

  # A method call whose receiver is Tina4-rooted: `Tina4.get(`, `Tina4::Auth.get_token(`.
  TINA4_CALL = /\b(Tina4(?:::[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_]*[!?]?)/.freeze

  # A constructor binding inside a fence: `db = Tina4::Database.new(...)`.
  CTOR_BIND = /\b([a-z_][A-Za-z0-9_]*)\s*=\s*(Tina4(?:::[A-Z][A-Za-z0-9_]*)+)\.new\b/.freeze

  def read_utf8(path)
    File.read(path, encoding: "UTF-8")
  end

  # Yield [start_line, code] for every ```ruby fenced block.
  def each_ruby_fence(markdown)
    return enum_for(:each_ruby_fence, markdown) unless block_given?

    markdown.scan(/```ruby\b[^\n]*\n(.*?)```/m) do |(code)|
      start = markdown[0...Regexp.last_match.begin(0)].count("\n") + 2
      yield start, code
    end
  end

  # Resolve a "Tina4::A::B" string to its object, or nil if it does not exist.
  def resolve_const(path)
    Object.const_get(path)
  rescue NameError
    nil
  end

  # True if `obj` (a resolved Module/Class) answers to `name` either as a
  # singleton method or as an instance method of the class.
  def member?(obj, name)
    sym = name.to_sym
    return true if obj.respond_to?(sym, true)

    obj.is_a?(Module) &&
      (obj.instance_methods.include?(sym) ||
       obj.private_instance_methods.include?(sym))
  end

  def check_claude_md(root = REPO_ROOT)
    path = File.join(root, "CLAUDE.md")
    return ["#{path}: CLAUDE.md not found"] unless File.exist?(path)

    text = read_utf8(path)
    problems = []

    each_ruby_fence(text) do |start, code|
      # 1. Constructor bindings in this fence: var -> Tina4 class.
      bound = {}
      code.scan(CTOR_BIND) { |(var, klass)| bound[var] = klass }

      # 2. Tina4-rooted constant references must resolve.
      code.scan(CONST_REF) do |_|
        ref = Regexp.last_match(0)
        # A `Tina4::Klass.new` head is covered by the call check; still verify
        # the constant resolves here so a bad class name is always caught.
        next if resolve_const(ref)

        problems << "CLAUDE.md:#{start}: `#{ref}` -- not a defined Tina4 constant"
      end

      # 3. Tina4-rooted method calls must name a real method.
      code.scan(TINA4_CALL) do |(recv, meth)|
        next if meth == "new" # every Class answers .new

        obj = resolve_const(recv) || (recv == "Tina4" ? Tina4 : nil)
        next if obj.nil? # constant miss already reported above
        next if member?(obj, meth)

        problems << "CLAUDE.md:#{start}: `#{recv}.#{meth}(...)` -- " \
                    "`#{recv}` has no method `#{meth}`"
      end

      # 4. Method calls on a var bound to a Tina4 class in this fence.
      bound.each do |var, klass|
        obj = resolve_const(klass)
        next if obj.nil?

        # The lookbehind keeps `api` in a URL like `https://api.example.com` (or
        # any dotted/quoted string) from being read as a method receiver.
        code.scan(/(?<![\w.\/"'])#{Regexp.escape(var)}\.([a-z_][A-Za-z0-9_]*[!?]?)/) do |(meth)|
          next if meth == "new"
          next if member?(obj, meth)

          problems << "CLAUDE.md:#{start}: `#{var}.#{meth}(...)` -- " \
                      "#{klass} (bound to `#{var}`) has no method `#{meth}`"
        end
      end
    end

    problems.uniq
  end

  def check(root = REPO_ROOT)
    check_claude_md(root)
  end

  def main(argv)
    strict = argv.include?("--strict")
    problems = check(REPO_ROOT)
    if problems.empty?
      puts "Doc-drift audit: clean -- every documented Tina4 API resolves against the live code."
      return 0
    end
    puts "Doc-drift audit: #{problems.length} problem(s) found:\n\n"
    problems.each { |p| puts "  - #{p}" }
    puts "\nFix CLAUDE.md to match the code (or the code to match CLAUDE.md)."
    strict ? 1 : 0
  end
end

exit(DocDriftAudit.main(ARGV)) if $PROGRAM_NAME == __FILE__
