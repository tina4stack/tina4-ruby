# frozen_string_literal: true

# lib/tina4/import_helper.rb
#
# AI-agent experience: fail LOUD with an actionable hint when a wrong Tina4
# import is guessed. Two bounded hooks, installed once at framework boot from
# `lib/tina4.rb`:
#
#   1. `Tina4.const_missing(:Route)` -> "uninitialized constant Tina4::Route.
#      Did you mean Tina4::Router?" (using stdlib DidYouMean; Levenshtein
#      fallback if unavailable).
#
#   2. `require "tina4/route"` (unknown framework file) -> "cannot load such
#      file -- tina4/route. Did you mean tina4/router?" — walks the real files
#      that ship in `lib/tina4/*.rb` for close matches.
#
# BOTH hooks are BOUNDED: the constant hook only fires for `Tina4::*`, and the
# require hook only intervenes when the requested path starts with `tina4/`
# AND the resulting LoadError is about that exact path. Anything else passes
# through unchanged — a genuinely missing gem must surface as its own real
# error, not be masked by our hint (`spec/import_helper_spec.rb` locks that in
# with the "broken_module" masking gate).
#
# The hint is a suggestion, never a truth claim: the raised class stays
# NameError / LoadError, so callers who rescue those still work.

module Tina4
  module ImportHelper
    # The directory that holds the real framework files (lib/tina4/*.rb).
    # Computed from this file's own location so it survives being loaded from
    # a gem install path, a git checkout, or a worktree alike.
    FRAMEWORK_DIR = File.expand_path(__dir__).freeze

    class << self
      # Install both hooks. Idempotent: safe to call more than once (extra
      # calls no-op). The framework boot in `lib/tina4.rb` calls this exactly
      # once at the end of its own require chain.
      def install
        return if @installed

        # Load DidYouMean once, quietly. It ships with Ruby 3.1+ (the
        # framework's minimum), but never *fail* boot if it happens to be
        # absent: the close_matches Levenshtein fallback covers that case.
        begin
          require "did_you_mean"
        rescue LoadError
          # fall through to the Levenshtein path in close_matches
        end

        Tina4.singleton_class.prepend(ConstMissing)
        Kernel.prepend(RequireHook)
        @installed = true
      end

      def installed?
        @installed == true
      end

      # Return up to `max` close-match strings from `dictionary` for `word`.
      # Uses stdlib DidYouMean::SpellChecker where available (Ruby 3.1+ ships
      # it), and falls back to a small Levenshtein implementation otherwise.
      #
      # Never raises: an empty dictionary or a blank word returns [].
      def close_matches(word, dictionary, max: 3)
        list = Array(dictionary).map(&:to_s)
        return [] if list.empty? || word.to_s.empty?

        if defined?(DidYouMean::SpellChecker)
          suggestions = DidYouMean::SpellChecker.new(dictionary: list).correct(word.to_s)
          return suggestions.first(max) unless suggestions.nil? || suggestions.empty?
        end

        # Levenshtein fallback: rank by edit distance, keep the closest few
        # within a reasonable threshold so a truly wrong guess still returns [].
        scored = list.map { |candidate| [candidate, levenshtein(word.to_s, candidate)] }
        threshold = [(word.to_s.length / 3.0).ceil, 3].max
        scored.select { |_, distance| distance <= threshold }
              .sort_by { |candidate, distance| [distance, candidate] }
              .first(max)
              .map(&:first)
      end

      # A short, ordered sample of real Tina4 constants — used when nothing
      # was close enough to suggest, so the reader still leaves with something
      # to try.
      def some_tina4_constants(limit = 5)
        Tina4.constants.map(&:to_s).sort.first(limit)
      end

      private

      # Iterative two-row Levenshtein: O(a.length * b.length) time,
      # O(b.length) space. Pure logic, no allocations of intermediate strings.
      def levenshtein(a, b)
        return b.length if a.empty?
        return a.length if b.empty?

        prev = (0..b.length).to_a
        (1..a.length).each do |i|
          curr = Array.new(b.length + 1, 0)
          curr[0] = i
          (1..b.length).each do |j|
            cost = a[i - 1] == b[j - 1] ? 0 : 1
            curr[j] = [
              curr[j - 1] + 1,
              prev[j] + 1,
              prev[j - 1] + cost
            ].min
          end
          prev = curr
        end
        prev[b.length]
      end
    end

    # Hook 1 -- Tina4::<Missing>. Only fires when a bare `Tina4::<Name>`
    # constant is asked for and does not exist. Ruby dispatches
    # `const_missing` on the module itself (via its singleton class), so a
    # prepended `ConstMissing#const_missing` runs first and re-raises with a
    # helpful hint.
    module ConstMissing
      def const_missing(name)
        real = Tina4.constants.map(&:to_s)
        matches = Tina4::ImportHelper.close_matches(name.to_s, real)

        message =
          if matches.any?
            "uninitialized constant Tina4::#{name}. Did you mean Tina4::#{matches.first}?"
          else
            examples = Tina4::ImportHelper.some_tina4_constants
            hint =
              if examples.any?
                " Real Tina4 constants include: #{examples.map { |c| "Tina4::#{c}" }.join(', ')}."
              else
                ""
              end
            "uninitialized constant Tina4::#{name}.#{hint}"
          end

        # NameError.new(msg, name) records the missing constant symbol, so
        # code doing `rescue NameError => e; e.name` still works.
        raise NameError.new(message, name)
      end
    end

    # Hook 2 -- require "tina4/<something>". Runs BEFORE the real
    # Kernel#require via `Module#prepend`. On success, indistinguishable from
    # plain require. On failure, only rewrites the LoadError when:
    #
    #   * the requested path starts with "tina4/", AND
    #   * the LoadError's own #path is nil or equal to that requested path.
    #
    # The second condition is the masking gate: a nested `require
    # "definitely_missing_gem"` inside a loaded tina4/*.rb raises a LoadError
    # whose #path is that inner name — we MUST propagate it unchanged, not
    # replace it with a spurious "did you mean tina4/router?" hint.
    module RequireHook
      def require(path)
        super
      rescue LoadError => e
        raise unless path.is_a?(String) && path.start_with?("tina4/")

        offending = e.respond_to?(:path) ? e.path : nil
        raise unless offending.nil? || offending == path

        base = path.sub(%r{\Atina4/}, "")
        real = Dir.glob(File.join(Tina4::ImportHelper::FRAMEWORK_DIR, "*.rb"))
                  .map { |file| File.basename(file, ".rb") }
        matches = Tina4::ImportHelper.close_matches(base, real)

        if matches.any?
          suggestion = matches.first
          raise LoadError, "cannot load such file -- #{path}. Did you mean tina4/#{suggestion}?"
        else
          raise LoadError, "cannot load such file -- #{path}. No close match under tina4/*."
        end
      end

      # Preserve Kernel#require's private visibility: prepending a module that
      # publicly defines `require` would otherwise leak `some_obj.require(...)`
      # as a public method. Keep the surface identical.
      private :require
    end
  end
end
