# frozen_string_literal: true

module Tina4
  # Base64 on core Array#pack / String#unpack1, so Tina4 needs no base64 gem.
  #
  # The base64 gem stopped being a default gem in Ruby 3.4, and a bundled gem an
  # app does not declare is not on the load path under Bundler. The gem is itself
  # a thin wrapper over pack("m"), so this module keeps its method names and its
  # exact semantics (same bytes out, same ArgumentError on bad strict input) and
  # the call sites read the same with a Tina4:: prefix.
  module Base64
    module_function

    # RFC 2045 (MIME): a newline after every 60 encoded characters and at the end.
    def encode64(binary)
      [binary].pack("m")
    end

    # Lenient decode: characters outside the alphabet are skipped, never raised on.
    def decode64(string)
      string.unpack1("m")
    end

    # RFC 4648: no line feeds.
    def strict_encode64(binary)
      [binary].pack("m0")
    end

    # Raises ArgumentError on anything that is not canonical, padded base64.
    def strict_decode64(string)
      string.unpack1("m0")
    end

    # RFC 4648 URL-safe alphabet ("-" and "_"), padding optional.
    def urlsafe_encode64(binary, padding: true)
      encoded = strict_encode64(binary)
      encoded.chomp!("==") or encoded.chomp!("=") unless padding
      encoded.tr!("+/", "-_")
      encoded
    end

    # Accepts padded or unpadded input; raises ArgumentError on invalid input.
    def urlsafe_decode64(string)
      if !string.end_with?("=") && string.length % 4 != 0
        string = string.ljust((string.length + 3) & ~3, "=")
        string.tr!("-_", "+/")
      else
        string = string.tr("-_", "+/")
      end
      strict_decode64(string)
    end
  end
end
