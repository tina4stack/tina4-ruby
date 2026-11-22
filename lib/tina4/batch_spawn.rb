# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

module Tina4
  # Run a program that may be a Windows batch file (`.cmd` / `.bat`).
  #
  # A batch file is always run by cmd.exe, which re-parses the command line.
  # Ruby quotes array-form arguments for the C runtime, not for cmd.exe, so an
  # argument holding `%PATH%` is expanded, `^` vanishes, and `x|y` runs `y` as
  # a command (the BatBadBut class). The fix is the one tina4-python
  # (core/batch_spawn.py) and tina4-nodejs (packages/core/src/batchSpawn.ts)
  # use, after cross-spawn and https://qntm.org/cmd: build the cmd.exe line
  # here, each argument quoted, embedded quotes and the backslashes before them
  # escaped, and every cmd.exe metacharacter caret-escaped TWICE, once for the
  # `cmd /c` line and once more because the batch file re-parses the `%*` it
  # forwards.
  #
  # The Ruby-specific part is getting that line to CreateProcess unchanged.
  # Ruby has no verbatim-arguments option: the array form re-quotes every
  # argument, and the single-string form goes through `w32_spawn` in Ruby's
  # win32/win32.c, which asks `has_redirection()` about the string. When that
  # says no, the string reaches CreateProcess exactly as written. When it says
  # yes, Ruby runs `%COMSPEC% /c "<string>"` instead. So we ask the same
  # question first (#redirection? is a port of `has_redirection`) and hand Ruby
  # whichever string comes out as exactly one cmd.exe layer over our line:
  #
  # * `"%COMSPEC%" /d /c <line>` when Ruby will pass it through untouched, or
  # * `<line>` alone when Ruby will wrap it, because its `%COMSPEC% /c "<line>"`
  #   is then the one cmd.exe layer (cmd.exe strips the outer quotes, the same
  #   as `/s` does, since the line always holds more than two quotes).
  #
  # Anything that is not a batch file, and every non-Windows platform, is
  # spawned exactly as before.
  module BatchSpawn
    # cmd.exe metacharacters, the same set cross-spawn, tina4-python and
    # tina4-nodejs escape.
    CMD_META = /([()\]\[%!^"`<>&|;, *?])/

    module_function

    # Native Windows Ruby (mswin / mingw), whose spawn goes through win32.c.
    def windows?
      RUBY_PLATFORM.match?(/mswin|mingw/)
    end

    # True when +path+ is a batch file that cmd.exe must run (Windows only).
    def batch_file?(path, windows: windows?)
      windows && path.to_s.match?(/\.(cmd|bat)\z/i)
    end

    # One argument, quoted and escaped for a batch file run by cmd.exe.
    def escape_argument(arg)
      quote_argument(arg.to_s).gsub(CMD_META, '^\1').gsub(CMD_META, '^\1')
    end

    # C-runtime quoting, in one linear pass (no backtracking regex): backslashes
    # before a quote double and the quote is backslash-escaped; backslashes
    # before the closing quote we add double too; any other backslash is kept.
    def quote_argument(arg)
      quoted = +'"'
      backslashes = 0
      arg.each_char do |char|
        if char == "\\"
          backslashes += 1
          next
        end
        quoted << ("\\" * (char == '"' ? (backslashes * 2) + 1 : backslashes)) << char
        backslashes = 0
      end
      quoted << ("\\" * backslashes * 2) << '"'
    end

    # The batch file and its escaped arguments, as one cmd.exe command line.
    def command_line(path, args)
      [path.to_s.gsub(CMD_META, '^\1'), *args.map { |arg| escape_argument(arg) }].join(" ")
    end

    # `Kernel#system(env, program, *args)`, except that a batch file on Windows
    # runs through cmd.exe with every argument escaped. Same return value and
    # `$?` as Kernel#system.
    def system(env, program, *args, **options)
      return Kernel.system(env, program, *args, **options) unless batch_file?(program)

      comspec = ENV["COMSPEC"] || "cmd.exe"
      # Pin the COMSPEC Ruby wraps with to the one we chose, and keep RUBYSHELL
      # (which Ruby would use instead of cmd.exe) out of this one spawn.
      Kernel.system(env.merge("COMSPEC" => comspec, "RUBYSHELL" => nil),
                    shell_string(program, args, comspec), **options)
    end

    # The single string to give Ruby's spawn so that CreateProcess receives
    # exactly one cmd.exe layer over #command_line (see the module comment).
    def shell_string(program, args, comspec)
      line = command_line(program, args)
      direct = %("#{comspec}" /d /c #{line})
      return direct unless redirection?(direct)
      return line if redirection?(line)

      # Neither form survives Ruby's spawn intact (only possible with an
      # unusual COMSPEC path). Refuse rather than run a mangled command line.
      raise ArgumentError, "cannot pass these arguments to #{program} through cmd.exe intact"
    end

    # Port of `has_redirection()` from Ruby's win32/win32.c (the same logic in
    # Ruby 3.1, 3.3 and 3.4; master only adds an end-of-string check that does
    # not change the answer): true when Ruby's single-string spawn will run
    # +cmd+ through `%COMSPEC% /c` rather than pass it to CreateProcess as is.
    # Byte-wise like the C: a multibyte UTF-8 character never contains one of
    # the ASCII bytes it looks for.
    def redirection?(cmd)
      bytes = cmd.b
      quote = nil
      i = 0
      while i < bytes.bytesize
        found, i, quote = redirection_step(bytes, i, quote)
        return true if found
      end
      false
    end

    # One step of has_redirection() at byte +i+: [redirection found?, next
    # index, quote state].
    def redirection_step(bytes, i, quote)
      char = bytes[i]
      case char
      when "'", '"' then [false, i + 1, toggle_quote(quote, char)]
      when ">", "<", "|", "&", "\n" then [quote.nil?, i + 1, quote]
      when "%" then [*environment_reference(bytes, i), quote]
      when "\\" then [false, i + 2, quote]
      else [false, i + 1, quote]
      end
    end

    # A quote opens a quoted run, and only the same quote character closes it.
    def toggle_quote(quote, char)
      return char if quote.nil?

      quote == char ? nil : quote
    end

    # `%NAME%` counts as redirection, quoted or not. +i+ is at the `%`; returns
    # [found?, where the scan resumes], exactly where the C leaves its pointer.
    def environment_reference(bytes, i)
      j = i + 1
      return [false, j] unless bytes[j]&.match?(/[A-Za-z_]/)

      j += 1
      j += 1 while bytes[j]&.match?(/\w/)
      [bytes[j] == "%", j + 1]
    end
  end
end
