# frozen_string_literal: true

# Tina4 Ruby
#
# Text folding + chunking for the Context subsystem.
#
# A thin, idiomatic port of the proven slice of tina4-python's
# tina4_python/context/chunker.py (itself a port of neemee's
# tokenizer/chunkers). Pure stdlib — nothing here touches SQLite; it produces
# the (folded body, raw text) pairs the FTS5 index stores.

module Tina4
  class Context
    # Folding + chunking helpers. All methods are module functions so they read
    # as `Chunker.fold(text)`, matching the Python free-function layout.
    module Chunker
      module_function

      # Join comma-grouped numbers ("24,601" -> "24601") and split camelCase
      # ("ForeignKeyField" -> "foreign key field") so a query token reaches a
      # code identifier. snake_case already splits for free at the tokenizer.
      NUM_COMMA = /(?<=\d),(?=\d)/
      CAMEL     = /(?<=[a-z0-9])(?=[A-Z])/
      WORD_RE   = /[a-z0-9]+/

      # Sentence boundary = end punctuation FOLLOWED BY whitespace/EOL, or a
      # newline. NOT a bare '.', which would shred embedded code in prose
      # ("db.fetch()" -> "db. fetch()"). Intra-token dots stay intact.
      SENT = /(?<=[.!?])\s+|\n+/

      # Chunk boundaries across languages. Ruby is the native target so
      # def/class/module are accepted at any indent (Ruby nests methods inside
      # classes/modules); the cross-language alternatives (php/js/ts function,
      # ts export, Object Pascal unit/routine headers) mirror the Python port so
      # the SAME index can hold .rb, .py, .php, .js, .ts, .pas … files.
      TOPLEVEL = Regexp.new(
        '\A(?:' \
          '\s*(?:async )?def |\s*class |\s*module |@\w' \
          '|\s*(?:public |private |protected |static |final |abstract )*function \w' \
          '|(?:export )?(?:default )?(?:abstract )?class ' \
          '|interface |trait ' \
          '|export (?:const|function|interface|type|async) ' \
          '|[Uu]nit |[Pp]rocedure |[Ff]unction |[Cc]onstructor |[Dd]estructor ' \
          '|[Tt]ype$' \
        ')'
      )

      # Lowercase, strip diacritics, join comma-grouped numbers, split camelCase.
      # Applied symmetrically to the indexed body and to query tokens so matching
      # is consistent: a query for "field" reaches "IntegerField".
      def fold(text)
        s = text.to_s.gsub(NUM_COMMA, "")
        s = s.gsub(CAMEL, " ").downcase
        s.unicode_normalize(:nfkd)
         .encode(Encoding::ASCII, invalid: :replace, undef: :replace, replace: "")
      end

      # Fold simple plurals: strip one trailing 's', never from ss/us/is endings
      # (class, status, axis). QUERY-side only — so "fields" also reaches "Field".
      def light_stem(token)
        if token.length > 3 && token.end_with?("s") && !token.end_with?("ss", "us", "is")
          token[0..-2]
        else
          token
        end
      end

      # Accent-folded lowercase alphanumeric tokens (digits kept).
      def terms(text)
        fold(text).scan(WORD_RE)
      end

      # Pack line-segments into chunks of at most max_lines lines, hard-splitting
      # any single oversized segment.
      def pack(segments, max_lines)
        chunks = []
        cur = []
        segments.each do |seg|
          seg = seg.dup
          while seg.length > max_lines # oversized segment: hard split
            unless cur.empty?
              chunks << cur
              cur = []
            end
            chunks << seg[0...max_lines]
            seg = seg[max_lines..] || []
          end
          if !cur.empty? && cur.length + seg.length > max_lines
            chunks << cur
            cur = []
          end
          cur += seg
        end
        chunks << cur unless cur.empty?
        chunks
      end

      # Chunk source on top-level def/class/module boundaries (sentence chunking
      # shreds code). Segments are packed up to max_lines, and every chunk starts
      # with a "# file: <path>" line so the path's tokens are indexed — "where is
      # the router?" should match core/router.rb by name.
      #
      # Returns an array of [index, chunk_text] pairs.
      def chunk_code(text, path: "", max_lines: 60)
        lines = text.to_s.split("\n", -1)
        lines.pop if lines.last == "" # drop trailing empty from a final newline
        bounds = []
        lines.each_with_index { |ln, i| bounds << i if TOPLEVEL.match?(ln) }
        bounds = [0] + bounds if bounds.empty? || bounds.first != 0

        ends = bounds[1..] + [lines.length]
        segments = bounds.zip(ends).map { |a, b| lines[a...b] }

        header = path.to_s.empty? ? nil : "# file: #{path}"
        out = []
        pack(segments, max_lines).each_with_index do |ch, i|
          body = ((header ? [header] : []) + ch).join("\n")
          out << [i, body]
        end
        out
      end

      # Chunk prose/docs into sentence-packed windows of at most max_words words.
      # Returns an array of [index, chunk_text] pairs.
      def chunk_text(text, max_words: 350)
        sents = text.to_s.split(SENT).map(&:strip).reject(&:empty?)
        chunks = []
        cur = []
        cur_words = 0
        sents.each do |s|
          w = s.split.length
          if !cur.empty? && cur_words + w > max_words
            chunks << cur.join(" ")
            cur = []
            cur_words = 0
          end
          cur << s
          cur_words += w
        end
        chunks << cur.join(" ") unless cur.empty?
        chunks.each_with_index.map { |c, i| [i, c] }
      end
    end
  end
end
