# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# Tina4::BatchSpawn's pure functions: the cmd.exe escaping, the port of Ruby's
# win32 has_redirection(), and the choice between the two command lines. No
# process and no double: these run on every platform, so Linux CI checks the
# escaping too. The end-to-end proof that a real tina4.cmd receives every
# argument verbatim is spec/cli_delegated_commands_spec.rb, on Windows.

require "spec_helper"
require "tina4/batch_spawn"

RSpec.describe Tina4::BatchSpawn do
  comspec = 'C:\Windows\system32\cmd.exe'
  batch = 'C:\tools\tina4.cmd'

  describe ".batch_file?" do
    it "is true for .cmd and .bat on Windows, any case" do
      %w[tina4.cmd tina4.CMD C:/bin/tina4.bat].each do |path|
        expect(described_class.batch_file?(path, windows: true)).to be(true), path
      end
    end

    it "is false for an executable, and for everything off Windows" do
      expect(described_class.batch_file?("tina4.exe", windows: true)).to be(false)
      expect(described_class.batch_file?("tina4.cmd.exe", windows: true)).to be(false)
      expect(described_class.batch_file?("tina4.cmd", windows: false)).to be(false)
    end
  end

  describe ".escape_argument" do
    it "quotes the argument and caret-escapes every metacharacter twice" do
      expect(described_class.escape_argument("x|y")).to eq('^^^"x^^^|y^^^"')
      expect(described_class.escape_argument("100%PATH%")).to eq('^^^"100^^^%PATH^^^%^^^"')
      expect(described_class.escape_argument("")).to eq('^^^"^^^"')
    end

    it "backslash-escapes an embedded quote and doubles the backslashes before it" do
      expect(described_class.escape_argument('a\"b')).to eq('^^^"a\\\\\\^^^"b^^^"')
    end

    it "doubles trailing backslashes so they do not escape the closing quote" do
      expect(described_class.escape_argument("tail\\")).to eq('^^^"tail\\\\^^^"')
    end
  end

  describe ".command_line" do
    it "escapes the batch path once and each argument twice" do
      line = described_class.command_line('C:\Program Files (x86)\tina4.cmd', ["a&b"])
      expect(line).to eq('C:\Program^ Files^ ^(x86^)\tina4.cmd ^^^"a^^^&b^^^"')
    end
  end

  describe ".redirection? (Ruby's win32 has_redirection)" do
    it "sees < > | & and a newline outside quotes" do
      ["a|b", "a>b", "a<b", "a&b", "a\nb"].each do |cmd|
        expect(described_class.redirection?(cmd)).to be(true), cmd.inspect
      end
    end

    it "ignores them inside double or single quotes, or after a backslash" do
      ['"a|b"', "'a|b'", %q("it's|"), "a\\|b"].each do |cmd|
        expect(described_class.redirection?(cmd)).to be(false), cmd.inspect
      end
    end

    it "counts %NAME% even inside quotes, but not a lone or caret-split percent" do
      expect(described_class.redirection?('"%PATH%"')).to be(true)
      expect(described_class.redirection?("100%")).to be(false)
      expect(described_class.redirection?("%1%")).to be(false)
      expect(described_class.redirection?("%PATH^%")).to be(false)
    end
  end

  describe ".shell_string" do
    it "hands Ruby the cmd.exe line itself when Ruby will pass it through untouched" do
      line = described_class.command_line(batch, ["deploy", "x|y"])
      expect(described_class.shell_string(batch, ["deploy", "x|y"], comspec))
        .to eq(%("#{comspec}" /d /c #{line}))
    end

    it "hands Ruby the bare line when Ruby will wrap it in cmd /c itself" do
      args = ["deploy", 'say "x|y"']
      expect(described_class.shell_string(batch, args, comspec))
        .to eq(described_class.command_line(batch, args))
    end

    it "never returns a string Ruby would wrap a second time" do
      args = ["deploy", "a&b", "100%PATH%", 'say "hi"', "a^b", "x|y", "<in", "(p)", "!bang!", "",
              "tail\\", "x&cd.>marker", "x|cd.>marker", 'say "x|y"', 'q"&cd.>marker', "it's", "a'b|c'd"]
      args.each do |arg|
        chosen = described_class.shell_string(batch, ["deploy", arg], comspec)
        direct = chosen.start_with?(%("#{comspec}"))
        # Direct: Ruby must see no redirection, or it would wrap it again.
        # Bare line: Ruby must see redirection, or it would not wrap it at all.
        expect(described_class.redirection?(chosen)).to be(!direct), arg.inspect
      end
    end
  end
end
