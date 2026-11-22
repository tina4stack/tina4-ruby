# Task: run a tina4.cmd / tina4.bat client with its arguments intact (Windows)

**Outcome:** `tina4ruby doctor|setup|deploy <args>` delivers every argument
verbatim to a batch-file `tina4` client on Windows, and no argument is ever run
as a command. Parity with tina4-nodejs#211 (`packages/core/src/batchSpawn.ts`)
and tina4-python (`tina4_python/core/batch_spawn.py`, branch
`fix/windows-test-portability`). Central tracker:
`tina4-documentation/plan/v3/windows-framework-bugs.md`.

## Scope
- [x] Measure the bug on Windows 11 / Ruby 3.3.10 x64-mingw-ucrt with a real `tina4.cmd`
- [x] Find a Ruby spawn form that hands CreateProcess the exact cmd.exe line (measured, see Bugs)
- [x] `Tina4::BatchSpawn` (`lib/tina4/batch_spawn.rb`): escaping + has_redirection port + spawn
- [x] `delegate_to_client` uses it; guard env var and exit-code propagation unchanged
- [x] Survey the other `system` / backtick / Open3 sites in `lib/tina4/` (reported in the PR)

## Parity
| Fix | Python | PHP | Ruby | Node |
|-----|--------|-----|------|------|
| batch client args verbatim | ✅ batch_spawn.py | ✅ proc_open array form already verbatim | ✅ this PR | ✅ #211 |

## Tests (real, no mocks)
- [x] `spec/cli_delegated_commands_spec.rb`: a real `tina4.cmd` + Ruby recorder on Windows (shell script elsewhere); hostile-arguments example, each argument alone and all at once, marker file must not appear
- [x] `spec/batch_spawn_spec.rb`: escaping vectors, has_redirection port, branch choice (pure functions, every platform)
- [x] Mutation 1 (plain `system`): 9 of 14 arguments mangled or executed, marker created 3 times
- [x] Mutation 2 (ignore has_redirection, always the direct form): the 2 wrapped-branch arguments fail, marker created

## Bugs
- [x] `100%PATH%` expanded, `a^b` lost its caret, `x|y` / `x&cd.>marker` ran a command, through a batch client
- [ ] dev-admin `deps_install` / `run_tests_payload` probe `command -v bundle`, which cmd.exe lacks, so Windows never uses bundler there (functional gap, reported, not fixed here)

## Commits
- b04bb3d  fix: run a tina4.cmd client with its arguments intact on Windows (PR #187)
- 32a7952  fix: linear argument quoting and a flatter has_redirection port (CodeQL rb/polynomial-redos + metrics gate)
- CI on 32a7952: all checks green; Linux test 7152 examples, 0 failures, 108 pending (v3 baseline 7139 / 108 pending: +13 new, no new skips)

## Status: In Review
