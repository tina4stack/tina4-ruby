# Feature: AI-agent experience — import hints and generate resolution transparency

Outcome: Wrong Ruby guesses (`Tina4::Routr`, `require "tina4/route"`) fail loudly with a
`Did you mean tina4/router?` hint; `tina4ruby generate` prints its class/table/route/file
resolution — as human text by default and a JSON envelope on `--json` — with a `--dry-run`
that plans the actions but writes nothing.

## Scope
- [x] Feature A: `lib/tina4/import_helper.rb` with two hooks:
  - `Tina4.const_missing(name)` → `DidYouMean::SpellChecker`-based suggestion over `Tina4.constants`, Levenshtein fallback
  - `Kernel#require` wrapper via `Module#prepend`, bounded to `tina4/*` paths, walks framework `lib/tina4/*.rb`
- [x] Wire-up: one `require "tina4/import_helper"` + `Tina4::ImportHelper.install` at the end of `lib/tina4.rb`
- [x] Install idempotent (safe to call more than once)
- [x] Feature B: `SQL_RESERVED_TABLE_NAMES` set + `pluralize_table` helper (mirror Python master)
- [x] `to_table_name` routes through reserved-word pluralize
- [x] `to_route_name` helper — fixes double-`s` for reserved tables AND `y`-ending plurals across generate crud/form/view
- [x] `--json` flag on `generate model/route/migration/middleware` emits `generate_v1` envelope
- [x] `--dry-run` flag: `dry_run: true`, `actions_taken: []`, writes no files
- [x] Bare `generate model` prints human resolution block to STDERR before writing
- [x] `commands --json` manifest gains `"resolution_contract" => {"version" => "1", "envelope" => "generate_v1"}`

## Tests (real subprocess via `Open3.capture3`, no mocks)
- [x] `spec/import_helper_spec.rb` — 8 examples green:
  - positive-happy const: `Tina4.const_get(:Router).name` exits 0
  - positive-happy require: `require "tina4/router"` exits 0
  - negative-hint (const): `Tina4::Routr` stderr names `Router`
  - negative-hint (require): `require 'tina4/route'` stderr names `tina4/router`
  - negative-no-match: `Tina4::Zzzzz` stderr names 3+ real constants (verified against real Tina4.constants)
  - masking gate: `broken_module` requiring `definitely_missing_gem` re-raises the original LoadError, NOT our hint
  - install idempotency: double `install` still works
  - mutation gate: stash import_helper.rb → red; unstash → green
- [x] `spec/generate_resolution_spec.rb` — 6 examples green:
  - `--json` prints valid envelope for reserved word `Order` with `reserved_word_pluralize` transformation
  - `--dry-run` writes no files, `actions_taken: []`, `dry_run: true`
  - human resolution block to STDERR for bare `generate model Order`
  - normal-class `Widget` shows no reserved-word note
  - `commands --json` manifest carries `resolution_contract`
  - bare-name `generate model User` also pluralizes (user is reserved)

## Bugs
- [x] `generate crud Order` used to write `src/routes/orderss.rb` (double `s`) as soon as `to_table_name` pluralized reserved words. Fixed by adding `to_route_name` (always pluralizes from the class-name snake) and routing crud/form/view through it. `to_route_name(Category)` now correctly emits `categories`, not the naive `categorys` (Category was ALREADY wrong before this change; fixed as a side effect).
- [x] Detail view was `#{table}.twig` — for reserved-word `Order`, that collided with the list view `orders.twig`. Now keyed by `to_snake_case(name)`.

## Commits
- 60cc0f1  feat(cli): AI-agent import hints + generate resolution transparency

## Status: Complete
