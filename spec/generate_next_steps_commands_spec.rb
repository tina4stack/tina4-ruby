# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

#
# The "Next:" steps a generator prints are commands people (and models) copy
# verbatim, so every one of them has to be a command the CLI really runs.
#
# `generate migration` used to print `tina4ruby migrate status` and
# `tina4ruby migrate rollback`. Neither exists: both ran plain `migrate`
# (the trailing word is ignored), exited 0, and rolled nothing back. The real
# commands are `migrate:status` and `migrate:rollback`, as the other three
# frameworks' hints and the docs already say.

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "tina4/cli"

RSpec.describe "generator next steps name commands the CLI runs" do
  cli = Tina4::CLI

  # Every `tina4ruby ...` invocation in one step, as token lists. A step can
  # chain two (`... && tina4ruby seed`) or point past the command (`serve -> curl`).
  def invocations(step)
    step.split(/&&|->|;/).filter_map do |part|
      m = part.match(/\btina4ruby\s+(.*)/) or next
      m[1].split
    end
  end

  # Why `tokens` is not a command the CLI would run as written, or nil. Options
  # go through the CLI's own check (#accepted_options / #option_problem, what
  # #check_options runs before any handler), so a hint passes exactly when
  # tina4ruby would accept its options: short aliases, values, generator flags.
  def problem(cli, tokens)
    name, *rest = tokens
    return nil if cli::DELEGATED.key?(name) # the tina4 client owns their options
    spec = cli::COMMANDS[name] or return "unknown command #{name.inspect}"

    case name
    when "generate"
      return "unknown generator #{rest.first.inspect}" unless cli::GENERATORS.key?(rest.first)
    when "queue"
      return "unknown queue subcommand #{rest.first.inspect}" unless cli::QUEUE_SUBCOMMANDS.key?(rest.first)
    end

    runner = cli.new
    return nil if rest.any? { |arg| runner.send(:help_flags, name).include?(arg) }
    accepted = runner.send(:accepted_options, name, rest) or return nil
    label = runner.send(:option_label, name, rest)
    takes_words = %w[generate queue].include?(name) || spec[:args]&.any?
    i = 0
    while i < rest.length
      message, consumed = runner.send(:option_problem, rest, i, accepted, spec[:short] || {}, label)
      return message.lines.first.strip if message
      if consumed == 1 && !rest[i].start_with?("-") && !takes_words
        # `migrate rollback`: the word is silently dropped and plain migrate runs.
        return "#{name} takes no argument, so #{rest[i].inspect} would be ignored"
      end
      i += consumed
    end
    nil
  end

  cli::GENERATORS.each_key do |target|
    builder = cli::NEXT_STEPS[target] or next

    it "every command in the `generate #{target}` next steps exists" do
      bad = Array(builder.call({})).flat_map do |step|
        invocations(step).filter_map do |tokens|
          why = problem(cli, tokens) and "#{step.strip}  (#{why})"
        end
      end
      expect(bad).to be_empty, "next steps name commands the CLI does not run:\n  #{bad.join("\n  ")}"
    end
  end

  # Round trip: run the migration hints exactly as printed and check each one
  # did what its label says.
  describe "generate migration, run as printed" do
    around(:each) do |ex|
      Dir.mktmpdir("tina4_next_steps") do |dir|
        @dir = dir
        FileUtils.mkdir_p(File.join(dir, "migrations"))
        ex.run
      end
    end

    def run_cli(*args)
      env = {
        "TINA4_DATABASE_URL" => "sqlite:///#{File.join(@dir, 'app.db')}",
        "TINA4_DATABASE_USERNAME" => nil,
        "TINA4_DATABASE_PASSWORD" => nil,
        "TINA4_AUTO_MIGRATE" => "false", # each command is judged on its own effect
        "TINA4_DEBUG" => nil,
        "TINA4_SECRET" => "next-steps-spec-secret-0123456789abcdef"
      }
      out, status = Open3.capture2e(env, RUBY_BIN, EXE, *args, chdir: @dir)
      expect(status.exitstatus).to eq(0), "tina4ruby #{args.join(' ')} exited #{status.exitstatus}:\n#{out}"
      out
    end

    it "applies, reports and rolls back the migration it scaffolded" do
      out = run_cli("generate", "migration", "create_widgets")
      hint = ->(label) do
        line = out.lines.find { |l| l.include?(label) } or raise "no #{label.inspect} step in:\n#{out}"
        line[/tina4ruby\s+(.*)/, 1].split
      end

      run_cli(*hint.call("Apply it:"))
      status = run_cli(*hint.call("Check status:"))
      expect(status).to match(/Completed: 1\s+Pending: 0/), "the status step did not report status:\n#{status}"

      run_cli(*hint.call("Rollback if wrong:"))
      status = run_cli(*hint.call("Check status:"))
      expect(status).to match(/Completed: 0\s+Pending: 1/), "the rollback step did not roll back:\n#{status}"
    end
  end
end
