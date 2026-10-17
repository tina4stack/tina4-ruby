# Task: CLI `--help` and option checking, all four frameworks (Ruby port)

## Outcome
`--help` / `-h` on any framework CLI command prints that command's usage and
writes nothing. Unknown options are refused with a did-you-mean, value options
need a value, and `ai --all` works. Same behaviour and same wording in Python,
PHP, Ruby and Node, each with equivalent no-mock tests. This file tracks the
Ruby port of the Python reference (tina4-python `fix/cli-help-flags`).

## Context
Found through `tina4 generate model --help`, which created a model called
`--help` in Python. The Rust `tina4` client forwards these commands verbatim,
so the fix belongs in the framework CLIs. What unfixed Ruby v3 did (real runs
in a temp project):

| Command | What it did |
|---|---|
| `generate model -h` (and every other generator) | files named `-h` (`src/orm/-h.rb`, migrations, spec) |
| `generate model --help` | `Usage: ... <name>`, exit 1 (the `--` name check caught it, `-h` slipped through) |
| `generate auth --help` | wrote the whole auth scaffold |
| `lint --help` | ran `bundle add rubocop --group development` |
| `migrate:status --help`, `routes --help`, `console --help`, `test --help` | booted the app / loaded routes |
| `queue work --help` | started a worker that polled forever |
| `build --help`, `queue --help` | exit 1, no help |
| `init`, `start`, `migrate`, `migrate:rollback`, `seed`, `ai` `--help` | OptionParser's own banner (a different format) |

Other broken switches found by the same audit:
- Misspelled options (`--feilds`, `--publc`, `--onse`) were silently dropped:
  the model came out without its fields; `queue work --onse` polled forever.
- `serve --port` crashed with an `OptionParser::MissingArgument` backtrace;
  `--fields` with no value generated a field-less model and exited 1;
  `--every` with no value was ignored.
- `ai --all` crashed: `uninitialized constant Tina4::VERSION` (ai.rb never
  required version.rb, and `ai` runs before lib/tina4 loads).

## Design (Python is the reference)
- Each COMMANDS / GENERATORS entry declares `flags: { name => takes_value }`.
  `help` is `flags: nil` (not checked: it prints the reference whatever
  follows). Queue subcommands have `QUEUE_FLAGS`; the resolution-aware
  generators (`RESOLUTION_TARGETS`) add `RESOLUTION_FLAGS` (`--json`,
  `--dry-run`). Commands with OptionParser short options declare
  `short: { "p" => "port" }`.
- `CLI#run`, before any handler:
  1. `--help` / `-h` anywhere after a command → that command's usage, exit 0.
  2. Unknown option → `Unknown option --feilds for "generate model". Did you mean --fields?`
     then `Run "tina4ruby generate model --help" for its options.`, exit 1
     (DidYouMean::SpellChecker from stdlib).
  3. Value option with no value → `Option --fields for "generate model" needs a value: --fields <value>`, exit 1.
  4. An OptionParser error the pre-check can't see (`serve --port abc`) is
     printed with the same "Run ... --help" line, exit 1, no backtrace.
- `--name=value` is accepted as well as `--name value` (parse_flags and OptionParser).
- `generate` refuses a name starting with `-`; an unknown generator is now
  reported before the name check.
- Delegated commands (`doctor`, `setup`, `deploy`) are untouched.
- **Ruby exception:** `serve` / `start` already define `-h` as `--host`.
  `--help` is help everywhere; `-h HOST` keeps meaning host there.

