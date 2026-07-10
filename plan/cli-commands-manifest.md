# Task: self-describing `commands` CLI subcommand (Ruby mirror of Python PR #79)

## Goal
Mirror the Python master (tina4-python PR #79, commit 342d8fe) into tina4-ruby:
a `commands` / `commands --json` subcommand driven by a SINGLE command registry
so dispatch, help, AND the manifest all derive from one source (no drift).

## Context
Python master shipped `COMMANDS` + `GENERATORS` registries in
`tina4_python/cli/__init__.py`. Ruby's `lib/tina4/cli.rb` currently has THREE
drifting copies of the command surface: the `case command when ...` dispatch in
`run`, the hand-written `cmd_help` heredoc, and the `case what when ...` in
`cmd_generate` (+ the `ALL_GENERATORS` string). Refactor to one registry each.

## Manifest shape (must match Python exactly, framework = "ruby")
```json
{ "framework": "ruby", "version": "<Tina4::VERSION>",
  "commands": [ { "name": "...", "summary": "...", "args": ["..."]?, "subcommands": ["..."]? } ] }
```

## Scope
- [x] Read Python master (342d8fe) + its test
- [x] Ground with tina4_context("...", "ruby")
- [x] Full dispatch refactor: `run` + `cmd_generate` read the registries
- [x] `COMMANDS` array -> `COMMANDS` hash (name => {handler:, usage?:, args?:, subcommands?:, summary:})
- [x] `GENERATORS` hash (name => {handler:, usage:, summary:}); `generate.subcommands` = GENERATORS.keys (live)
- [x] `cmd_help` derived from COMMANDS + GENERATORS
- [x] `commands_manifest` builder + `cmd_commands` handler (bare = human, --json = manifest)
- [x] cheap/side-effect-free: no Tina4.initialize!, no DB
- [x] Real test spec/commands_manifest_spec.rb (in-process builder + real subprocess, app/DB-free)
- [x] `bundle exec rspec spec/commands_manifest_spec.rb` green — 11 examples, 0 failures (macOS, Ruby 4.0.2)
- [x] full `bundle exec rspec` — 3759 examples, 14 failures (ALL pre-existing PostgreSQL
      live-service specs: no reachable/authenticated PG locally; proven identical with
      cli.rb reverted to origin/v3), 90 pending. My change is CLI-only; every non-PG spec green.

## Refactor scope
FULL dispatch refactor (not the minimal fallback): `run`, `cmd_generate`,
`cmd_help`, and the manifest all read from COMMANDS / GENERATORS. `-h`/`--help`
stay dispatch aliases for `help` (not manifest entries, mirroring Python).

## Command set (truthful to Ruby's actual dispatch)
init, start, serve, migrate, migrate:status, migrate:rollback, seed, seed:create,
test, version, routes, console, generate, ai, metrics, commands, help.
(NO migrate:create / env-migrate / build — those are Python-only / later phase.)
Generators: model, route, crud, migration, middleware, test, form, view, auth,
service, queue, validator, seeder, websocket, listener.

## Status: Done (awaiting independent re-verify + merge)
