# Task: Port `tina4 lint` (silent on-demand install) to tina4-ruby

Outcome: `tina4ruby lint [--fix] [--no-install]` mirrors the Python master
(tina4-python 9bcac09, feature/release3.13.128): scope = `src/**/*.rb` + `app.rb`;
detect rubocop; if absent and not `--no-install`, silently `bundle add rubocop
--group development` (running the command IS the consent), then run it; else the
zero-dependency `ruby -c` syntax baseline. Framework ships NO linter -> remove the
gemspec's rubocop dev-dependency.

Branch: feature/release3.13.128 (from v3). Do NOT bump version / tag / merge — lead
does that centrally after all four verify.

## Scope
- [x] Read Python master `_lint` + `_resolve_ruff` + tests/test_cli_lint.py
- [x] Resurface parked `cmd_lint` foundation (parked/lint-and-migration-20260829)
- [x] Redesign to silent on-demand install (`bundle add rubocop --group development`)
- [x] Drop the `.rubocop.yml` config gate (Python has none) — detect = resolvable rubocop
- [x] Switch user-visible strings to ASCII `--` (parity with Python master + task example; parked used em-dash)
- [x] Remove `spec.add_development_dependency "rubocop"` from tina4ruby.gemspec
- [x] grep rubocop across .github/ + Rakefile — only gemspec:102 referenced it (no CI/Rake lint task)
- [x] spec/cli_lint_spec.rb (real, no mocks)
- [x] `bundle exec rspec spec/cli_lint_spec.rb` green at HEAD — 6 ex, 0 fail, 0 skip
      (Ruby 4.0.2 local; seeds 1/1234/4242/9999); mutation-proofed all 3 gate tests;
      CLI neighborhood (commands_manifest/cli/build/delegated/test-exit) 46 ex 0 fail

## Parity
| Feature | Python | PHP | Ruby | Node |
|---------|--------|-----|------|------|
| lint (silent install) | ✅ (master) | ❌ (lead) | ✅ this branch | ❌ (lead) |

## Tests (real — no mocks, positive + negative)
- [x] Baseline: clean src file `--no-install` -> exit 0
- [x] Baseline: syntax-error src file -> exit 1
- [x] Baseline: `app.rb` in scope (broken app.rb -> exit 1)
- [x] Baseline: nothing to lint -> exit 0
- [x] Registration: `lint` in COMMANDS, handler :cmd_lint
- [x] On-demand install (REAL): temp project + minimal Gemfile, real `bundle add`
      over network -> Gemfile mutated to include rubocop (dev group) AND rubocop
      (not `ruby -c`) ran. Seeded file is a valid-syntax rubocop offense so the
      run is deterministic and proves rubocop, not the baseline, executed.

## Bugs
- (none)

## Commits
- (pending)

## Status: Complete (Ruby side; PHP + Node owed by the lead for full parity)