## Ruby flags map (differences from Python, and why)
| Entry | Ruby flags | vs Python |
|---|---|---|
| init | template* | Python: ai, production. Ruby's OptionParser defines only --template |
| serve / start | port*, host*, dev, managed, production, no-browser, no-reload, no-kill; short -p -h -d | + dev and the short aliases (Ruby's OptionParser) |
| migrate | create*, rollback* | Python: none. Ruby's OptionParser defines both |
| migrate:create | fields*, json, dry-run | Python also table-name; Ruby's migration generator never reads it |
| migrate:rollback | steps*; short -n | Ruby only |
| migrate:status, routes, console, version, seed:create | none | |
| seed | clear | Python: none |
| test | none | Python: unchecked (pytest). Ruby's `test` reads no arguments |
| queue work/stats/retry/clear | once, poll*, services* / json / - / - | same |
| build, lint, ai, commands | tag* file* / fix no-install / all / json | same |
| help | nil (unchecked) | same |
| generate model | fields*, table-name*, no-migration + json, dry-run | same |
| generate route | model*, public + json, dry-run | same |
| generate crud | fields*, table-name*, public, no-templates, no-migration, skip-model | same |
| generate migration | fields* + json, dry-run | same |
| generate middleware, queue | + json, dry-run | same |
| generate form, view | fields*, table-name* + json, dry-run | Ruby resolution-aware (ADR-0063); Python not |
| generate test | model*, public | same |
| generate auth | none | Python: fields, table-name, no-migration. Ruby's auth generator ignores flags |
| generate service | every*, cron* | same |
| generate seeder | table-name* | same |
| generate validator, websocket, listener | none | same; Ruby has no base/page generators |

`*` = takes a value.

## Parity
| Surface | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| `--help` / `-h` per command, no side effects | ✅ | ❌ BUILD | ✅ (serve/start: `--help` only) | ❌ BUILD |
| unknown option refused + did-you-mean | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| value option needs a value | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| `--name=value` | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| `ai --all` | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| generate name can't start with `-` | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| `help --help` prints the reference | ✅ | ❌ BUILD | ✅ | ❌ BUILD |
| `generate crud --skip-model` | ✅ | ❌ BUILD | ✅ | ❌ BUILD |

## Tests (spec/cli_help_flags_spec.rb — real exe/tina4ruby child processes, no mocks)
- [x] every command and generator, `--help` and `-h` (not `-h` for serve/start):
      exit 0, usage line + registry summary printed, project tree hashed
      before/after and unchanged (66 cases)
- [x] `--help` / `-h` after the name and options still wins
- [x] top-level `--help` / `-h`; `help`, `help --help`, `help -h` print the reference
- [x] exact per-command format (queue: usage, blank, summary, subcommands)
- [x] `generate --help` and `generate <unknown> --help` list every generator
- [x] `serve -h 127.0.0.1` is host: parse continues to the next option; `start -h`
      needs a value; a real server boots on `-p PORT -h 127.0.0.1`
- [x] misspelled options refused with the right suggestion, nothing written
      (incl. `--feilds=x`)
- [x] short and foreign options refused (`-f`, `serve -x`, `test -q`, `generate auth --fields`)
- [x] value option without a value refused, no backtrace (incl. `serve --port`, `migrate:rollback -n`)
- [x] `serve --port abc` refused without a backtrace
- [x] `--fields price:float` and `--fields=price:float` both reach the model
- [x] `generate crud Product --skip-model` after `generate model Product`: exit 0,
      no "already exists", model and migrations byte-identical, crud route written
      (fails with the skip reverted)
- [x] `ai --all` and `ai all` write CLAUDE.md without the menu
- [x] every option in a usage string is an accepted option (drift guard,
      long and short)
- [x] all 66 help cases fail on unfixed v3 (98 of 105 fail; the 7 that pass are
      regression guards: top-level help, `help`, one `--fields` spelling, `serve -h` boot)
- [x] full suite at HEAD (see Results)

## Results
| Run | Result |
|---|---|
| spec/cli_help_flags_spec.rb | 106 examples, 0 failures |
| same spec on unfixed v3 | 98 of 105 fail; all 66 help cases fail (skip-model case added later, fails with the skip reverted) |
| spec/cli*_spec.rb + manifest, migrate:create parity, generate resolution, port config, serve boot specs | 292 examples, 0 failures, 1 pending |
| full suite (local macOS, no service containers) | 6981 examples, 32 failures, 688 pending |
| those 32 on clean v3 (git stash) | 32 of 32 fail: Redis/Valkey/Memcached/Postgres/MSSQL-backed caches, sessions and DB URLs, overlay, metrics handoff, driver hints. None CLI. CI provisions those services |

Spec count: 6876 before, 6982 after.

Running the new spec against unfixed code is NOT side-effect free: v3's
`lint --help` really runs `bundle add rubocop` and rewrote the enclosing
repo's Gemfile.lock during one probe run. Run unfixed-code probes with `bundle`
off PATH.

## Bugs found on the way
- `ai --all` crashed on v3 (`Tina4::VERSION` not loaded) — fixed here.
- The `generate model` next-steps hint suggests `generate crud X --skip-model`,
  but no generator had the option (Python too): silently ignored, and option
  checking would now refuse it. Implemented, as in Python: crud skips step 1
  (model + migration) with `--skip-model`.

## Commits
- fix(cli): --help prints usage; unknown options are refused

## Status: Python done; Ruby done (this branch); PHP, Node in progress
